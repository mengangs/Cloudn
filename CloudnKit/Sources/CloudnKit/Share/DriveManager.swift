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
    func createShare(_ files: [ShareFile]) async throws -> DriveShareLink
    /// 容量；拿不到返回 nil
    func quota() async -> DriveQuota?
}

public extension DriveManager {
    var driveCapabilities: DriveCapabilities { .all }
    func createFolder(_ name: String, in parentId: String) async throws { throw CloudnError("该网盘暂不支持新建文件夹") }
    func rename(_ file: ShareFile, to name: String) async throws { throw CloudnError("该网盘暂不支持重命名") }
    func move(_ files: [ShareFile], to folderId: String) async throws { throw CloudnError("该网盘暂不支持移动") }
    func delete(_ files: [ShareFile]) async throws { throw CloudnError("该网盘暂不支持删除") }
    func createShare(_ files: [ShareFile]) async throws -> DriveShareLink { throw CloudnError("该网盘暂不支持创建分享") }
    func quota() async -> DriveQuota? { nil }
}
