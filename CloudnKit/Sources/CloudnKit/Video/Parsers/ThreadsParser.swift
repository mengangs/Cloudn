// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 threads 解析。
import Foundation

/// Threads：帖子 code 按 Instagram 字母表转成 postID，POST GraphQL（BarcelonaPostPageDirectQuery）。
/// 公开帖子匿名即可；登录墙内容（私密 / 受限）需要 Cookie（与 Instagram 同一套登录）。
struct ThreadsParser: VideoParser {
    let platform = VideoPlatform.threads

    static let graphqlURL = "https://www.threads.com/graphql/query"
    static let homeURL = "https://www.threads.com/"
    static let postDocID = "27419285281047858"
    static let appID = "238260118697367"

    /// 查询强制要求的 relay provider 变量：必须全部传入（值统一 false），会随前端更新变化
    static let relayProviders = [
        "BarcelonaHasPermalinkIndentation", "BarcelonaIsLoggedIn", "BarcelonaHasPostAuthorNotifControls",
        "BarcelonaShouldShowFediverseM1Features", "BarcelonaHasPermalinkPodcastCard", "BarcelonaHasDearAlgoConsumption",
        "BarcelonaHasEventBadge", "BarcelonaGenAIRepliesEnabled", "BarcelonaIsSearchDiscoveryEnabled",
        "BarcelonaHasCommunities", "BarcelonaHasGameScoreShare", "BarcelonaHasPublicViewCountCard",
        "BarcelonaHasCommunityEntityCard", "BarcelonaHasScorecardCommunity", "BarcelonaHasSportTeamAllegianceCard",
        "BarcelonaHasMusic", "BarcelonaHasNewspaperLinkStyle", "BarcelonaHasMessaging",
        "BarcelonaHasPodcastTextFragments", "BarcelonaShouldFulfillLightboxQuery", "BarcelonaHasViewerReplied",
        "BarcelonaHasPrivateRepliesDeprecation", "BarcelonaHasGhostPostEmojiActivation", "BarcelonaOptionalCookiesEnabled",
        "BarcelonaHasDearAlgoWebProduction", "BarcelonaHasWebFavicons", "BarcelonaIsCrawler",
        "BarcelonaHasCommunityTopContributors", "BarcelonaCanSeeSponsoredContent", "BarcelonaShouldShowFediverseM075Features",
        "BarcelonaIsInternalUser"
    ]

    struct Media: Equatable {
        let kind: MediaKind
        let url: String
        var quality: String = ""
        /// 同一视频的其余清晰度（video_versions 里第一条之外的，从高到低）
        var alternatives: [OverseasVariants.Option] = []

        /// video_versions → 视频（第一条为默认）；没有可用链接时为 nil
        static func video(_ versions: [JSON]) -> Media? {
            guard !versions.isEmpty, !versions[0]["url"].string.isEmpty else { return nil }
            let options = OverseasVariants.metaVideoVersions(versions)
            guard let first = options.first else { return nil }
            return Media(kind: .video, url: first.url, quality: first.quality, alternatives: Array(options.dropFirst()))
        }
    }

    /// 登录态：带 Cookie 打开首页（不跟随跳转），被送回登录页即失效；Threads 没有轻量的「当前用户」接口，
    /// 能打开时按关键 Cookie 判定，显示名带上用户 ID 末尾
    static func validate(cookie: String) async -> String? {
        let request = HTTPRequest.get(homeURL, headers: [("User-Agent", VideoHTTP.uaChrome), ("Cookie", cookie)],
                                      followRedirects: false)
        return await OverseasAccount.probe(.threads, cookie: cookie, request) { r in
            probeResult(status: r.status, location: r.header("Location") ?? "")
        }
    }

    static func probeResult(status: Int, location: String) -> OverseasAccount.Probe {
        if (300..<400).contains(status) && location.contains("login") { return .invalid }
        if status == 401 { return .invalid }
        return .unknown
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let code = link.id.isEmpty ? (Self.postCode(from: link.url) ?? "") : link.id
        guard !code.isEmpty, let pk = MetaShortcode.decimal(code) else {
            throw VideoParseError(.unsupported, "无法从链接中识别 Threads 帖子 ID")
        }
        var jar = cookie
        var csrf = CookieUtil.value(of: "csrftoken", in: jar) ?? ""
        if csrf.isEmpty {
            // 拿不到 csrftoken 也继续（参考实现同样视为可选）
            let home = try await OverseasHTTP.send(.get(Self.homeURL, headers: headers(jar: jar, csrf: "")), site: "Threads")
            jar = OverseasHTTP.merge(jar, home.cookies)
            csrf = CookieUtil.value(of: "csrftoken", in: jar) ?? ""
        }
        let form = [("variables", Self.variables(pk: pk)), ("doc_id", Self.postDocID), ("server_timestamps", "true")]
        let r = try await OverseasHTTP.send(.postForm(Self.graphqlURL, form, headers: headers(jar: jar, csrf: csrf), followRedirects: false),
                                            site: "Threads")
        let loginWall = cookie.isEmpty
            ? OverseasHTTP.loginRequired("Threads", reason: "该帖子可能位于登录墙内")
            : VideoParseError(.unknown, "无法获取帖子内容（可能为私人或受限内容，或 Cookie 已失效）")
        if r.status == 429 { throw VideoParseError(.blocked, "Threads 请求过于频繁（HTTP 429），请稍后重试") }
        if (300..<400).contains(r.status) || r.status == 401 || r.status == 403 { throw loginWall }
        guard r.status == 200 else { throw VideoParseError(.unknown, "Threads GraphQL 请求失败（HTTP \(r.status)）") }
        // 未登录被拦时返回的是 HTML 登录页
        guard let payload = r.json, payload.isObject else { throw loginWall }
        if !payload["errors"].array.isEmpty { throw loginWall }
        guard let post = Self.extractPost(payload, code: code) else { throw loginWall }
        if Self.medias(post).isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        return build(link, code: code, post: post)
    }

