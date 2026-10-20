// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 tumblr 解析。
import Foundation

/// Tumblr：先从登录页拿网页版公开的 API_TOKEN，再请求 `/api/v2/blog/<blog>/posts/<id>/permalink`
/// 拿 NPF 内容块（转帖链 trail 里的原帖 + 本帖），取图片原图 / Tumblr 自家视频与音频（外站嵌入跳过）。
/// 接口不可用时退回帖子页面（WhatsApp UA 可绕过同意页）的 og:image / og:video。
struct TumblrParser: VideoParser {
    let platform = VideoPlatform.tumblr

    static let subdomainRx = Rx(#"([A-Za-z0-9\-]+)\.tumblr\.com/(?:post|image|video/[A-Za-z0-9\-]+)/(\d+)"#, ignoreCase: true)
    static let pathRx = Rx(#"(?<![A-Za-z0-9.\-])(?:www\.)?tumblr\.com/(?:blog/view/)?([A-Za-z0-9\-]+)/(\d+)"#, ignoreCase: true)
    static let referer = "https://www.tumblr.com/"

    struct Item: Equatable {
        let kind: MediaKind
        let url: String
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var target = Self.blogAndID(link.url)
        if target == nil {
            let expanded = try await OverseasHTTP.expandShareLink(link.url, until: Self.subdomainRx, site: "Tumblr")
            target = Self.blogAndID(expanded)
        }
        guard let target else { throw VideoParseError(.unsupported, "无法从链接中识别 Tumblr 帖子") }
        let blog = target.blog
        let id = target.id

        if let post = try await fetchAPI(blog: blog, id: id) {
            let items = Self.items(post)
            if !items.isEmpty { return build(post: post, blog: blog, id: id, items: items, pageTitle: "") }
            if Self.hasExternalVideo(post) {
                throw VideoParseError(.unsupported, "该帖子的视频来自外部网站，请到原站解析")
            }
        }
        let page = try await fetchPage(blog: blog, id: id)
        if page.items.isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        return build(post: JSON(nil), blog: blog, id: id, items: page.items, pageTitle: page.title)
    }

    /// 网页版 API；令牌或接口拿不到返回 nil（交给页面兜底），明确 404 直接报错
    private func fetchAPI(blog: String, id: String) async throws -> JSON? {
        let login = try await OverseasHTTP.send(.get("https://www.tumblr.com/login", headers: [("User-Agent", VideoHTTP.uaChrome)]),
                                                site: "Tumblr")
        guard let token = Rx(#""API_TOKEN"\s*:\s*"(\w+)""#).first(in: login.text) else { return nil }
        let url = "https://www.tumblr.com/api/v2/blog/\(blog)/posts/\(id)/permalink"
        let headers: [(String, String)] = [("Accept", "application/json"), ("Authorization", "Bearer \(token)"),
                                           ("Referer", Self.referer), ("User-Agent", VideoHTTP.uaChrome)]
        let r = try await OverseasHTTP.send(.get(url, headers: headers), site: "Tumblr")
        if r.status == 404 { throw VideoParseError(.notFound, "帖子不存在或已删除（HTTP 404）") }
        guard r.isSuccess, let json = r.json else { return nil }
        let post = json["response"]["timeline"]["elements"][0]
        return post.isObject ? post : nil
    }

    private func fetchPage(blog: String, id: String) async throws -> (items: [Item], title: String) {
        let url = "https://\(blog).tumblr.com/post/\(id)"
        let r = try await OverseasHTTP.send(.get(url, headers: [("User-Agent", "WhatsApp/2.0")]), site: "Tumblr")
        if r.status == 404 { throw VideoParseError(.notFound, "帖子不存在或已删除（HTTP 404）") }
        if Rx(#"(?:tumblr\.com|^)/(?:safe-mode|login_required|blog/view)"#).matches(r.url) {
            throw VideoParseError(.unknown, "该帖子仅登录后可见（敏感内容或仅限仪表盘），暂不支持登录 Tumblr")
        }
        guard r.isSuccess else { throw VideoParseError(.unknown, "Tumblr 页面请求失败（HTTP \(r.status)）") }
        return (Self.pageItems(r.text), Self.pageTitle(r.text))
    }

    private func build(post: JSON, blog: String, id: String, items: [Item], pageTitle: String) -> VideoParseResult {
        let headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer, "Accept": "*/*"]
        let text = Self.text(post)
        var title = post["summary"].string.trimmed
        if title.isEmpty { title = String(text.prefix(40)) }
        if title.isEmpty { title = pageTitle }
        let base = FileNames.base(title, fallback: "tumblr_\(id)")
        let single = items.count == 1
        var medias: [VideoMedia] = []
        for (i, item) in items.enumerated() {
            let ext: String
            switch item.kind {
            case .video: ext = "mp4"
            case .audio: ext = Self.audioExtension(item.url)
            case .image: ext = DomesticHTML.imageExtension(item.url)
            }
            let name = single ? "\(base).\(ext)" : "\(base)_\(i + 1).\(ext)"
            medias.append(VideoMedia(url: item.url, kind: item.kind, fileName: name, headers: headers))
        }
        var author = post["reblogged_root_name"].string
        if author.isEmpty { author = post["blog_name"].string }
        if author.isEmpty { author = blog }
        var timestamp = post["trail"][0]["post"]["timestamp"].int64
        if timestamp == 0 { timestamp = post["timestamp"].int64 }
        let cover = items.first(where: { $0.kind == .image })?.url ?? ""
        let url = post["post_url"].string.isEmpty ? "https://\(blog).tumblr.com/post/\(id)" : post["post_url"].string
        return VideoParseResult(platform: platform, title: title.isEmpty ? "Tumblr \(id)" : title, author: author,
                                cover: cover, text: text, timestamp: timestamp, url: url, medias: medias)
    }

    // MARK: 纯逻辑

    /// 链接 → (博客名, 帖子 ID)
    static func blogAndID(_ url: String) -> (blog: String, id: String)? {
        if let m = subdomainRx.firstMatch(in: url), m[1].lowercased() != "www" { return (m[1], m[2]) }
        if let m = pathRx.firstMatch(in: url) { return (m[1], m[2]) }
        return nil
    }

    /// NPF 内容块：转帖链里的原帖内容在前，本帖追加内容在后
    static func blocks(_ post: JSON) -> [JSON] {
        var out: [JSON] = []
        for entry in post["trail"].array { out.append(contentsOf: entry["content"].array) }
        out.append(contentsOf: post["content"].array)
        return out
    }

    static func items(_ post: JSON) -> [Item] {
        var out: [Item] = []
        for block in blocks(post) {
            switch block["type"].string {
            case "image":
                let url = bestImage(block["media"].array)
                if !url.isEmpty { out.append(Item(kind: .image, url: url)) }
            case "video", "audio":
                let provider = block["provider"].string
                guard provider.isEmpty || provider == "tumblr" else { continue }
                let media = block["media"].isArray ? block["media"][0] : block["media"]
                var url = media["url"].string
                if url.isEmpty && provider == "tumblr" { url = block["url"].string }
                guard !url.isEmpty else { continue }
                out.append(Item(kind: block["type"].string == "audio" ? .audio : .video, url: url))
            default:
                continue
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.url).inserted }
    }

    /// NPF 图片的多档尺寸：has_original_dimensions 那档就是原图，否则取最宽
    static func bestImage(_ media: [JSON]) -> String {
        if let original = media.first(where: { $0["has_original_dimensions"].bool }) {
            let url = original["url"].string
            if !url.isEmpty { return url }
        }
        var best = ""
        var bestWidth = -1
        for m in media {
            let url = m["url"].string
            let width = m["width"].int
            if !url.isEmpty && width > bestWidth {
                best = url
                bestWidth = width
            }
        }
        return best
    }

    static func hasExternalVideo(_ post: JSON) -> Bool {
        blocks(post).contains { block in
            let provider = block["provider"].string
            return block["type"].string == "video" && !provider.isEmpty && provider != "tumblr"
        }
    }

    static func text(_ post: JSON) -> String {
        let parts = blocks(post).filter { $0["type"].string == "text" }.map { $0["text"].string }.filter { !$0.isEmpty }
        return parts.joined(separator: "\n\n")
    }

    /// 帖子页兜底：og:video（或 Tumblr 视频直链）+ og:image
    static func pageItems(_ html: String) -> [Item] {
        var out: [Item] = []
        var videos = OverseasHTTP.metaContent("og:video", in: html)
        videos += OverseasHTTP.metaContent("og:video:url", in: html)
        if let source = Rx(#"https?://(?:ve|va)\.media\.tumblr\.com/[^"'\s<>]+?\.mp4"#).first(in: html, group: 0) {
            videos.append(source)
        }
        for url in videos where url.hasPrefix("http") && !out.contains(where: { $0.url == url }) {
            out.append(Item(kind: .video, url: url))
            break
        }
        for url in OverseasHTTP.metaContent("og:image", in: html) where url.contains("media.tumblr.com") {
            if !out.contains(where: { $0.url == url }) { out.append(Item(kind: .image, url: url)) }
        }
        return out
    }

    static func pageTitle(_ html: String) -> String {
        let raw = Rx(#"<title>(.*?)</title>"#, dotAll: true).first(in: html) ?? ""
        let title = DomesticHTML.unescape(raw).trimmed
        return Rx(#"\s*\|\s*Tumblr$"#).replacing(in: title, with: "")
    }

    static func audioExtension(_ url: String) -> String {
        let ext = (url.substringBefore("?") as NSString).pathExtension.lowercased()
        return ["mp3", "m4a", "ogg", "wav", "aac"].contains(ext) ? ext : "mp3"
    }
}
