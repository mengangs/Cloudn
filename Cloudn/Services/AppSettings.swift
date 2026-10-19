// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation
import SwiftUI

/// 全部偏好设置的唯一入口（UserDefaults），值域在 setter 里兜住
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var maxConcurrentTasks: Int {
        didSet { defaults.set(maxConcurrentTasks, forKey: "maxConcurrentTasks"); publish() }
    }
    var connectionsPerTask: Int {
        didSet { defaults.set(connectionsPerTask, forKey: "connectionsPerTask"); publish() }
    }
    var retryCount: Int {
        didSet { defaults.set(retryCount, forKey: "retryCount"); publish() }
    }
    /// 全局限速（KB/s），0 表示不限
    var speedLimitKB: Int {
        didSet { defaults.set(speedLimitKB, forKey: "speedLimitKB"); publish() }
    }
    /// 按平台覆盖单任务连接数（键为平台显示名）
    var connectionsBySource: [String: Int] {
        didSet { defaults.set(connectionsBySource, forKey: "connectionsBySource"); publish() }
    }
    /// 免转存下载（夸克 / UC 先直接取链，失败再临时转存）
    var directFirst: Bool {
        didSet { defaults.set(directFirst, forKey: "directFirst"); resolverOptions.directFirst = directFirst }
    }
    /// 完成后移动到的文件夹（安全作用域书签）；nil 表示留在应用的下载目录
    var exportFolderBookmark: Data? {
        didSet { defaults.set(exportFolderBookmark, forKey: "exportFolderBookmark") }
    }
    var clipboardHint: Bool {
        didSet { defaults.set(clipboardHint, forKey: "clipboardHint") }
    }
    /// 视频/图片下载完成后自动存入相册
    var autoSaveToPhotos: Bool {
        didSet { defaults.set(autoSaveToPhotos, forKey: "autoSaveToPhotos") }
    }
    /// 应用不在前台时，下载完成 / 失败发本地通知
    var notifyOnFinish: Bool {
        didSet { defaults.set(notifyOnFinish, forKey: "notifyOnFinish") }
    }
    /// 外观：跟随系统 / 浅色 / 深色
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    /// 启动时自动检查更新（每天最多一次）
    var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }
    var lastUpdateCheck: Date? {
        didSet { defaults.set(lastUpdateCheck, forKey: "lastUpdateCheck") }
    }
    /// 用户选择忽略的版本（自动检查不再提示）
    var skippedVersion: String {
        didSet { defaults.set(skippedVersion, forKey: "skippedVersion") }
    }
    var acceptedNotice: Bool {
        didSet { defaults.set(acceptedNotice, forKey: "acceptedNotice") }
    }

    /// 下载引擎在后台线程读取，这里维护一份线程安全快照
    @ObservationIgnored let snapshot = SettingsSnapshot()
    @ObservationIgnored let resolverOptions = ResolverOptions()

    init() {
        defaults.register(defaults: [
            "maxConcurrentTasks": 3,
            "connectionsPerTask": 8,
            "clipboardHint": true,
            "autoSaveToPhotos": false,
            "notifyOnFinish": true,
            "retryCount": 3,
            "speedLimitKB": 0,
            "directFirst": true,
            "autoCheckUpdates": true
        ])
        maxConcurrentTasks = min(5, max(1, defaults.integer(forKey: "maxConcurrentTasks")))
        connectionsPerTask = min(16, max(1, defaults.integer(forKey: "connectionsPerTask")))
        retryCount = min(10, max(0, defaults.integer(forKey: "retryCount")))
        speedLimitKB = max(0, defaults.integer(forKey: "speedLimitKB"))
        connectionsBySource = defaults.dictionary(forKey: "connectionsBySource") as? [String: Int] ?? [:]
        directFirst = defaults.bool(forKey: "directFirst")
        exportFolderBookmark = defaults.data(forKey: "exportFolderBookmark")
        clipboardHint = defaults.bool(forKey: "clipboardHint")
        autoSaveToPhotos = defaults.bool(forKey: "autoSaveToPhotos")
        notifyOnFinish = defaults.bool(forKey: "notifyOnFinish")
        acceptedNotice = defaults.bool(forKey: "acceptedNotice")
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        skippedVersion = defaults.string(forKey: "skippedVersion") ?? ""
        resolverOptions.directFirst = directFirst
        publish()
    }

    private func publish() {
        snapshot.set(DownloadSettings(maxConcurrentTasks: maxConcurrentTasks, connectionsPerTask: connectionsPerTask, retryCount: retryCount,
                                      speedLimit: Int64(speedLimitKB) * 1024, connectionsBySource: connectionsBySource))
    }
}

final class SettingsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value = DownloadSettings()

    func set(_ v: DownloadSettings) { lock.lock(); value = v; lock.unlock() }
    func get() -> DownloadSettings { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - 完成后移动到所选文件夹

extension AppSettings {
    /// 解析书签得到文件夹地址；书签失效返回 nil
    var exportFolder: URL? {
        guard let data = exportFolderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        return url
    }

    func setExportFolder(_ url: URL?) {
        guard let url else { exportFolderBookmark = nil; return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        exportFolderBookmark = try? url.bookmarkData()
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
