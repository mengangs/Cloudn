// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 zhihu 解析。
import Foundation

/// 知乎：回答 / 问题（取第一个回答）/ 专栏文章 / 想法（pin）/ 日报（跟随「查看知乎原文」）。
///
/// - 接口要求请求头 `x-zse-96` 签名：md5(版本 + 路径 + d_c0) 后做魔改 SM4-CBC + 自定义 base64；
/// - 签名依赖 Cookie 里的 `d_c0`，且未登录基本拿不到内容，所以必须先登录知乎；
/// - 只取媒体：回答/文章正文里的图片、想法里的原图和视频（最高清晰度）。
struct ZhihuParser: VideoParser {
    let platform = VideoPlatform.zhihu

    static let zse93 = "101_3_3.0"
    static let loginURL = "https://www.zhihu.com/signin"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36 Edg/123.0.0.0"
    static let needLogin = "知乎需要登录：请先到「我的」页登录知乎"
    static let noMedia = "这条内容没有可下载的图片或视频"

    /// 链接指向的内容
    enum Target: Equatable {
        case answer(String)
        case question(String)
        case article(String)
        case pin(String)
        case story(String)
    }

    // MARK: 入口

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        guard let dC0 = Self.dC0(in: cookie) else { throw VideoParseError(.unsupported, Self.needLogin) }
        guard let target = Self.target(kind: link.kind, id: link.id) ?? Self.target(of: link.url) else {
            throw VideoParseError(.unsupported, "不支持的知乎链接形态")
        }
        return try await parse(target, cookie: cookie, dC0: dC0, followStory: true)
    }

    private func parse(_ target: Target, cookie: String, dC0: String, followStory: Bool) async throws -> VideoParseResult {
        switch target {
        case .answer(let id):
            return try await parseAnswer(id, cookie: cookie, dC0: dC0)
        case .question(let qid):
            let list = try await api("https://www.zhihu.com/api/v4/questions/\(qid)/answers",
                                     query: [("offset", ""), ("limit", "1"), ("sort_by", "default"), ("include", "data[*].content")],
                                     cookie: cookie, dC0: dC0, what: "知乎问题回答列表")
            let first = list["data"][0]["id"].string
            guard !first.isEmpty else { throw VideoParseError(.unsupported, "这个问题还没有回答，没有可下载的图片或视频") }
            return try await parseAnswer(first, cookie: cookie, dC0: dC0)
        case .article(let id):
            return try await parseArticle(id, cookie: cookie, dC0: dC0)
        case .pin(let id):
            return try await parsePin(id, cookie: cookie, dC0: dC0)
        case .story(let id):
            guard followStory else { throw VideoParseError(.unsupported, "知乎日报原文链接无法识别") }
            return try await parseStory(id, cookie: cookie, dC0: dC0)
        }
    }

    private func parseAnswer(_ id: String, cookie: String, dC0: String) async throws -> VideoParseResult {
        let json = try await api("https://www.zhihu.com/api/v4/answers/\(id)", query: [("include", "data[*].content")],
                                 cookie: cookie, dC0: dC0, what: "知乎回答")
        let title = json["question"]["title"].string
        var refs = Self.contentImages(json["content"].string).map { (url: $0, kind: MediaKind.image) }
        // 视频回答：视频挂在 attachment 上
        let attachedVariants = Self.playlistVariants(json["attachment"]["video"]["video_info"])
        if let attached = attachedVariants.first?.url { refs.insert((url: attached, kind: MediaKind.video), at: 0) }
        let qid = json["question"]["id"].string
        let url = qid.isEmpty ? "https://www.zhihu.com/answer/\(id)" : "https://www.zhihu.com/question/\(qid)/answer/\(id)"
        let author = json["author"]
        return try build(refs, title: title, fallback: "zhihu_answer_\(id)", author: author["name"].string,
                         avatar: author["avatar_url"].string, text: Self.stripHTML(json["excerpt"].string),
                         timestamp: json["created_time"].int64, url: url,
                         variants: attachedVariants.isEmpty ? [:] : [attachedVariants[0].url: attachedVariants])
    }

    private func parseArticle(_ id: String, cookie: String, dC0: String) async throws -> VideoParseResult {
        let json = try await api("https://zhuanlan.zhihu.com/api/articles/\(id)", query: [], cookie: cookie, dC0: dC0, what: "知乎专栏文章")
        let refs = Self.contentImages(json["content"].string).map { (url: $0, kind: MediaKind.image) }
        let author = json["author"]
        return try build(refs, title: json["title"].string, fallback: "zhihu_article_\(id)", author: author["name"].string,
                         avatar: author["avatar_url"].string, cover: json.string("image_url", "title_image"),
                         text: Self.stripHTML(json["excerpt"].string), timestamp: json["created"].int64,
                         url: "https://zhuanlan.zhihu.com/p/\(id)")
    }

    private func parsePin(_ id: String, cookie: String, dC0: String) async throws -> VideoParseResult {
        let json = try await api("https://www.zhihu.com/api/v4/pins/\(id)", query: [], cookie: cookie, dC0: dC0, what: "知乎想法")
        var refs = Self.pinMedias(json)
        var variants = Self.pinVideoVariants(json)
        // 转发的想法：自己没有媒体时取原想法的
        if refs.isEmpty && json["origin_pin"].isObject {
            refs = Self.pinMedias(json["origin_pin"])
            variants = Self.pinVideoVariants(json["origin_pin"])
        }
        let text = Self.pinText(json)
        let author = json["author"]
        return try build(refs, title: String(text.prefix(40)), fallback: "zhihu_pin_\(id)", author: author["name"].string,
                         avatar: author["avatar_url"].string, text: text, timestamp: json["created"].int64,
                         url: "https://www.zhihu.com/pin/\(id)", variants: variants)
    }

    /// 日报正文里找「查看知乎原文」跳回知乎本站解析（日报接口本身不需要签名）
    private func parseStory(_ id: String, cookie: String, dC0: String) async throws -> VideoParseResult {
        let json = try await VideoHTTP.getJSON("https://daily.zhihu.com/api/7/story/\(id)", headers: ["User-Agent": Self.ua], what: "知乎日报")
        let body = json["body"].string
        if let origin = Self.storyOriginURL(body), let target = Self.target(of: origin) {
            return try await parse(target, cookie: cookie, dC0: dC0, followStory: false)
        }
        // 没有原文链接：退回日报正文里的图片
        let refs = Self.contentImages(body).map { (url: $0, kind: MediaKind.image) }
        guard !refs.isEmpty else { throw VideoParseError(.unsupported, "未在知乎日报中找到原文链接，也没有可下载的图片") }
        return try build(refs, title: json["title"].string, fallback: "zhihu_story_\(id)", cover: json["image"].string,
                         url: "https://daily.zhihu.com/story/\(id)")
    }

    /// variants：视频默认地址 → 该视频的各档清晰度（第一档即默认地址）
    private func build(_ refs: [(url: String, kind: MediaKind)], title: String, fallback: String, author: String = "",
                       avatar: String = "", cover: String = "", text: String = "", timestamp: Int64 = 0, url: String,
                       variants: [String: [DomesticVariant]] = [:]) throws -> VideoParseResult {
        guard !refs.isEmpty else { throw VideoParseError(.unsupported, Self.noMedia) }
        let base = FileNames.base(title, fallback: fallback)
        let headers = ["User-Agent": Self.ua, "Referer": "https://www.zhihu.com/"]
        var medias: [VideoMedia] = []
        for (i, ref) in refs.enumerated() {
            let ext = ref.kind == .video ? "mp4" : Self.imageExt(ref.url)
            let name = refs.count == 1 ? "\(base).\(ext)" : "\(base)_\(i + 1).\(ext)"
            if ref.kind == .video, let list = variants[ref.url], list.count > 1 {
                let stem = refs.count == 1 ? base : "\(base)_\(i + 1)"
                medias += DomesticVariant.medias(list, base: stem, ext: ext, group: "video\(i + 1)", headers: headers)
                continue
            }
            let isHLS = ref.kind == .video && ref.url.contains(".m3u8")
            let quality = ref.kind == .video ? "最高清晰度" : "原图"
            medias.append(VideoMedia(url: ref.url, kind: ref.kind, fileName: name, isHLS: isHLS, headers: headers, quality: quality))
        }
        let firstImage = refs.first(where: { $0.kind == .image })?.url ?? ""
        return VideoParseResult(platform: .zhihu, title: title, author: author, avatar: avatar,
                                cover: cover.isEmpty ? firstImage : cover, text: text, timestamp: timestamp, url: url, medias: medias)
    }

    // MARK: 请求

    /// 带 x-zse-96 签名的 GET。签名用未编码的查询串（与网页端一致），实际请求把方括号转义
    private func api(_ base: String, query: [(String, String)], cookie: String, dC0: String, what: String) async throws -> JSON {
        let path = Self.signPath(url: base, query: query)
        let signature = Self.xZse96(path: path, dC0: dC0)
        let url = base + Self.encodedQuery(query)
        let r = try await VideoHTTP.send(.get(url, headers: Self.apiHeaders(signature, cookie: cookie)))
        return try Self.check(r, what)
    }

    static func apiHeaders(_ signature: String, cookie: String) -> [(String, String)] {
        [
            ("Accept", "*/*"),
            ("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6"),
            ("Origin", "https://zhuanlan.zhihu.com"),
            ("Referer", "https://zhuanlan.zhihu.com/"),
            ("sec-ch-ua", #""Microsoft Edge";v="123", "Not:A-Brand";v="8", "Chromium";v="123""#),
            ("sec-ch-ua-mobile", "?0"),
            ("sec-ch-ua-platform", #""Windows""#),
            ("Sec-Fetch-Dest", "empty"),
            ("Sec-Fetch-Mode", "cors"),
            ("Sec-Fetch-Site", "same-site"),
            ("User-Agent", ua),
            ("X-Requested-With", "fetch"),
            ("x-zse-93", zse93),
            ("x-zse-96", signature),
            ("Cookie", cookie)
        ]
    }

    /// 知乎接口出错时返回 `{"error":{"code":…,"message":…}}`（HTTP 状态可能是 401/403/404）
    static func check(_ r: HTTPResponse, _ what: String) throws -> JSON {
        let json = r.json ?? JSON(nil)
        let error = json["error"]
        if error.isObject {
            throw mapError(status: r.status, code: error["code"].int, message: error["message"].string)
        }
        try VideoHTTP.requireSuccess(r, what)
        guard json.isObject else { throw VideoParseError(.unknown, "\(what) 返回的不是合法 JSON") }
        return json
    }

    static func mapError(status: Int, code: Int, message: String) -> VideoParseError {
        if status == 401 || code == 100 || code == 101 {
            return VideoParseError(.unsupported, "知乎登录已失效，请到「我的」页重新登录知乎")
        }
        if status == 404 || status == 410 { return VideoParseError(.notFound, "知乎内容不存在或已删除（\(message)）") }
        if status == 403 { return VideoParseError(.blocked, "知乎拒绝了请求（\(code)：\(message)）") }
        return VideoParseError(.unknown, "知乎接口错误 \(code)：\(message)")
    }

    /// 登录态校验：带签名请求 /api/v4/me，返回昵称
    static func validate(cookie: String) async -> String? {
        guard let dC0 = dC0(in: cookie) else { return nil }
        let base = "https://www.zhihu.com/api/v4/me"
        let headers = apiHeaders(xZse96(path: signPath(url: base, query: []), dC0: dC0), cookie: cookie)
        guard let r = try? await HTTPClient.shared.send(.get(base, headers: headers)), r.isSuccess,
              let json = r.json, json.isObject, !json["error"].isObject else { return nil }
        let name = json["name"].string
        return name.isEmpty ? "知乎用户" : name
    }

    // MARK: 链接

    static func dC0(in cookie: String) -> String? {
        guard !cookie.isEmpty, let v = CookieUtil.value(of: "d_c0", in: cookie), !v.isEmpty else { return nil }
        return v
    }

    /// VideoLinkParser 的 kind + id → 内容
    static func target(kind: String, id: String) -> Target? {
        guard !id.isEmpty else { return nil }
        switch kind {
        case "answer": return .answer(id)
        case "question": return .question(id)
        case "article": return .article(id)
        case "pin": return .pin(id)
        case "story": return .story(id)
        default: return nil
        }
    }

    /// 从完整链接识别（日报原文链接、规则 id 不可用时）
    static func target(of url: String) -> Target? {
        guard url.lowercased().contains("zhihu.com") else { return nil }
        if let a = Rx(#"/answer/(\d+)"#).first(in: url) { return .answer(a) }
        if let q = Rx(#"/question/(\d+)"#).first(in: url) { return .question(q) }
        if url.contains("zhuanlan."), let p = Rx(#"/p/(\d+)"#).first(in: url) { return .article(p) }
        if let p = Rx(#"/pin/(\d+)"#).first(in: url) { return .pin(p) }
        if let s = Rx(#"/story/(\d+)"#).first(in: url) { return .story(s) }
        return nil
    }

    /// 日报 body 里文字含「查看知乎原文」的 <a> 的 href
    static func storyOriginURL(_ body: String) -> String? {
        let rx = Rx(#"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>((?:(?!</a>).)*?)</a>"#, ignoreCase: true, dotAll: true)
        for m in rx.allMatches(in: body) where m.count > 2 && m[2].contains("查看知乎原文") {
            return https(decodeEntities(m[1]))
        }
        return nil
    }

    // MARK: 签名

    /// 签名用的路径：path + "?" + 未编码的 k=v（按传入顺序）
    static func signPath(url: String, query: [(String, String)]) -> String {
        let afterScheme = url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
        let path = afterScheme.firstIndex(of: "/").map { String(afterScheme[$0...]) } ?? "/"
        guard !query.isEmpty else { return path }
        return path + "?" + query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// 实际发出的查询串：只转义 URL 里不合法的方括号，其余保持原样（与签名串一一对应）
    static func encodedQuery(_ query: [(String, String)]) -> String {
        guard !query.isEmpty else { return "" }
        let parts = query.map { pair -> String in
            let v = pair.1.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
            return "\(pair.0)=\(v)"
        }
        return "?" + parts.joined(separator: "&")
    }

    /// x-zse-96 头的值。iv 仅供测试注入，正常请求用随机 16 字节
    static func xZse96(path: String, dC0: String, iv: [UInt8]? = nil) -> String {
        let source = [zse93, path, dC0].joined(separator: "+")
        return "2.0_" + encryptMD5(source, iv: iv)
    }

    /// md5(source) 后加密，返回不带 "2.0_" 前缀的签名主体
    static func encryptMD5(_ source: String, iv: [UInt8]? = nil) -> String {
        let digest = Crypto.md5Hex(source)
        let theIV = iv ?? (0..<16).map { _ in UInt8.random(in: 0...255) }
        return encrypt(digest: digest, iv: theIV)
    }

    /// digest[14...] 的 ASCII 补齐到 32 字节 → SM4-CBC → iv + 密文 → 自定义 base64
    static func encrypt(digest: String, iv: [UInt8]) -> String {
        let tail: [UInt8] = Array(Array(digest.utf8).dropFirst(14))
        let plain = pkcs7(tail)
        let cipher = sm4CBC(plain, iv: iv)
        return customBase64(iv + cipher)
    }

    static func pkcs7(_ data: [UInt8], block: Int = 16) -> [UInt8] {
        let pad = block - data.count % block
        return data + [UInt8](repeating: UInt8(pad), count: pad)
    }

    static func sm4CBC(_ data: [UInt8], iv: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var prev = iv
        var offset = 0
        while offset + 16 <= data.count {
            var xored = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { xored[i] = data[offset + i] ^ prev[i] }
            prev = sm4Block(xored)
            result += prev
            offset += 16
        }
        return result
    }

    static func sm4Block(_ block: [UInt8]) -> [UInt8] {
        var x = [UInt32](repeating: 0, count: 36)
        for i in 0..<4 { x[i] = loadBE(block, i * 4) }
        for i in 0..<32 {
            let mixed: UInt32 = x[i + 1] ^ x[i + 2] ^ x[i + 3] ^ sm4ZK[i]
            x[i + 4] = x[i] ^ tauL(mixed)
        }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for word in [x[35], x[34], x[33], x[32]] {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    private static func loadBE(_ a: [UInt8], _ o: Int) -> UInt32 {
        let b0 = UInt32(a[o]) << 24
        let b1 = UInt32(a[o + 1]) << 16
        let b2 = UInt32(a[o + 2]) << 8
        return b0 | b1 | b2 | UInt32(a[o + 3])
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    /// S 盒逐字节替换后做 L 变换
    private static func tauL(_ x: UInt32) -> UInt32 {
        let t0 = UInt32(sm4ZB[Int((x >> 24) & 0xff)]) << 24
        let t1 = UInt32(sm4ZB[Int((x >> 16) & 0xff)]) << 16
        let t2 = UInt32(sm4ZB[Int((x >> 8) & 0xff)]) << 8
        let t3 = UInt32(sm4ZB[Int(x & 0xff)])
        let b: UInt32 = t0 | t1 | t2 | t3
        let r1: UInt32 = rotl(b, 2) ^ rotl(b, 10)
        let r2: UInt32 = rotl(b, 18) ^ rotl(b, 24)
        return b ^ r1 ^ r2
    }

    /// 48 字节 → 64 个 6 位组（高位在前），倒序后逐个异或掩码再查表
    static func customBase64(_ blob: [UInt8]) -> String {
        guard blob.count == 48 else { return "" }
        var bits: [UInt8] = []
        bits.reserveCapacity(384)
        for b in blob {
            for j in 0..<8 { bits.append((b >> UInt8(7 - j)) & 1) }
        }
        var sextets = [Int](repeating: 0, count: 64)
        for k in 0..<64 {
            var v = 0
            for j in 0..<6 { v = (v << 1) | Int(bits[6 * k + j]) }
            sextets[k] = v
        }
        let alphabet = Array(b64Alphabet)
        var out = ""
        for g in 0..<64 {
            let index = sextets[63 - g] ^ b64Masks[g % 16]
            out.append(alphabet[index])
        }
        return out
    }

    static let b64Alphabet = "6fpLRqJO8M/c3jnYxFkUVC4ZIG12SiH=5v0mXDazWBTsuw7QetbKdoPyAl+hN9rgE"
    /// 每 16 组循环一次，共 4 轮
    static let b64Masks: [Int] = [58, 0, 0, 0, 0, 40, 3, 0, 0, 0, 32, 14, 0, 0, 0, 0]

    /// SM4 S 盒（取自网页端 VM，与标准 SM4 不同）
    static let sm4ZB: [UInt8] = [
        20, 223, 245, 7, 248, 2, 194, 209, 87, 6, 227, 253, 240, 128, 222, 91,
        237, 9, 125, 157, 230, 93, 252, 205, 90, 79, 144, 199, 159, 197, 186, 167,
        39, 37, 156, 198, 38, 42, 43, 168, 217, 153, 15, 103, 80, 189, 71, 191,
        97, 84, 247, 95, 36, 69, 14, 35, 12, 171, 28, 114, 178, 148, 86, 182,
        32, 83, 158, 109, 22, 255, 94, 238, 151, 85, 77, 124, 254, 18, 4, 26,
        123, 176, 232, 193, 131, 172, 143, 142, 150, 30, 10, 146, 162, 62, 224, 218,
        196, 229, 1, 192, 213, 27, 110, 56, 231, 180, 138, 107, 242, 187, 54, 120,
        19, 44, 117, 228, 215, 203, 53, 239, 251, 127, 81, 11, 133, 96, 204, 132,
        41, 115, 73, 55, 249, 147, 102, 48, 122, 145, 106, 118, 74, 190, 29, 16,
        174, 5, 177, 129, 63, 113, 99, 31, 161, 76, 246, 34, 211, 13, 60, 68,
        207, 160, 65, 111, 82, 165, 67, 169, 225, 57, 112, 244, 155, 51, 236, 200,
        233, 58, 61, 47, 100, 137, 185, 64, 17, 70, 234, 163, 219, 108, 170, 166,
        59, 149, 52, 105, 24, 212, 78, 173, 45, 0, 116, 226, 119, 136, 206, 135,
        175, 195, 25, 92, 121, 208, 126, 139, 3, 75, 141, 21, 130, 98, 241, 40,
        154, 66, 184, 49, 181, 46, 243, 88, 101, 183, 8, 23, 72, 188, 104, 179,
        210, 134, 250, 201, 164, 89, 216, 202, 220, 50, 221, 152, 140, 33, 235, 214
    ]

    /// 预展开的 32 轮轮密钥（原样照抄的有符号 32 位值）
    static let sm4ZKRaw: [Int64] = [
        1170614578, 1024848638, 1413669199, -343334464, -766094290, -1373058082, -143119608, -297228157,
        1933479194, -971186181, -406453910, 460404854, -547427574, -1891326262, -1679095901, 2119585428,
        -2029270069, 2035090028, -1521520070, -5587175, -77751101, -2094365853, -1243052806, 1579901135,
        1321810770, 456816404, -1391643889, -229302305, 330002838, -788960546, 363569021, -1947871109
    ]

    static let sm4ZK: [UInt32] = sm4ZKRaw.map { UInt32(truncatingIfNeeded: $0) }

    // MARK: 媒体

    /// 回答 / 文章正文里的图片：优先 data-original（原图），跳过 svg 占位与公式图
    static func contentImages(_ html: String) -> [String] {
        var out: [String] = []
        for m in Rx(#"<img\b[^>]*>"#, ignoreCase: true).allMatches(in: html) {
            let tag = m[0]
            let src = attr("src", in: tag)
            let candidates = [attr("data-original", in: tag), attr("data-actualsrc", in: tag), src]
            guard let url = candidates.first(where: { isUsableImage($0) }) else { continue }
            if src.contains("/equation") || url.contains("/equation") { continue }
            let full = https(decodeEntities(url))
            if !out.contains(full) { out.append(full) }
        }
        return out
    }

    private static func isUsableImage(_ url: String) -> Bool {
        !url.isEmpty && !url.hasPrefix("data:") && !url.contains("/equation")
    }

    static func attr(_ name: String, in tag: String) -> String {
        let rx = Rx(#"(?:^|\s)"# + Rx.escape(name) + #"\s*=\s*["']([^"']*)["']"#, ignoreCase: true)
        return rx.first(in: tag) ?? ""
    }

    /// 想法：图片取 original_url，视频取播放列表里最高清的一档
    static func pinMedias(_ pin: JSON) -> [(url: String, kind: MediaKind)] {
        var out: [(url: String, kind: MediaKind)] = []
        for c in pin["content"].array {
            switch c["type"].string {
            case "image":
                let url = c.string("original_url", "url")
                if !url.isEmpty { out.append((url: https(url), kind: .image)) }
            case "video":
                let url = bestPlaylistURL(c["video_info"])
                if !url.isEmpty { out.append((url: https(url), kind: .video)) }
            default:
                continue
            }
        }
        return out
    }

    /// 想法里各视频的清晰度：默认地址 → 各档（与 pinMedias 的视频地址一致）
    static func pinVideoVariants(_ pin: JSON) -> [String: [DomesticVariant]] {
        var out: [String: [DomesticVariant]] = [:]
        for c in pin["content"].array where c["type"].string == "video" {
            let list = playlistVariants(c["video_info"])
            if let first = list.first { out[first.url] = list }
        }
        return out
    }

    static func pinText(_ pin: JSON) -> String {
        for c in pin["content"].array where c["type"].string == "text" {
            let text = stripHTML(c["content"].string)
            if !text.isEmpty { return text }
        }
        return stripHTML(pin.string("excerpt_title", "content_html"))
    }

    static let playlistRank: [String: Int] = ["fhd": 4, "hd": 3, "sd": 2, "ld": 1]

    static let playlistNames: [String: String] = ["fhd": "超清", "hd": "高清", "sd": "标清", "ld": "流畅"]

    /// video_info.playlist：「清晰度 → {url,width,height}」（偶尔是数组）；取分辨率最大的一档
    static func bestPlaylistURL(_ videoInfo: JSON) -> String {
        playlistVariants(videoInfo).first.map { $0.url } ?? ""
    }

    /// 播放列表的各档（地址已补 https）：分辨率最大的一档在前（与 bestPlaylistURL 一致），其余按分辨率降序
    static func playlistVariants(_ videoInfo: JSON) -> [DomesticVariant] {
        var playlist = videoInfo["playlist"]
        if playlist.keys.isEmpty && playlist.array.isEmpty { playlist = videoInfo["playlist_v2"] }
        var entries: [(rank: Int, name: String, item: JSON)] = []
        if playlist.isArray {
            entries = playlist.array.map { (rank: 0, name: "", item: $0) }
        } else {
            entries = playlist.keys.sorted().map { (rank: playlistRank[$0.lowercased()] ?? 0, name: $0.lowercased(), item: playlist[$0]) }
        }
        var scored: [(score: Int, order: Int, variant: DomesticVariant)] = []
        for (order, entry) in entries.enumerated() {
            let url = entry.item["url"].string
            guard !url.isEmpty else { continue }
            let w = entry.item["width"].int
            let h = entry.item["height"].int
            let label = DomesticVariant.label(width: w, height: h, fallback: playlistNames[entry.name] ?? entry.name.uppercased())
            let full = https(url)
            let v = DomesticVariant(url: full, label: label, size: entry.item["size"].int64, isHLS: full.contains(".m3u8"))
            scored.append((score: w * h * 10 + entry.rank, order: order, variant: v))
        }
        // 同分取先出现的（与以前「严格大于才替换」一致）
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return DomesticVariant.normalized(scored.map { $0.variant })
    }

    static func imageExt(_ url: String) -> String {
        let last = url.substringBefore("?").substringAfterLast("/")
        let e = last.contains(".") ? last.substringAfterLast(".").lowercased() : ""
        return ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(e) ? e : "jpg"
    }

    static func https(_ url: String) -> String {
        if url.hasPrefix("//") { return "https:" + url }
        return url
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func stripHTML(_ html: String) -> String {
        let withBreaks = Rx(#"<br\s*/?>|</p>"#, ignoreCase: true).replacing(in: html, with: "\n")
        return decodeEntities(Rx(#"<[^>]+>"#).replacing(in: withBreaks, with: "")).trimmed
    }
}
