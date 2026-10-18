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
    let settings: AppSettings
    let accounts: AccountStore
    let bookmarks: BookmarkStore
    let downloads: DownloadStore
    @ObservationIgnored let resolvers: ShareResolvers
    @ObservationIgnored let videoService: VideoParseService

    var selectedTab: AppTab = .resolve
    var toast: Toast?
    /// 外部（URL Scheme / 分享）送进来的待解析文本
    var pendingInput: String?

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cloudn", isDirectory: true)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)

        settings = AppSettings()
        accounts = AccountStore()
        bookmarks = BookmarkStore(directory: support)
        resolvers = ShareResolvers(credentials: accounts.vault)
        videoService = VideoParseService(credentials: accounts.vault, webExtractor: HeadlessWebExtractor())

        let snapshot = settings.snapshot
        let engine = DownloadEngine(baseDirectory: support, downloadsDirectory: documents) { snapshot.get() }
        downloads = DownloadStore(engine: engine, resolvers: resolvers)

        let resolvers = self.resolvers
        Task { [weak self] in
            await engine.configure(merger: MediaTools.merger) { item in
                // 夸克兜底转存产生的临时目录：下载完成后删除
                if let cleanup = item.request.cleanup, let platform = SharePlatform(rawValue: cleanup.platform) {
                    await resolvers.resolver(for: platform)?.cleanup(token: cleanup.token)
                }
                await self?.didFinish(item)
            }
        }
    }

    private func didFinish(_ item: DownloadItem) async {
        guard settings.autoSaveToPhotos, let url = downloads.engine.fileURL(for: item), MediaTools.canSaveToPhotos(url) else { return }
        do {
            try await MediaTools.saveToPhotos(url)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    func show(_ message: String, error: Bool = false) {
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

    /// 进入后台时申请一段后台执行时间，让进行中的下载尽量跑完/落盘
    func scenePhaseChanged(active: Bool) {
        if active {
            endBackgroundTask()
        } else if downloads.activeCount > 0, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "downloads") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
