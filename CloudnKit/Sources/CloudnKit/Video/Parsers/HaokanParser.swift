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
        let variants = meta.isObject ? Self.variants(meta) : []
        guard !variants.isEmpty else {
            throw VideoParseError(.notFound, "好看视频没有返回该作品的播放地址（可能已删除）")
        }
        let title = meta["title"].string
        let base = FileNames.base(title, fallback: "haokan_\(vid)")
        let mth = meta["mth"]
        return VideoParseResult(platform: platform, title: title, author: mth["author_name"].string, avatar: mth["author_photo"].string,
                                cover: meta["poster"].string, url: "https://haokan.baidu.com/v?vid=\(vid)",
                                medias: DomesticVariant.medias(variants, base: base, headers: headers))
    }

    // MARK: 纯逻辑

    /// 各档：默认档同 bestPlay，其余为 clarityUrl 里的其它清晰度（rank 从高到低）
    static func variants(_ meta: JSON) -> [DomesticVariant] {
        guard let best = bestPlay(meta) else { return [] }
        let rest = meta["clarityUrl"].array.enumerated()
            .filter { !$0.element["url"].string.isEmpty }
            .sorted { a, b in
                let ra = a.element["rank"].int
                let rb = b.element["rank"].int
                return ra != rb ? ra > rb : a.offset > b.offset
            }
            .map { DomesticVariant(url: $0.element["url"].string, label: $0.element["title"].string.nilIfBlank ?? $0.element["key"].string) }
        return DomesticVariant.normalized([DomesticVariant(url: best.url, label: best.quality)] + rest)
    }

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
