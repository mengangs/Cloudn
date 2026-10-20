// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 haokan 解析。
import Foundation

/// 好看视频：`haokan.baidu.com/v?_format=json&vid={vid}` 直接返回作品 JSON（data.apiData.curVideoMeta）。
/// clarityUrl 里列出各档清晰度，取 rank 最高的一档；没有时退回 playurl。
struct HaokanParser: VideoParser {
    let platform = VideoPlatform.haokan

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaIPhone, "Referer": "https://haokan.baidu.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let vid = link.id
        guard !vid.isEmpty else { throw VideoParseError(.unsupported, "无法识别好看视频链接") }
        let payload = try await VideoHTTP.getJSON("https://haokan.baidu.com/v?_format=json&vid=\(vid)", headers: headers, what: "好看视频")
        if payload["errno"].int != 0 {
            let message = payload["error"].string
            throw VideoParseError(.notFound, "好看视频返回错误：\(message.isEmpty ? "未知错误" : message)")
        }
        let meta = payload["data"]["apiData"]["curVideoMeta"]
        guard meta.isObject, let best = Self.bestPlay(meta) else {
            throw VideoParseError(.notFound, "好看视频没有返回该作品的播放地址（可能已删除）")
        }
        let title = meta["title"].string
        let base = FileNames.base(title, fallback: "haokan_\(vid)")
        let media = VideoMedia(url: best.url, kind: .video, fileName: "\(base).mp4", headers: headers, quality: best.quality)
        let mth = meta["mth"]
        return VideoParseResult(platform: platform, title: title, author: mth["author_name"].string, avatar: mth["author_photo"].string,
                                cover: meta["poster"].string, url: "https://haokan.baidu.com/v?vid=\(vid)", medias: [media])
    }

    // MARK: 纯逻辑

    /// clarityUrl 取 rank 最大（同 rank 取靠后）的一档，否则用 playurl
    static func bestPlay(_ meta: JSON) -> (url: String, quality: String)? {
        var best: JSON?
        for c in meta["clarityUrl"].array where !c["url"].string.isEmpty {
            if let b = best, c["rank"].int < b["rank"].int { continue }
            best = c
        }
        if let b = best {
            let quality = b["title"].string.nilIfBlank ?? b["key"].string
            return (url: b["url"].string, quality: quality)
        }
        let play = meta["playurl"].string
        if play.isEmpty { return nil }
        return (url: play, quality: "")
    }
}
