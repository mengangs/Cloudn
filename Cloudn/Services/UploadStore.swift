// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation
import UIKit

/// 上传队列：一次传一个（各网盘对并发上传都很敏感），离开页面也继续；切到后台借一段执行时间
@MainActor
@Observable
final class UploadStore {
    struct Item: Identifiable, Equatable {
        enum Status: Equatable { case waiting, running, done, failed(String), cancelled }

        let id = UUID()
        let file: URL
        let name: String
        let size: Int64
        let platform: SharePlatform
        let folderId: String
        /// 用完删除（相册导出的临时文件）
        let temporary: Bool
        /// 安全作用域（从「文件」选的）：上传期间保持访问
        let scoped: Bool
        var status: Status = .waiting
        var phase: UploadPhase = .hashing
        var fraction: Double = 0

        var isActive: Bool { status == .waiting || status == .running }
    }

    private(set) var items: [Item] = []
    /// 每完成一个就加一，「我的网盘」页据此刷新
    private(set) var finishedRevision = 0

    @ObservationIgnored private let resolvers: ShareResolvers
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var current: Task<Void, Error>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored var onMessage: ((String, Bool) -> Void)?
    /// 这一批已传完的文件名：队列全部结束时合并成一条提示，不逐个弹
    @ObservationIgnored private var uploadedNames: [String] = []

    init(resolvers: ShareResolvers) { self.resolvers = resolvers }

    func items(in platform: SharePlatform, folder: String) -> [Item] {
        items.filter { $0.platform == platform && $0.folderId == folder && $0.status != .done }
    }

    var activeCount: Int { items.filter(\.isActive).count }

    /// 加入队列；超过平台单文件上限的直接提示
    func enqueue(_ files: [(url: URL, temporary: Bool, scoped: Bool)], platform: SharePlatform, folderId: String) {
        guard let uploader = resolvers.uploader(for: platform) else {
            onMessage?("\(platform.displayName)暂不支持上传", true)
            // 相册导出的临时文件没人再用，删掉
            for f in files where f.temporary { try? FileManager.default.removeItem(at: f.url) }
            return
        }
        var added = 0
        for f in files {
            if f.scoped { _ = f.url.startAccessingSecurityScopedResource() }
            let size = FileChunks.size(of: f.url)
            if let limit = uploader.uploadSizeLimit, size > limit {
                onMessage?("「\(f.url.lastPathComponent)」超过单文件 \(ByteFormat.string(limit)) 上限", true)
                release(f.url, temporary: f.temporary, scoped: f.scoped)
                continue
            }
            items.append(Item(file: f.url, name: f.url.lastPathComponent, size: size, platform: platform, folderId: folderId,
                              temporary: f.temporary, scoped: f.scoped))
            added += 1
        }
        if added > 0 { onMessage?(added > 1 ? "已加入上传队列 · \(added) 个" : "已开始上传", false) }
        pump()
    }

    func cancel(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        // 正在传的由 run() 在取消后收尾；排队中的在这里放掉文件
        if items[i].status == .running { current?.cancel() } else if items[i].status == .waiting { release(items[i]) }
        items.remove(at: i)
    }

    func retry(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), case .failed = items[i].status else { return }
        if items[i].scoped { _ = items[i].file.startAccessingSecurityScopedResource() }
        items[i].status = .waiting
        items[i].fraction = 0
        pump()
    }

    func dismiss(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].isActive {
            cancel(id)
            return
        }
        let item = items.remove(at: i)
        // 失败后不再重试：相册导出的临时文件删掉（作用域在失败时已放掉，这里不再重复放）
        if case .failed = item.status { release(item.file, temporary: item.temporary, scoped: false) }
    }

    private func pump() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.items.first(where: { $0.status == .waiting }) {
                await self.run(next.id)
            }
            self?.worker = nil
            self?.reportUploaded()
            self?.endBackgroundTask()
        }
    }

    private func run(_ id: UUID) async {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        // 没有上传器也要改掉「等待」状态，否则 pump 会一直取到同一条、原地空转
        guard let uploader = resolvers.uploader(for: items[i].platform) else {
            items[i].status = .failed("暂不支持上传")
            return
        }
        let item = items[i]
        items[i].status = .running
        beginBackgroundTask()
        let progress = UploadProgress { [weak self] phase, fraction in
            Task { @MainActor in self?.update(id, phase: phase, fraction: fraction) }
        }
        let task = Task { try await uploader.upload(item.file, name: item.name, to: item.folderId, progress: progress) }
        current = task
        do {
            try await task.value
            set(id, .done)
            finishedRevision += 1
            Log.info("上传完成：\(item.name) → \(item.platform.displayName)")
            items.removeAll { $0.id == id }
            release(item)
            uploadedNames.append(item.name)
        } catch _ where !items.contains(where: { $0.id == id }) {
            // 用户取消（任务已从列表移除）：上传请求被取消时抛的多是 URLError.cancelled 而不是 CancellationError，
            // 不论抛的是什么都按取消收尾：放掉作用域、删掉临时文件
            release(item)
        } catch {
            // 还在列表里却被取消（系统中断）：按失败处理，留着可重试
            let message = Self.isCancellation(error) ? "上传被中断，请重试"
                : ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            Log.error("上传失败：\(item.name)：\(message)")
            set(id, .failed(message))
            // 失败的留着可重试；作用域先放掉，重试时再申请
            if item.scoped { item.file.stopAccessingSecurityScopedResource() }
        }
        current = nil
    }

    /// 队列跑完：这一批传完的合并成一条提示（失败的在列表里显示，不另弹）
    private func reportUploaded() {
        guard let first = uploadedNames.first else { return }
        onMessage?(uploadedNames.count > 1 ? "已上传 \(uploadedNames.count) 个文件" : "「\(first)」已上传", false)
        uploadedNames = []
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? URLError, e.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private func update(_ id: UUID, phase: UploadPhase, fraction: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].status == .running else { return }
        // 每读一块、每传一片都会回报：变化不到 1% 不改，免得整个列表跟着高频重绘
        guard phase != items[i].phase || (fraction >= 1 && items[i].fraction < 1) || abs(fraction - items[i].fraction) >= 0.01 else { return }
        items[i].phase = phase
        items[i].fraction = fraction
    }

    private func set(_ id: UUID, _ status: Item.Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    private func release(_ item: Item) { release(item.file, temporary: item.temporary, scoped: item.scoped) }

    private func release(_ url: URL, temporary: Bool, scoped: Bool) {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if temporary { try? FileManager.default.removeItem(at: url) }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        // 到期回调在主线程上同步调用，必须在它返回前结束后台任务，否则系统会直接杀掉应用；
        // 绕一道 Task 是异步的，来不及
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "uploads") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
