// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

/// 某个分享的下载情况
struct ShareDownloadProgress: Equatable {
    var done: Int
    var total: Int
}

/// 下载引擎的界面侧镜像。
/// 引擎每 0.5 秒推一次完整列表；只有真正需要进度的视图读 `items` / `shareFiles`，
/// 角标、解析页最近记录读的是只在数量变化时才更新的派生值，不会跟着进度一起重绘
@MainActor
@Observable
final class DownloadStore {
    private(set) var items: [DownloadItem] = []
    /// 进行中的任务数（标签角标）
    private(set) var activeCount = 0
    /// 「平台|分享 ID」→ 已完成 / 总数（解析页最近记录）
    private(set) var shareProgress: [String: ShareDownloadProgress] = [:]
    /// 分享链接 → 文件 ID → 该文件最近一次的下载任务（分享页行尾状态）
    private(set) var shareFiles: [String: [String: DownloadItem]] = [:]
    /// 分享链接 → 分享 ID 的解析缓存（链接解析是一串正则，不能每次进度刷新都跑）
    @ObservationIgnored private var shareIdCache: [String: String] = [:]
    @ObservationIgnored let engine: DownloadEngine
    @ObservationIgnored private let resolvers: ShareResolvers
    @ObservationIgnored private let videoService: VideoParseService
    @ObservationIgnored private let background: BackgroundTransfers
    @ObservationIgnored private let activity = DownloadActivity()
    /// 已移到外部文件夹的文件的位置（由 AppModel 提供，依赖设置里的文件夹书签）
    @ObservationIgnored var exportedURL: ((DownloadItem) -> URL?)?

    init(engine: DownloadEngine, resolvers: ShareResolvers, videoService: VideoParseService, background: BackgroundTransfers) {
        self.engine = engine
        self.resolvers = resolvers
        self.videoService = videoService
        self.background = background
        Task { [weak self] in
            for await list in await engine.updates() {
                self?.apply(list)
            }
        }
    }

    private func apply(_ list: [DownloadItem]) {
        items = list
        activity.update(with: list)

        let active = list.reduce(0) { $0 + ($1.status.isActive ? 1 : 0) }
        if active != activeCount { activeCount = active }

        var progress: [String: ShareDownloadProgress] = [:]
        var files: [String: [String: DownloadItem]] = [:]
        for item in list {
            guard let origin = item.request.origin else { continue }
            if let key = shareKey(platform: origin.platform, shareURL: origin.shareURL) {
                var p = progress[key] ?? ShareDownloadProgress(done: 0, total: 0)
                p.total += 1
                if item.status == .completed { p.done += 1 }
                progress[key] = p
            }
            // 同一文件下过多次时：已完成的不被之后失败的那次盖掉
            if let old = files[origin.shareURL]?[origin.fileId], old.status == .completed, item.status == .failed { continue }
            files[origin.shareURL, default: [:]][origin.fileId] = item
        }
        if progress != shareProgress { shareProgress = progress }
        shareFiles = files
    }

    /// 「平台|分享 ID」：同一分享的不同写法（带不带提取码、短链参数）归到一起
    func shareKey(platform: SharePlatform, shareURL: String) -> String? {
        if let id = shareIdCache[shareURL] { return platform.rawValue + "|" + id }
        guard let id = ShareLinkParser.parse(shareURL)?.shareId else { return nil }
        shareIdCache[shareURL] = id
        return platform.rawValue + "|" + id
    }

    func enqueue(_ request: DownloadRequest) {
        // 只有打开了「下载完成通知」才申请通知权限（权限弹窗也会让应用短暂进入 inactive）
        if UserDefaults.standard.bool(forKey: "notifyOnFinish") { Notifier.requestAuthorizationIfNeeded() }
        Task { await engine.enqueue(request) }
    }

    func enqueue(link: DownloadLink, platform: SharePlatform, folder: String, origin: ShareOrigin?, group: DownloadGroup? = nil, slot: Int = 0,
                 mirrors: [DownloadLink] = [], refresh: RefreshSource? = nil) {
        let kind: DownloadKind = link.url.contains(".m3u8") ? .hls : .file
        enqueue(DownloadRequest(
            url: link.url, headers: link.headers, fileName: link.fileName, folder: folder, kind: kind,
            expectedSize: link.size, source: platform.displayName,
            cleanup: link.cleanupToken.map { CleanupToken(platform: platform.rawValue, token: $0, slot: slot == 0 ? nil : slot) },
            origin: origin, group: group,
            mirrors: mirrors.isEmpty ? nil : mirrors.map { DownloadSource(url: $0.url, headers: $0.headers) },
            refresh: refresh))
    }

