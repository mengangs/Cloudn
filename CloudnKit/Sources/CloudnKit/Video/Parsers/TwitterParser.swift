// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 twitter 解析。
import Foundation

/// X（Twitter）：GraphQL TweetResultByRestId。
/// 未登录走游客令牌（静态 Bearer + guest/activate）；Cookie 里有 ct0 + auth_token 时按登录态请求。
struct TwitterParser: VideoParser {
    let platform = VideoPlatform.twitter

    static let bearer = "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    static let queryURL = "https://api.x.com/graphql/kPLTRmMnzbPTv70___D06w/TweetResultByRestId"
    static let features = #"{"creator_subscriptions_tweet_preview_api_enabled":true,"communities_web_enable_tweet_community_results_fetch":true,"c9s_tweet_anatomy_moderator_badge_enabled":true,"tweetypie_unmention_optimization_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"creator_subscriptions_quote_tweet_preview_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"tweet_with_visibility_results_prefer_gql_media_interstitial_enabled":false,"rweb_video_timestamps_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"rweb_tipjar_consumption_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_enhance_cards_enabled":false}"#
    static let fieldToggles = #"{"withArticleRichContentState":true,"withArticlePlainText":false}"#

    /// 解析出的一条媒体（纯数据，便于离线测试）
    struct Media: Equatable {
        let kind: MediaKind
        let url: String
        let quality: String
    }

    struct Tweet {
        var id = ""
        var title = ""
        var text = ""
        var author = ""
        var avatar = ""
        var timestamp: Int64 = 0
        var medias: [Media] = []
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id.isEmpty ? (Self.tweetID(from: link.url) ?? "") : link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别推文 ID") }
        let loggedIn = Self.hasLoginCookie(cookie)
        var headers = Self.apiHeaders(cookie: cookie)
        if !loggedIn, let guest = try await guestToken() {
            headers.append(("x-guest-token", guest))
        }
        let r = try await OverseasHTTP.send(.get(Self.requestURL(id: id), headers: headers), site: "X")
        switch r.status {
        case 200: break
        case 401, 403:
            if loggedIn { throw VideoParseError(.unknown, "X 拒绝了请求（HTTP \(r.status)），登录可能已失效，请到「我的」页重新登录 X") }
            throw OverseasHTTP.loginRequired("X")
        case 404: throw VideoParseError(.notFound, "推文不存在（HTTP 404）")
        case 429:
            if loggedIn { throw VideoParseError(.blocked, "X 接口请求过于频繁（HTTP 429），请稍后重试") }
            throw VideoParseError(.blocked, "X 游客接口请求过于频繁（HTTP 429），请稍后重试；到「我的」页登录 X 后可避开游客限额")
        default: throw VideoParseError(.unknown, "X 接口请求失败（HTTP \(r.status)）")
        }
        guard let json = r.json else { throw VideoParseError(.unknown, "X 接口返回的不是合法 JSON") }
        let tweet = try Self.parseTweet(json, loggedIn: loggedIn)
        if tweet.medias.isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        return build(link, id: id, tweet: tweet)
    }

    /// 游客令牌：拿不到也不致命，按参考实现直接带 Bearer 请求
    private func guestToken() async throws -> String? {
        let request = HTTPRequest(url: "https://api.x.com/1.1/guest/activate.json", method: "POST",
                                  headers: [("authorization", Self.bearer), ("user-agent", VideoHTTP.uaChrome)])
        let r = try await OverseasHTTP.send(request, site: "X")
        guard r.isSuccess else { return nil }
        return r.json?["guest_token"].string.nilIfBlank
    }

