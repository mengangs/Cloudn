// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation
import SwiftUI
import UIKit

enum AppTab: Hashable { case resolve, downloads, me }

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var isError = false
}

/// 全局状态与依赖装配（单例，手工注入到各页面）
@MainActor
@Observable
final class AppModel {
    /// 系统可能在后台拉起应用投递下载事件（此时不创建界面），所以由 AppDelegate 与界面共用同一个实例
    static let shared = AppModel()

    let settings: AppSettings
    let accounts: AccountStore
    let bookmarks: BookmarkStore
    let downloads: DownloadStore
    let uploads: UploadStore
    let torrents: TorrentFetchStore
    @ObservationIgnored let resolvers: ShareResolvers
    @ObservationIgnored let videoService: VideoParseService
    @ObservationIgnored let background: BackgroundTransfers

    var selectedTab: AppTab = .resolve
    var toast: Toast?
    /// 外部（URL Scheme / 分享）送进来的待解析文本
    var pendingInput: String?
    /// 外部打开 / 导入的种子文件（解析页接手）
    var pendingTorrent: TorrentTarget?
    /// 自动检查发现的新版本（弹窗提示）
    var availableUpdate: AppRelease?

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 挂起前被暂停的前台任务（m3u8 / 分轨），回到前台时继续
    @ObservationIgnored private var suspendedIds: [UUID] = []
    /// 已自动重新取过链的任务（每个任务只自动换一次，避免反复失败反复换）
    @ObservationIgnored private var autoRefreshed = Set<UUID>()

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cloudn", isDirectory: true)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)

        Log.configure(file: support.appendingPathComponent("logs/cloudn.log"))
        settings = AppSettings()
        accounts = AccountStore()
        bookmarks = BookmarkStore(directory: support)
        resolvers = ShareResolvers(credentials: accounts.vault, options: settings.resolverOptions)
        uploads = UploadStore(resolvers: resolvers)
        videoService = VideoParseService(credentials: accounts.vault, webExtractor: HeadlessWebExtractor())

        let snapshot = settings.snapshot
        let engine = DownloadEngine(baseDirectory: support, downloadsDirectory: documents) { snapshot.get() }
        background = BackgroundTransfers(engine: engine, staging: support.appendingPathComponent("background", isDirectory: true))
        downloads = DownloadStore(engine: engine, resolvers: resolvers, videoService: videoService, background: background)
        torrents = TorrentFetchStore(cacheDirectory: engine.torrentCacheDirectory,
                                     extraTrackers: { [settings] in settings.useExtraTrackers ? TorrentDefaults.publicTrackers : [] })
        background.reconcile()

