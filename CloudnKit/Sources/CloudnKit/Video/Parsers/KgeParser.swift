// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 quanminkge 解析。
import Foundation

/// 全民K歌：作品页 `kg.qq.com/node/play?s={shareid}` 内嵌 `window.__DATA__ = {...}`，取 detail：
/// MV 作品有 playurl_video（mp4，按视频下载）；纯音频作品只有 playurl（m4a 等，按音频下载）。
struct KgeParser: VideoParser {
    let platform = VideoPlatform.kge

    private static let pageUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.5112.102 Safari/537.36 Edg/104.0.1293.70"
    private var headers: [String: String] { ["User-Agent": Self.pageUA, "Referer": "https://kg.qq.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let sid = link.id
        guard !sid.isEmpty else { throw VideoParseError(.unsupported, "无法识别全民K歌链接") }
        let url = "https://kg.qq.com/node/play?s=\(sid.urlQueryEncoded)"
        let html = try await VideoHTTP.getText(url, headers: headers, what: "全民K歌作品页")
        guard let detail = Self.detail(fromHTML: html) else {
            throw VideoParseError(.notFound, "全民K歌页面里没有作品数据（作品可能已删除或设为私密）")
        }
        guard let media = Self.media(detail, headers: headers, fallbackName: "kge_\(sid)") else {
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
        }
        let title = Self.title(detail)
        return VideoParseResult(platform: platform, title: title, author: detail["nick"].string, avatar: detail["avatar"].string,
                                cover: detail["cover"].string, text: detail["content"].string, timestamp: detail["ctime"].int64,
                                url: url, medias: [media])
    }

    // MARK: 纯逻辑

    /// `window.__DATA__ = {...};` → detail（按 JS 字面量解析，不靠「第一个分号」截断）
    static func detail(fromHTML html: String) -> JSON? {
        guard let marker = html.range(of: "window.__DATA__") else { return nil }
        var rest = html[marker.upperBound...].drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst()
        guard let literal = JSLiteral.parse(String(rest)) else { return nil }
        let detail = literal.json["detail"]
        return detail.isObject ? detail : nil
    }

    /// 标题：歌名优先，其次作品描述
    static func title(_ detail: JSON) -> String {
        let song = detail["song_name"].string
        if !song.isEmpty { return song }
        return detail["content"].string
    }

    static func media(_ detail: JSON, headers: [String: String], fallbackName: String) -> VideoMedia? {
        let base = FileNames.base(title(detail), fallback: fallbackName)
        let video = detail["playurl_video"].string
        if !video.isEmpty {
            return VideoMedia(url: video, kind: .video, fileName: "\(base).mp4", headers: headers, quality: "MV")
        }
        let audio = detail["playurl"].string
        guard !audio.isEmpty else { return nil }
        return VideoMedia(url: audio, kind: .audio, fileName: "\(base).\(audioExtension(audio))", headers: headers)
    }

    static func audioExtension(_ url: String) -> String {
        let path = URL(string: url)?.path ?? url.substringBefore("?")
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3", "m4a", "aac", "flac", "ogg", "wav": return ext
        default: return "m4a"
        }
    }
}