    private func headers(jar: String, csrf: String) -> [(String, String)] {
        var h: [(String, String)] = [
            ("Accept", "*/*"), ("Referer", Self.homeURL), ("User-Agent", VideoHTTP.uaChrome), ("X-IG-App-ID", Self.appID)
        ]
        if !csrf.isEmpty { h.append(("x-csrftoken", csrf)) }
        if !jar.isEmpty { h.append(("Cookie", jar)) }
        return h
    }

    private func build(_ link: DetectedVideoLink, code: String, post: JSON) -> VideoParseResult {
        let list = Self.medias(post)
        let caption = post["caption"]
        let text = caption.isObject ? caption["text"].string : caption.string
        let user = post["user"]
        let username = user["username"].string
        let title = text.isEmpty ? "Threads \(code)" : String(text.prefix(40))
        let base = FileNames.base(title, fallback: "threads_\(code)")
        let headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.homeURL]
        let single = list.count == 1
        var medias: [VideoMedia] = []
        for (i, m) in list.enumerated() {
            let ext = m.kind == .video ? "mp4" : "jpg"
            let stem = single ? base : "\(base)_\(i + 1)"
            if m.kind == .video {
                let options = [OverseasVariants.Option(url: m.url, quality: m.quality)] + m.alternatives
                medias += OverseasVariants.medias(options, stem: stem, ext: ext, group: "video\(i + 1)", headers: headers)
                continue
            }
            medias.append(VideoMedia(url: m.url, kind: m.kind, fileName: "\(stem).\(ext)", headers: headers))
        }
        let cover = post["image_versions2"]["candidates"][0]["url"].string
        let url = username.isEmpty ? link.url : "https://www.threads.com/@\(username)/post/\(code)"
        return VideoParseResult(platform: platform, title: title, author: username, avatar: user["profile_pic_url"].string,
                                cover: cover, text: text, timestamp: post["taken_at"].int64, url: url, medias: medias)
    }

    // MARK: 纯逻辑

    static func postCode(from url: String) -> String? {
        Rx(#"/(?:post|t)/([A-Za-z0-9_\-]+)"#).first(in: url)
    }

    /// `{"postID":"<pk>","__relay_internal__pv__<名>relayprovider":false,...}`（键序同参考实现）
    static func variables(pk: String) -> String {
        var pairs: [(String, OrderedJSON)] = [("postID", .string(pk))]
        for name in relayProviders {
            pairs.append(("__relay_internal__pv__\(name)relayprovider", .bool(false)))
        }
        return OrderedJSON.object(pairs).text
    }

    /// data.data.edges[].node.thread_items[].post：优先 code 精确匹配，否则第一条
    static func extractPost(_ payload: JSON, code: String) -> JSON? {
        var fallback: JSON?
        for edge in payload["data"]["data"]["edges"].array {
            for item in edge["node"]["thread_items"].array {
                let post = item["post"]
                guard post.isObject else { continue }
                if fallback == nil { fallback = post }
                if post["code"].string == code { return post }
            }
        }
        return fallback
    }

    /// media_type：1 图 / 2 视频 / 8 轮播 / 19 文字帖（取 linked_inline_media）
    static func medias(_ post: JSON, depth: Int = 0) -> [Media] {
        switch post["media_type"].int {
        case 1:
            let url = post["image_versions2"]["candidates"][0]["url"].string
            return url.isEmpty ? [] : [Media(kind: .image, url: url)]
        case 2:
            return Media.video(post["video_versions"].array).map { [$0] } ?? []
        case 8:
            var out: [Media] = []
            for m in post["carousel_media"].array {
                if let video = Media.video(m["video_versions"].array) {
                    out.append(video)
                    continue
                }
                let image = m["image_versions2"]["candidates"][0]["url"].string
                if !image.isEmpty { out.append(Media(kind: .image, url: image)) }
            }
            return out
        case 19:
            let linked = post["text_post_app_info"]["linked_inline_media"]
            return (linked.isObject && depth < 2) ? medias(linked, depth: depth + 1) : []
        default:
            return []
        }
    }
}
