// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 网盘平台。识别规则见 `ShareLinkParser`，解析能力见 `SharePlatform.isResolvable`。
public enum SharePlatform: String, Codable, CaseIterable, Sendable, Identifiable {
    case quark, uc, xunlei, baidu, c139, pan123, pan115, guangya, ilanzou, lanzou

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .xunlei: return "迅雷网盘"
        case .baidu: return "百度网盘"
        case .c139: return "139 网盘"
        case .pan123: return "123 云盘"
        case .pan115: return "115 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏云优享版"
        case .lanzou: return "蓝奏云"
        }
    }

    /// 已实现解析的平台（识别规则新增平台时，在实现解析器之前保持 false 会提示「暂未支持」）
    public var isResolvable: Bool { true }

    /// 对应的登录账号类型（不需要登录的平台为 nil）
    public var accountKind: AccountKind? {
        switch self {
        case .quark: return .quark
        case .uc: return .uc
        case .xunlei: return .xunlei
        case .baidu: return .baidu
        case .c139: return .c139
        case .pan123: return .pan123
        case .pan115: return .pan115
        case .guangya: return .guangya
        case .ilanzou: return .ilanzou
        case .lanzou: return .lanzou
        }
    }
}

/// 链接识别结果：分享 id + 提取码 + 平台 + 原始链接
public struct ParsedShare: Equatable, Sendable {
    public let shareId: String
    public let pwd: String?
    public let platform: SharePlatform
    public let url: String

    public init(shareId: String, pwd: String?, platform: SharePlatform, url: String) {
        self.shareId = shareId
        self.pwd = pwd
        self.platform = platform
        self.url = url
    }
}

/// 一次分享解析的会话凭证
public struct ShareSession: Hashable, Sendable {
    public let platform: SharePlatform
    public let shareId: String
    /// 分享访问令牌（夸克/UC 的 stoken；蓝奏云存提取码）
    public let stoken: String
    public let title: String
    /// 根目录 id（夸克/UC 为 "0"）
    public let rootId: String

    public init(platform: SharePlatform, shareId: String, stoken: String, title: String, rootId: String = "0") {
        self.platform = platform
        self.shareId = shareId
        self.stoken = stoken
        self.title = title
        self.rootId = rootId
    }
}

/// 分享内的文件 / 目录
public struct ShareFile: Hashable, Identifiable, Sendable {
    public let fid: String
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    public let parentId: String
    /// 文件令牌（夸克/UC 的 share_fid_token；蓝奏云为文件分享页地址）
    public let token: String
    public let modified: String

    public var id: String { fid }

    public init(fid: String, name: String, size: Int64, isDirectory: Bool, parentId: String = "", token: String = "", modified: String = "") {
        self.fid = fid
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.parentId = parentId
        self.token = token
        self.modified = modified
    }
}

/// 下载直链：直链 + 下载时必须带的请求头（Cookie / UA / Referer，缺一 CDN 即 403/412）
public struct DownloadLink: Sendable, Equatable {
    public let fileName: String
    public let url: String
    public let size: Int64
    public let headers: [String: String]
    /// 下载完成后交回解析器清理的令牌（夸克临时转存子目录 fid）；nil 表示无需清理
    public let cleanupToken: String?

    public init(fileName: String, url: String, size: Int64, headers: [String: String], cleanupToken: String? = nil) {
        self.fileName = fileName
        self.url = url
        self.size = size
        self.headers = headers
        self.cleanupToken = cleanupToken
    }
}

/// 需要登录的平台账号类型
public enum AccountKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case quark, uc, baidu, xunlei, pan123, pan115, c139, guangya, ilanzou, lanzou, bilibili, xiaohongshu, pixiv, zhihu

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .baidu: return "百度网盘"
        case .xunlei: return "迅雷网盘"
        case .pan123: return "123 云盘"
        case .pan115: return "115 网盘"
        case .c139: return "139 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏云优享版"
        case .lanzou: return "蓝奏云"
        case .bilibili: return "哔哩哔哩"
        case .xiaohongshu: return "小红书"
        case .pixiv: return "Pixiv"
        case .zhihu: return "知乎"
        }
    }

    /// 网盘账号（区别于视频平台账号）
    public var isDrive: Bool { ![.bilibili, .xiaohongshu, .pixiv, .zhihu].contains(self) }
}

/// 解析过程中给用户看的错误（文案即提示语）
public struct CloudnError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public let code: Int

    public init(_ message: String, code: Int = 0) {
        self.message = message
        self.code = code
    }

    public var errorDescription: String? { message }
}
