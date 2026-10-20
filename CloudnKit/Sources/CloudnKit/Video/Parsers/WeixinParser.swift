// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 weixin 解析。
import Foundation

/// 微信公众号：文章页内嵌的 `window.cgiDataNew`（JS 对象字面量，非 JSON）。
/// - item_show_type 0（文章）：正文 content_noencode 里 `<img data-src>` 的图片（换成 /0 原尺寸）；
/// - item_show_type 8（图片消息）：picture_page_info_list[].watermark_info.cdn_url（原图），缺失退回 cdn_url；
/// - 任意形态：页面里的公众号视频（mp_video_trans_info 取最大一档，取不到再从页面里搜 mpvideo.qpic.cn 直链）。
struct WeixinParser: VideoParser {
    let platform = VideoPlatform.weixin

    static let payloadName = "cgiDataNew"
    static let blockMarkers = ["环境异常", "secitptpage", "wappoc_appmsgcaptcha", "verify.html"]
    static let goneMarkers = ["该内容已被发布者删除", "此内容因违规无法查看", "此内容被投诉且经审核涉嫌侵权", "该公众号已迁移", "内容已删除"]

    private var mediaHeaders: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://mp.weixin.qq.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        // /s/<token> 形态用 token 重建地址；/s?__biz=... 形态（kind = "params"）原样请求
        let pageURL = link.kind == "article" && !link.id.isEmpty ? "https://mp.weixin.qq.com/s/\(link.id)" : link.url
        let html = try await VideoHTTP.getText(pageURL, headers: ["User-Agent": VideoHTTP.uaChrome], what: "公众号文章")
        let data = Self.payload(html)
        if data == nil {
            if Self.goneMarkers.contains(where: { html.contains($0) }) {
                throw VideoParseError(.notFound, "公众号文章已删除或无法查看")
            }
            if Self.blockMarkers.contains(where: { html.contains($0) }) {
                throw VideoParseError(.blocked, "微信要求环境验证，请稍后重试")
            }
        }
        let json = data ?? JSON(nil)
        let showType = json["item_show_type"].int
        let fallbackTitle = Self.htmlTitle(html)
        let title = json["title"].string.nilIfBlank ?? fallbackTitle
        let base = FileNames.base(title, fallback: "weixin_\(link.id)")

        var images: [String] = []
        var text = ""
        if data == nil {
            // 老版页面没有 cgiDataNew：直接从 #js_content 取图
            let content = Self.jsContent(html)
            images = Self.articleImages(content)
            text = DomesticHTML.text(content)
        } else if showType == 8 {
            images = Self.photos(json)
            text = DomesticHTML.text(json["content_noencode"].string)
        } else if showType == 10 {
            text = DomesticHTML.text(json["text_page_info"]["content_noencode"].string)
        } else {
            let content = json["content_noencode"].string
            images = Self.articleImages(content)
            text = DomesticHTML.text(content)
        }

