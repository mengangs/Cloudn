// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 tiktok 解析。
import Foundation

/// TikTok：抓 `/@_/video/<id>` 网页里的 `__UNIVERSAL_DATA_FOR_REHYDRATION__`（webapp.video-detail）。
/// 遇到 WAF 的 SHA256 工作量证明页先解题写 Cookie 再重试（做法同 yt-dlp）。
/// HTTPClient 关闭了自动 Cookie，这里手工维护 Cookie 罐；下载视频也要带上这些 Cookie 与 Referer。
struct TikTokParser: VideoParser {
    let platform = VideoPlatform.tiktok

    static let pageHeaders: [(String, String)] = [
        ("User-Agent", VideoHTTP.uaChrome),
        ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
        ("Accept-Language", "en-US,en;q=0.9"),
        ("Referer", "https://www.tiktok.com/")
    ]

    struct Media: Equatable {
        let kind: MediaKind
        let url: String
        let quality: String
        var size: Int64 = -1
        /// 同一视频的其余清晰度（从高到低，不含 url 本身）
        var alternatives: [OverseasVariants.Option] = []
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id.isEmpty ? (Self.itemID(from: link.url) ?? "") : link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 TikTok 作品 ID") }
        // 图文也请求 /video/ 页面：/photo/ 页面里没有 webapp.video-detail
        let (html, jar) = try await fetchPage("https://www.tiktok.com/@_/video/\(id)", cookie: cookie)
        guard let scope = Self.universalData(html) else {
            throw VideoParseError(.blocked, "TikTok 返回了验证页面，无法取得作品数据，请稍后重试")
        }
        let item = try Self.extractItem(scope)
        let itemID = item.string("id", "aweme_id")
        if !itemID.isEmpty && itemID != id {
            throw VideoParseError(.unknown, "TikTok 返回的作品与链接不一致")
        }
        let list = try Self.medias(item)
        return build(link, id: id, item: item, list: list, cookie: jar)
    }

