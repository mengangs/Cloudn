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
    /// 完成后移动到的文件夹（安全作用域书签）；nil 表示留在应用的下载目录。只经 setExportFolder 修改
    private(set) var exportFolderBookmark: Data? {
        didSet { defaults.set(exportFolderBookmark, forKey: "exportFolderBookmark") }
    }
    /// 书签解析出的文件夹：启动和更换文件夹时各解析一次，界面读取不碰磁盘、不改状态
    private(set) var exportFolder: URL? = nil
    /// 当前持有安全访问的文件夹（与 exportFolder 同一个；start / stop 成对，见 resolveExportFolder）
    @ObservationIgnored private var exportFolderAccess: URL?
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
        didSet {
            defaults.set(notifyOnFinish, forKey: "notifyOnFinish")
            if notifyOnFinish && !oldValue { Notifier.requestAuthorizationIfNeeded() }
        }
    }
    /// BT 下载附加内置的公共 tracker（磁力链接自带的 tracker 常已失效）
    var useExtraTrackers: Bool {
        didSet { defaults.set(useExtraTrackers, forKey: "useExtraTrackers"); publish() }
    }
    /// 多账号下载：批量下载时按文件轮换使用同平台的多个账号
    var multiAccountDownload: Bool {
        didSet { defaults.set(multiAccountDownload, forKey: "multiAccountDownload") }
    }
    /// 抖音作品文件按「昵称_抖音号_发布时间」命名（默认按标题）
    var authorStyledNames: Bool {
        didSet { defaults.set(authorStyledNames, forKey: Self.authorStyledNamesKey) }
    }
    static let authorStyledNamesKey = "authorStyledNames"
    /// 允许把夸克 / UC 中文口令发给第三方「星海」服务解析（唯一用到第三方服务的地方；首次使用时询问）
    var allowCommandService: Bool {
        didSet { defaults.set(allowCommandService, forKey: "allowCommandService") }
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
    /// 平台图标：线性（默认）/ 实心。组件直接用 @AppStorage 读同一个键，改了即时生效
    var platformIconStyle: PlatformIconStyle {
        didSet { defaults.set(platformIconStyle.rawValue, forKey: PlatformIconStyle.key) }
    }
    /// 「我的」页不显示的网盘（AccountKind.rawValue）；隐藏只影响展示，解析、下载照常
    var hiddenDrives: [String] {
        didSet { defaults.set(hiddenDrives, forKey: "hiddenDrives") }
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
    /// 应用内网络代理；关闭时跟随系统（含 VPN）
    var proxyEnabled: Bool {
        didSet { defaults.set(proxyEnabled, forKey: "proxyEnabled"); applyProxy() }
    }
    var proxyKind: NetworkProxy.Kind {
        didSet { defaults.set(proxyKind.rawValue, forKey: "proxyKind"); applyProxy() }
    }
    var proxyHost: String {
        didSet { defaults.set(proxyHost, forKey: "proxyHost"); applyProxy() }
    }
    var proxyPort: Int {
        didSet { defaults.set(proxyPort, forKey: "proxyPort"); applyProxy() }
    }

    /// 下载引擎在后台线程读取，这里维护一份线程安全快照
    @ObservationIgnored let snapshot = SettingsSnapshot()
    @ObservationIgnored let resolverOptions = ResolverOptions()

    init() {
        defaults.register(defaults: [
            "maxConcurrentTasks": 3,
            "clipboardHint": true,
            "autoSaveToPhotos": false,
            "notifyOnFinish": true,
            "retryCount": 3,
            "speedLimitKB": 0,
            "directFirst": true,
            "autoCheckUpdates": true,
            "liveActivity": true,
            "useExtraTrackers": true,
            "proxyPort": 7890
        ])
        maxConcurrentTasks = min(5, max(1, defaults.integer(forKey: "maxConcurrentTasks")))
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
        allowCommandService = defaults.bool(forKey: "allowCommandService")
        authorStyledNames = defaults.bool(forKey: Self.authorStyledNamesKey)
        useExtraTrackers = defaults.bool(forKey: "useExtraTrackers")
        multiSourceDownload = defaults.bool(forKey: "multiSourceDownload")
        accentHex = defaults.string(forKey: "accentHex") ?? ""
        githubMirror = defaults.string(forKey: "githubMirror") ?? ""
        githubToken = Keychain.read("github.token").map { String(decoding: $0, as: UTF8.self) } ?? ""
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        platformIconStyle = PlatformIconStyle(rawValue: defaults.string(forKey: PlatformIconStyle.key) ?? "") ?? .line
        hiddenDrives = defaults.stringArray(forKey: "hiddenDrives") ?? []
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        acceptPrerelease = defaults.bool(forKey: "acceptPrerelease")
        lastUpdateCheck = defaults.object(forKey: "lastUpdateCheck") as? Date
        skippedVersion = defaults.string(forKey: "skippedVersion") ?? ""
        proxyEnabled = defaults.bool(forKey: "proxyEnabled")
        proxyKind = NetworkProxy.Kind(rawValue: defaults.string(forKey: "proxyKind") ?? "") ?? .http
        proxyHost = defaults.string(forKey: "proxyHost") ?? ""
        proxyPort = min(65535, max(1, defaults.integer(forKey: "proxyPort")))
        resolverOptions.directFirst = directFirst
        publish()
        applyProxy()
        resolveExportFolder()
    }

    /// 代理设置（填写完整时才生效）
    var proxy: NetworkProxy? {
        let p = NetworkProxy(kind: proxyKind, host: proxyHost.trimmingCharacters(in: .whitespaces), port: proxyPort)
        return proxyEnabled && p.isValid ? p : nil
    }

    private func applyProxy() {
        NetworkProxy.current = proxy
    }

    private func publish() {
        var settings = DownloadSettings(maxConcurrentTasks: maxConcurrentTasks, retryCount: retryCount,
                                        speedLimit: Int64(speedLimitKB) * 1024, connectionsBySource: connectionsBySource)
        settings.useExtraTrackers = useExtraTrackers
        snapshot.set(settings)
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
    /// 解析书签得到文件夹地址并缓存；书签过期时就地刷新，彻底失效为 nil。
    /// 对所选文件夹只保持一次安全访问：打开、分享（分享面板异步读文件）、删除已移过去的文件都要用到，
    /// 这些操作分散在别处、没法逐次包住；更换或清除文件夹时先结束旧的访问，所以 start / stop 始终成对，
    /// 不会像以前那样每次界面刷新都多开一次、永不释放
    private func resolveExportFolder() {
        if let previous = exportFolderAccess {
            previous.stopAccessingSecurityScopedResource()
            exportFolderAccess = nil
        }
        guard let data = exportFolderBookmark else {
            exportFolder = nil
            return
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
            exportFolder = nil
            return
        }
        if url.startAccessingSecurityScopedResource() { exportFolderAccess = url }
        if stale, let fresh = try? url.bookmarkData() { exportFolderBookmark = fresh }
        exportFolder = url
    }

    /// 已移到外部文件夹的下载文件的位置（exportedTo 记的是「文件夹名/子目录/文件名」）；文件不在了返回 nil。
    /// 文件夹的安全访问由 resolveExportFolder 统一持有，这里不再开启
    func exportedFileURL(_ item: DownloadItem) -> URL? {
        guard let text = item.exportedTo, let folder = exportFolder else { return nil }
        let relative = text.split(separator: "/").dropFirst().joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        let url = folder.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func setExportFolder(_ url: URL?) {
        if let url {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            exportFolderBookmark = try? url.bookmarkData()
        } else {
            exportFolderBookmark = nil
        }
        resolveExportFolder()
    }
}

extension AppSettings {
    /// 预设主题色：每个都有深色模式下提亮的一份，避免深底上看不见
    static let accentPresets: [(name: String, hex: String, dark: String)] = [
        ("陶土", "", ""), ("墨蓝", "3D5A80", "8FB3D9"), ("苔绿", "4F6F52", "8DB596"),
        ("赭石", "A0682A", "D9A066"), ("葡萄", "6E4E7E", "B596C4"), ("墨黑", "2B2A27", "E6E1D6")
    ]

    /// 当前强调色（浅色 / 深色各一份）；未自定义时是资源里的陶土色
    var accentUIColor: UIColor {
        Self.accentUIColor(hex: accentHex) ?? UIColor(named: "AccentColor") ?? UIColor(red: 0.71, green: 0.33, blue: 0.18, alpha: 1)
    }

    /// 某个主题色（RRGGBB）实际用的浅色 / 深色两份；hex 为空或格式不对返回 nil（用资源里的陶土色）。
    /// 浅色下对纸色不足 4.5:1 的（如赭石、自选的浅黄）自动压暗；深色用预设的提亮版，自选的按对比度自动提亮
    static func accentUIColor(hex: String) -> UIColor? {
        guard let raw = UIColor(hexString: hex) else { return nil }
        let light = lightModeVariant(of: raw)
        let dark = accentPresets.first { $0.hex == hex }.flatMap { UIColor(hexString: $0.dark) } ?? darkModeVariant(of: raw)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    private static func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// 浅色模式用的强调色：逐步向黑色混合，直到对浅色纸底（#F7F5EF）的对比度达到 4.5:1；本来就够深的原样返回
    static func lightModeVariant(of color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        let paper = luminance(0xF7 / 255, 0xF5 / 255, 0xEF / 255)
        var t: CGFloat = 0
        while t < 0.9 {
            let (mr, mg, mb) = (r * (1 - t), g * (1 - t), b * (1 - t))
            if (paper + 0.05) / (luminance(mr, mg, mb) + 0.05) >= 4.5 {
                return t == 0 ? color : UIColor(red: mr, green: mg, blue: mb, alpha: a)
            }
            t += 0.02
        }
        return UIColor(red: r * 0.1, green: g * 0.1, blue: b * 0.1, alpha: a)
    }

    /// 深色模式用的强调色：逐步向白色混合，直到对深色卡片底（#23221F）的对比度达到 4.5:1；本来就够亮的原样返回
    static func darkModeVariant(of color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        let surface = luminance(0x23 / 255, 0x22 / 255, 0x1F / 255)
        var t: CGFloat = 0
        while t < 0.9 {
            let (mr, mg, mb) = (r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t)
            if (luminance(mr, mg, mb) + 0.05) / (surface + 0.05) >= 4.5 {
                return UIColor(red: mr, green: mg, blue: mb, alpha: a)
            }
            t += 0.05
        }
        return UIColor(red: r + (1 - r) * 0.9, green: g + (1 - g) * 0.9, blue: b + (1 - b) * 0.9, alpha: a)
    }

    var accentColor: Color { Color(uiColor: accentUIColor) }
}

extension UIColor {
    /// RRGGBB → 颜色；格式不对返回 nil
    convenience init?(hexString: String) {
        let h = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
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

enum PlatformIconStyle: String, CaseIterable, Identifiable {
    case line, solid

    static let key = "platformIconStyle"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return "线性"
        case .solid: return "实心"
        }
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