        var medias: [VideoMedia] = []
        let videos = Self.videos(json, html: html)
        for (i, url) in videos.enumerated() {
            let name = videos.count == 1 ? "\(base).mp4" : "\(base)_v\(i + 1).mp4"
            medias.append(VideoMedia(url: url, kind: .video, fileName: name, headers: mediaHeaders))
        }
        for (i, url) in images.enumerated() {
            medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1).\(Self.imageExtension(url))",
                                     headers: mediaHeaders, quality: "原图"))
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let timestamp = json["ori_create_time"].int64 > 0 ? json["ori_create_time"].int64 : json["create_time"].int64
        return VideoParseResult(platform: platform, title: title, author: json.string("nick_name", "author"),
                                avatar: json.string("round_head_img", "hd_head_img"),
                                cover: json.string("msg_cdn_url", "cdn_url_1_1", "cdn_url").nilIfBlank ?? (images.first ?? ""),
                                text: text, timestamp: timestamp, url: pageURL, medias: medias)
    }

    // MARK: 纯逻辑

    /// 取出 `cgiDataNew = {...}` 并按宽松 JS 字面量解析
    static func payload(_ html: String) -> JSON? {
        guard let r = html.range(of: payloadName) else { return nil }
        let after = html[r.upperBound...]
        guard let brace = after.firstIndex(of: "{") else { return nil }
        guard let lit = JSLiteral.parse(String(after[brace...])) else { return nil }
        let json = lit.json
        return json.isObject ? json : nil
    }

    static func htmlTitle(_ html: String) -> String {
        if let og = Rx(#"<meta\s+property="og:title"\s+content="([^"]*)""#, ignoreCase: true).first(in: html), !og.isEmpty {
            return DomesticHTML.unescape(og)
        }
        return ""
    }

    static func jsContent(_ html: String) -> String {
        guard let r = html.range(of: "id=\"js_content\"") else { return "" }
        return String(html[r.upperBound...])
    }

    /// 正文图片：`<img ... data-src="...">`，换成 /0 原尺寸
    static func articleImages(_ html: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let rx = Rx(#"<img[^>]*?\bdata-src\s*=\s*["']([^"']+)["']"#, ignoreCase: true)
        for m in rx.allMatches(in: html) {
            let url = originalImage(DomesticHTML.absolute(DomesticHTML.unescape(m[1])))
            if seen.insert(url).inserted { result.append(url) }
        }
        return result
    }

    /// 图片消息：优先 watermark_info.cdn_url（原图），否则 cdn_url
    static func photos(_ data: JSON) -> [String] {
        data["picture_page_info_list"].array.map { (entry: JSON) -> String in
            let raw = entry["watermark_info"]["cdn_url"].string.nilIfBlank ?? entry["cdn_url"].string
            return DomesticHTML.unescape(raw)
        }.filter { !$0.isEmpty }
    }

    /// mmbiz.qpic.cn 路径末段是宽度（/640、/300），换成 /0 即原尺寸
    static func originalImage(_ url: String) -> String {
        guard let m = Rx(#"^(https?://mmbiz\.qpic\.cn/[^?#]*/)\d+((?:[?#].*)?)$"#).firstMatch(in: url) else { return url }
        return m[1] + "0" + m[2]
    }

    /// 扩展名取自 wx_fmt 参数，缺失默认 jpg
    static func imageExtension(_ url: String) -> String {
        let fmt = (Rx(#"[?&]wx_fmt=([A-Za-z0-9]+)"#).first(in: url) ?? "").lowercased()
        switch fmt {
        case "jpeg", "jpg": return "jpg"
        case "png", "gif", "webp", "bmp": return fmt
        default: return DomesticHTML.imageExtension(url)
        }
    }

    /// 公众号视频：每个含 mp_video_trans_info 的节点取一路（文件最大的一档）；取不到再从页面里搜 mpvideo 直链
    static func videos(_ data: JSON, html: String) -> [String] {
        var result: [String] = []
        var nodes: [JSON] = []
        collectVideoNodes(data, into: &nodes, depth: 0)
        for node in nodes {
            let entries = node["mp_video_trans_info"].array.filter { !$0["url"].string.isEmpty }
            let best = entries.max { a, b in
                let sa = a["filesize"].int64
                let sb = b["filesize"].int64
                if sa != sb { return sa < sb }
                return a["width"].int * a["height"].int < b["width"].int * b["height"].int
            }
            guard let best else { continue }
            let url = DomesticHTML.unescape(best["url"].string)
            if !result.contains(url) { result.append(url) }
        }
        if !result.isEmpty { return result }
        return pageVideoURLs(html)
    }

    private static func collectVideoNodes(_ node: JSON, into nodes: inout [JSON], depth: Int) {
        guard depth < 12 else { return }
        if node.isObject {
            if node["mp_video_trans_info"].isArray { nodes.append(node) }
            for k in node.keys.sorted() where k != "content_noencode" {
                collectVideoNodes(node[k], into: &nodes, depth: depth + 1)
            }
        } else if node.isArray {
            for item in node.array { collectVideoNodes(item, into: &nodes, depth: depth + 1) }
        }
    }

    /// 页面里的 mpvideo.qpic.cn 直链（JS 字符串里常写成 \x26amp;），按视频 id 去重
    static func pageVideoURLs(_ html: String) -> [String] {
        let rx = Rx(#"https?:(?:\\?/){2}mpvideo\.qpic\.cn\\?/[^'"\s<>]+"#)
        var seenIDs = Set<String>()
        var result: [String] = []
        for m in rx.allMatches(in: html) {
            var url = m[0].replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\x26", with: "&")
                .replacingOccurrences(of: "\\u0026", with: "&")
            url = DomesticHTML.unescape(DomesticHTML.unescape(url))
            let id = Rx(#"mpvideo\.qpic\.cn/([^/?.]+)"#).first(in: url) ?? url
            if seenIDs.insert(id).inserted { result.append(url) }
        }
        return result
    }
}
