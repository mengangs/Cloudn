// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 lishipin 与 yt-dlp（Unlicense）的 pearvideo 解析。
import Foundation

/// 梨视频：
/// - 作品页（www.pearvideo.com/video_{id}）里若直接写着 `srcUrl="..."` 这类变量就用最高一档；
/// - 否则请求 `videoStatus.jsp?contId={id}`（必须带作品页 Referer），返回的 srcUrl 里把 systemTime 换成 `cont-{id}` 才是真实地址。
struct LishipinParser: VideoParser {
    let platform = VideoPlatform.lishipin

    private static let order = ["ldflv", "ld", "sdflv", "sd", "hdflv", "hd", "src"]

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.pearvideo.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法识别梨视频链接") }
        let pageURL = "https://www.pearvideo.com/video_\(id)"
        let html = (try? await VideoHTTP.getText(pageURL, headers: headers, what: "梨视频作品页")) ?? ""

        var videoURL = Self.pageVideoURL(html) ?? ""
        if videoURL.isEmpty {
            let api = "https://www.pearvideo.com/videoStatus.jsp?contId=\(id)&mrd=\(Double.random(in: 0..<1))"
            let apiHeaders = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.pearvideo.com/detail_\(id)"]
            let payload = try await VideoHTTP.getJSON(api, headers: apiHeaders, what: "梨视频")
            videoURL = Self.statusVideoURL(payload, id: id) ?? ""
            if videoURL.isEmpty {
                let msg = payload["resultMsg"].string
                throw VideoParseError(.notFound, "梨视频没有返回播放地址\(msg.isEmpty ? "（作品可能已下线）" : "：\(msg)")")
            }
        }
        let title = Self.title(html)
        let base = FileNames.base(title, fallback: "pearvideo_\(id)")
        let media = VideoMedia(url: videoURL, kind: .video, fileName: "\(base).mp4", headers: headers)
        return VideoParseResult(platform: platform, title: title.isEmpty ? "梨视频 \(id)" : title, cover: Self.cover(html),
                                text: Self.summary(html), url: pageURL, medias: [media])
    }

    // MARK: 纯逻辑

    /// 页面里 `xxUrl="//..."` 形式的直链，按清晰度顺序取最高
    static func pageVideoURL(_ html: String) -> String? {
        let rx = Rx(#"([a-zA-Z]+)Url\s*=\s*(["'])((?:https?:)?//.+?)\2"#)
        var best: (rank: Int, url: String)?
        for m in rx.allMatches(in: html) {
            guard let rank = order.firstIndex(of: m[1]) else { continue }
            if let b = best, b.rank >= rank { continue }
            best = (rank: rank, url: DomesticHTML.absolute(m[3]))
        }
        return best?.url
    }

    /// videoStatus.jsp：srcUrl 中的 systemTime 段替换为 cont-{id}
    static func statusVideoURL(_ payload: JSON, id: String) -> String? {
        let videos = payload["videoInfo"]["videos"]
        let src = videos["srcUrl"].string
        if !src.isEmpty {
            let time = payload["systemTime"].string
            return time.isEmpty ? src : src.replacingOccurrences(of: time, with: "cont-\(id)")
        }
        for key in ["hdUrl", "hdflvUrl", "sdUrl", "sdflvUrl", "ldUrl", "ldflvUrl"] {
            let u = videos[key].string
            if !u.isEmpty { return u }
        }
        return nil
    }

    static func title(_ html: String) -> String {
        let rx1 = Rx(#"<h1[^>]+\bclass=(["'])video-tt\1[^>]*>([^<]+)"#, ignoreCase: true)
        if let t = rx1.first(in: html, group: 2), !t.trimmed.isEmpty { return DomesticHTML.unescape(t.trimmed) }
        let rx2 = Rx(#"<[^>]+\bdata-title=(["'])((?:(?!\1).)+)\1"#, ignoreCase: true)
        if let t = rx2.first(in: html, group: 2) { return DomesticHTML.unescape(t.trimmed) }
        return ""
    }

    static func summary(_ html: String) -> String {
        let rx = Rx(#"<div[^>]+\bclass=(["'])summary\1[^>]*>([^<]+)"#, ignoreCase: true)
        guard let t = rx.first(in: html, group: 2) else { return "" }
        return DomesticHTML.unescape(t.trimmed)
    }

    static func cover(_ html: String) -> String {
        let rx = Rx(#"<div[^>]+\bclass=(["'])img\1[^>]*\bstyle=["'][^"']*url\(([^)]+)\)"#, ignoreCase: true)
        guard let u = rx.first(in: html, group: 2) else { return "" }
        return DomesticHTML.absolute(u.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
    }
}
