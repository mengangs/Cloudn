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
    /// 批量解析下载任务（合集 / 多链接）；离开页面也继续
    var batchJobs: [BatchJob] = []

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 后台时间快用完前提前暂停前台任务的计时
    @ObservationIgnored private var expiryWatch: Task<Void, Never>?
    /// 挂起前被暂停的前台任务（m3u8 / 分轨），回到前台时继续
    @ObservationIgnored private var suspendedIds: [UUID] = []
    /// 已自动重新取过链的任务（每个任务只自动换一次，避免反复失败反复换）
    @ObservationIgnored private var autoRefreshed = Set<UUID>()
    /// 实况照片已下完、另一半还在下载的一半：等另一半下完一起存成实况照片、再一起移到外部文件夹
    @ObservationIgnored private var heldLiveHalves: [UUID: DownloadItem] = [:]
    /// 已存成实况照片的配对（文件夹 + 图片名）：两半几乎同时下完时两边的回调都会去存，只存一次
    @ObservationIgnored private var savedLivePairs = Set<String>()

    init() {
        let fm = FileManager.default
        #if DEBUG
        // 截图模式（-CloudnScreenshot，仅 Debug 构建）：换成每次启动清空的临时目录并预置演示数据；正常启动为 nil。见 ScreenshotMode.swift
        let demo = ScreenshotMode.prepare()
        #else
        let demo: (support: URL, documents: URL)? = nil
        #endif
        let support = demo?.support ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cloudn", isDirectory: true)
        let documents = demo?.documents ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)

        Log.configure(file: support.appendingPathComponent("logs/cloudn.log"))
        settings = AppSettings()
        accounts = AccountStore()
        #if DEBUG
        // 截图模式：演示账号已读进内存，从钥匙串删掉（正常启动时无操作）
        if demo != nil { ScreenshotMode.accountsLoaded() }
        #endif
        bookmarks = BookmarkStore(directory: support)
        resolvers = ShareResolvers(credentials: accounts.vault, options: settings.resolverOptions)
        uploads = UploadStore(resolvers: resolvers)
        videoService = VideoParseService(credentials: accounts.vault, webExtractor: HeadlessWebExtractor())

        let snapshot = settings.snapshot
        // 被系统在后台拉起（投递后台下载事件）时不开前台下载：很快会被挂起，排队的单文件任务改交给后台会话
        let launchedInBackground = UIApplication.shared.applicationState == .background
        let engine = DownloadEngine(baseDirectory: support, downloadsDirectory: documents,
                                    launchedInBackground: launchedInBackground) { snapshot.get() }
        background = BackgroundTransfers(engine: engine, staging: support.appendingPathComponent("background", isDirectory: true))
        let transfers = background
        Task { await engine.setBackgroundSubmitter { [weak transfers] jobs in transfers?.submit(jobs) } }
        // 兜底：被系统在后台拉起、之后用户才打开应用时，场景的 .active 不一定会走到 scenePhaseChanged，
        // 应用一变成活跃就把引擎切回前台（重复调用无副作用）
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { transfers.cancel(itemIds: Set(await engine.enterForeground())) }
        }
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
        if notifiesInBackground { Notifier.downloadFailed(item.displayName, message: message.isEmpty ? "未知错误" : message) }
        // 实况照片的另一半下载失败：已下完的这一半不再等，单独存
        await releaseHeldLiveHalves()
    }

    /// 应用不在前台时发本地通知（包括被系统在后台唤醒、没有界面的时候）；多个任务的完成 / 失败合并成一条
    private var notifiesInBackground: Bool {
        UIApplication.shared.applicationState != .active && settings.notifyOnFinish
    }

    /// 实况照片的另一半还在下载（排队、下载中、暂停）：先不存，等另一半下完时一起存成实况照片。
    /// 读引擎的最新列表（界面镜像可能还没收到刚完成的状态）
    private func partnerPending(_ item: DownloadItem) async -> Bool {
        let names = Set(LivePhoto.partnerNames(for: item.request.fileName))
        guard !names.isEmpty else { return false }
        return await downloads.engine.snapshot().contains {
            $0.id != item.id && $0.request.folder == item.request.folder && names.contains($0.request.fileName)
                && $0.status != .completed && $0.status != .failed
        }
    }

    private func didFinish(_ item: DownloadItem) async {
        if notifiesInBackground { Notifier.downloadFinished(item.displayName) }
        guard let url = downloads.engine.fileURL(for: item) else { return }
        let wantsPhotos = settings.autoSaveToPhotos && MediaTools.canSaveToPhotos(url)
        if wantsPhotos, await partnerPending(item) {
            // 另一半还没下完：这一半先留在下载目录（不移到外部文件夹），否则配对时找不到它
            heldLiveHalves[item.id] = item
            await releaseHeldLiveHalves()
            return
        }
        // 已在等它的另一半：存成一张实况照片，再把两半都移走
        let partners = heldLiveHalves.values.filter {
            $0.request.folder == item.request.folder && LivePhoto.isPartner($0.request.fileName, of: item.request.fileName)
        }
        for partner in partners { heldLiveHalves[partner.id] = nil }
        if wantsPhotos {
            // 另一半在等它时，那一半的回调已经走完，不会再来存
            await saveToPhotos(item, file: url, partnerMayFollow: partners.isEmpty)
        }
        await exportIfNeeded(item, file: url)
        for partner in partners {
            if let file = downloads.engine.fileURL(for: partner) { await exportIfNeeded(partner, file: file) }
        }
        await releaseHeldLiveHalves()
    }

    /// 在等另一半的实况照片：另一半已不会再完成（下载失败、被删除）的，单独存相册、移到外部文件夹
    private func releaseHeldLiveHalves() async {
        for (id, held) in heldLiveHalves {
            // 中途可能已被另一半的完成回调取走
            guard heldLiveHalves[id] != nil else { continue }
            if await partnerPending(held) { continue }
            // 另一半刚下完、它的完成回调还没轮到：由那边一起存成实况照片
            let finishedAt = held.finishedAt ?? .distantPast
            let partnerJustDone = await downloads.engine.snapshot().contains {
                $0.status == .completed && $0.request.folder == held.request.folder
                    && LivePhoto.isPartner($0.request.fileName, of: held.request.fileName)
                    && ($0.finishedAt ?? .distantPast) >= finishedAt
            }
            if partnerJustDone || heldLiveHalves[id] == nil { continue }
            heldLiveHalves[id] = nil
            guard let url = downloads.engine.fileURL(for: held) else { continue }
            Log.info("实况照片的另一半没能下完，单独保存：\(held.displayName)")
            await saveToPhotos(held, file: url, partnerMayFollow: false)
            await exportIfNeeded(held, file: url)
        }
    }

    /// 自动存相册：实况照片的两半配对存一次（另一半的回调再来时跳过）。
    /// partnerMayFollow：另一半的完成回调可能还会来（两半几乎同时下完）
    private func saveToPhotos(_ item: DownloadItem, file: URL, partnerMayFollow: Bool) async {
        if let key = LivePhoto.pairKey(for: item.request.fileName).map({ item.request.folder + "/" + $0 }) {
            if savedLivePairs.remove(key) != nil {
                // 另一半已经把这一对存好了
                return
            }
            if partnerMayFollow, LivePhoto.pair(for: file) != nil { savedLivePairs.insert(key) }
        }
        do {
            try await MediaTools.saveToPhotosSmart(file)
        } catch {
            // 自动存相册在后台悄悄进行：提示里带上是哪一步出的错
            show("自动存相册失败：\(error.localizedDescription)", error: true)
        }
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
            show("自动下载失败，已打开分享页：\(error.localizedDescription)", error: true)
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
            Notifier.resetSummary()
            let ids = suspendedIds
            suspendedIds = []
            let sessions = background
            Task {
                // 交给后台会话的任务收回前台（已写回的段保留），多连接、限速重新生效；会话里没下完的段撤掉
                let reclaimed = await engine.enterForeground()
                sessions.cancel(itemIds: Set(reclaimed))
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
        // 运行中的单文件任务交给后台会话；之后排队的单文件任务也探测后陆续交过去，不再开前台下载
        let transfers = self.background
        Task { transfers.submit(await engine.enterBackground()) }
        guard downloads.activeCount > 0, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
            // 必须在回调返回前结束后台任务，否则系统会直接杀掉应用；暂停落盘由下面提前开始的计时完成
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        expiryWatch?.cancel()
        expiryWatch = Task { [weak self] in
            // 后台时间只剩几秒时提前暂停前台任务、干净落盘，再交还系统
            while !Task.isCancelled {
                let remaining = UIApplication.shared.backgroundTimeRemaining
                if remaining < 6 { break }
                try? await Task.sleep(nanoseconds: UInt64(min(remaining - 6, 5) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.suspendForegroundTransfers()
        }
    }

    /// 后台执行时间用完：暂停仍在前台下载的任务，干净落盘后再交还系统
    private func suspendForegroundTransfers() async {
        suspendedIds += await downloads.engine.pauseForegroundForSuspension()
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        expiryWatch?.cancel()
        expiryWatch = nil
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
