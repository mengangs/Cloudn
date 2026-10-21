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
        case .twitter: return .twitter
        case .instagram: return .instagram
        case .tiktok: return .tiktok
        case .reddit: return .reddit
        case .facebook: return .facebook
        case .threads: return .threads
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
    /// 同一个视频的不同清晰度共用一个组名（空串表示独立媒体）。组内排在最前的是默认选择（最高画质），
    /// 界面上合成一行供挑选，「全部下载」每组只下选中的那一个；各清晰度的文件名必须不同
    public let variantGroup: String

    public init(url: String, kind: MediaKind, fileName: String, size: Int64 = -1, isHLS: Bool = false,
                headers: [String: String] = [:], quality: String = "", audioURL: String = "", variantGroup: String = "") {
        self.id = UUID()
        self.url = url
        self.kind = kind
        self.fileName = fileName
        self.size = size
        self.isHLS = isHLS
        self.headers = headers
        self.quality = quality
        self.audioURL = audioURL
        self.variantGroup = variantGroup
    }

    func withSecureURLs() -> VideoMedia {
        VideoMedia(url: VideoHTTP.secureURL(url), kind: kind, fileName: fileName, size: size, isHLS: isHLS,
                   headers: headers, quality: quality, audioURL: VideoHTTP.secureURL(audioURL), variantGroup: variantGroup)
    }
}

/// 合集 / 播放列表 / 多 P 里的一条：只记作品链接，下载时再逐条解析
public struct VideoEntry: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    /// 能被 VideoLinkParser 识别的作品链接
    public let url: String
    /// 秒；未知为 nil
    public let duration: Double?
    public let cover: String

    public init(title: String, url: String, duration: Double? = nil, cover: String = "") {
        self.id = UUID()
        self.title = title
        self.url = url
        self.duration = duration
        self.cover = cover
    }
}

/// 字幕轨：下载时取回并统一转成 SRT（见 SubtitleConverter）
public struct SubtitleTrack: Hashable, Sendable, Identifiable {
    public enum Format: String, Sendable { case srt, vtt, biliJSON, youtubeJSON3 }

    public let id: UUID
    /// 显示名，如「中文（自动生成）」
    public let name: String
    /// 语言代码，用在文件名里，如 zh-Hans
    public let language: String
    public let url: String
    public let format: Format
    public let headers: [String: String]
    /// 机器自动生成的字幕
    public let automatic: Bool

    public init(name: String, language: String, url: String, format: Format, headers: [String: String] = [:], automatic: Bool = false) {
        self.id = UUID()
        self.name = name
        self.language = language
        self.url = url
        self.format = format
        self.headers = headers
        self.automatic = automatic
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
    /// 合集 / 播放列表 / 多 P：各条作品（非空时界面按合集展示，可多选批量下载）
    public let entries: [VideoEntry]
    /// 可下载的字幕
    public let subtitles: [SubtitleTrack]
    /// 作者在平台上的账号（如抖音号）；拿不到为空
    public let authorID: String
    /// 媒体文件名用的主干（文件名都以它开头）；按「作者_账号_发布时间」重命名时据此替换，为空表示不支持重命名
    public let fileBase: String

    public init(platform: VideoPlatform, title: String, author: String = "", avatar: String = "", cover: String = "",
                text: String = "", timestamp: Int64 = 0, url: String = "", medias: [VideoMedia] = [], notice: String = "",
                entries: [VideoEntry] = [], subtitles: [SubtitleTrack] = [], authorID: String = "", fileBase: String = "") {
        self.authorID = authorID
        self.fileBase = fileBase
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
        self.entries = entries
        self.subtitles = subtitles
    }

    /// 「全部下载」的默认对象：每个清晰度组只取第一个（最高画质），其余媒体（独立视频、图片）全取
    public var defaultDownloads: [VideoMedia] {
        var seen = Set<String>()
        return medias.filter { media in
            guard !media.variantGroup.isEmpty else { return true }
            return seen.insert(media.variantGroup).inserted
        }
    }

    public var videoCount: Int { medias.filter { $0.kind == .video }.count }
    public var imageCount: Int { medias.filter { $0.kind == .image }.count }

    /// 实况照片：图片 id → 配对的视频（与图片同名加 `_live` 后缀，如 `作品_1.jpg` + `作品_1_live.mp4`）。
    /// 配上对的视频在界面上挂在图片上，不再单独列为视频
    public var livePairs: [UUID: VideoMedia] { Self.livePairs(medias) }

    /// 按「作者_账号_发布时间」改写文件名（只替换开头的 fileBase，清晰度 / 序号 / _live 后缀保留）；
    /// 缺作者或发布时间、或文件名不以 fileBase 开头时原样返回
    public func authorStyledName(_ fileName: String) -> String {
        guard !fileBase.isEmpty, fileName.hasPrefix(fileBase), !author.isEmpty, timestamp > 0 else { return fileName }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        let base = FileNames.base([author, authorID, date].filter { !$0.isEmpty }.joined(separator: "_"), fallback: fileBase)
        return base + fileName.dropFirst(fileBase.count)
    }

    static func livePairs(_ medias: [VideoMedia]) -> [UUID: VideoMedia] {
        let suffix = "_live"
        var images: [String: UUID] = [:]
        for media in medias where media.kind == .image {
            let stem = (media.fileName as NSString).deletingPathExtension
            if images[stem] == nil { images[stem] = media.id }
        }
        var pairs: [UUID: VideoMedia] = [:]
        for media in medias where media.kind == .video {
            let stem = (media.fileName as NSString).deletingPathExtension
            guard stem.hasSuffix(suffix), let image = images[String(stem.dropLast(suffix.count))], pairs[image] == nil else { continue }
            pairs[image] = media
        }
        return pairs
    }
}

extension VideoParseResult: Hashable {
    public static func == (lhs: VideoParseResult, rhs: VideoParseResult) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum VideoParseErrorKind: Sendable { case blocked, notFound, network, unsupported, unknown }

public struct VideoParseError: Error, LocalizedError, Sendable {
    public let kind: VideoParseErrorKind
    public let detail: String
    /// 建议改用网页嗅探打开的地址（如短链展开后的终址）；nil 表示用原链接
    public let sniffURL: String?

    public init(_ kind: VideoParseErrorKind, _ detail: String, sniffURL: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.sniffURL = sniffURL
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
    /// 打开 url，轮询 readyScript 直到返回 true，再执行 extractScript 并返回其 JSON 文本。
    /// cookie（`a=1; b=2` 形式，可为空）在页面加载前写进该站点，用于登录后才能看的内容
    func extract(url: String, userAgent: String, cookie: String, documentStartScripts: [String],
                 readyScript: String, extractScript: String, timeout: TimeInterval) async -> String?
}
