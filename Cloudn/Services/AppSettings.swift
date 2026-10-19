// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation
import SwiftUI
import UIKit

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
    /// 锁屏与灵动岛显示下载进度（实时活动）
    var liveActivity: Bool {
        didSet { defaults.set(liveActivity, forKey: "liveActivity") }
    }
    /// 应用不在前台时，下载完成 / 失败发本地通知
    var notifyOnFinish: Bool {
        didSet { defaults.set(notifyOnFinish, forKey: "notifyOnFinish") }
    }
    /// 多账号下载：批量下载时按文件轮换使用同平台的多个账号
    var multiAccountDownload: Bool {
        didSet { defaults.set(multiAccountDownload, forKey: "multiAccountDownload") }
    }
    /// 单文件多源分片：大文件同时用多个账号各自取到的直链分摊分片（依赖多账号下载）
    var multiSourceDownload: Bool {
        didSet { defaults.set(multiSourceDownload, forKey: "multiSourceDownload") }
    }
    /// GitHub 下载镜像前缀（空串表示直连 GitHub）
    var githubMirror: String {
        didSet { defaults.set(githubMirror, forKey: "githubMirror") }
    }
    /// GitHub Token（存钥匙串；只用于提高接口限额 / 访问自己的私有仓库）
    var githubToken: String {
        didSet {
            if githubToken.isEmpty { Keychain.delete("github.token") } else { Keychain.write("github.token", Data(githubToken.utf8)) }
        }
    }
    /// 主题色（十六进制 RRGGBB，空串为默认蓝）
    var accentHex: String {
        didSet { defaults.set(accentHex, forKey: "accentHex") }
    }
    /// 外观：跟随系统 / 浅色 / 深色
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    /// 启动时自动检查更新（每天最多一次）
    var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }
    /// 检查更新时包含预发布版（测试版）
    var acceptPrerelease: Bool {
        didSet { defaults.set(acceptPrerelease, forKey: "acceptPrerelease"); lastUpdateCheck = nil }
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
            "autoCheckUpdates": true,
            "liveActivity": true
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
        liveActivity = defaults.bool(forKey: "liveActivity")
        acceptedNotice = defaults.bool(forKey: "acceptedNotice")
        multiAccountDownload = defaults.bool(forKey: "multiAccountDownload")
        multiSourceDownload = defaults.bool(forKey: "multiSourceDownload")
        accentHex = defaults.string(forKey: "accentHex") ?? ""
        githubMirror = defaults.string(forKey: "githubMirror") ?? ""
        githubToken = Keychain.read("github.token").map { String(decoding: $0, as: UTF8.self) } ?? ""
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        acceptPrerelease = defaults.bool(forKey: "acceptPrerelease")
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

extension AppSettings {
    /// 主题色；nil 表示使用默认强调色
    var accentColor: Color? { Color(hex: accentHex) }

    /// 预设主题色
    static let accentPresets: [(name: String, hex: String)] = [
        ("陶土", ""), ("墨蓝", "3D5A80"), ("苔绿", "4F6F52"), ("赭石", "A0682A"), ("葡萄", "6E4E7E"), ("墨黑", "2B2A27")
    ]
}

extension Color {
    /// RRGGBB → 颜色；格式不对返回 nil
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// 颜色 → RRGGBB（按 sRGB 取分量）
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ c: CGFloat) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
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
