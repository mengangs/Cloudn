// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public enum VideoPlatform: String, Codable, CaseIterable, Sendable, Identifiable {
    case douyin, xiaohongshu, kuaishou, weibo, acfun, bilibili, pixiv
    case toutiao, tieba, weixin, douban, coolapk, pipix, zuiyou, zhihu
    case twitter, tiktok, instagram, threads
    case ixigua, haokan, weishi, kge, huoshan, lishipin, lvzhou, meipai, pipigaoxiao, xinpianchang, huya, cctv
    case reddit, pinterest, tumblr, imgur, bluesky, snapchat, vimeo, dailymotion, twitch, soundcloud, medium, bangumi
    case youtube, facebook, xiaoheihe, wxchannels

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .douyin: return "抖音"
        case .xiaohongshu: return "小红书"
        case .pixiv: return "Pixiv"
        case .kuaishou: return "快手"
        case .weibo: return "微博"
        case .acfun: return "AcFun"
        case .bilibili: return "哔哩哔哩"
        case .toutiao: return "今日头条"
        case .tieba: return "百度贴吧"
        case .weixin: return "微信公众号"
        case .douban: return "豆瓣"
        case .coolapk: return "酷安"
        case .pipix: return "皮皮虾"
        case .zuiyou: return "最右"
        case .zhihu: return "知乎"
        case .twitter: return "X（Twitter）"
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .threads: return "Threads"
        case .ixigua: return "西瓜视频"
        case .haokan: return "好看视频"
        case .weishi: return "微视"
        case .kge: return "全民K歌"
        case .huoshan: return "抖音火山版"
        case .lishipin: return "梨视频"
        case .lvzhou: return "绿洲"
        case .meipai: return "美拍"
        case .pipigaoxiao: return "皮皮搞笑"
        case .xinpianchang: return "新片场"
        case .huya: return "虎牙"
        case .cctv: return "央视网"
        case .reddit: return "Reddit"
        case .pinterest: return "Pinterest"
        case .tumblr: return "Tumblr"
        case .imgur: return "Imgur"
        case .bluesky: return "Bluesky"
        case .snapchat: return "Snapchat"
        case .vimeo: return "Vimeo"
        case .dailymotion: return "Dailymotion"
        case .twitch: return "Twitch"
        case .soundcloud: return "SoundCloud"
        case .medium: return "Medium"
        case .bangumi: return "Bangumi"
        case .youtube: return "YouTube"
        case .facebook: return "Facebook"
        case .xiaoheihe: return "小黑盒"
        case .wxchannels: return "微信视频号"
        }
    }

    /// 登录后能力更强的平台对应的账号类型
    public var accountKind: AccountKind? {
        switch self {
        case .bilibili: return .bilibili
        case .xiaohongshu: return .xiaohongshu
        case .pixiv: return .pixiv
        case .zhihu: return .zhihu
        case .wxchannels: return .yuanbao
        default: return nil
        }
    }
}

public enum MediaKind: String, Codable, Sendable { case video, image, audio }

/// 一条可下载的媒体，自带直链真正需要的请求头
public struct VideoMedia: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let url: String
    public let kind: MediaKind
    public let fileName: String
    public let size: Int64
    /// m3u8 流：下载走 HLS 分片合并
    public let isHLS: Bool
    public let headers: [String: String]
    /// 清晰度/规格，仅展示
    public let quality: String
    /// 分轨音频（B 站 DASH）；非空时下载完需与视频合轨
    public let audioURL: String

    public init(url: String, kind: MediaKind, fileName: String, size: Int64 = -1, isHLS: Bool = false,
                headers: [String: String] = [:], quality: String = "", audioURL: String = "") {
        self.id = UUID()
        self.url = url
        self.kind = kind
        self.fileName = fileName
        self.size = size
        self.isHLS = isHLS
        self.headers = headers
        self.quality = quality
        self.audioURL = audioURL
    }

    func withSecureURLs() -> VideoMedia {
        VideoMedia(url: VideoHTTP.secureURL(url), kind: kind, fileName: fileName, size: size, isHLS: isHLS,
                   headers: headers, quality: quality, audioURL: VideoHTTP.secureURL(audioURL))
    }
}

/// 一次解析的结果：一个作品（视频 / 图集）
public struct VideoParseResult: Sendable, Identifiable {
    public let id = UUID()
    public let platform: VideoPlatform
    public let title: String
    public let author: String
    public let avatar: String
    public let cover: String
    public let text: String
    public let timestamp: Int64
    public let url: String
    public let medias: [VideoMedia]
    /// 给用户的附加提示（如部分图片只能拿到带水印的平台图）；空串表示没有
    public let notice: String

    public init(platform: VideoPlatform, title: String, author: String = "", avatar: String = "", cover: String = "",
                text: String = "", timestamp: Int64 = 0, url: String = "", medias: [VideoMedia] = [], notice: String = "") {
        self.platform = platform
        self.title = title
        self.author = author
        self.avatar = avatar
        self.cover = cover
        self.text = text
        self.timestamp = timestamp
        self.url = url
        self.medias = medias
        self.notice = notice
    }

    public var videoCount: Int { medias.filter { $0.kind == .video }.count }
    public var imageCount: Int { medias.filter { $0.kind == .image }.count }
}

extension VideoParseResult: Hashable {
    public static func == (lhs: VideoParseResult, rhs: VideoParseResult) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum VideoParseErrorKind: Sendable { case blocked, notFound, network, unsupported, unknown }

public struct VideoParseError: Error, LocalizedError, Sendable {
    public let kind: VideoParseErrorKind
    public let detail: String

    public init(_ kind: VideoParseErrorKind, _ detail: String) {
        self.kind = kind
        self.detail = detail
    }

    /// 面向用户的一句话（细节留在 detail）
    public var errorDescription: String? {
        switch kind {
        case .blocked: return "平台风控拦截了本次请求，请稍后重试"
        case .notFound: return "内容不存在、已删除或不可见"
        case .network: return "网络请求失败，请检查网络后重试"
        case .unsupported, .unknown: return detail.isEmpty ? "解析失败，请稍后重试" : detail
        }
    }
}

/// 识别结果：平台 + 资源类型 + id；短链 id 为空，需先展开
public struct DetectedVideoLink: Sendable, Equatable {
    public let platform: VideoPlatform
    public let kind: String
    public let id: String
    public let url: String

    public var isShortLink: Bool { kind == "short" }

    public init(platform: VideoPlatform, kind: String, id: String, url: String) {
        self.platform = platform
        self.kind = kind
        self.id = id
        self.url = url
    }
}

/// 「把页面在真实浏览器内核里跑一遍再取数」的能力（抖音需要）。
/// iOS 端由隐藏的 WKWebView 实现；单元测试/Linux 下不提供。
public protocol WebPageExtractor: Sendable {
    /// 打开 url，轮询 readyScript 直到返回 true，再执行 extractScript 并返回其 JSON 文本
    func extract(url: String, userAgent: String, documentStartScripts: [String],
                 readyScript: String, extractScript: String, timeout: TimeInterval) async -> String?
}
