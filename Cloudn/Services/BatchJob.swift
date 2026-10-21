// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

/// 批量解析下载：合集 / 播放列表的各条，或一次粘贴的多个链接。
/// 逐条解析（间隔一小会儿，避免触发平台风控），每条按默认选择（最高画质）加入下载，归到同一个下载分组。
/// 由 AppModel 持有：离开页面也会继续
@MainActor
@Observable
final class BatchJob: Identifiable {
    enum State: Equatable {
        case waiting, parsing
        /// 已加入下载的文件数
        case added(Int)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let url: String
        var state: State = .waiting
    }

    let id = UUID()
    let title: String
    private(set) var items: [Item]
    private(set) var running = false
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 每次开始 / 停止加一：停止后旧的那一轮可能还在收尾（等网络请求返回），它看到编号变了就不再改动状态，
    /// 「停止」后马上「继续」也不会出现两轮同时跑
    @ObservationIgnored private var runToken = 0
    @ObservationIgnored private let group: DownloadGroup

    init(title: String, entries: [(title: String, url: String)]) {
        self.title = title
        items = entries.map { Item(title: $0.title, url: $0.url) }
        group = DownloadGroup(title: title)
    }

    var doneCount: Int { items.filter { if case .added = $0.state { return true } else { return false } }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true } else { return false } }.count }
    var finished: Bool { !running && items.allSatisfy { $0.state != .waiting && $0.state != .parsing } }

    func start(app: AppModel) {
        guard !running else { return }
        running = true
        runToken += 1
        let token = runToken
        task = Task { [weak self] in
            await self?.run(app: app, token: token)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runToken += 1
        running = false
        for i in items.indices where items[i].state == .parsing { items[i].state = .waiting }
    }

    /// 把失败的重新排队再跑一遍
    func retryFailed(app: AppModel) {
        for i in items.indices {
            if case .failed = items[i].state { items[i].state = .waiting }
        }
        start(app: app)
    }

    private func run(app: AppModel, token: Int) async {
        defer { if token == runToken { running = false } }
        let folder = FileNames.base(title, fallback: "批量下载")
        var first = true
        for i in items.indices where items[i].state == .waiting {
            if Task.isCancelled || token != runToken { return }
            if !first { try? await Task.sleep(nanoseconds: 800_000_000) }
            first = false
            if Task.isCancelled || token != runToken { return }
            items[i].state = .parsing
            let state = await parse(items[i].url, app: app, folder: folder)
            // 已经停止（或换了新一轮）：这一条交给 cancel() 复位成等待，不再写回
            guard token == runToken else { return }
            items[i].state = state
        }
    }

    private func parse(_ url: String, app: AppModel, folder: String) async -> State {
        guard let link = VideoLinkParser.parse(url) else { return .failed("链接无法识别") }
        do {
            let result = try await app.videoService.parse(link)
            if Task.isCancelled { return .waiting }
            let medias = result.defaultDownloads
            guard !medias.isEmpty else {
                return .failed(result.entries.isEmpty ? "没有可下载的媒体" : "这也是一个合集，请单独打开")
            }
            // 已在下载列表里（正在下 / 已下完）的跳过：重复粘贴、停止后继续都不会重复入队
            let existing = Self.queuedKeys(app.downloads.items)
            for media in medias where !existing.contains(Self.key(url: media.url)) && !existing.contains(Self.key(page: result.url, file: media.fileName)) {
                app.downloads.enqueue(media: media, result: result, folder: folder, group: group)
            }
            return .added(medias.count)
        } catch is CancellationError {
            return .waiting
        } catch {
            if Task.isCancelled { return .waiting }
            return .failed(error.localizedDescription)
        }
    }

    /// 下载列表里没失败的任务：按直链、以及「作品页 + 文件名」（直链带签名，重新解析会变）各记一个键
    private static func queuedKeys(_ items: [DownloadItem]) -> Set<String> {
        var keys = Set<String>()
        for item in items where item.status != .failed {
            keys.insert(key(url: item.request.url))
            if case .video(let page, let file, _) = item.request.refresh, !page.isEmpty { keys.insert(key(page: page, file: file)) }
        }
        return keys
    }

    private static func key(url: String) -> String { "u|" + url }
    private static func key(page: String, file: String) -> String { page.isEmpty ? "" : "p|\(page)|\(file)" }
}

extension AppModel {
    /// 新建并开始一个批量任务
    @discardableResult
    func startBatch(title: String, entries: [(title: String, url: String)]) -> BatchJob {
        let job = BatchJob(title: title, entries: entries)
        batchJobs.append(job)
        job.start(app: self)
        show("开始批量解析 \(entries.count) 个")
        return job
    }

    /// 字幕：取回、统一转成 SRT，作为一条已完成的下载加进下载列表（文件在「文件」App 里与视频同一处）
    func saveSubtitle(_ track: SubtitleTrack, title: String, source: String, page: String) async throws -> String {
        let r = try await HTTPClient.shared.send(.get(track.url, headers: track.headers.map { ($0.key, $0.value) }))
        guard r.isSuccess else { throw CloudnError("字幕下载失败（HTTP \(r.status)）") }
        guard let srt = SubtitleConverter.toSRT(r.body, format: track.format) else { throw CloudnError("字幕格式无法识别") }
        let name = FileNames.base(title, fallback: "subtitle") + "." + (track.language.isEmpty ? "sub" : track.language) + ".srt"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        try srt.write(to: temp, options: .atomic)
        do {
            let item = try await downloads.importLocalFile(temp, name: name, source: source, page: page)
            return item.outputPath.map { ($0 as NSString).lastPathComponent } ?? name
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
