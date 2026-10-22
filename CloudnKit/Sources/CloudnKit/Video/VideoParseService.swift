// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

protocol VideoParser: Sendable {
    var platform: VideoPlatform { get }
    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult
}

/// 识别 → 展开短链 → 取该平台 Cookie → 交给对应解析器
public final class VideoParseService: Sendable {
    private let credentials: CredentialStore
    private let parsers: [VideoPlatform: VideoParser]

    public init(credentials: CredentialStore, webExtractor: WebPageExtractor?) {
        self.credentials = credentials
        let list: [VideoParser] = [
            DouyinParser(extractor: webExtractor),
            XiaohongshuParser(),
            PixivParser(),
            KuaishouParser(extractor: webExtractor),
            WeiboParser(),
            AcFunParser(),
            BilibiliParser(),
            ZhihuParser(),
            TwitterParser(),
            TikTokParser(),
            InstagramParser(),
            ThreadsParser(),
            ToutiaoParser(),
            TiebaParser(),
            WeixinParser(),
            DoubanParser(),
            CoolapkParser(),
            PipixParser(),
            ZuiyouParser(),
            IxiguaParser(),
            HaokanParser(),
            WeishiParser(),
            KgeParser(),
            HuoshanParser(),
            LishipinParser(),
            LvzhouParser(),
            MeipaiParser(),
            PipigaoxiaoParser(),
            XinpianchangParser(),
            HuyaParser(),
            CctvParser(),
            VimeoParser(),
            DailymotionParser(),
            TwitchParser(),
            SoundCloudParser(),
            MediumParser(),
            BangumiParser(),
            RedditParser(),
            PinterestParser(),
            TumblrParser(),
            ImgurParser(),
            BlueskyParser(),
            SnapchatParser(),
            WxChannelsParser(),
            YouTubeParser(),
            FacebookParser(extractor: webExtractor),
            XiaoheiheParser(extractor: webExtractor)
        ]
        parsers = Dictionary(uniqueKeysWithValues: list.map { ($0.platform, $0) })
    }

    public func parse(_ link: DetectedVideoLink) async throws -> VideoParseResult {
        let resolved = link.isShortLink ? try await expand(link) : link
        guard let parser = parsers[resolved.platform] else {
            throw VideoParseError(.unsupported, "暂不支持解析\(resolved.platform.displayName)")
        }
        if let error = Self.unexpandedError(original: link, resolved: resolved) { throw error }
        var cookie = ""
        if let kind = resolved.platform.accountKind { cookie = await credentials.cookie(for: kind) ?? "" }
        let result = try await parser.parse(resolved, cookie: cookie)
        // 只给了一个多清晰度 m3u8 的，拆成可挑选的清晰度
        let medias = await HLSVariants.expand(result.medias.map { $0.withSecureURLs() })
        return VideoParseResult(platform: result.platform, title: result.title, author: result.author, avatar: result.avatar,
                                cover: VideoHTTP.secureURL(result.cover), text: result.text, timestamp: result.timestamp,
                                url: result.url, medias: medias, notice: result.notice,
                                entries: result.entries, subtitles: result.subtitles, authorID: result.authorID,
                                fileBase: result.fileBase)
    }

    /// 展开后仍是短链（快手的短链由解析器自己展开，除外）：
    /// 终址变了但认不出 → 指向的是不支持的页面（直播间、活动页…），附上终址供网页嗅探；终址没变 → 展开失败
    static func unexpandedError(original: DetectedVideoLink, resolved: DetectedVideoLink) -> VideoParseError? {
        guard resolved.isShortLink, resolved.platform != .kuaishou else { return nil }
        if resolved.url != original.url {
            return VideoParseError(.unsupported, "暂不支持这类链接：短链指向的页面不是可解析的\(resolved.platform.displayName)作品，可以用网页嗅探试试",
                                   sniffURL: resolved.url)
        }
        return VideoParseError(.unsupported, "短链展开失败，请复制完整链接后重试")
    }

    /// 展开短链（最多 5 跳），终址能重新识别就用新的识别结果
    private func expand(_ link: DetectedVideoLink) async throws -> DetectedVideoLink {
        var current = link
        let ua: String
        switch link.platform {
        case .douyin, .kuaishou: ua = VideoHTTP.uaIPhone
        // t.co 对浏览器 UA 回 200 + meta refresh 而不是 301；Threads 分享链同理
        case .twitter, .threads: ua = "curl/8.5.0"
        default: ua = VideoHTTP.uaChrome
        }
        for _ in 0..<5 {
            guard let next = try await VideoHTTP.expandRedirect(current.url, headers: ["User-Agent": ua]) else { return current }
            guard let again = VideoLinkParser.parse(next) else {
                return DetectedVideoLink(platform: current.platform, kind: current.kind, id: current.id, url: next)
            }
            if !again.isShortLink { return again }
            current = again
        }
        return current
    }
}

