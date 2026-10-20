// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation

/// 系统后台下载会话：应用退到后台时，单文件任务剩余的分片交给它继续下载（锁屏、进程被系统回收也不中断）。
/// 分片下完后按偏移写回引擎的数据文件；失败的任务退回前台引擎从已落盘的位置续传。
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

    init(engine: DownloadEngine, staging: URL) {
        self.engine = engine
        self.staging = staging
        super.init()
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
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

    /// 取消某个任务在会话里的全部分片（暂停、删除、换直链、失败退回前台时）
    func cancel(itemId: UUID) {
        session.getAllTasks { tasks in
            for task in tasks where BackgroundChunkJob.parse(taskDescription: task.taskDescription)?.itemId == itemId {
                task.cancel()
            }
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
        // 回调返回后系统会删除临时文件，必须在这里同步挪走
        let file = staging.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: file)
        } catch {
            fail(job.itemId)
            return
        }
        beginApply()
        Task { [engine] in
            let ok = await engine.applyBackgroundChunk(itemId: job.itemId, chunkIndex: job.chunkIndex, offset: job.offset,
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
        fail(job.itemId)
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
