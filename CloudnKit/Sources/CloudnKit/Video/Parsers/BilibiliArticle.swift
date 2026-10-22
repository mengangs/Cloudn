// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// MARK: 专栏 / 长图文 opus 的完整正文
//
// 动态详情接口（x/polymer/web-dynamic/v1/detail）对专栏、长图文只给 opus.summary（截断、末尾带「…」）
// 和头一两张图，完整内容要另取：
// - opus 详情 x/polymer/web-dynamic/v1/opus/detail?id=<opus/动态 id>：modules 里
//   MODULE_TYPE_TITLE（标题）、MODULE_TYPE_AUTHOR（作者）、MODULE_TYPE_TOP（图文动态的顶部图集）、
//   MODULE_TYPE_CONTENT（module_content.paragraphs：para_type 1 文字 / 2 图片 / 3 分割线 / 4 引用 /
//   5 列表 / 6 链接卡片 / 7 代码 / 8 标题）
// - 专栏 x/article/view?id=<cvid>：dyn_id_str 指向对应 opus；没有时用 opus.content.paragraphs，
//   再不行用 content（旧版是 HTML，新版编辑器是 {"ops":[…]} 的 Quill delta）+ origin_image_urls

/// 整理好的完整图文
struct BiliOpusArticle: Equatable, Sendable {
    var title = ""
    var author = ""
    var face = ""
    var timestamp: Int64 = 0
    var text = ""
    var pics: [BiliDynamicPic] = []

    var isEmpty: Bool { text.isEmpty && pics.isEmpty }
}

extension BilibiliParser {
    static let opusDetailURL = "https://api.bilibili.com/x/polymer/web-dynamic/v1/opus/detail"
    static let articleViewURL = "https://api.bilibili.com/x/article/view"
    static let opusFeatures = "onlyfansVote,onlyfansAssetsV2,decorationCard,htmlNewStyle,ugcDelete,editable,opusPrivateVisible,tribeeEdit,avatarAutoTheme,avatarTypeOpus"

    /// 带 buvid 指纹的请求头（匿名访问不带会被 -352 风控）
    static func fingerprintedHeaders(_ cookie: String, referer: String) async -> [String: String] {
        var requestCookie = cookie
        if let ids = await buvid() {
            requestCookie = CookieUtil.setting("buvid3", ids.b3, in: requestCookie)
            if !ids.b4.isEmpty { requestCookie = CookieUtil.setting("buvid4", ids.b4, in: requestCookie) }
        }
        var headers = headers(requestCookie)
        headers["Referer"] = referer
        return headers
    }

    /// WBI 签名后的查询串；拿不到密钥就不签（接口多数情况下仍可用）
    static func signedQuery(_ params: [String: String], headers: [String: String]) async -> String {
        if let key = await BilibiliWbi.cache.mixinKey(headers: headers) {
            return BilibiliWbi.sign(params, mixinKey: key, timestamp: Int(Date().timeIntervalSince1970))
        }
        return params.keys.sorted().map { "\($0)=\(BilibiliWbi.encode(params[$0] ?? ""))" }.joined(separator: "&")
    }

    /// opus 详情 → 完整图文；失败返回 nil（调用方退回动态摘要）
    static func fetchOpusArticle(id: String, headers: [String: String]) async -> BiliOpusArticle? {
        let params = ["id": id, "timezone_offset": "-480", "features": opusFeatures]
        let query = await signedQuery(params, headers: headers)
        guard let json = try? await VideoHTTP.getJSON("\(opusDetailURL)?\(query)", headers: headers, what: "B站图文详情"),
              json["code"].int == 0 else { return nil }
        let article = opusArticle(json["data"]["item"])
        return article.isEmpty ? nil : article
    }