/// 账号 Cookie 校验（保存登录态前调用），返回昵称；无效返回 nil
public enum AccountValidator {
    /// 统一凭据的存储形态：123 存裸 JWT，迅雷存序列化后的凭据 JSON，其余为 Cookie 串
    public static func normalize(_ kind: AccountKind, _ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .pan123: return Pan123Resolver.normalizeToken(trimmed)
        case .xunlei: return XunleiCredential.parse(trimmed)?.serialized ?? trimmed
        case .guangya: return GuangYaCredential.parse(trimmed)?.serialized ?? trimmed
        case .aliyun: return AliyunCredential.parse(trimmed)?.serialized ?? trimmed
        default: return trimmed
        }
    }

    public static func validate(_ kind: AccountKind, cookie: String) async -> String? {
        switch kind {
        case .quark:
            return await QuarkFamilyResolver(config: .quark, credentials: NoCredentials()).fetchNickname(cookie: cookie)
        case .uc:
            return await QuarkFamilyResolver(config: .uc, credentials: NoCredentials()).fetchNickname(cookie: cookie)
        case .bilibili:
            return await BilibiliParser.nickname(cookie: cookie)
        case .xiaohongshu:
            return await XiaohongshuParser.validate(cookie: cookie)
        case .pixiv:
            return await PixivParser.validate(cookie: cookie)
        case .zhihu:
            return await ZhihuParser.validate(cookie: cookie)
        case .yuanbao:
            return await WxChannelsParser.validate(cookie: cookie)
        case .twitter:
            return await TwitterParser.validate(cookie: cookie)
        case .instagram:
            return await InstagramParser.validate(cookie: cookie)
        case .tiktok:
            return await TikTokParser.validate(cookie: cookie)
        case .reddit:
            return await RedditParser.validate(cookie: cookie)
        case .facebook:
            return await FacebookParser.validate(cookie: cookie)
        case .threads:
            return await ThreadsParser.validate(cookie: cookie)
        case .baidu:
            guard BaiduResolver.isValidCookie(cookie) else { return nil }
            return await BaiduResolver(credentials: NoCredentials()).fetchNickname(cookie: cookie)
        case .pan115:
            guard Pan115Resolver.isValidCookie(cookie) else { return nil }
            return await Pan115Resolver(credentials: NoCredentials()).fetchNickname(cookie: cookie)
        case .pan123:
            let token = Pan123Resolver.normalizeToken(cookie)
            guard !token.isEmpty else { return nil }
            return await Pan123Resolver(credentials: NoCredentials()).fetchNickname(token: token)
        case .c139:
            // 139 没有轻量的账号信息接口：登录态字段齐全且能解出手机号即视为有效（取链时服务端再校验）
            guard C139Resolver.isValidCookie(cookie), C139Resolver.account(in: cookie) != nil else { return nil }
            return C139Resolver.displayAccount(in: cookie) ?? "139 网盘用户"
        case .xunlei:
            guard let cred = XunleiCredential.parse(cookie),
                  await XunleiResolver(credentials: NoCredentials()).validate(cred) else { return nil }
            // 令牌里带用户 ID：取末四位区分多个账号（同名会被当成同一个账号覆盖）
            let sub = XunleiCredential.jwtClaim(cred.accessToken, "sub").string
            if sub.count >= 4 {
                return "迅雷用户 · \(sub.suffix(4))"
            }
            return "迅雷网盘用户"
        case .guangya:
            guard let cred = GuangYaCredential.parse(cookie) else { return nil }
            if let name = await GuangYaLogin.nickname(cred, client: .shared) { return name }
            // 访问令牌过期但 refresh_token 仍有效：续期成功即视为有效（解析器取链时会再续期并回写）
            guard let renewed = await GuangYaLogin.refresh(cred, client: .shared) else { return nil }
            return await GuangYaLogin.nickname(renewed, client: .shared) ?? "光鸭云盘用户"
        case .ilanzou:
            guard let cred = ILanzouCredential.parse(cookie) else { return nil }
            return await ILanzouResolver.accountInfo(appToken: cred.appToken, uuid: cred.uuid, client: .shared)?.nickname
        case .lanzou:
            guard let params = await LanzouAccount.loginParams(cookie: cookie) else { return nil }
            return "蓝奏云用户 \(params.uid)"
        case .aliyun:
            guard let cred = AliyunCredential.parse(cookie) else { return nil }
            return await AliyunCredential.nickname(cred, client: .shared)
        }
    }
}

extension AccountValidator {
    /// 网络是否通到该平台：有任何 HTTP 响应即算通（用来区分「登录失效」与「没网 / 被墙」）
    public static func reachable(_ url: String) async -> Bool {
        (try? await HTTPClient.shared.send(HTTPRequest(url: url, method: "HEAD", timeout: 10))) != nil
    }
}

/// 不提供任何账号的凭证源（校验、测试用）
public struct NoCredentials: CredentialStore {
    public init() {}
    public func cookie(for kind: AccountKind) async -> String? { nil }
    public func updateCookie(_ new: String, replacing old: String, for kind: AccountKind) async {}
}
