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
}
