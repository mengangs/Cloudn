// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation
import UIKit

enum AppTab: Hashable { case resolve, accounts, downloads, settings }

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
    @ObservationIgnored let resolvers: ShareResolvers
    @ObservationIgnored let videoService: VideoParseService
    @ObservationIgnored let background: BackgroundTransfers

    var selectedTab: AppTab = .resolve
    var toast: Toast?
    /// 外部（URL Scheme / 分享）送进来的待解析文本
    var pendingInput: String?
    /// 自动检查发现的新版本（弹窗提示）
    var availableUpdate: AppRelease?

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 挂起前被暂停的前台任务（m3u8 / 分轨），回到前台时继续
    @ObservationIgnored private var suspendedIds: [UUID] = []
    @ObservationIgnored private var isActive = true

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
        videoService = VideoParseService(credentials: accounts.vault, webExtractor: HeadlessWebExtractor())

        let snapshot = settings.snapshot
        let engine = DownloadEngine(baseDirectory: support, downloadsDirectory: documents) { snapshot.get() }
        background = BackgroundTransfers(engine: engine, staging: support.appendingPathComponent("background", isDirectory: true))
        downloads = DownloadStore(engine: engine, resolvers: resolvers, background: background)
        background.reconcile()

        let resolvers = self.resolvers
        let onFinished: @Sendable (DownloadItem) async -> Void = { [weak self] item in
            // 夸克兜底转存产生的临时目录：下载完成后删除
            if let cleanup = item.request.cleanup, let platform = SharePlatform(rawValue: cleanup.platform) {
                await resolvers.resolver(for: platform)?.cleanup(token: cleanup.token)
            }
            await self?.didFinish(item)
        }
        let onFailed: @Sendable (DownloadItem) async -> Void = { [weak self] item in
            await self?.notify(title: "下载失败", body: "\(item.displayName)：\(item.errorMessage ?? "未知错误")")
        }
        Task { await engine.configure(merger: MediaTools.merger, onFinished: onFinished, onFailed: onFailed) }
    }

    /// 应用不在前台时发本地通知
    private func notify(title: String, body: String) {
        guard !isActive, settings.notifyOnFinish else { return }
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
        let fm = FileManager.default
        let sub = (item.outputPath as NSString?)?.deletingLastPathComponent ?? ""
        let dir = sub.isEmpty ? folder : folder.appendingPathComponent(sub, isDirectory: true)
        do {
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
            let location = folder.lastPathComponent + (sub.isEmpty ? "" : "/" + sub) + "/" + target.lastPathComponent
            await downloads.engine.markExported(item.id, to: location)
        } catch {
            show("移动到所选文件夹失败：\(error.localizedDescription)", error: true)
        }
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// 启动 / 回到前台时的自动检查：每天最多一次，跳过用户忽略的版本，失败静默
    func autoCheckForUpdates() {
        guard settings.autoCheckUpdates else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        settings.lastUpdateCheck = Date()
        Task {
            guard let release = try? await UpdateChecker.check(current: Self.currentVersion),
                  release.version != settings.skippedVersion else { return }
            availableUpdate = release
        }
    }

    func show(_ message: String, error: Bool = false) {
        if error { Log.error(message) }
        toast = Toast(message: message, isError: error)
    }

    /// 打开外部传入的链接：cloudn://resolve?text=...
    func handle(url: URL) {
        guard url.scheme == "cloudn", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let text = comps.queryItems?.first(where: { $0.name == "text" || $0.name == "url" })?.value, !text.isEmpty {
            pendingInput = text
            selectedTab = .resolve
        }
    }

    /// 进入后台：单文件任务剩余分片交给系统后台会话；其余任务借一段后台执行时间，到期前暂停、回到前台再继续
    func scenePhaseChanged(active: Bool) {
        isActive = active
        let engine = downloads.engine
        if active {
            autoCheckForUpdates()
            endBackgroundTask()
            let ids = suspendedIds
            suspendedIds = []
            if !ids.isEmpty { Task { await engine.resume(ids) } }
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