    /// 专栏 cv 号 → 完整图文
    static func fetchCVArticle(cvid: String, headers: [String: String]) async throws -> BiliOpusArticle {
        let params = ["id": cvid, "gaia_source": "main_web", "web_location": "333.976"]
        let query = await signedQuery(params, headers: headers)
        let json = try await VideoHTTP.getJSON("\(articleViewURL)?\(query)", headers: headers, what: "B站专栏")
        guard json["code"].int == 0, json["data"].isObject else {
            throw articleError(code: json["code"].int, message: json["message"].string)
        }
        let data = json["data"]
        // 已迁移到 opus 的专栏，opus 详情的段落结构最完整
        let dynID = data["dyn_id_str"].string
        if !dynID.isEmpty, dynID != "0", var full = await fetchOpusArticle(id: dynID, headers: headers) {
            if full.title.isEmpty { full.title = data["title"].string }
            return full
        }
        return cvArticle(data)
    }

    static func articleError(code: Int, message: String) -> VideoParseError {
        switch code {
        case -352: return VideoParseError(.blocked, "B站专栏接口触发风控（-352），请稍后重试")
        case -404, 404: return VideoParseError(.notFound, "B站专栏不存在或已删除")
        default: return VideoParseError(.unknown, "B站专栏接口返回 code=\(code) \(message)")
        }
    }

