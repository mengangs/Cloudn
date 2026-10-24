// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 网页源码里直接写着的音视频地址：一次普通请求拿到的页面里就能找到，不用打开浏览器等播放。
/// 认 og:video / twitter:player:stream 等元标签、<video> / <audio> / <source> 的 src、JSON-LD 的 contentUrl，
/// 以及页面脚本里以 .m3u8 / .mp4 等扩展名结尾的完整地址（含 JSON 里转义过的 `\/`）。
/// 网页嗅探打开页面时同时用它扫一遍源码，找到的先列出来；找不到就照旧等页面播放
public enum PageMediaScanner {
    public struct Scan: Equatable, Sendable {
        /// og:title，没有就用 <title>（下载时作文件名）
        public let title: String
        public let urls: [String]
    }

    static let maxResults = 20
    static let mediaExtensions = ["m3u8", "mp4", "m4v", "mov", "webm", "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav"]
    static let metaKeys: Set<String> = ["og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream",
                                        "og:audio", "og:audio:url", "og:audio:secure_url"]

    public static func scan(html: String, baseURL: String) -> Scan {
        let text = unescape(html)
        var urls: [String] = []
        func add(_ raw: String) {
            let candidate = decodeEntities(raw).trimmed
            guard urls.count < maxResults, !candidate.isEmpty else { return }
            let url = VideoHTTP.absolutize(base: baseURL, candidate)
            guard url.hasPrefix("http://") || url.hasPrefix("https://"), !urls.contains(url) else { return }
            urls.append(url)
        }
        let tags = Rx(#"<(meta|video|audio|source)\b[^>]*>"#, ignoreCase: true).allMatches(in: text)
        // 元标签：og:video 也可能是播放器网页（如嵌入页），只收带音视频扩展名的
        for tag in tags where tag[1].lowercased() == "meta" {
            let key = (attribute("property", in: tag[0]) ?? attribute("name", in: tag[0]) ?? "").lowercased()
            if metaKeys.contains(key), let content = attribute("content", in: tag[0]), hasMediaExtension(content) { add(content) }
        }
        // 媒体标签：src 本身就是音视频；<picture> 里的 <source> 是图片，按 type 排除
        for tag in tags where tag[1].lowercased() != "meta" {
            if (attribute("type", in: tag[0]) ?? "").lowercased().hasPrefix("image/") { continue }
            if let src = attribute("src", in: tag[0]) { add(src) }
        }
        for match in Rx(#""contentUrl"\s*:\s*"([^"]+)""#).allMatches(in: text) where hasMediaExtension(match[1]) {
            add(match[1])
        }
        let ext = mediaExtensions.joined(separator: "|")
        let bare = Rx(#"https?://[^\s"'<>()\\]+?\.(?:"# + ext + #")(?:\?[^\s"'<>()\\]*)?(?![A-Za-z0-9._-])"#, ignoreCase: true)
        for match in bare.allMatches(in: text) { add(match[0]) }
        return Scan(title: title(in: text), urls: urls)
    }

    static func title(in html: String) -> String {
        for tag in Rx(#"<meta\b[^>]*>"#, ignoreCase: true).allMatches(in: html).map({ $0[0] }) {
            let key = (attribute("property", in: tag) ?? attribute("name", in: tag) ?? "").lowercased()
            if key == "og:title", let content = attribute("content", in: tag)?.trimmed, !content.isEmpty { return decodeEntities(content) }
        }
        let raw = Rx(#"<title[^>]*>(.*?)</title>"#, ignoreCase: true, dotAll: true).first(in: html) ?? ""
        return decodeEntities(raw).trimmed
    }

    /// 地址路径以音视频扩展名结尾（不看查询串）
    static func hasMediaExtension(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? url.substringBefore("?")).lowercased()
        return mediaExtensions.contains { path.hasSuffix("." + $0) }
    }

    /// 标签里某个属性的值：双引号、单引号或不带引号
    static func attribute(_ name: String, in tag: String) -> String? {
        guard let groups = Rx(#"\s"# + Rx.escape(name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, ignoreCase: true)
            .firstMatch(in: tag) else { return nil }
        return groups.dropFirst().first { !$0.isEmpty } ?? ""
    }

    /// 脚本 / JSON 里转义过的斜杠与 &
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\u002F"#, with: "/")
            .replacingOccurrences(of: #"\u002f"#, with: "/")
            .replacingOccurrences(of: #"\u0026"#, with: "&")
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
