// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 meipai 与 yt-dlp（Unlicense）的 meipai 解析。
import Foundation

/// 美拍：作品页（www.meipai.com/media/{id}，新版为 /video/{id}）上 `#shareMediaBtn` 的 data-video 是混淆过的 base64：
/// 前 4 位倒序为十六进制数，其十进制各位拆成两组 (pre, tail) 指出两段插入的干扰串，去掉后再 base64 解码得到协议相对地址。
/// 直播回放页则是 `file: encodeURIComponent('…m3u8')`，按 HLS 下载。
struct MeipaiParser: VideoParser {
    let platform = VideoPlatform.meipai

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.meipai.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法识别美拍链接") }
        let first = link.url.range(of: "/video/") != nil ? "video" : "media"
        let paths = first == "video" ? ["video", "media"] : ["media", "video"]

        var lastError: Error = VideoParseError(.notFound, "美拍作品不存在或已删除")
        for path in paths {
            let pageURL = "https://www.meipai.com/\(path)/\(id)"
            do {
                let html = try await VideoHTTP.getText(pageURL, headers: headers, what: "美拍作品页")
                if let result = build(html, id: id, pageURL: pageURL) { return result }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func build(_ html: String, id: String, pageURL: String) -> VideoParseResult? {
        let title = Self.title(html)
        let base = FileNames.base(title, fallback: "meipai_\(id)")
        let media: VideoMedia
        if let m3u8 = Self.replayM3U8(html) {
            media = VideoMedia(url: m3u8, kind: .video, fileName: "\(base).mp4", isHLS: true, headers: headers, quality: "直播回放")
        } else if let encoded = Self.dataVideo(html), let url = Self.decodeVideo(encoded) {
            media = VideoMedia(url: url, kind: .video, fileName: "\(base).mp4", headers: headers)
        } else {
            return nil
        }
        var author = ""
        var avatar = ""
        if let tag = DomesticHTML.openTags("img", in: html).first(where: { $0.range(of: "detail-avatar") != nil }) {
            author = DomesticHTML.attribute("alt", in: tag) ?? ""
            avatar = DomesticHTML.absolute(DomesticHTML.attribute("src", in: tag) ?? "")
        }
        return VideoParseResult(platform: platform, title: title, author: author, avatar: avatar,
                                cover: DomesticHTML.absolute(Self.meta("og:image", in: html)), text: Self.meta("og:description", in: html),
                                url: pageURL, medias: [media])
    }

    // MARK: 纯逻辑

    static func dataVideo(_ html: String) -> String? {
        let rx = Rx(#"data-video\s*=\s*(["'])((?:(?!\1).)+)\1"#, ignoreCase: true)
        guard let v = rx.first(in: html, group: 2) else { return nil }
        return DomesticHTML.unescape(v)
    }

    static func replayM3U8(_ html: String) -> String? {
        let rx = Rx(#"file:\s*encodeURIComponent\((["'])((?:(?!\1).)+)\1\)"#)
        guard let u = rx.first(in: html, group: 2), !u.isEmpty else { return nil }
        return DomesticHTML.absolute(u)
    }

    static func title(_ html: String) -> String {
        if let el = DomesticHTML.element(class: "detail-cover-title", in: html) {
            let t = DomesticHTML.text(el)
            if !t.isEmpty { return t }
        }
        let og = meta("og:title", in: html)
        if !og.isEmpty { return og }
        if let t = Rx(#"<title[^>]*>([^<]*)</title>"#, ignoreCase: true).first(in: html) { return DomesticHTML.unescape(t.trimmed) }
        return ""
    }

    static func meta(_ property: String, in html: String) -> String {
        for tag in DomesticHTML.openTags("meta", in: html) {
            let key = DomesticHTML.attribute("property", in: tag) ?? DomesticHTML.attribute("name", in: tag) ?? ""
            if key == property { return DomesticHTML.attribute("content", in: tag) ?? "" }
        }
        return ""
    }

    /// data-video 解混淆；本身已是地址时原样返回
    static func decodeVideo(_ encoded: String) -> String? {
        let s = encoded.trimmed
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if s.hasPrefix("//") { return "https:" + s }
        let bytes = Array(s.utf8)
        guard bytes.count > 4 else { return nil }
        let hex = String(decoding: bytes[0..<4].reversed(), as: UTF8.self)
        let body = Array(bytes[4...])
        guard let n = Int(hex, radix: 16) else { return nil }
        let digits = String(n).compactMap { $0.wholeNumberValue }
        guard digits.count >= 4 else { return nil }
        let pre = [digits[0], digits[1]]
        let tail = Array(digits[2...])
        guard let d = cut(body, pre) else { return nil }
        let pos = [d.count - tail[0] - tail[1], tail[1]]
        guard let kk = cut(d, pos) else { return nil }
        guard let data = Crypto.base64Decode(String(decoding: kk, as: UTF8.self)) else { return nil }
        let path = String(decoding: data, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("http") ? path : "https:" + path
    }

    /// s[0:b0] + s[b0:] 去掉所有 s[b0:b0+b1]（与 parse-video 的 subStr 一致）
    private static func cut(_ s: [UInt8], _ b: [Int]) -> [UInt8]? {
        let start = b[0]
        let length = b[1]
        guard start >= 0, length >= 0, start + length <= s.count else { return nil }
        let head = Array(s[0..<start])
        let needle = Array(s[start..<(start + length)])
        let rest = Array(s[start...])
        return head + removeAll(needle, from: rest)
    }

    private static func removeAll(_ needle: [UInt8], from s: [UInt8]) -> [UInt8] {
        guard !needle.isEmpty else { return s }
        var out: [UInt8] = []
        var i = 0
        while i < s.count {
            if i + needle.count <= s.count && Array(s[i..<(i + needle.count)]) == needle {
                i += needle.count
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }
}