        let resolvers = self.resolvers
        let onFinished: @Sendable (DownloadItem) async -> Void = { [weak self] item in
            // 夸克兜底转存产生的临时目录：下载完成后删除
            if let cleanup = item.request.cleanup, let platform = SharePlatform(rawValue: cleanup.platform) {
                await AccountSlot.$current.withValue(cleanup.slot ?? 0) {
                    await resolvers.resolver(for: platform)?.cleanup(token: cleanup.token)
                }
            }
            await self?.didFinish(item)
        }
        let onFailed: @Sendable (DownloadItem) async -> Void = { [weak self] item in
            await self?.didFail(item)
        }
        Task { await engine.configure(merger: MediaTools.merger, onFinished: onFinished, onFailed: onFailed) }
        let settings = self.settings
        downloads.exportedURL = { settings.exportedFileURL($0) }
        uploads.onMessage = { [weak self] message, isError in self?.show(message, error: isError) }
    }

    /// 下载失败：像是直链过期（403 / 404 / 410 / 412）且能重新取链的，自动换链继续一次；仍失败才通知
    private func didFail(_ item: DownloadItem) async {
        let message = item.errorMessage ?? ""
        let expired = ["HTTP 403", "HTTP 404", "HTTP 410", "HTTP 412"].contains { message.hasPrefix($0) }
        if expired, item.request.canRefresh, !autoRefreshed.contains(item.id) {
            autoRefreshed.insert(item.id)
            do {
                try await downloads.refreshLink(item)
                Log.info("直链过期，已自动重新取链：\(item.displayName)")
                return
            } catch {
                Log.error("自动重新取链失败：\(item.displayName)：\(error.localizedDescription)")
            }
        }
        notify(title: "下载失败", body: "\(item.displayName)：\(message.isEmpty ? "未知错误" : message)")
    }

    /// 应用不在前台时发本地通知（包括被系统在后台唤醒、没有界面的时候）
    private func notify(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active, settings.notifyOnFinish else { return }
        Notifier.post(title: title, body: body)
    }

    private func didFinish(_ item: DownloadItem) async {
        notify(title: "下载完成", body: item.displayName)
        guard let url = downloads.engine.fileURL(for: item) else { return }
        if settings.autoSaveToPhotos, MediaTools.canSaveToPhotos(url) {
            do {
                try await MediaTools.saveToPhotos(url)
            } catch {
                show(error.localizedDescription, error: true)
            }
        }
        await exportIfNeeded(item, file: url)
    }

    /// 设置了「完成后移动到」时，把文件（保留子目录）移到所选文件夹
    private func exportIfNeeded(_ item: DownloadItem, file: URL) async {
        guard let folder = settings.exportFolder else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let sub = (item.outputPath as NSString?)?.deletingLastPathComponent ?? ""
        let dir = sub.isEmpty ? folder : folder.appendingPathComponent(sub, isDirectory: true)
        do {
            // 大文件跨卷复制可能要几十秒，放到后台线程，不卡界面
            let target = try await Task.detached(priority: .utility) { () throws -> URL in
                let fm = FileManager.default
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var target = dir.appendingPathComponent(file.lastPathComponent)
                var n = 1
                let base = (file.lastPathComponent as NSString).deletingPathExtension
                let ext = file.pathExtension
                while fm.fileExists(atPath: target.path) {
                    target = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
                    n += 1
                }
                // 跨卷（如 iCloud 云盘）不能直接 move，先复制再删
                try fm.copyItem(at: file, to: target)
                try? fm.removeItem(at: file)
                return target
            }.value
            let location = folder.lastPathComponent + (sub.isEmpty ? "" : "/" + sub) + "/" + target.lastPathComponent
            await downloads.engine.markExported(item.id, to: location)
        } catch {
            show("移动到所选文件夹失败：\(error.localizedDescription)", error: true)
        }
    }

    /// 网盘更新：打开发布说明里的网盘分享，找到最大的 .ipa 直接下载；做不到（要登录、要验证、没有安装包）就打开分享页让用户自己选
    func startUpdateDownload(_ share: ParsedShare) async {
        do {
            guard let resolver = resolvers.resolver(for: share.platform) else { throw CloudnError("暂不支持\(share.platform.displayName)") }
            let session = try await resolver.openSession(share, pwd: share.pwd)
            guard let file = try await UpdatePackage.findPackage(resolver: resolver, session: session) else {
                throw CloudnError("分享里没有找到 .ipa 安装包")
            }
            let link = try await resolver.downloadLink(session, file: file)
            downloads.enqueue(link: link, platform: share.platform, folder: "",
                              origin: ShareOrigin(platform: share.platform, shareURL: share.url, pwd: share.pwd ?? "", file: file))
            selectedTab = .downloads
            show("已开始下载 \(file.name)")
        } catch {
            var text = share.url
            if let pwd = share.pwd, !pwd.isEmpty, ShareLinkParser.parse(text)?.pwd != pwd { text += " 提取码：\(pwd)" }
            pendingInput = text
            selectedTab = .resolve
            show("没能自动下载：\(error.localizedDescription)，已打开分享页", error: true)
        }
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// 启动 / 回到前台时的自动检查：每天最多一次，跳过用户忽略的版本，失败静默
    func autoCheckForUpdates() {
        guard settings.autoCheckUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        settings.lastUpdateCheck = Date()
        Task {
            guard let release = try? await UpdateChecker.check(current: Self.currentVersion, includePrerelease: settings.acceptPrerelease),
                  release.tag != settings.skippedVersion else { return }
            availableUpdate = release
        }
    }

    func show(_ message: String, error: Bool = false) {
        if error { Log.error(message) }
        toast = Toast(message: message, isError: error)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// 打开外部传入的链接：cloudn://resolve?text=...
    func handle(url: URL) {
        if url.isFileURL {
            if url.pathExtension.lowercased() == "torrent" { openTorrentFile(url) }
            return
        }
        guard url.scheme == "cloudn", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let text = comps.queryItems?.first(where: { $0.name == "text" || $0.name == "url" })?.value, !text.isEmpty {
            pendingInput = text
            selectedTab = .resolve
        }
    }

    /// 读种子文件：元数据直接进缓存，解析页列出文件（不用再向节点要）
    func openTorrentFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let (info, trackers) = try TorrentInfo.parse(torrentFile: try Data(contentsOf: url))
            TorrentMetadataCache.save(info, in: downloads.engine.torrentCacheDirectory)
            pendingTorrent = TorrentTarget(magnet: MagnetLink(infoHash: info.infoHash, displayName: info.name, trackers: trackers))
            selectedTab = .resolve
        } catch {
            show("无法打开种子文件：\(error.localizedDescription)", error: true)
        }
    }

    /// 进入后台：单文件任务剩余分片交给系统后台会话；其余任务借一段后台执行时间，到期前暂停、回到前台再继续。
    /// 只在真正进入后台时交出：下拉通知中心 / 控制中心、系统弹窗只是 inactive，交出去会白白断掉前台的多连接下载
    func scenePhaseChanged(_ phase: ScenePhase) {
        let engine = downloads.engine
        switch phase {
        case .active:
            autoCheckForUpdates()
            endBackgroundTask()
            let ids = suspendedIds
            suspendedIds = []
            Task {
                await engine.endSuspension()
                if !ids.isEmpty { await engine.resume(ids) }
            }
            return
        case .background:
            QuickActions.refresh(self)
            downloads.enterBackground()
        default:
            return
        }
        guard downloads.activeCount > 0, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
            Task { @MainActor in await self?.suspendForegroundTransfers() }
        }
        let transfers = self.background
        Task { transfers.submit(await engine.handOffToBackground()) }
    }

    /// 后台执行时间用完：暂停仍在前台下载的任务，干净落盘后再交还系统
    private func suspendForegroundTransfers() async {
        suspendedIds += await downloads.engine.pauseForegroundForSuspension()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