    private func build(_ link: DetectedVideoLink, id: String, tweet: Tweet) -> VideoParseResult {
        let headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://x.com/"]
        let title = tweet.title.isEmpty ? String(tweet.text.prefix(40)) : tweet.title
        let base = FileNames.base(title, fallback: "x_\(id)")
        let single = tweet.medias.count == 1
        var medias: [VideoMedia] = []
        for (i, m) in tweet.medias.enumerated() {
            let ext = m.kind == .video ? "mp4" : Self.imageExtension(m.url)
            let name = single ? "\(base).\(ext)" : "\(base)_\(i + 1).\(ext)"
            medias.append(VideoMedia(url: m.url, kind: m.kind, fileName: name, headers: headers, quality: m.quality))
        }
        let cover = tweet.medias.first(where: { $0.kind == .image })?.url ?? ""
        let screen = tweet.author
        let url = screen.isEmpty ? "https://x.com/i/status/\(id)" : "https://x.com/\(screen)/status/\(id)"
        return VideoParseResult(platform: platform, title: title, author: screen, avatar: tweet.avatar, cover: cover,
                                text: tweet.text, timestamp: tweet.timestamp, url: url, medias: medias)
    }

    // MARK: 纯逻辑

    static func tweetID(from url: String) -> String? {
        Rx(#"status(?:es)?/(\d+)"#).first(in: url)
    }

    static func hasLoginCookie(_ cookie: String) -> Bool {
        let ct0 = csrfToken(cookie) ?? ""
        let auth = CookieUtil.value(of: "auth_token", in: cookie) ?? ""
        return !ct0.isEmpty && !auth.isEmpty
    }

    /// 网页 Cookie 里的 ct0 即 CSRF 令牌，登录态请求须原样放进 x-csrf-token
    static func csrfToken(_ cookie: String) -> String? {
        guard let v = CookieUtil.value(of: "ct0", in: cookie)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")),
              !v.isEmpty else { return nil }
        return v
    }

    /// API 请求头：带登录 Cookie 时按网页登录态（Cookie + x-csrf-token + OAuth2Session），否则只带公共 Bearer
    static func apiHeaders(cookie: String) -> [(String, String)] {
        var headers: [(String, String)] = [
            ("accept-language", "zh-CN,zh;q=0.9"), ("authorization", bearer), ("content-type", "application/json"),
            ("user-agent", VideoHTTP.uaChrome), ("x-twitter-active-user", "yes"), ("x-twitter-client-language", "zh-cn")
        ]
        if hasLoginCookie(cookie) {
            headers.append(("x-csrf-token", csrfToken(cookie) ?? ""))
            headers.append(("x-twitter-auth-type", "OAuth2Session"))
            headers.append(("Cookie", cookie))
        }
        return headers
    }

    // MARK: 账号校验

    /// 网页客户端启动时就会请求的账号设置接口，返回 screen_name
    static let settingsURL = "https://api.x.com/1.1/account/settings.json"

    static func validate(cookie: String) async -> String? {
        guard hasLoginCookie(cookie) else { return nil }
        let request = HTTPRequest.get(settingsURL, headers: apiHeaders(cookie: cookie))
        return await OverseasAccount.probe(.twitter, cookie: cookie, request) { r in
            Self.probeResult(status: r.status, json: r.json)
        }
    }

    /// 401/403（未登录 code 32/215、ct0 不匹配 code 353）算失效；其余（429、5xx）说不准
    static func probeResult(status: Int, json: JSON?) -> OverseasAccount.Probe {
        if status == 401 || status == 403 { return .invalid }
        guard (200..<300).contains(status), let json, json.isObject else { return .unknown }
        let screen = json["screen_name"].string
        return screen.isEmpty ? .unknown : .valid("@" + screen)
    }

    static func requestURL(id: String) -> String {
        let variables = #"{"tweetId":"\#(id)","withCommunity":false,"includePromotedContent":false,"withVoice":false}"#
        return queryURL + "?variables=" + variables.urlQueryEncoded + "&features=" + features.urlQueryEncoded
            + "&fieldToggles=" + fieldToggles.urlQueryEncoded
    }

    /// GraphQL 响应 → 推文；错误按参考实现映射成可读提示
    static func parseTweet(_ json: JSON, loggedIn: Bool = false) throws -> Tweet {
        let result = json["data"]["tweetResult"]["result"]
        if !result.isObject {
            if let first = json["errors"].array.first {
                throw VideoParseError(.unknown, "X 接口返回错误：\(first["message"].string)")
            }
            throw VideoParseError(.notFound, "帖子或用户不存在")
        }
        return try parseResult(result, loggedIn: loggedIn, allowQuote: true)
    }

    private static func parseResult(_ result: JSON, loggedIn: Bool, allowQuote: Bool) throws -> Tweet {
        // TweetWithVisibilityResults 把真正的推文包在 tweet 里
        let node = result["tweet"].isObject ? result["tweet"] : result
        let legacy = node["legacy"]
        if !legacy.isObject {
            if result["__typename"].string == "TweetTombstone" {
                if loggedIn { throw VideoParseError(.notFound, "该推文不可见（已删除或受限）") }
                throw OverseasHTTP.loginRequired("X", reason: "该推文开启了限制，匿名用户无法查看")
            }
            switch result["reason"].string {
            case "Suspended": throw VideoParseError(.notFound, "这个帖子来自一个被冻结的账号")
            case "BounceDeleted": throw VideoParseError(.notFound, "这个帖子违反了 X 规则，已不可见")
            case "Protected":
                throw VideoParseError(.unknown, "该账号设置了受保护，只有获准的关注者才能查看其帖子")
            default:
                throw VideoParseError(.unknown, "无法查看这条推文：\(result["reason"].string)")
            }
        }

        var tweet = Tweet()
        tweet.id = node["rest_id"].string
        tweet.timestamp = parseTime(legacy["created_at"].string)
        let user = node["core"]["user_results"]["result"]
        let screen = user["core"]["screen_name"].string
        tweet.author = screen.isEmpty ? user["legacy"]["screen_name"].string : screen
        let avatar = user["avatar"]["image_url"].string
        tweet.avatar = avatar.isEmpty ? user["legacy"]["profile_image_url_https"].string : avatar

        let articleNode = node["article"].isObject ? node["article"] : result["article"]
        let article = articleNode["article_results"]["result"]
        if article.isObject {
            tweet.title = article["title"].string
            tweet.text = article["preview_text"].string
            tweet.medias = articleMedias(article)
            return tweet
        }

        let note = node["note_tweet"]["note_tweet_results"]["result"]["text"].string
        let fullText = note.isEmpty ? legacy["full_text"].string : note
        tweet.medias = legacyMedias(legacy)
        if !tweet.medias.isEmpty {
            tweet.text = Rx(#"\s*https://t\.co/[^\s,]+$"#).replacing(in: fullText, with: "")
        } else {
            tweet.text = fullText
        }
        // 推广推文等把视频放在卡片（unified_card）里
        if tweet.medias.isEmpty { tweet.medias = cardMedias(node["card"]) }
        // 自己没有媒体的引用推文：取被引用推文里的媒体
        let quoted = node["quoted_status_result"]["result"]
        if tweet.medias.isEmpty && allowQuote && quoted.isObject,
           let inner = try? parseResult(quoted, loggedIn: loggedIn, allowQuote: false) {
            tweet.medias = inner.medias
        }
        return tweet
    }

    /// legacy.extended_entities.media（缺失时退回 entities.media）→ 媒体列表
    static func legacyMedias(_ legacy: JSON) -> [Media] {
        var list = legacy["extended_entities"]["media"].array
        if list.isEmpty { list = legacy["entities"]["media"].array }
        return mediaItems(list)
    }

    /// 卡片里的 unified_card（JSON 字符串）→ media_entities，结构与推文媒体相同
    static func cardMedias(_ card: JSON) -> [Media] {
        for binding in card["legacy"]["binding_values"].array where binding["key"].string == "unified_card" {
            guard let unified = JSON(text: binding["value"]["string_value"].string) else { continue }
            let entities = unified["media_entities"]
            let medias = mediaItems(entities.keys.sorted().map { entities[$0] })
            if !medias.isEmpty { return medias }
        }
        return []
    }

    static func mediaItems(_ list: [JSON]) -> [Media] {
        var out: [Media] = []
        for item in list {
            let type = item["type"].string
            if type == "photo" {
                let raw = item["media_url_https"].string
                guard !raw.isEmpty else { continue }
                out.append(Media(kind: .image, url: imageURL(raw, size: "orig"), quality: "原图"))
            } else if type == "video" || type == "animated_gif" {
                let variants = item["video_info"]["variants"].array
                let best = bestMP4(variants)
                let url = best.isEmpty ? variants.last?["url"].string ?? "" : best
                guard !url.isEmpty else { continue }
                let quality = type == "animated_gif" ? "GIF" : resolution(of: url)
                out.append(Media(kind: .video, url: url, quality: quality))
            }
        }
        return out
    }

    /// 长文（Article）：封面 + 正文内嵌的图片/视频
    static func articleMedias(_ article: JSON) -> [Media] {
        var out: [Media] = []
        let cover = article["cover_media"]["media_info"]["original_img_url"].string
        if !cover.isEmpty { out.append(Media(kind: .image, url: cover, quality: "封面")) }
        for entity in article["media_entities"].array {
            let info = entity["media_info"]
            switch info["__typename"].string {
            case "ApiImage":
                let url = info["original_img_url"].string
                if !url.isEmpty && !out.contains(where: { $0.url == url }) {
                    out.append(Media(kind: .image, url: url, quality: "原图"))
                }
            case "ApiVideo", "ApiGif":
                let url = bestMP4(info["variants"].array)
                if !url.isEmpty { out.append(Media(kind: .video, url: url, quality: resolution(of: url))) }
            default: continue
            }
        }
        return out
    }

    /// 码率最高的 mp4 变体（legacy 用 bitrate，Article 用 bit_rate）
    static func bestMP4(_ variants: [JSON]) -> String {
        var bestURL = ""
        var bestRate = -1
        for v in variants where v["content_type"].string == "video/mp4" {
            let rate = v.has("bitrate") ? v["bitrate"].int : v["bit_rate"].int
            let url = v["url"].string
            if !url.isEmpty && rate > bestRate {
                bestRate = rate
                bestURL = url
            }
        }
        return bestURL
    }

    static func imageURL(_ url: String, size: String) -> String {
        let sep = url.contains("?") ? "&" : "?"
        return "\(url)\(sep)name=\(size)"
    }

    static func imageExtension(_ url: String) -> String {
        let path = url.substringBefore("?")
        let ext = (path as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "gif"].contains(ext) { return ext }
        if let fmt = Rx(#"[?&]format=(\w+)"#).first(in: url) { return fmt.lowercased() }
        return "jpg"
    }

    /// 视频直链路径里的 `1280x720` 当清晰度
    static func resolution(of url: String) -> String {
        Rx(#"/(\d{2,5}x\d{2,5})/"#).first(in: url) ?? ""
    }

    /// `Wed Oct 10 20:19:24 +0000 2018` → 秒
    static func parseTime(_ s: String) -> Int64 {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f.date(from: s).map { Int64($0.timeIntervalSince1970) } ?? 0
    }
}

/// 海外平台共用：网络层失败多半是所在网络到不了该站，给出可操作的提示；以及手工 Cookie 罐。
enum OverseasHTTP {
    static func send(_ request: HTTPRequest, site: String) async throws -> HTTPResponse {
        do {
            return try await HTTPClient.shared.send(request)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw unreachable(site)
        }
    }

    static func unreachable(_ site: String) -> VideoParseError {
        VideoParseError(.unknown, "所在网络无法访问 \(site)，可在设置里配置网络代理")
    }

    /// 支持在「我的」页登录的海外站点（与 OverseasAccount.kinds 的 displayName 对应）
    static let accountSites: Set<String> = ["X", "Instagram", "TikTok", "Reddit", "Facebook"]

    static func loginRequired(_ site: String, reason: String = "") -> VideoParseError {
        let prefix = reason.isEmpty ? "" : reason + "。"
        let action = accountSites.contains(site) ? "，请先到「我的」页登录 \(site)" : ""
        return VideoParseError(.unknown, "\(prefix)该内容需要登录 \(site) 后才能查看\(action)")
    }

    /// 把响应里的 Set-Cookie 合进 Cookie 串（空值多为删除指令，忽略）
    static func merge(_ jar: String, _ cookies: [(name: String, value: String)]) -> String {
        var result = jar
        for c in cookies where !c.value.isEmpty {
            result = CookieUtil.setting(c.name, c.value, in: result)
        }
        return result
    }
}
