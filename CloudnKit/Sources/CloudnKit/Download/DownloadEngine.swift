// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 音视频分轨合并（iOS 端用 AVFoundation 实现）：输入视频轨、音轨文件，输出合并后的文件
public typealias TrackMerger = @Sendable (_ video: URL, _ audio: URL, _ output: URL) async throws -> Void

/// 下载引擎：任务排队与并发控制、断点续传、任务表持久化。
///
/// - 工作目录 `workDirectory/<id>/` 存放未完成数据；完成后移动到 `downloadsDirectory/<folder>/<文件名>`。
/// - 设置项通过闭包读取，修改后对下一个开始的任务即时生效。
public actor DownloadEngine {
    public let downloadsDirectory: URL
    private let workDirectory: URL
    private let stateFile: URL
    private let settings: @Sendable () -> DownloadSettings
    private var merger: TrackMerger?
    private var onFinished: (@Sendable (DownloadItem) async -> Void)?

    private var items: [DownloadItem] = []
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var progress: [UUID: TransferProgress] = [:]
    private var lastBytes: [UUID: (Int64, Date)] = [:]
    private var observers: [UUID: AsyncStream<[DownloadItem]>.Continuation] = [:]
    private var ticker: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private let streamer = StreamingSession()
    private let client: HTTPClient

    public init(baseDirectory: URL, downloadsDirectory: URL, client: HTTPClient = .shared,
                settings: @escaping @Sendable () -> DownloadSettings) {
        self.downloadsDirectory = downloadsDirectory
        workDirectory = baseDirectory.appendingPathComponent("work", isDirectory: true)
        stateFile = baseDirectory.appendingPathComponent("downloads.json")
        self.settings = settings
        self.client = client
        let fm = FileManager.default
        try? fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateFile), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            // 上次进程被杀时仍在运行的任务恢复成暂停，由用户决定是否继续（直链可能已过期）
            items = saved.map { item in
                var copy = item
                if copy.status == .running || copy.status == .merging { copy.status = .paused }
                return copy
            }
        }
    }

    public func configure(merger: TrackMerger?, onFinished: (@Sendable (DownloadItem) async -> Void)?) {
        self.merger = merger
        self.onFinished = onFinished
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
        guard let i = index(id), items[i].status.isActive else { return }
        runners[id]?.cancel()
        runners[id] = nil
        syncProgress(i)
        items[i].status = .paused
        items[i].speed = 0
        changed(force: true)
        schedule()
    }

    public func resume(_ id: UUID) {
        guard let i = index(id), items[i].status == .paused || items[i].status == .failed else { return }
        items[i].status = .queued
        items[i].errorMessage = nil
        changed(force: true)
        schedule()
    }

    /// 用新直链重新开始（直链过期后重新解析得到）
    public func restart(_ id: UUID, with request: DownloadRequest) {
        guard let i = index(id) else { return }
        runners[id]?.cancel()
        runners[id] = nil
        try? FileManager.default.removeItem(at: workDir(id))
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

    /// 换一条新直链继续下载（同一文件重新取链，已下载的分片保留）
    public func replaceLink(_ id: UUID, url: String, headers: [String: String]) {
        guard let i = index(id), items[i].status != .completed else { return }
        runners[id]?.cancel()
        runners[id] = nil
        syncProgress(i)
        items[i].request.url = url
        items[i].request.headers = headers
        items[i].status = .queued
        items[i].errorMessage = nil
        changed(force: true)
        schedule()
    }

    public func remove(_ id: UUID, deleteFile: Bool) {
        guard let i = index(id) else { return }
        runners[id]?.cancel()
        runners[id] = nil
        progress[id] = nil
        try? FileManager.default.removeItem(at: workDir(id))
        if deleteFile, let path = items[i].outputPath {
            try? FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent(path))
        }
        items.remove(at: i)
        changed(force: true)
        schedule()
    }

    public func pauseAll() {
        for item in items where item.status.isActive { pause(item.id) }
    }

    public func resumeAll() {
        for item in items where item.status == .paused { resume(item.id) }
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
        items[i].status = .running
        let item = items[i]
        let box = progress[id] ?? TransferProgress(chunks: item.chunks, total: item.totalBytes)
        progress[id] = box
        lastBytes[id] = (box.received, Date())
        changed(force: true)
        let config = settings()
        runners[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.perform(item, box: box, config: config)
                await self.finish(id, output: output)
            } catch is CancellationError {
                // 暂停/删除：状态已由调用方设置
            } catch {
                if Task.isCancelled { return }
                await self.fail(id, error)
            }
        }
    }

    private nonisolated func perform(_ item: DownloadItem, box: TransferProgress, config: DownloadSettings) async throws -> URL {
        let dir = workDir(item.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let request = item.request
        switch request.kind {
        case .file:
            let target = dir.appendingPathComponent("data")
            try await RangeTransfer(url: request.url, headers: request.headers, destination: target, progress: box,
                                    connections: config.connectionsPerTask, retryCount: config.retryCount, streamer: streamer).run()
            return target
        case .hls:
            return try await HLSTransfer(url: request.url, headers: request.headers, workDir: dir.appendingPathComponent("hls"),
                                         progress: box, connections: config.connectionsPerTask, retryCount: config.retryCount,
                                         client: client).run()
        case .dash(let audioURL):
            let video = dir.appendingPathComponent("video.m4s")
            let audio = dir.appendingPathComponent("audio.m4s")
            if item.phase == 0 {
                try await RangeTransfer(url: request.url, headers: request.headers, destination: video, progress: box,
                                        connections: config.connectionsPerTask, retryCount: config.retryCount, streamer: streamer).run()
                await advancePhase(item.id, to: 1, box: box)
            }
            if await currentPhase(item.id) <= 1 {
                try await RangeTransfer(url: audioURL, headers: request.headers, destination: audio, progress: box,
                                        connections: config.connectionsPerTask, retryCount: config.retryCount, streamer: streamer).run()
                await advancePhase(item.id, to: 2, box: box)
            }
            guard let merger = await currentMerger() else { throw TransferError("当前平台不支持音视频合并") }
            let output = dir.appendingPathComponent("merged.mp4")
            try? FileManager.default.removeItem(at: output)
            try await merger(video, audio, output)
            return output
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

    private func finish(_ id: UUID, output: URL) async {
        guard let i = index(id) else { return }
        let request = items[i].request
        var name = FileNames.sanitize(request.fileName)
        if name.isEmpty { name = "download" }
        if case .hls = request.kind, output.pathExtension == "ts" {
            name = (name as NSString).deletingPathExtension + ".ts"
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
            items[i].status = .completed
            items[i].finishedAt = Date()
            items[i].speed = 0
            let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? items[i].receivedBytes
            items[i].totalBytes = size
            items[i].receivedBytes = size
            items[i].chunks = []
            items[i].outputPath = folder.isEmpty ? target.lastPathComponent : folder + "/" + target.lastPathComponent
            runners[id] = nil
            progress[id] = nil
            changed(force: true)
            let done = items[i]
            schedule()
            await onFinished?(done)
        } catch {
            fail(id, error)
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        guard let i = index(id) else { return }
        syncProgress(i)
        items[i].status = .failed
        items[i].speed = 0
        items[i].errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        runners[id] = nil
        changed(force: true)
        schedule()
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
        } else {
            ticker = nil
        }
        return active
    }

    private func syncProgress(_ i: Int) {
        guard let box = progress[items[i].id] else { return }
        items[i].chunks = box.chunks
        items[i].receivedBytes = box.received
        let total = box.total
        if total > 0 { items[i].totalBytes = total }
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
