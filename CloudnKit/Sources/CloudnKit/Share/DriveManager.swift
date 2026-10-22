// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 「我的网盘」文件管理：浏览、下载、新建文件夹、重命名、移动、删除、创建分享、容量。
// 各平台个人盘接口参考 YunX（AGPL-3.0）的 *Api / *CloudViewModel。
import Foundation

/// 网盘容量（字节）
public struct DriveQuota: Equatable, Sendable {
    public let used: Int64
    public let total: Int64

    public init(used: Int64, total: Int64) {
        self.used = used
        self.total = total
    }
}

/// 新建的分享链接
public struct DriveShareLink: Equatable, Sendable {
    public let url: String
    public let pwd: String

    public init(url: String, pwd: String = "") {
        self.url = url
        self.pwd = pwd
    }

    /// 复制给别人的文本
    public var text: String { pwd.isEmpty ? url : "\(url) 提取码：\(pwd)" }
}

/// 分享有效期（按天）；0 = 永久。各平台字段语义不同，在各自的 createShare 里换算（参考 YunX §3.20）
public struct ShareExpiry: Hashable, Sendable, Identifiable {
    public let days: Int
    public init(days: Int) { self.days = days }

    public var id: Int { days }
    public var isForever: Bool { days == 0 }
    public var label: String { isForever ? "永久有效" : "\(days) 天" }

    public static let forever = ShareExpiry(days: 0)
    /// 夸克 / UC / 百度 / 迅雷 / 123 / 139 / 光鸭
    public static let standard = [0, 1, 7, 30].map(ShareExpiry.init(days:))
    /// 115 只有这几档
    public static let pan115 = [0, 1, 3, 7, 15].map(ShareExpiry.init(days:))

    /// 不在平台档位里的有效期直接报错，不悄悄换成别的档位
    func require(in options: [ShareExpiry]) throws {
        guard options.contains(self) else { throw CloudnError("该网盘不支持「\(label)」的分享有效期") }
    }
}

/// 分享链接谁能打开
public enum ShareAudience: String, Sendable, CaseIterable, Identifiable {
    /// 知道链接的任何人
    case anyone
    /// 只有同一组织（工作或学校账号）的人
    case organization

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .anyone: return "知道链接的任何人"
        case .organization: return "仅组织内的人"
        }
    }
}

/// 打开分享链接的人能做什么
public enum ShareRole: String, Sendable, CaseIterable, Identifiable {
    case view, edit

    public var id: String { rawValue }
    public var label: String { self == .view ? "仅查看" : "可编辑" }
}

/// 创建分享的完整选项（支持的平台在分享设置页里逐项选择）
public struct ShareOptions: Sendable, Equatable {
    public var audience: ShareAudience
    public var role: ShareRole
    public var expiry: ShareExpiry
    /// 空串为不设密码
    public var password: String

    public init(audience: ShareAudience = .anyone, role: ShareRole = .view, expiry: ShareExpiry = .forever, password: String = "") {
        self.audience = audience
        self.role = role
        self.expiry = expiry
        self.password = password
    }
}

/// 一个已存在的分享链接
public struct DriveShareInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let url: String
    public let audience: String
    public let role: String
    /// 过期时间（已格式化），永久为空
    public let expires: String
    public let hasPassword: Bool
    /// 继承自上级文件夹的分享：该文件夹的名字（取消时会作用在那个文件夹上）
    public let inheritedFrom: String?

    public init(id: String, url: String, audience: String, role: String, expires: String, hasPassword: Bool, inheritedFrom: String? = nil) {
        self.id = id
        self.url = url
        self.audience = audience
        self.role = role
        self.expires = expires
        self.hasPassword = hasPassword
        self.inheritedFrom = inheritedFrom
    }
}

/// 平台支持的管理操作
public struct DriveCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let createFolder = DriveCapabilities(rawValue: 1 << 0)
    public static let rename = DriveCapabilities(rawValue: 1 << 1)
    public static let move = DriveCapabilities(rawValue: 1 << 2)
    public static let delete = DriveCapabilities(rawValue: 1 << 3)
    public static let share = DriveCapabilities(rawValue: 1 << 4)
    public static let all: DriveCapabilities = [.createFolder, .rename, .move, .delete, .share]
}

/// 登录后管理自己网盘里的文件（需要对应平台已登录）
public protocol DriveManager: Sendable {
    /// 根目录 id
    var driveRootId: String { get }
    var driveCapabilities: DriveCapabilities { get }

    /// 列出目录（文件 + 文件夹）
    func listDrive(_ folderId: String) async throws -> [ShareFile]
    /// 个人盘文件直链
    func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink
    func createFolder(_ name: String, in parentId: String) async throws
    func rename(_ file: ShareFile, to name: String) async throws
    func move(_ files: [ShareFile], to folderId: String) async throws
    func delete(_ files: [ShareFile]) async throws
    /// 可选的分享有效期，第一项为默认
    var shareExpiryOptions: [ShareExpiry] { get }
    func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink
    /// 容量；拿不到返回 nil
    func quota() async -> DriveQuota?

    /// 分享设置页的「谁能访问」选项；为空表示平台不支持细分设置，只用有效期菜单
    var shareAudienceOptions: [ShareAudience] { get }
    var shareRoleOptions: [ShareRole] { get }
    /// 能否给分享设密码
    var supportsSharePassword: Bool { get }
    /// 分享设置页底部的说明（例如个人版设密码要订阅）
    var shareOptionsNote: String { get }
    func createShare(_ files: [ShareFile], options: ShareOptions) async throws -> DriveShareLink
    /// 能否列出 / 取消已有的分享
    var supportsShareManagement: Bool { get }
    func existingShares(_ file: ShareFile) async throws -> [DriveShareInfo]
    func revokeShare(_ file: ShareFile, id: String) async throws
}

public extension DriveManager {
    var driveCapabilities: DriveCapabilities { .all }
    func createFolder(_ name: String, in parentId: String) async throws { throw CloudnError("该网盘暂不支持新建文件夹") }
    func rename(_ file: ShareFile, to name: String) async throws { throw CloudnError("该网盘暂不支持重命名") }
    func move(_ files: [ShareFile], to folderId: String) async throws { throw CloudnError("该网盘暂不支持移动") }
    func delete(_ files: [ShareFile]) async throws { throw CloudnError("该网盘暂不支持删除") }
    var shareExpiryOptions: [ShareExpiry] { ShareExpiry.standard }
    func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink { throw CloudnError("该网盘暂不支持创建分享") }
    /// 永久有效的分享
    func createShare(_ files: [ShareFile]) async throws -> DriveShareLink { try await createShare(files, expiry: .forever) }
    func quota() async -> DriveQuota? { nil }

    var shareAudienceOptions: [ShareAudience] { [] }
    var shareRoleOptions: [ShareRole] { [] }
    var supportsSharePassword: Bool { false }
    var shareOptionsNote: String { "" }
    func createShare(_ files: [ShareFile], options: ShareOptions) async throws -> DriveShareLink {
        try await createShare(files, expiry: options.expiry)
    }
    var supportsShareManagement: Bool { false }
    func existingShares(_ file: ShareFile) async throws -> [DriveShareInfo] { [] }
    func revokeShare(_ file: ShareFile, id: String) async throws { throw CloudnError("该网盘暂不支持取消分享") }
}
