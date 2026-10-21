// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation

/// 系统后台下载会话：应用退到后台时，单文件任务剩余的部分切成小段（≤32MB）交给它继续下载（锁屏、进程被系统回收也不中断）。
/// 每段下完就按偏移写回引擎的数据文件；某段因网络问题失败时在后台从这一段的起点重试两次，
/// 仍失败（或服务器拒绝）才把任务退回前台引擎，从已写回的位置续传（已写回的段都保留）。
///
/// 没有用 resume data 续传失败的段：我们的请求自带 Range 头，系统续传时如何改写 Range 没有文档保证，
/// 拼错了位置会悄悄写坏文件；段已经切得很小，从段起点重下的代价有限。
final class BackgroundTransfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "com.mengangs.Cloudn.background"

    private let engine: DownloadEngine
    private let staging: URL
    private var session: URLSession!
    private let lock = NSLock()
    /// 系统唤醒应用处理会话事件时交来的回调：所有分片写回完成后才能调用，否则应用可能在拷贝途中被挂起
    private var systemCompletion: (() -> Void)?
    private var eventsFinished = false
    private var pendingApplies = 0
    private var lastProgress: [Int: Date] = [:]
    /// 各段（按 taskDescription）在后台已重试的次数
    private var retries: [String: Int] = [:]
    static let maxRetries = 2

    init(engine: DownloadEngine, staging: URL) {
        self.engine = engine
        self.staging = staging
        super.init()
        let fm = FileManager.default
        // 上个进程挪到暂存目录、还没来得及写回就被杀掉的分段：没有任务会再引用它们，会话建好之前清掉
        if let leftovers = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil), !leftovers.isEmpty {
            Log.info("清理后台下载暂存文件：\(leftovers.count) 个")
            for file in leftovers { try? fm.removeItem(at: file) }
        }
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // 与 HTTPClient 一致：Cookie 由各网盘显式放进请求头，不让系统 Cookie 罐混进来
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 16
        // 后台会话的配置创建后改不了：代理以应用启动时的设置为准
        NetworkProxy.apply(to: config)
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func submit(_ jobs: [BackgroundChunkJob]) {
        for job in jobs {
            guard let url = URL(string: job.url) else { continue }
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            for (k, v) in job.headers { request.setValue(v, forHTTPHeaderField: k) }
            if let range = job.rangeHeader { request.setValue(range, forHTTPHeaderField: "Range") }
            let task = session.downloadTask(with: request)
            task.taskDescription = job.taskDescription
            task.resume()
        }
    }

    /// 取消某个任务在会话里的全部分片（暂停、删除、换直链、失败退回前台时）。已下完、写回了的段不受影响
    func cancel(itemId: UUID) {
        cancel(itemIds: [itemId])
    }

    /// 批量取消（回到前台收回多个任务时）
    func cancel(itemIds: Set<UUID>) {
        guard !itemIds.isEmpty else { return }
        session.getAllTasks { [weak self] tasks in
            var cancelled: [String] = []
            for task in tasks {
                guard let id = BackgroundChunkJob.parse(taskDescription: task.taskDescription)?.itemId, itemIds.contains(id) else { continue }
                task.cancel()
                if let d = task.taskDescription { cancelled.append(d) }
            }
            guard let self else { return }
            self.lock.lock()
            for d in cancelled { self.retries[d] = nil }
            self.lock.unlock()
        }
    }

    /// 启动时核对：标记为后台下载、但会话里已没有对应分片的任务退回前台
    func reconcile() {
        session.getAllTasks { [engine] tasks in
            let active = Set(tasks.compactMap { BackgroundChunkJob.parse(taskDescription: $0.taskDescription)?.itemId })
            Task { await engine.reconcileBackground(activeItemIds: active) }
        }
    }

    func setSystemCompletion(_ handler: @escaping () -> Void) {
        lock.lock()
        systemCompletion = handler
        lock.unlock()
        // 会话事件可能在交来回调之前就已处理完（会话在应用初始化时就建好了），这里补一次
        callSystemCompletionIfIdle()
    }

    // MARK: URLSessionDownloadDelegate

    /// 跳到别的主机时去掉 Authorization（GitHub 私有附件 302 到已签名的存储地址，带着 Token 会被拒）
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let newHost = request.url?.host?.lowercased(), newHost != task.originalRequest?.url?.host?.lowercased(),
              request.value(forHTTPHeaderField: "Authorization") != nil else {
            completionHandler(request)
            return
        }
        var copy = request
        copy.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(copy)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = BackgroundChunkJob.parse(taskDescription: downloadTask.taskDescription) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // 408 / 429 / 5xx：服务器一时忙不过来，这一段在后台重下（403 / 404 等直链失效的才退回前台重新取链）
        if Self.isRetryable(status: status), retryLater(downloadTask, reason: "HTTP \(status)") { return }
        // 回调返回后系统会删除临时文件，必须在这里同步挪走
        let file = staging.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: file)
        } catch {
            fail(job.itemId)
            return
        }
        beginApply()
        lock.lock()
        retries[downloadTask.taskDescription ?? ""] = nil
        lock.unlock()
        Task { [engine] in
            let ok = await engine.applyBackgroundChunk(itemId: job.itemId, chunkIndex: job.chunkIndex, offset: job.offset, end: job.end,
                                                       status: status, file: file)
            if !ok { self.fail(job.itemId) }
            self.endApply()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = BackgroundChunkJob.parse(taskDescription: downloadTask.taskDescription) else { return }
        // 进度只用于显示，半秒报一次
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastProgress[downloadTask.taskIdentifier] ?? .distantPast) > 0.5
        if due { lastProgress[downloadTask.taskIdentifier] = now }
        lock.unlock()
        guard due else { return }
        Task { [engine] in
            await engine.backgroundProgress(itemId: job.itemId, chunkIndex: job.chunkIndex, offset: job.offset, written: totalBytesWritten)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        lastProgress[task.taskIdentifier] = nil
        lock.unlock()
        guard let error, let job = BackgroundChunkJob.parse(taskDescription: task.taskDescription) else { return }
        // 我们自己取消的（暂停 / 删除 / 退回前台）不算失败
        if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled { return }
        // 网络问题：这一段从它自己的起点在后台重下，其余段不受影响
        if Self.isTransient(error), retryLater(task, reason: error.localizedDescription) { return }
        Log.error("后台分段失败：\(error.localizedDescription)")
        fail(job.itemId)
    }

    /// 这一段按原请求（同一 Range）在后台重新下载；超过次数返回 false，由调用方按失败处理
    private func retryLater(_ task: URLSessionTask, reason: String) -> Bool {
        guard let request = task.originalRequest, let description = task.taskDescription else { return false }
        lock.lock()
        let attempt = (retries[description] ?? 0) + 1
        let retry = attempt <= Self.maxRetries
        retries[description] = retry ? attempt : nil
        lock.unlock()
        guard retry else { return false }
        Log.info("后台分段出错（\(reason)），第 \(attempt) 次重试")
        let again = session.downloadTask(with: request)
        again.taskDescription = description
        // 稍等一会儿再开始，别立刻撞上同一个问题
        again.earliestBeginDate = Date().addingTimeInterval(Double(attempt) * 5)
        again.resume()
        return true
    }

    static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    /// 换个时间再试多半能好的网络错误
    static func isTransient(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        let transient: [URLError.Code] = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                                          .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
                                          .callIsActive, .backgroundSessionWasDisconnected, .secureConnectionFailed]
        return transient.contains(code)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        eventsFinished = true
        lock.unlock()
        callSystemCompletionIfIdle()
    }

    // MARK: 内部

    /// 任何一个分片失败，整个任务退回前台续传，并撤掉它在会话里的其余分片
    private func fail(_ itemId: UUID) {
        cancel(itemId: itemId)
        beginApply()
        Task { [engine] in
            await engine.backgroundChunkFailed(itemId: itemId)
            self.endApply()
        }
    }

    private func beginApply() {
        lock.lock()
        pendingApplies += 1
        lock.unlock()
    }

    private func endApply() {
        lock.lock()
        pendingApplies -= 1
        lock.unlock()
        callSystemCompletionIfIdle()
    }

    private func callSystemCompletionIfIdle() {
        lock.lock()
        guard eventsFinished, pendingApplies == 0, let completion = systemCompletion else {
            lock.unlock()
            return
        }
        systemCompletion = nil
        eventsFinished = false
        lock.unlock()
        DispatchQueue.main.async { completion() }
    }
}