    func enqueue(media: VideoMedia, result: VideoParseResult, folder: String = "", group: DownloadGroup? = nil) {
        let kind: DownloadKind = !media.audioURL.isEmpty ? .dash(audioURL: media.audioURL) : (media.isHLS ? .hls : .file)
        // 记下作品页与这是第几个媒体：直链过期后重新解析作品页换链
        let index = result.medias.firstIndex { $0.id == media.id } ?? 0
        let refresh: RefreshSource? = result.url.isEmpty ? nil : .video(pageURL: result.url, fileName: media.fileName, index: index)
        enqueue(DownloadRequest(url: media.url, headers: media.headers, fileName: media.fileName, folder: folder, kind: kind,
                                expectedSize: media.size, source: result.platform.displayName, group: group, refresh: refresh))
    }

    // 交给后台会话的分片要一并撤掉，否则会在任务暂停 / 删除后继续占用流量
    func pause(_ item: DownloadItem) {
        background.cancel(itemId: item.id)
        Task { await engine.pause(item.id) }
    }
    func resume(_ item: DownloadItem) { Task { await engine.resume(item.id) } }
    func remove(_ item: DownloadItem, deleteFile: Bool) {
        remove([item], deleteFile: deleteFile)
    }
    func pauseAll() {
        for item in items where item.backgrounded { background.cancel(itemId: item.id) }
        Task { await engine.pauseAll() }
    }

    /// 批量操作：引擎只落盘、发布一次
    func pause(_ batch: [DownloadItem]) {
        for item in batch where item.backgrounded { background.cancel(itemId: item.id) }
        let ids = batch.map(\.id)
        Task { await engine.pause(ids) }
    }
    func resume(_ batch: [DownloadItem]) {
        let ids = batch.map(\.id)
        Task { await engine.resume(ids) }
    }
    func remove(_ batch: [DownloadItem], deleteFile: Bool) {
        for item in batch where item.backgrounded { background.cancel(itemId: item.id) }
        // 已移到外部文件夹的文件不在下载目录里，引擎删不到，这里删
        if deleteFile {
            for item in batch where item.exportedTo != nil {
                if let url = exportedURL?(item) { try? FileManager.default.removeItem(at: url) }
            }
        }
        let ids = batch.map(\.id)
        Task { await engine.remove(ids, deleteFile: deleteFile) }
    }
    func resumeAll() { Task { await engine.resumeAll() } }
    func clearFinished() { Task { await engine.clearFinished() } }
    /// 下载完成的文件：在下载目录里，或已移到外部文件夹
    func fileURL(_ item: DownloadItem) -> URL? { engine.fileURL(for: item) ?? exportedURL?(item) }

    /// 直链过期：按来源信息重新解析取链，保留已下载部分继续
    /// 直链过期：按来源（分享链接 / 我的网盘 / 作品页）重新取链，保留已下载部分继续
    func refreshLink(_ item: DownloadItem) async throws {
        if let origin = item.request.origin {
            guard let resolver = resolvers.resolver(for: origin.platform), let share = ShareLinkParser.parse(origin.shareURL) else {
                throw CloudnError("该任务没有可重新解析的来源，请回到解析页重新下载")
            }
            let session = try await resolver.openSession(share, pwd: origin.pwd)
            let link = try await resolver.downloadLink(session, file: origin.file)
            background.cancel(itemId: item.id)
            await engine.replaceLink(item.id, url: link.url, headers: link.headers)
            return
        }
        switch item.request.refresh {
        case .drive(let platform, let file):
            guard let manager = resolvers.manager(for: platform) else {
                throw CloudnError("\(platform.displayName)暂不支持重新取链，请到「我的网盘」重新下载")
            }
            let link = try await manager.driveDownloadLink(file.file)
            background.cancel(itemId: item.id)
            await engine.replaceLink(item.id, url: link.url, headers: link.headers)
        case .video(let pageURL, let fileName, let index):
            guard let detected = VideoLinkParser.parse(pageURL) else { throw CloudnError("作品链接无法识别，请回到解析页重新解析") }
            let result = try await videoService.parse(detected)
            // 先按文件名对上；文件名变了（标题被改）再按序号
            guard let media = result.medias.first(where: { $0.fileName == fileName })
                    ?? (index < result.medias.count ? result.medias[index] : nil) else {
                throw CloudnError("作品里已找不到这个文件，可能已被删除")
            }
            let kind: DownloadKind = !media.audioURL.isEmpty ? .dash(audioURL: media.audioURL) : (media.isHLS ? .hls : .file)
            background.cancel(itemId: item.id)
            await engine.replaceLink(item.id, url: media.url, headers: media.headers, kind: kind)
        case nil:
            throw CloudnError("该任务没有可重新解析的来源，请回到解析页重新下载")
        }
    }
}