    /// 取作品页：手工跟随重定向以收集每一跳的 Set-Cookie；没拿到数据时尝试解 WAF 挑战，最多 3 次
    private func fetchPage(_ url: String, cookie: String) async throws -> (String, String) {
        var jar = cookie
        var html = ""
        for attempt in 0..<3 {
            var current = url
            var response: HTTPResponse?
            for _ in 0..<5 {
                var headers = Self.pageHeaders
                if !jar.isEmpty { headers.append(("Cookie", jar)) }
                let r = try await OverseasHTTP.send(.get(current, headers: headers, followRedirects: false), site: "TikTok")
                jar = OverseasHTTP.merge(jar, r.cookies)
                response = r
                guard (300..<400).contains(r.status), let loc = r.header("Location") else { break }
                current = VideoHTTP.absolutize(base: current, loc)
                if Self.isLoginURL(current) { throw OverseasHTTP.loginRequired("TikTok") }
                if current.lowercased().contains("notfound") {
                    throw VideoParseError(.unknown, "TikTok 页面不可用，可能是地区限制：所在网络无法访问 TikTok，可在设置里配置网络代理")
                }
            }
            guard let r = response else { break }
            if Self.isLoginURL(r.url) { throw OverseasHTTP.loginRequired("TikTok") }
            try VideoHTTP.requireSuccess(r, "TikTok 作品页")
            html = r.text
            if Self.universalData(html) != nil { return (html, jar) }
            if let cookies = Self.solveChallenge(html) {
                for (name, value) in cookies { jar = CookieUtil.setting(name, value, in: jar) }
                continue
            }
            if attempt < 2 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        return (html, jar)
    }

    func build(_ link: DetectedVideoLink, id: String, item: JSON, list: [Media], cookie: String) -> VideoParseResult {
        var headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.tiktok.com/"]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let desc = item["desc"].string
        let base = FileNames.base(String(desc.prefix(60)), fallback: "tiktok_\(id)")
        let single = list.count == 1
        var medias: [VideoMedia] = []
        for (i, m) in list.enumerated() {
            let ext = m.kind == .video ? "mp4" : "jpg"
            let stem = single ? base : "\(base)_\(i + 1)"
            if m.kind == .video {
                let options = [OverseasVariants.Option(url: m.url, quality: m.quality, size: m.size)] + m.alternatives
                medias += OverseasVariants.medias(options, stem: stem, ext: ext, group: "video\(i + 1)", headers: headers)
                continue
            }
            medias.append(VideoMedia(url: m.url, kind: m.kind, fileName: "\(stem).\(ext)", headers: headers, quality: m.quality))
        }
        let author = item["author"]
        let unique = author["uniqueId"].string
        let name = author["nickname"].string
        let url = unique.isEmpty ? link.url : "https://www.tiktok.com/@\(unique)/video/\(id)"
        return VideoParseResult(platform: platform, title: desc.isEmpty ? "TikTok \(id)" : String(desc.prefix(60)),
                                author: name.isEmpty ? unique : name, avatar: author.string("avatarLarger", "avatarMedium", "avatarThumb"),
                                cover: Self.pickCover(item["video"]), text: desc, timestamp: item["createTime"].int64,
                                url: url, medias: medias)
    }

    // MARK: 账号校验

    /// 网页端 passport 账号信息接口：登录后 message=success、data 里有 username / screen_name
    static let accountInfoURL = "https://www.tiktok.com/passport/web/account/info/?aid=1459&app_name=tiktok_web&device_platform=web_pc"

    static func validate(cookie: String) async -> String? {
        let headers: [(String, String)] = [
            ("User-Agent", VideoHTTP.uaChrome), ("Accept", "application/json, text/plain, */*"),
            ("Referer", "https://www.tiktok.com/"), ("Cookie", cookie)
        ]
        let request = HTTPRequest.get(accountInfoURL, headers: headers)
        return await OverseasAccount.probe(.tiktok, cookie: cookie, request) { r in
            Self.probeResult(status: r.status, json: r.json)
        }
    }

    /// 只有明确的「会话过期 / 请登录」才算失效；限流、风控等其余错误说不准
    static func probeResult(status: Int, json: JSON?) -> OverseasAccount.Probe {
        if status == 401 { return .invalid }
        guard (200..<300).contains(status), let json, json.isObject else { return .unknown }
        let data = json["data"]
        if json["message"].string == "success" {
            let nick = data["screen_name"].string
            if !nick.isEmpty { return .valid(nick) }
            let user = data["username"].string
            return .valid(user.isEmpty ? "" : "@" + user)
        }
        let desc = data["description"].string.lowercased()
        let expired = desc.contains("session expired") || desc.contains("sign in") || desc.contains("log in")
        if data["error_code"].int == 4 || expired { return .invalid }
        return .unknown
    }

    // MARK: 纯逻辑

    static func itemID(from url: String) -> String? {
        Rx(#"/(?:video|photo|v)/(\d+)"#).first(in: url)
    }

    static func isLoginURL(_ url: String) -> Bool {
        guard let path = URL(string: url)?.path else { return false }
        return path == "/login" || path.hasPrefix("/login/")
    }

    /// `__UNIVERSAL_DATA_FOR_REHYDRATION__` → `__DEFAULT_SCOPE__`
    static func universalData(_ html: String) -> JSON? {
        let rx = Rx(#"<script[^>]+id=["']__UNIVERSAL_DATA_FOR_REHYDRATION__["'][^>]*>(.*?)</script>"#, dotAll: true)
        guard let raw = rx.first(in: html)?.trimmed, !raw.isEmpty else { return nil }
        guard let json = JSON(text: htmlUnescape(raw)) else { return nil }
        let scope = json["__DEFAULT_SCOPE__"]
        return scope.isObject ? scope : nil
    }

    static func htmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// webapp.video-detail → itemStruct；按 statusCode 给出可读错误
    static func extractItem(_ scope: JSON) throws -> JSON {
        let detail = scope["webapp.video-detail"]
        let item = detail["itemInfo"]["itemStruct"]
        if item.isObject && !(item.dictionary?.isEmpty ?? true) { return item }
        let status = detail["statusCode"].int
        if status == 10216 || status == 10222 { throw OverseasHTTP.loginRequired("TikTok", reason: "这个 TikTok 内容需要登录或无权访问") }
        if status == 10204 { throw VideoParseError(.notFound, "TikTok 作品不存在或不可见") }
        let msg = detail.string("statusMsg", "statusMessage")
        throw VideoParseError(.unknown, "TikTok 页面中没有作品详情（status=\(msg.isEmpty ? String(status) : msg)）")
    }

    /// 作品 → 媒体：图文取每张 displayImage，视频在各码率里取 (分辨率, 码率, 体积) 最大的
    static func medias(_ item: JSON) throws -> [Media] {
        let imagePost = item.object("image_post_info", "imagePost")
        if imagePost.isObject && !(imagePost.dictionary?.isEmpty ?? true) {
            var out: [Media] = []
            for image in imagePost["images"].array {
                let display = firstNonNull(image, ["display_image", "displayImage", "imageURL", "image"])
                if let url = mediaURLs(display).first {
                    out.append(Media(kind: .image, url: url, quality: "原图"))
                }
            }
            if out.isEmpty { throw VideoParseError(.unknown, "TikTok 解析失败：未获取到图文下载地址") }
            return out
        }
        let video = item["video"]
        guard video.isObject else { throw VideoParseError(.unknown, "TikTok 解析失败：未获取到视频数据") }
        guard let best = bestVideo(video) else {
            throw VideoParseError(.unknown, "TikTok 解析失败：未获取到无水印视频下载地址")
        }
        return [best]
    }

    static func bestVideo(_ video: JSON) -> Media? {
        let options = videoOptions(video)
        guard let best = options.first else { return nil }
        return Media(kind: .video, url: best.url, quality: best.quality, size: best.size, alternatives: Array(options.dropFirst()))
    }

    /// 视频的各档清晰度，按 (分辨率, 码率, 体积) 从大到小（同值保持原顺序），第一档即默认下载的那一档。
    /// 没有码率列表时退回 playAddr / downloadAddr，只有一档
    static func videoOptions(_ video: JSON) -> [OverseasVariants.Option] {
        func label(_ w: Int, _ h: Int, hevc: Bool) -> String {
            let side = (w > 0 && h > 0) ? "\(min(w, h))P" : ""
            return hevc && !side.isEmpty ? side + " · H.265" : side
        }
        var list: [(index: Int, key: (Int, Int, Int), option: OverseasVariants.Option)] = []
        for rate in video.arrayValue("bit_rate", "bitrateInfo") {
            let play = firstNonNull(rate, ["play_addr", "PlayAddr"])
            guard let url = preferredVideoURL(play) else { continue }
            let w = firstInt(play, ["width", "Width"], fallback: video["width"].int)
            let h = firstInt(play, ["height", "Height"], fallback: video["height"].int)
            let bitrate = firstInt(rate, ["bit_rate", "Bitrate", "bitrate"], fallback: 0)
            let size = firstInt(play, ["data_size", "DataSize"], fallback: rate["data_size"].int)
            let codec = rate.string("CodecType", "codec_type").lowercased()
            let hevc = rate["is_bytevc1"].int == 1 || rate["is_h265"].int == 1
                || codec.contains("265") || codec.contains("hev") || codec.contains("bytevc1")
            list.append((list.count, (w * h, bitrate, size),
                         OverseasVariants.Option(url: url, quality: label(w, h, hevc: hevc), size: size > 0 ? Int64(size) : -1)))
        }
        if !list.isEmpty {
            list.sort { $0.key != $1.key ? $0.key > $1.key : $0.index < $1.index }
            return list.map { $0.option }
        }
        let play = firstNonNull(video, ["play_addr", "playAddr"])
        if let url = preferredVideoURL(play) {
            let w = firstInt(play, ["width"], fallback: video["width"].int)
            let h = firstInt(play, ["height"], fallback: video["height"].int)
            return [OverseasVariants.Option(url: url, quality: label(w, h, hevc: false))]
        }
        let download = firstNonNull(video, ["download_addr", "downloadAddr"])
        if let url = preferredVideoURL(download) {
            return [OverseasVariants.Option(url: url, quality: label(video["width"].int, video["height"].int, hevc: false))]
        }
        return []
    }

    static func pickCover(_ video: JSON) -> String {
        for key in ["origin_cover", "cover", "dynamic_cover", "originCover", "dynamicCover"] {
            if let url = mediaURLs(video[key]).first { return url }
        }
        return ""
    }

    /// 字符串 / 数组 / 带 url_list 的对象 → 直链列表（参考实现的 media_urls）
    static func mediaURLs(_ data: JSON) -> [String] {
        if let s = data.raw as? String {
            if s.hasPrefix("//") { return ["https:" + s] }
            return (s.hasPrefix("http://") || s.hasPrefix("https://")) ? [s] : []
        }
        if data.isArray { return data.array.flatMap { mediaURLs($0) } }
        guard data.isObject else { return [] }
        for key in ["url_list", "UrlList", "urlList"] where data.has(key) {
            return mediaURLs(data[key])
        }
        return []
    }

    static func preferredVideoURL(_ data: JSON) -> String? {
        let urls = mediaURLs(data)
        return urls.first(where: { $0.contains("aweme") }) ?? urls.first
    }

    private static func firstNonNull(_ obj: JSON, _ keys: [String]) -> JSON {
        for k in keys {
            let v = obj[k]
            if v.isNull { continue }
            if let d = v.dictionary, d.isEmpty { continue }
            if let s = v.raw as? String, s.isEmpty { continue }
            return v
        }
        return JSON(nil)
    }

    private static func firstInt(_ obj: JSON, _ keys: [String], fallback: Int) -> Int {
        for k in keys {
            let v = obj[k].int
            if v != 0 { return v }
        }
        return fallback
    }

    // MARK: WAF 挑战

    /// 页面里 `<... id="name" class="value">` 的 class 值
    static func htmlClass(_ html: String, id: String) -> String? {
        guard let tag = Rx(#"<[^>]+\bid=""# + Rx.escape(id) + #""[^>]*>"#).firstMatch(in: html)?.first else { return nil }
        return Rx(#"\bclass="([^"]*)""#).first(in: tag)
    }

    /// 解 SHA256 工作量证明：sha256(base64d(v.a) + str(i)) == base64d(v.c)，i ∈ [0, 1_000_000]。
    /// 返回要写入的 Cookie（wci 名 → 带答案的挑战 JSON 的 base64；有 rci/rs 时一并返回）
    static func solveChallenge(_ html: String) -> [(String, String)]? {
        guard let encoded = htmlClass(html, id: "cs"), !encoded.isEmpty,
              let cookieName = htmlClass(html, id: "wci"), !cookieName.isEmpty,
              let decoded = Crypto.base64Decode(encoded),
              let challenge = OrderedValue.parse(String(decoding: decoded, as: UTF8.self)),
              let v = challenge.member("v"),
              let aText = v.member("a")?.stringValue, let cText = v.member("c")?.stringValue,
              let a = Crypto.base64Decode(aText), let expected = Crypto.base64Decode(cText) else { return nil }
        guard let answer = proofOfWork(prefix: a, expected: [UInt8](expected)) else { return nil }
        let d = Data(String(answer).utf8).base64EncodedString()
        let solved = challenge.setting("d", .string(d))
        let value = Data(solved.text.utf8).base64EncodedString()
        var out: [(String, String)] = [(cookieName, value)]
        if let rciName = htmlClass(html, id: "rci"), let rciValue = htmlClass(html, id: "rs"), !rciName.isEmpty, !rciValue.isEmpty {
            out.append((rciName, rciValue))
        }
        return out
    }

    static func proofOfWork(prefix: Data, expected: [UInt8], limit: Int = 1_000_000) -> Int? {
        var base = SHA256Hasher()
        base.update(prefix)
        for i in 0...limit {
            var h = base
            h.update(Data(String(i).utf8))
            if h.finalize() == expected { return i }
        }
        return nil
    }
}

/// 保序 JSON（挑战回写时要与 Python `json.dumps(separators=(",", ":"))` 输出一致：键序不变、非 ASCII 转义）
indirect enum OrderedValue: Equatable {
    case object([String], [String: OrderedValue])
    case array([OrderedValue])
    case string(String)
    /// 数字 / true / false / null 原样保留
    case literal(String)

    func member(_ key: String) -> OrderedValue? {
        if case .object(_, let dict) = self { return dict[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    func setting(_ key: String, _ value: OrderedValue) -> OrderedValue {
        guard case .object(var keys, var dict) = self else { return self }
        if dict[key] == nil { keys.append(key) }
        dict[key] = value
        return .object(keys, dict)
    }

    var text: String {
        switch self {
        case .object(let keys, let dict):
            let parts = keys.map { k -> String in
                let v = dict[k] ?? .literal("null")
                return OrderedValue.quote(k) + ":" + v.text
            }
            return "{" + parts.joined(separator: ",") + "}"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .string(let s): return OrderedValue.quote(s)
        case .literal(let s): return s
        }
    }

    /// Python json.dumps（ensure_ascii=True）的字符串转义
    static func quote(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            default:
                if unit < 0x20 || unit > 0x7E {
                    if unit == 0x7F {
                        out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
                    } else {
                        let hex = String(unit, radix: 16)
                        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                    }
                } else {
                    out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
                }
            }
        }
        return out + "\""
    }

    static func parse(_ text: String) -> OrderedValue? {
        var p = Parser(chars: Array(text.unicodeScalars))
        guard let v = p.value() else { return nil }
        p.skipSpace()
        return p.index == p.chars.count ? v : nil
    }

    private struct Parser {
        let chars: [Unicode.Scalar]
        var index = 0
        /// 嵌套层数上限：数据来自网络，嵌套过深会把递归解析的栈撑爆
        var depth = 0
        static let maxDepth = 256

        mutating func skipSpace() {
            let spaces: Set<Unicode.Scalar> = [" ", "\n", "\r", "\t"]
            while index < chars.count, spaces.contains(chars[index]) { index += 1 }
        }

        mutating func value() -> OrderedValue? {
            skipSpace()
            guard index < chars.count, depth < Self.maxDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            switch chars[index] {
            case "{": return object()
            case "[": return array()
            case "\"": return string().map { OrderedValue.string($0) }
            default: return literal()
            }
        }

        mutating func object() -> OrderedValue? {
            index += 1
            var keys: [String] = []
            var dict: [String: OrderedValue] = [:]
            skipSpace()
            if index < chars.count, chars[index] == "}" { index += 1; return .object(keys, dict) }
            while true {
                skipSpace()
                guard index < chars.count, chars[index] == "\"", let key = string() else { return nil }
                skipSpace()
                guard index < chars.count, chars[index] == ":" else { return nil }
                index += 1
                guard let v = value() else { return nil }
                if dict[key] == nil { keys.append(key) }
                dict[key] = v
                skipSpace()
                guard index < chars.count else { return nil }
                if chars[index] == "," { index += 1; continue }
                if chars[index] == "}" { index += 1; return .object(keys, dict) }
                return nil
            }
        }

        mutating func array() -> OrderedValue? {
            index += 1
            var items: [OrderedValue] = []
            skipSpace()
            if index < chars.count, chars[index] == "]" { index += 1; return .array(items) }
            while true {
                guard let v = value() else { return nil }
                items.append(v)
                skipSpace()
                guard index < chars.count else { return nil }
                if chars[index] == "," { index += 1; continue }
                if chars[index] == "]" { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func string() -> String? {
            index += 1
            var units: [UInt16] = []
            while index < chars.count {
                let c = chars[index]
                index += 1
                if c == "\"" { return String(decoding: units, as: UTF16.self) }
                if c != "\\" {
                    units.append(contentsOf: Array(String(c).utf16))
                    continue
                }
                guard index < chars.count else { return nil }
                let e = chars[index]
                index += 1
                switch e {
                case "\"": units.append(0x22)
                case "\\": units.append(0x5C)
                case "/": units.append(0x2F)
                case "b": units.append(0x08)
                case "f": units.append(0x0C)
                case "n": units.append(0x0A)
                case "r": units.append(0x0D)
                case "t": units.append(0x09)
                case "u":
                    guard index + 4 <= chars.count else { return nil }
                    let hex = String(String.UnicodeScalarView(chars[index..<(index + 4)]))
                    guard let unit = UInt16(hex, radix: 16) else { return nil }
                    units.append(unit)
                    index += 4
                default: return nil
                }
            }
            return nil
        }

        mutating func literal() -> OrderedValue? {
            let start = index
            while index < chars.count, !",}] \n\r\t".unicodeScalars.contains(chars[index]) { index += 1 }
            guard index > start else { return nil }
            return .literal(String(String.UnicodeScalarView(chars[start..<index])))
        }
    }
}