    /// bilibili.com/read/cvNNN（及 read/mobile?id=、read/native?id=）
    func parseArticle(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let cvid = link.id.isEmpty ? (Rx(#"cv(\d+)"#, ignoreCase: true).first(in: link.url) ?? "") : link.id
        guard !cvid.isEmpty else { throw VideoParseError(.unsupported, "没有识别出B站专栏 ID") }
        let headers = await Self.fingerprintedHeaders(cookie, referer: "https://www.bilibili.com/read/cv\(cvid)")
        let article: BiliOpusArticle
        do {
            article = try await Self.fetchCVArticle(cvid: cvid, headers: headers)
        } catch {
            // 专栏页现在多半 302 到 /opus/<id>：接口不通时顺着跳转拿 opus id
            guard let next = try? await VideoHTTP.expandRedirect("https://www.bilibili.com/read/cv\(cvid)",
                                                                 headers: ["User-Agent": VideoHTTP.uaChrome]),
                  let opusID = Rx(#"/opus/(\d{10,20})"#).first(in: next),
                  let full = await Self.fetchOpusArticle(id: opusID, headers: headers) else { throw error }
            article = full
        }
        return try Self.articleResult(article, id: "cv\(cvid)", url: "https://www.bilibili.com/read/cv\(cvid)", cookie: cookie)
    }

    static func articleResult(_ article: BiliOpusArticle, id: String, url: String, cookie: String) throws -> VideoParseResult {
        guard !article.pics.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let title = article.title.isEmpty ? String(article.text.prefix(40)) : article.title
        let base = FileNames.base(title, fallback: "bilibili_\(id)")
        let medias = dynamicMedias(article.pics, base: base, headers: headers(cookie))
        return VideoParseResult(platform: .bilibili, title: title, author: article.author, avatar: secureImage(article.face),
                                cover: article.pics[0].url, text: article.text, timestamp: article.timestamp,
                                url: url, medias: medias)
    }

    // MARK: 解析（纯函数，便于测试）

    /// opus 详情的 data.item → 完整图文
    static func opusArticle(_ item: JSON) -> BiliOpusArticle {
        var article = BiliOpusArticle()
        var top: [BiliDynamicPic] = []
        var paragraphs: [JSON] = []
        for module in item["modules"].array {
            switch module["module_type"].string {
            case "MODULE_TYPE_TITLE":
                article.title = module["module_title"]["text"].string.trimmed
            case "MODULE_TYPE_AUTHOR":
                let author = module["module_author"]
                article.author = author["name"].string
                article.face = author["face"].string
                article.timestamp = author["pub_ts"].int64
            case "MODULE_TYPE_TOP":
                top += module["module_top"]["display"]["album"]["pics"].array.map(pic)
            case "MODULE_TYPE_CONTENT":
                paragraphs += module["module_content"]["paragraphs"].array
            default:
                break
            }
        }
        let body = renderParagraphs(paragraphs)
        article.text = body.text
        article.pics = dedupePics(top + body.pics)
        if article.title.isEmpty { article.title = item["basic"]["title"].string.trimmed }
        return article
    }

    /// x/article/view 的 data（没有可用的 opus 时）→ 完整图文
    static func cvArticle(_ data: JSON) -> BiliOpusArticle {
        var article = BiliOpusArticle()
        article.title = data["title"].string.trimmed
        article.author = data["author"]["name"].string.nilIfBlank ?? data["author_name"].string
        article.face = data["author"]["face"].string
        article.timestamp = data["publish_time"].int64 > 0 ? data["publish_time"].int64 : data["ctime"].int64
        var pics: [BiliDynamicPic] = []
        let paragraphs = data["opus"]["content"]["paragraphs"].array
        if !paragraphs.isEmpty {
            let body = renderParagraphs(paragraphs)
            article.text = body.text
            pics = body.pics
        } else {
            let content = data["content"].string
            if content.trimmed.hasPrefix("{"), let delta = JSON(text: content), delta["ops"].isArray {
                let body = renderDelta(delta["ops"].array)
                article.text = body.text
                pics = body.pics
            } else {
                let body = renderHTML(content)
                article.text = body.text
                pics = body.pics
            }
        }
        if pics.isEmpty {
            let urls = data["origin_image_urls"].array.map(\.string).filter { !$0.isEmpty }
            pics = (urls.isEmpty ? data["image_urls"].array.map(\.string) : urls).map { BiliDynamicPic(url: $0, liveURL: "") }
        }
        if pics.isEmpty, !data["banner_url"].string.isEmpty { pics = [BiliDynamicPic(url: data["banner_url"].string, liveURL: "")] }
        article.pics = dedupePics(pics)
        if article.text.isEmpty { article.text = data["summary"].string.trimmed }
        return article
    }

    /// opus 段落 → 文本（段落间换行）+ 按出现顺序的图片
    static func renderParagraphs(_ paragraphs: [JSON]) -> (text: String, pics: [BiliDynamicPic]) {
        var lines: [String] = []
        var pics: [BiliDynamicPic] = []
        for para in paragraphs {
            switch para["para_type"].int {
            case 2:
                pics += para["pic"]["pics"].array.map(pic)
            case 3:
                lines.append("————")
            case 4:
                let quote = nodesText(para["text"]["nodes"])
                if !quote.trimmed.isEmpty {
                    lines.append(quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n"))
                }
            case 5:
                let ordered = para["list"]["style"].int == 1
                var index = 0
                for item in para["list"]["items"].array {
                    let text = nodesText(item["nodes"])
                    guard !text.trimmed.isEmpty else { continue }
                    index += 1
                    let indent = String(repeating: "  ", count: max(0, item["level"].int - 1))
                    let order = item["order"].int > 0 ? item["order"].int : index
                    lines.append(indent + (ordered ? "\(order). " : "• ") + text)
                }
            case 6:
                let card = para["link_card"]["card"]
                let title = linkCardTitle(card)
                if !title.isEmpty { lines.append("[\(title)]") }
            case 7:
                let code = para["code"]["content"].string
                if !code.trimmed.isEmpty { lines.append(code) }
            default:
                // 1 正文、8 标题，以及以后新增的带文字段落
                let nodes = para["text"]["nodes"].isArray ? para["text"]["nodes"] : para["heading"]["nodes"]
                let text = nodesText(nodes)
                if !text.trimmed.isEmpty { lines.append(text) }
                pics += para["pic"]["pics"].array.map(pic)
            }
        }
        return (normalizeText(lines.joined(separator: "\n")), pics)
    }

    static func nodesText(_ nodes: JSON) -> String {
        nodes.array.map { node -> String in
            if node["word"].isObject { return node["word"]["words"].string }
            if node["rich"].isObject {
                let rich = node["rich"]
                return rich["text"].string.nilIfBlank ?? rich["orig_text"].string
            }
            if node["formula"].isObject { return node["formula"]["latex_content"].string }
            return node["text"].string
        }.joined()
    }

    static func linkCardTitle(_ card: JSON) -> String {
        for key in card.keys.sorted() where card[key].isObject {
            let title = card[key]["title"].string.trimmed
            if !title.isEmpty { return title }
        }
        return ""
    }

    /// 新版专栏编辑器的 Quill delta：字符串 insert 是文字，native-image / image 是图片
    static func renderDelta(_ ops: [JSON]) -> (text: String, pics: [BiliDynamicPic]) {
        var text = ""
        var pics: [BiliDynamicPic] = []
        for op in ops {
            let insert = op["insert"]
            if let s = insert.raw as? String {
                text += s
            } else if insert.isObject {
                let url = insert["native-image"]["url"].string.nilIfBlank ?? insert["image"]["url"].string.nilIfBlank
                    ?? (insert["image"].raw as? String) ?? ""
                if !url.isEmpty { pics.append(BiliDynamicPic(url: url, liveURL: "")) }
                if !text.hasSuffix("\n") && !text.isEmpty { text += "\n" }
            }
        }
        return (normalizeText(text), pics)
    }

    /// 旧版专栏的 HTML 正文：块级标签换行、去标签；图片取 data-src / src
    static func renderHTML(_ html: String) -> (text: String, pics: [BiliDynamicPic]) {
        var pics: [BiliDynamicPic] = []
        for m in Rx(#"<img\b[^>]*>"#, ignoreCase: true).allMatches(in: html) {
            let tag = m[0]
            let url = Rx(#"\bdata-src\s*=\s*["']([^"']+)["']"#, ignoreCase: true).first(in: tag)
                ?? Rx(#"\bsrc\s*=\s*["']([^"']+)["']"#, ignoreCase: true).first(in: tag) ?? ""
            // 表情、分割线等小图标不算正文图片
            if !url.isEmpty, !url.contains("/bfs/emote/"), !tag.contains("cut-off") { pics.append(BiliDynamicPic(url: url, liveURL: "")) }
        }
        var s = Rx(#"<(script|style)\b.*?</\1>"#, ignoreCase: true, dotAll: true).replacing(in: html, with: "")
        s = Rx(#"<br\s*/?>"#, ignoreCase: true).replacing(in: s, with: "\n")
        s = Rx(#"</(p|h[1-6]|li|blockquote|figure|div|pre)>"#, ignoreCase: true).replacing(in: s, with: "\n")
        s = Rx(#"<[^>]+>"#).replacing(in: s, with: "")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return (normalizeText(s), pics)
    }

    /// 行尾空白去掉、空行去掉（段落间一个换行，与 opus 段落拼接一致），首尾 trim
    static func normalizeText(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = String(line)
                while let last = l.last, last == " " || last == "\t" || last == "\u{3000}" { l.removeLast() }
                return l
            }
        return lines.filter { !$0.trimmed.isEmpty }.joined(separator: "\n").trimmed
    }

    static func pic(_ json: JSON) -> BiliDynamicPic {
        BiliDynamicPic(url: json["url"].string.nilIfBlank ?? json["src"].string, liveURL: json["live_url"].string)
    }

    /// https、去掉 `@1256w_….webp` 之类的缩略图后缀（取原图），按地址去重并丢掉空地址
    static func dedupePics(_ pics: [BiliDynamicPic]) -> [BiliDynamicPic] {
        var seen = Set<String>()
        var out: [BiliDynamicPic] = []
        for p in pics {
            let url = secureImage(p.url)
            guard !url.isEmpty, seen.insert(url).inserted else { continue }
            out.append(BiliDynamicPic(url: url, liveURL: secure(p.liveURL)))
        }
        return out
    }

    static func secureImage(_ url: String) -> String {
        var u = secure(url.trimmed)
        guard u.contains("hdslb.com/") || u.contains("biliimg.com/") else { return u }
        if let q = u.firstIndex(of: "?") { u = String(u[..<q]) }
        if let slash = u.lastIndex(of: "/"), let at = u[slash...].firstIndex(of: "@") { u = String(u[..<at]) }
        return u
    }
}
