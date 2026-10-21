// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 instagram 解析。
import Foundation

/// Instagram：先取首页拿 csrftoken，再 POST GraphQL（doc_id 查询 shortcode）。
/// 先匿名请求；受限（登录墙 / 年龄限制）且有 Cookie 时再带 Cookie 重试。
struct InstagramParser: VideoParser {
    let platform = VideoPlatform.instagram

    static let graphqlURL = "https://www.instagram.com/graphql/query"
    static let homeURL = "https://www.instagram.com/"
    static let rulingURL = "https://www.instagram.com/api/v1/web/get_ruling_for_content/"
    static let appID = "936619743392459"
    static let shortcodeDocID = "27128499623469141"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

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

    struct Post {
        var code = ""
        var caption = ""
        var title = ""
        var author = ""
        var avatar = ""
        var timestamp: Int64 = 0
        var medias: [Media] = []
    }

    /// 受限（需要登录）——匿名失败时才值得带 Cookie 重试
    struct Restricted: Error { let message: String }

    /// 游客请求被限流（HTTP 429）——有 Cookie 时改用登录态重试
    struct RateLimited: Error {}

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let code = link.id.isEmpty ? (Self.shortcode(from: link.url) ?? "") : link.id
        guard !code.isEmpty else { throw VideoParseError(.unsupported, "Instagram 帖子链接无效") }
        let post: Post
        do {
            post = try await fetch(code, cookie: "")
        } catch let r as Restricted {
            guard !cookie.isEmpty else { throw OverseasHTTP.loginRequired("Instagram", reason: r.message) }
            post = try await fetchLoggedIn(code, cookie: cookie)
        } catch is RateLimited {
            guard !cookie.isEmpty else {
                throw VideoParseError(.blocked, "Instagram 游客请求过于频繁（HTTP 429），请稍后重试；到「我的」页登录 Instagram 后可避开游客限额")
            }
            post = try await fetchLoggedIn(code, cookie: cookie)
        }
        return build(link, code: code, post: post)
    }

    /// 带登录 Cookie 再取一次：先匿名是为了少用账号请求，降低账号被风控的概率
    private func fetchLoggedIn(_ code: String, cookie: String) async throws -> Post {
        do {
            return try await fetch(code, cookie: cookie)
        } catch let again as Restricted {
            throw VideoParseError(.unknown, "\(again.message)（登录可能已失效，请到「我的」页重新登录 Instagram）")
        } catch is RateLimited {
            throw VideoParseError(.blocked, "Instagram 请求过于频繁（HTTP 429），请稍后重试")
        }
    }

    private func fetch(_ code: String, cookie: String) async throws -> Post {
        var jar = CookieUtil.join("ig_pr=1; ig_vw=1920", cookie)
        var csrf = CookieUtil.value(of: "csrftoken", in: jar) ?? ""
        if csrf.isEmpty {
            let home = try await OverseasHTTP.send(.get(Self.homeURL, headers: baseHeaders(jar: jar, csrf: "")), site: "Instagram")
            jar = OverseasHTTP.merge(jar, home.cookies)
            csrf = CookieUtil.value(of: "csrftoken", in: jar) ?? ""
        }
        guard !csrf.isEmpty else { throw VideoParseError(.blocked, "无法获取 Instagram csrftoken，可能被风控拦截，请稍后重试") }

        let variables = #"{"shortcode":"\#(code)","__relay_internal__pv__PolarisAIGMMediaWebLabelEnabledrelayprovider":false}"#
        let form = [("variables", variables), ("doc_id", Self.shortcodeDocID), ("server_timestamps", "true")]
        let r = try await OverseasHTTP.send(.postForm(Self.graphqlURL, form, headers: baseHeaders(jar: jar, csrf: csrf), followRedirects: false),
                                            site: "Instagram")
        if (300..<400).contains(r.status) || r.status == 401 {
            throw Restricted(message: "Instagram 要求登录")
        }
        if r.status == 429 { throw RateLimited() }
        guard r.status == 200 else { throw VideoParseError(.unknown, "Instagram GraphQL 请求失败（HTTP \(r.status)）") }
        guard let payload = r.json, payload.isObject else {
            throw Restricted(message: "Instagram 返回了非 JSON 响应（多半是登录页）")
        }
        let status = payload["status"].string
        if !status.isEmpty && status != "ok" {
            throw VideoParseError(.unknown, "Instagram GraphQL 状态异常：\(payload["message"].string)")
        }
        if payload["data"].isNull && !payload["errors"].isNull {
            try await checkRuling(code, jar: jar, csrf: csrf)
        }
        return try Self.extractPost(payload)
    }

    /// GraphQL 报错时查内容裁决接口解释原因；查不到静默返回
    private func checkRuling(_ code: String, jar: String, csrf: String) async throws {
        guard let id = MetaShortcode.decimal(code, truncate: true) else { return }
        var headers = baseHeaders(jar: jar, csrf: csrf)
        headers.append(("X-IG-App-ID", Self.appID))
        let url = Self.rulingURL + "?content_type=MEDIA&target_id=\(id)"
        guard let r = try? await HTTPClient.shared.send(.get(url, headers: headers)), let body = r.json, body.isObject else { return }
        if body["message"].string == "Media cannot be found" {
            throw VideoParseError(.notFound, "帖子不存在或已被删除")
        }
        let title = body["title"].string
        if !title.isEmpty {
            let desc = body["description"].string
            throw Restricted(message: desc.isEmpty ? title : "\(title)：\(desc)")
        }
    }

    private func baseHeaders(jar: String, csrf: String) -> [(String, String)] {
        var h: [(String, String)] = [
            ("Accept", "*/*"), ("Accept-Language", "en-US,en;q=0.8"),
            ("Referer", "https://www.instagram.com/"), ("User-Agent", Self.userAgent)
        ]
        if !csrf.isEmpty { h.append(("x-csrftoken", csrf)) }
        if !jar.isEmpty { h.append(("Cookie", jar)) }
        return h
    }

    func build(_ link: DetectedVideoLink, code: String, post: Post) -> VideoParseResult {
        let headers = ["User-Agent": Self.userAgent, "Referer": "https://www.instagram.com/"]
        let title = post.title.isEmpty ? String(post.caption.prefix(40)) : post.title
        let base = FileNames.base(title, fallback: "instagram_\(code)")
        let single = post.medias.count == 1
        var medias: [VideoMedia] = []
        for (i, m) in post.medias.enumerated() {
            let ext = m.kind == .video ? "mp4" : "jpg"
            let stem = single ? base : "\(base)_\(i + 1)"
            if m.kind == .video {
                let options = [OverseasVariants.Option(url: m.url, quality: m.quality)] + m.alternatives
                medias += OverseasVariants.medias(options, stem: stem, ext: ext, group: "video\(i + 1)", headers: headers)
                continue
            }
            medias.append(VideoMedia(url: m.url, kind: m.kind, fileName: "\(stem).\(ext)", headers: headers))
        }
        let cover = post.medias.first(where: { $0.kind == .image })?.url ?? ""
        return VideoParseResult(platform: platform, title: title.isEmpty ? "Instagram \(code)" : title, author: post.author,
                                avatar: post.avatar, cover: cover, text: post.caption, timestamp: post.timestamp,
                                url: "https://www.instagram.com/p/\(code)/", medias: medias)
    }

    // MARK: 账号校验

    /// 网页「编辑资料」页用的当前用户接口：未登录时 302 到登录页或返回 login_required
    static let currentUserURL = "https://www.instagram.com/api/v1/accounts/current_user/?edit=true"

    static func validate(cookie: String) async -> String? {
        var headers: [(String, String)] = [
            ("Accept", "*/*"), ("User-Agent", userAgent), ("Referer", homeURL),
            ("X-IG-App-ID", appID), ("X-Requested-With", "XMLHttpRequest"), ("Cookie", cookie)
        ]
        if let csrf = CookieUtil.value(of: "csrftoken", in: cookie), !csrf.isEmpty { headers.append(("X-CSRFToken", csrf)) }
        let request = HTTPRequest.get(currentUserURL, headers: headers, followRedirects: false)
        return await OverseasAccount.probe(.instagram, cookie: cookie, request) { r in
            Self.probeResult(status: r.status, json: r.json)
        }
    }

    static func probeResult(status: Int, json: JSON?) -> OverseasAccount.Probe {
        if (300..<400).contains(status) || status == 401 { return .invalid }
        let message = json?["message"].string ?? ""
        // checkpoint_required：账号需要在官方应用里完成验证，登录态暂不可用
        if message == "login_required" || message == "checkpoint_required" { return .invalid }
        guard (200..<300).contains(status), let json, json.isObject else { return .unknown }
        let name = json["user"]["username"].string
        return name.isEmpty ? .unknown : .valid(name)
    }

    // MARK: 纯逻辑

    static func shortcode(from url: String) -> String? {
        Rx(#"/(?:p|reels?|tv)/([A-Za-z0-9_\-]+)"#).first(in: url)
    }

    /// GraphQL 响应 → 帖子：兼容旧版 xdt_shortcode_media 与新版 web_info.items（v1 结构）
    static func extractPost(_ payload: JSON) throws -> Post {
        let data = payload["data"]
        guard data.isObject else {
            let msg = payload["errors"][0]["message"].string
            throw VideoParseError(.unknown, msg.isEmpty ? "Instagram 响应缺少 data" : "Instagram 返回错误：\(msg)")
        }
        if data["xdt_shortcode_media"].isObject { return try graphPost(data["xdt_shortcode_media"]) }
        if data.has("xdt_shortcode_media") {
            throw Restricted(message: "受限内容无法匿名解析（可能需年满 18 周岁或帖子为私密）")
        }
        let webInfo = data["xdt_api__v1__media__shortcode__web_info"]
        guard webInfo.isObject else { throw VideoParseError(.unknown, "Instagram 响应缺少帖子数据（接口可能已变更）") }
        guard let item = webInfo["items"].array.first, item.isObject else {
            throw Restricted(message: "受限内容无法匿名解析（可能需年满 18 周岁或帖子为私密）")
        }
        return try v1Post(item)
    }

    /// 旧 GraphQL 节点（GraphImage / GraphVideo / GraphSidecar，可能带 XDT 前缀）
    static func graphPost(_ node: JSON) throws -> Post {
        var post = Post()
        post.code = node.string("shortcode", "code")
        post.title = node["title"].string
        let edges = node["edge_media_to_caption"]["edges"].array
        post.caption = edges.isEmpty ? node["caption"].string : edges[0]["node"]["text"].string
        post.author = node["owner"]["username"].string
        post.avatar = node["owner"]["profile_pic_url"].string
        post.timestamp = node["taken_at_timestamp"].int64
        let typename = node["__typename"].string
        if typename.hasSuffix("GraphSidecar") {
            for edge in node["edge_sidecar_to_children"]["edges"].array {
                if let m = graphMedia(edge["node"]) { post.medias.append(m) }
            }
        } else if let m = graphMedia(node) {
            post.medias.append(m)
        }
        if post.medias.isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        return post
    }

    private static func graphMedia(_ node: JSON) -> Media? {
        let video = node["video_url"].string
        if node["is_video"].bool && !video.isEmpty { return Media(kind: .video, url: video) }
        let image = node.string("display_url", "display_src")
        return image.isEmpty ? nil : Media(kind: .image, url: image)
    }

    /// 新版 v1 结构：media_type 1 图 / 2 视频 / 8 轮播
    static func v1Post(_ item: JSON) throws -> Post {
        var post = Post()
        post.code = item["code"].string
        post.title = item["title"].string
        let caption = item["caption"]
        post.caption = caption.isObject ? caption["text"].string : caption.string
        post.author = item["user"]["username"].string
        post.avatar = item["user"]["profile_pic_url"].string
        post.timestamp = item["taken_at"].int64
        let carousel = item["carousel_media"].array
        if item["media_type"].int == 8 || !carousel.isEmpty {
            for child in carousel {
                if let m = v1Media(child) { post.medias.append(m) }
            }
        } else if let m = v1Media(item) {
            post.medias.append(m)
        }
        if post.medias.isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        return post
    }

    private static func v1Media(_ item: JSON) -> Media? {
        if item["media_type"].int == 2, let video = Media.video(item["video_versions"].array) { return video }
        let image = item["image_versions2"]["candidates"][0]["url"].string
        return image.isEmpty ? nil : Media(kind: .image, url: image)
    }
}

/// Instagram / Threads 共用的 shortcode ↔ 数字 ID（base64 字母表 `A-Za-z0-9-_`）。
/// 结果可能超出 Int64，按十进制大数逐位计算。
enum MetaShortcode {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// truncate：Instagram 私密帖的 shortcode 超过 28 位时只取去掉末 28 位的前缀
    static func decimal(_ code: String, truncate: Bool = false) -> String? {
        var chars = Array(code)
        if truncate && chars.count > 28 { chars = Array(chars.dropLast(28)) }
        guard !chars.isEmpty else { return nil }
        // 小端存储的十进制位
        var digits: [Int] = [0]
        for ch in chars {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            var carry = v
            for i in 0..<digits.count {
                let x = digits[i] * 64 + carry
                digits[i] = x % 10
                carry = x / 10
            }
            while carry > 0 {
                digits.append(carry % 10)
                carry /= 10
            }
        }
        while digits.count > 1 && digits.last == 0 { digits.removeLast() }
        return digits.reversed().map { String($0) }.joined()
    }
}
