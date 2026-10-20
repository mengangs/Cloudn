// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 音视频分轨合并（iOS 端用 AVFoundation 实现）：输入视频轨、音轨文件，输出合并后的文件
public typealias TrackMerger = @Sendable (_ video: URL, _ audio: URL, _ output: URL) async throws -> Void

/// 下载引擎：任务排队与并发控制、断点续传、任务表持久化。
///
/// - 工作目录 `workDirectory/<id>/` 存放未完成数据；完成后移动到 `downloadsDirectory/<folder>/<文件名>`。
/// - 设置项通过闭包读取，修改后对下一个开始的任务即时生效。
public actor DownloadEngine {
    public nonisolated let downloadsDirectory: URL
    /// BT 元数据缓存（解析页取到的种子信息，开始下载时直接用）
    public nonisolated let torrentCacheDirectory: URL
    private let torrentNetwork: TorrentNetwork
    private let workDirectory: URL
    private let stateFile: URL
    private let settings: @Sendable () -> DownloadSettings
    private var merger: TrackMerger?
    private var onFinished: (@Sendable (DownloadItem) async -> Void)?
    private var onFailed: (@Sendable (DownloadItem) async -> Void)?

    private var items: [DownloadItem] = []
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var progress: [UUID: TransferProgress] = [:]
    private var lastBytes: [UUID: (Int64, Date)] = [:]
    /// 后台会话里各分片已收到、但还没写回数据文件的字节数（只用于显示进度）
    private var backgroundBytes: [UUID: [Int: Int64]] = [:]
    private var observers: [UUID: AsyncStream<[DownloadItem]>.Continuation] = [:]
    private var ticker: Task<Void, Never>?
    private var lastSave = Date.distantPast
    /// 应用即将被挂起：暂停的任务不应让排队任务顶上来
    private var suspended = false
    /// 每次开始运行分配一个编号；旧的运行（已被暂停 / 换链取消）结束时不能改动新一轮的状态
    private var runIds: [UUID: UUID] = [:]
    /// 回调还没配置好时完成的任务（后台会话唤醒时可能先于 configure 到达），配置后补发
    private var pendingFinished: [DownloadItem] = []
    private let limiter: RateLimiter
    private let streamer: StreamingSession
    private let client: HTTPClient

    public init(baseDirectory: URL, downloadsDirectory: URL, client: HTTPClient = .shared,
                torrentNetwork: TorrentNetwork = TorrentNetworks.system,
                settings: @escaping @Sendable () -> DownloadSettings) {
        self.downloadsDirectory = downloadsDirectory
        torrentCacheDirectory = baseDirectory.appendingPathComponent("torrents", isDirectory: true)
        self.torrentNetwork = torrentNetwork
        workDirectory = baseDirectory.appendingPathComponent("work", isDirectory: true)
        stateFile = baseDirectory.appendingPathComponent("downloads.json")
        self.settings = settings
        self.client = client
        let limiter = RateLimiter()
        self.limiter = limiter
        streamer = StreamingSession(limiter: limiter)
        let fm = FileManager.default
        try? fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateFile), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            // 上次进程被杀时仍在运行的任务恢复成暂停，由用户决定是否继续（直链可能已过期）；
            // 已交给系统后台会话的任务保持运行，等会话把结果送回来（或由 reconcileBackground 退回前台）
            items = saved.map { item in
                var copy = item
                if (copy.status == .running && !copy.backgrounded) || copy.status == .merging { copy.status = .paused }
                if copy.status != .running { copy.backgrounded = false }
                return copy
            }
        }
    }

    public func configure(merger: TrackMerger?, onFinished: (@Sendable (DownloadItem) async -> Void)?,
                          onFailed: (@Sendable (DownloadItem) async -> Void)? = nil) {
        self.merger = merger
        self.onFinished = onFinished
        self.onFailed = onFailed
        if let onFinished, !pendingFinished.isEmpty {
            let finished = pendingFinished
            pendingFinished = []
            Task { for item in finished { await onFinished(item) } }
        }
    }

    // MARK: 观察

    public func updates() -> AsyncStream<[DownloadItem]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[DownloadItem]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(items)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    public func snapshot() -> [DownloadItem] { items }

    private func publish() {
        for c in observers.values { c.yield(items) }
    }

    // MARK: 操作

    @discardableResult
    public func enqueue(_ request: DownloadRequest) -> UUID {
        let item = DownloadItem(request: request)
        items.insert(item, at: 0)
        changed()
        schedule()
        return item.id
    }

    public func pause(_ id: UUID) {
        pause([id])
    }

    /// 批量暂停：只落盘、发布一次
    public func pause(_ ids: [UUID]) {
        var touched = false
        for id in ids {
            guard let i = index(id), items[i].status.isActive else { continue }
            runners[id]?.cancel()
            runners[id] = nil
            runIds[id] = nil
            syncProgress(i)
            leaveBackground(i)
            items[i].status = .paused
            items[i].speed = 0
            touched = true
        }
        guard touched else { return }
        changed(force: true)
        schedule()
    }

    public func resume(_ id: UUID) {
        resume([id])
    }

    /// 批量继续（暂停的与失败的）：只落盘、发布一次
    public func resume(_ ids: [UUID]) {
        suspended = false
        var touched = false
        for id in ids {
            guard let i = index(id), items[i].status == .paused || items[i].status == .failed else { continue }
            items[i].status = .queued
            items[i].errorMessage = nil
            touched = true
        }
        guard touched else { return }
        changed(force: true)
        schedule()
    }

    /// 用新直链重新开始（直链过期后重新解析得到）
    public func restart(_ id: UUID, with request: DownloadRequest) {
        guard let i = index(id) else { return }
        runners[id]?.cancel()
        runners[id] = nil
        runIds[id] = nil
        try? FileManager.default.removeItem(at: workDir(id))
        leaveBackground(i)
        items[i].request = request
        items[i].chunks = []
        items[i].receivedBytes = 0
        items[i].totalBytes = request.expectedSize
        items[i].phase = 0
        items[i].segmentsDone = 0
        items[i].segmentsTotal = 0
        items[i].status = .queued
        items[i].errorMessage = nil
        progress[id] = nil
        changed(force: true)
        schedule()
    }

    /// 换一条新直链继续下载（同一文件重新取链，已下载的分片保留）。kind 不为空时一并替换（分轨视频的音轨直链也会过期）
    public func replaceLink(_ id: UUID, url: String, headers: [String: String], kind: DownloadKind? = nil) {
        guard let i = index(id), items[i].status != .completed else { return }
        runners[id]?.cancel()
        runners[id] = nil
        runIds[id] = nil
        syncProgress(i)
        leaveBackground(i)
        items[i].request.url = url
        items[i].request.headers = headers
        if let kind { items[i].request.kind = kind }
        // 其他账号的旧直链多半也过期了，换链后只用新链
        items[i].request.mirrors = nil
        items[i].status = .queued
        items[i].errorMessage = nil
        changed(force: true)
        schedule()
    }

    public func remove(_ id: UUID, deleteFile: Bool) {
        remove([id], deleteFile: deleteFile)
    }

    /// 批量删除：只落盘、发布一次
    public func remove(_ ids: [UUID], deleteFile: Bool) {
        let targets = Set(ids)
        guard items.contains(where: { targets.contains($0.id) }) else { return }
        let fm = FileManager.default
        for item in items where targets.contains(item.id) {
            runners[item.id]?.cancel()
            runners[item.id] = nil
            runIds[item.id] = nil
            progress[item.id] = nil
            backgroundBytes[item.id] = nil
            try? fm.removeItem(at: workDir(item.id))
            if deleteFile, let path = item.outputPath {
                try? fm.removeItem(at: downloadsDirectory.appendingPathComponent(path))
            }
        }
        items.removeAll { targets.contains($0.id) }
        changed(force: true)
        schedule()
    }

    public func pauseAll() {
        pause(items.filter(\.status.isActive).map(\.id))
    }

    /// 全部继续：暂停的与失败的都重新排队
    public func resumeAll() {
        resume(items.filter { $0.status == .paused || $0.status == .failed }.map(\.id))
    }

    public func clearFinished() {
        items.removeAll { $0.status == .completed }
        changed(force: true)
    }

    public nonisolated func fileURL(for item: DownloadItem) -> URL? {
        item.outputPath.map { downloadsDirectory.appendingPathComponent($0) }
    }

    // MARK: 调度

    private func schedule() {
        guard !suspended else { return }
        let limit = max(1, settings().maxConcurrentTasks)
        var running = items.filter { $0.status == .running || $0.status == .merging }.count
        // 队列按创建时间先进先出
        for item in items.reversed() where item.status == .queued {
            guard running < limit else { break }
            start(item.id)
            running += 1
        }
        ensureTicker()
    }

    private func start(_ id: UUID) {
        guard let i = index(id) else { return }
        Log.info("开始下载：\(items[i].request.fileName)（\(items[i].request.source)）\(items[i].request.url)")
        items[i].status = .running
        let item = items[i]
        // 每一轮用新的进度盒：上一轮被取消的连接可能还有回调在途，不能和这一轮记到同一个盒子里
        let box = TransferProgress(chunks: item.chunks, total: item.totalBytes)
        progress[id] = box
        lastBytes[id] = (box.received, Date())
        // 「运行中」重启后一律恢复成暂停，不必为它单独落盘
        changed()
        let config = settings()
        let run = UUID()
        runIds[id] = run
        runners[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.perform(item, box: box, config: config)
                if Task.isCancelled { return }
                await self.finish(id, output: output, run: run)
            } catch is CancellationError {
                // 暂停/删除：状态已由调用方设置
            } catch {
                if Task.isCancelled { return }
                await self.fail(id, error, run: run)
            }
        }
    }

    private nonisolated func perform(_ item: DownloadItem, box: TransferProgress, config: DownloadSettings) async throws -> URL {
        let dir = workDir(item.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let request = item.request
        limiter.setLimit(config.speedLimit)
        let connections = config.connections(for: request.source)
        switch request.kind {
        case .file:
            let target = dir.appendingPathComponent("data")
            try await RangeTransfer(url: request.url, headers: request.headers, destination: target, progress: box,
                                    connections: connections, retryCount: config.retryCount, streamer: streamer,
                                    mirrors: request.mirrors ?? []).run()
            return target
        case .hls:
            let result = try await HLSTransfer(url: request.url, headers: request.headers, workDir: dir.appendingPathComponent("hls"),
                                               progress: box, connections: connections, retryCount: config.retryCount,
                                               client: client, limiter: limiter).run()
            // TS：相册 / 文件 App 多数播不了，转封装成 MP4（独立音轨也是 TS 时一并合入）；转封装失败退回原 .ts
            if result.video.pathExtension == "ts" {
                let video = result.video
                let tsAudio: URL? = result.audio?.pathExtension == "ts" ? result.audio : nil
                let output = dir.appendingPathComponent("merged.mp4")
                do {
                    try await Task.detached(priority: .utility) {
                        try TSRemuxer.remux(video: video, audio: tsAudio, to: output)
                    }.value
                    return output
                } catch {
                    Log.error("TS 转 MP4 失败，保留原 TS：\(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: output)
                    return video
                }
            }
            // 独立音轨：两边都是 fMP4 时用 AVFoundation 无损合并
            guard let audio = result.audio, result.video.pathExtension == "mp4", audio.pathExtension == "mp4",
                  let merger = await currentMerger() else { return result.video }
            let output = dir.appendingPathComponent("merged.mp4")
            try? FileManager.default.removeItem(at: output)
            try await merger(result.video, audio, output)
            return output
        case .dash(let audioURL):
            let video = dir.appendingPathComponent("video.m4s")
            let audio = dir.appendingPathComponent("audio.m4s")
            if item.phase == 0 {
                try await RangeTransfer(url: request.url, headers: request.headers, destination: video, progress: box,
                                        connections: connections, retryCount: config.retryCount, streamer: streamer).run()
                await advancePhase(item.id, to: 1, box: box)
            }
            if await currentPhase(item.id) <= 1 {
                try await RangeTransfer(url: audioURL, headers: request.headers, destination: audio, progress: box,
                                        connections: connections, retryCount: config.retryCount, streamer: streamer).run()
                await advancePhase(item.id, to: 2, box: box)
            }
            guard let merger = await currentMerger() else { throw TransferError("当前平台不支持音视频合并") }
            let output = dir.appendingPathComponent("merged.mp4")
            try? FileManager.default.removeItem(at: output)
            try await merger(video, audio, output)
            return output
        case .torrent(let files):
            guard let magnet = MagnetLink.parse(request.url) else { throw TransferError("磁力链接无效") }
            return try await TorrentTransfer(magnet: magnet, selection: files, workDir: dir, cacheDir: torrentCacheDirectory, progress: box,
                                             network: torrentNetwork, client: client, limiter: limiter,
                                             extraTrackers: config.useExtraTrackers ? TorrentDefaults.publicTrackers : []).run()
        }
    }

    private func currentMerger() -> TrackMerger? { merger }
    private func currentPhase(_ id: UUID) -> Int { index(id).map { items[$0].phase } ?? 0 }

    private func advancePhase(_ id: UUID, to phase: Int, box: TransferProgress) {
        guard let i = index(id) else { return }
        items[i].phase = phase
        if phase == 2 { items[i].status = .merging }
        box.reset(chunks: [], total: -1)
        items[i].chunks = []
        items[i].receivedBytes = 0
        items[i].totalBytes = -1
        changed(force: true)
    }

    private func finish(_ id: UUID, output: URL, run: UUID? = nil) async {
        // 这一轮已被暂停 / 换链 / 重新开始取代：结果作废
        if let run, runIds[id] != run { return }
        guard let i = index(id) else { return }
        let request = items[i].request
        var name = FileNames.sanitize(request.fileName)
        if name.isEmpty { name = "download" }
        if case .hls = request.kind, output.pathExtension == "ts" {
            name = (name as NSString).deletingPathExtension + ".ts"
        }
        if case .torrent = request.kind {
            // 种子的产物名由元数据决定（单文件 = 文件名，多文件 = 目录名）
            name = FileNames.sanitize(output.lastPathComponent)
            if name.isEmpty { name = "download" }
        }
        let folder = FileNames.sanitizeRelativePath(request.folder) ?? ""
        let dir = folder.isEmpty ? downloadsDirectory : downloadsDirectory.appendingPathComponent(folder, isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = Self.uniqueURL(in: dir, name: name)
            try fm.moveItem(at: output, to: target)
            try? fm.removeItem(at: workDir(id))
            syncProgress(i)
            leaveBackground(i)
            items[i].status = .completed
            Log.info("下载完成：\(request.fileName)")
            items[i].finishedAt = Date()
            items[i].speed = 0
            let size = Self.size(of: target) ?? items[i].receivedBytes
            items[i].totalBytes = size
            items[i].receivedBytes = size
            items[i].chunks = []
            // 目录（多文件种子）以 / 结尾，界面据此按文件夹处理
            let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let leaf = target.lastPathComponent + (isDir ? "/" : "")
            items[i].outputPath = folder.isEmpty ? leaf : folder + "/" + leaf
            runners[id] = nil
            runIds[id] = nil
            progress[id] = nil
            changed(force: true)
            let done = items[i]
            schedule()
            // 完成后的收尾（清理临时转存、通知、存相册、移到外部文件夹）不阻塞引擎，也不拖住系统后台会话的回调
            if let onFinished {
                Task { await onFinished(done) }
            } else {
                pendingFinished.append(done)
            }
        } catch {
            fail(id, error)
        }
    }

    private func fail(_ id: UUID, _ error: Error, run: UUID? = nil) {
        if let run, runIds[id] != run { return }
        guard let i = index(id) else { return }
        syncProgress(i)
        leaveBackground(i)
        items[i].status = .failed
        items[i].speed = 0
        items[i].errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Log.error("下载失败：\(items[i].request.fileName)：\(items[i].errorMessage ?? "")（\(items[i].request.url)）")
        runners[id] = nil
        runIds[id] = nil
        changed(force: true)
        if let onFailed {
            let item = items[i]
            Task { await onFailed(item) }
        }
        schedule()
    }

    /// 文件大小；目录（多文件种子）为其中所有文件之和
    static func size(of url: URL) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value }
        var total: Int64 = 0
        let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = walker?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: 后台下载（系统后台会话）

    /// 应用退到后台：把运行中的单文件任务里没下完的分片交给系统后台会话，前台连接随即取消。
    /// m3u8 / 分轨任务不交出；还在探测阶段（没有分片计划）的任务留在前台。
    public func handOffToBackground() -> [BackgroundChunkJob] {
        var jobs: [BackgroundChunkJob] = []
        for i in items.indices where items[i].status == .running && !items[i].backgrounded {
            guard case .file = items[i].request.kind else { continue }
            let id = items[i].id
            syncProgress(i)
            let chunks = items[i].chunks
            let pending = chunks.indices.filter { !chunks[$0].isDone }
            guard !pending.isEmpty else { continue }
            runners[id]?.cancel()
            runners[id] = nil
            runIds[id] = nil
            let request = items[i].request
            for index in pending {
                let chunk = chunks[index]
                // 长度未知的流只能整文件重下
                let offset = chunk.end < 0 ? 0 : chunk.start + chunk.received
                jobs.append(BackgroundChunkJob(itemId: id, chunkIndex: index, url: request.url, headers: request.headers,
                                               offset: offset, end: chunk.end))
            }
            items[i].backgrounded = true
            items[i].speed = 0
        }
        if !jobs.isEmpty {
            Log.info("交给后台会话：\(Set(jobs.map(\.itemId)).count) 个任务、\(jobs.count) 个分片")
            changed(force: true)
        }
        return jobs
    }

    /// 系统后台会话下完一个分片：按偏移写回数据文件，全部分片完成后收尾。
    /// 返回 false 表示这份数据不可用（状态码不对、长度不足），调用方应按失败处理。
    @discardableResult
    public func applyBackgroundChunk(itemId: UUID, chunkIndex: Int, offset: Int64, status: Int, file: URL) async -> Bool {
        defer { try? FileManager.default.removeItem(at: file) }
        // 任务已被暂停 / 删除 / 退回前台：这份数据作废，但不算失败
        guard let i = index(itemId), items[i].backgrounded, items[i].status == .running,
              chunkIndex < items[i].chunks.count else { return true }
        var chunk = items[i].chunks[chunkIndex]
        let fm = FileManager.default
        let dest = workDir(itemId).appendingPathComponent("data")
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if chunk.end < 0 {
                guard (200..<300).contains(status), size > 0 else { return false }
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: file, to: dest)
                chunk = DownloadChunk(start: 0, end: size - 1, received: size)
                items[i].totalBytes = size
            } else {
                // 服务端忽略 Range 返回了整文件：只有从 0 开始的分片还能用
                guard status == 206 || (status == 200 && offset == 0) else { return false }
                let expected = chunk.end - offset + 1
                guard expected > 0, size >= expected else { return false }
                try Self.copy(file, into: dest, at: offset, length: expected)
                chunk.received = chunk.end - chunk.start + 1
            }
        } catch {
            return false
        }
        items[i].chunks[chunkIndex] = chunk
        backgroundBytes[itemId]?[chunkIndex] = nil
        progress[itemId] = TransferProgress(chunks: items[i].chunks, total: items[i].totalBytes)
        syncProgress(i)
        if items[i].chunks.allSatisfy(\.isDone) {
            await finish(itemId, output: dest)
        } else {
            changed(force: true)
        }
        return true
    }

    /// 后台会话的下载进度（只用于显示；数据写回前不改分片计划，失败时前台才能从正确位置续传）
    public func backgroundProgress(itemId: UUID, chunkIndex: Int, offset: Int64, written: Int64) {
        guard let i = index(itemId), items[i].backgrounded, chunkIndex < items[i].chunks.count else { return }
        let chunk = items[i].chunks[chunkIndex]
        // 偏移之前已落盘的部分已计入 chunk.received，这里只记新增
        let alreadyOnDisk = chunk.end < 0 ? 0 : offset - chunk.start - chunk.received
        backgroundBytes[itemId, default: [:]][chunkIndex] = max(0, written + alreadyOnDisk)
        syncProgress(i)
        changed()
    }

    /// 后台分片失败：任务退回前台引擎，从已写回数据文件的位置续传
    public func backgroundChunkFailed(itemId: UUID) {
        guard let i = index(itemId), items[i].backgrounded else { return }
        Log.error("后台分片失败，退回前台：\(items[i].request.fileName)")
        leaveBackground(i)
        items[i].status = .queued
        changed(force: true)
        schedule()
    }

    /// 启动时核对：标记为后台下载、但系统会话里已没有对应任务的（例如被用户强制退出），退回前台
    public func reconcileBackground(activeItemIds: Set<UUID>) {
        for item in items where item.backgrounded && !activeItemIds.contains(item.id) {
            backgroundChunkFailed(itemId: item.id)
        }
    }

    /// 完成的文件已被移到应用外的文件夹：记录去向，任务不再指向下载目录里的文件
    public func markExported(_ id: UUID, to location: String) {
        guard let i = index(id), items[i].status == .completed else { return }
        items[i].outputPath = nil
        items[i].exportedTo = location
        changed(force: true)
    }

    /// 应用即将被挂起：暂停仍在前台下载的任务（m3u8 / 分轨等无法交给后台会话的），返回它们的 id 供回到前台时继续
    public func pauseForegroundForSuspension() -> [UUID] {
        // 先挂起调度，暂停时排队的任务不会顶上来（挂起期间跑不完，下次启动还会变成「暂停」）
        suspended = true
        let ids = items.filter { $0.status == .running && !$0.backgrounded }.map(\.id)
        pause(ids)
        return ids
    }

    /// 当前仍由后台会话负责的任务
    public func backgroundedItemIds() -> Set<UUID> {
        Set(items.filter(\.backgrounded).map(\.id))
    }

    /// 回到前台：恢复调度（被挂起前暂停的任务由调用方另行继续）
    public func endSuspension() {
        guard suspended else { return }
        suspended = false
        schedule()
    }

    /// 结束后台状态：丢弃在途进度，进度盒按已落盘的分片计划重建
    private func leaveBackground(_ i: Int) {
        guard items[i].backgrounded else { return }
        let id = items[i].id
        items[i].backgrounded = false
        backgroundBytes[id] = nil
        progress[id] = TransferProgress(chunks: items[i].chunks, total: items[i].totalBytes)
        items[i].receivedBytes = items[i].chunks.reduce(0) { $0 + $1.received }
    }

    /// 把 source 的前 length 字节写入 dest 的 offset 处（1MB 一块，不整体读入内存）
    static func copy(_ source: URL, into dest: URL, at offset: Int64, length: Int64) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path) { _ = fm.createFile(atPath: dest.path, contents: nil) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        try output.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            guard let data = try input.read(upToCount: Int(min(remaining, 1 << 20))), !data.isEmpty else {
                throw TransferError("后台分片数据不完整")
            }
            try output.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
    }

    // MARK: 进度

    private func ensureTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if await !self.tick() { return }
            }
        }
    }

    /// 刷新进度与速度；没有活动任务时停止计时器
    private func tick() -> Bool {
        let now = Date()
        // 限速改动对进行中的任务即时生效
        limiter.setLimit(settings().speedLimit)
        var active = false
        for i in items.indices where items[i].status == .running || items[i].status == .merging {
            active = true
            let id = items[i].id
            syncProgress(i)
            if let (bytes, time) = lastBytes[id] {
                let dt = now.timeIntervalSince(time)
                if dt > 0 {
                    let instant = Double(max(0, items[i].receivedBytes - bytes)) / dt
                    items[i].speed = items[i].speed == 0 ? instant : items[i].speed * 0.6 + instant * 0.4
                }
            }
            lastBytes[id] = (items[i].receivedBytes, now)
        }
        if active {
            changed()
            // 「同时下载任务」调大后，排队中的任务不用等别的任务结束才开始
            let running = items.filter { $0.status == .running || $0.status == .merging }.count
            if !suspended, running < max(1, settings().maxConcurrentTasks), items.contains(where: { $0.status == .queued }) {
                schedule()
            }
        } else {
            ticker = nil
        }
        return active
    }

    private func syncProgress(_ i: Int) {
        if items[i].backgrounded {
            // 后台下载中：分片计划以已写回数据文件的为准，进度另加上会话里在途的字节
            let extra = backgroundBytes[items[i].id]?.values.reduce(0, +) ?? 0
            items[i].receivedBytes = items[i].chunks.reduce(0) { $0 + $1.received } + extra
            return
        }
        guard let box = progress[items[i].id] else { return }
        items[i].chunks = box.chunks
        items[i].receivedBytes = box.received
        let total = box.total
        if total > 0 { items[i].totalBytes = total }
        let peers = box.peers
        items[i].peers = peers.connected
        items[i].knownPeers = peers.known
        if let note = box.note { items[i].note = note }
        if let title = box.title, !title.isEmpty, items[i].request.fileName != title { items[i].request.fileName = title }
        let seg = box.segments
        if seg.total > 0 {
            items[i].segmentsDone = seg.done
            items[i].segmentsTotal = seg.total
        }
    }

    private func changed(force: Bool = false) {
        publish()
        let now = Date()
        if force || now.timeIntervalSince(lastSave) > 2 {
            lastSave = now
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: stateFile, options: [.atomic])
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex(where: { $0.id == id }) }
    private nonisolated func workDir(_ id: UUID) -> URL { workDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
}

// MARK: 导入本地文件

extension DownloadEngine {
    /// 把应用里已经生成好的本地文件（如网页嗅探录制的视频流）登记为一条已完成的下载：
    /// 文件移入下载目录（按 request 的文件名 / 文件夹，重名自动编号），走正常的完成回调（通知、存相册等）。
    /// 移动失败时不留下任务记录，错误抛给调用方。
    @discardableResult
    public func importFinishedFile(_ file: URL, request: DownloadRequest) async throws -> DownloadItem {
        var item = DownloadItem(request: request)
        // 不是 queued：调度器不会去下载它
        item.status = .merging
        items.insert(item, at: 0)
        await finish(item.id, output: file)
        guard let i = index(item.id) else { throw CloudnError("保存失败") }
        if items[i].status == .completed { return items[i] }
        let message = items[i].errorMessage ?? "保存失败"
        items.remove(at: i)
        changed(force: true)
        throw CloudnError(message)
    }
}
