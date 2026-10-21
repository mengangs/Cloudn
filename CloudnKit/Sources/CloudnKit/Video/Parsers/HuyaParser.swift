// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 huya（HuyaVideoIE）与 parse-video（MIT，wujunwei928/parse-video）的 huya 解析。
import Foundation

/// 虎牙视频（点播 / 剪辑，不含直播）：`liveapi.huya.com/moment/getMomentContent?videoId={id}` → data.moment.videoInfo。
/// definitions 里每档有 mp4 直链（url）与 m3u8：取最高清的 mp4，没有 mp4 时用 m3u8。
struct HuyaParser: VideoParser {
    let platform = VideoPlatform.huya

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://v.huya.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法识别虎牙视频链接") }
        let payload = try await VideoHTTP.getJSON("https://liveapi.huya.com/moment/getMomentContent?videoId=\(id)",
                                                  headers: headers, what: "虎牙视频")
        let moment = payload["data"]["moment"]
        let info = moment["videoInfo"]
        guard info.isObject else {
            let msg = payload["message"].string
            throw VideoParseError(.notFound, "虎牙视频不存在或已删除\(msg.isEmpty ? "" : "：\(msg)")")
        }
        let variants = Self.variants(info["definitions"].array)
        guard !variants.isEmpty else {
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
        }
        let title = info["videoTitle"].string
        let base = FileNames.base(title, fallback: "huya_\(id)")
        let author = info["nickName"].string.nilIfBlank ?? info["actorNick"].string
        let cover = info["videoBigCover"].string.nilIfBlank ?? info["videoCover"].string
        return VideoParseResult(platform: platform, title: title, author: author, avatar: info["actorAvatarUrl"].string,
                                cover: cover, text: DomesticHTML.text(moment["content"].string), timestamp: moment["cTime"].int64,
                                url: "https://www.huya.com/video/play/\(id).html",
                                medias: DomesticVariant.medias(variants, base: base, headers: headers))
    }

    // MARK: 纯逻辑

    /// mp4 优先、按 (height, size) 取最大；全无 mp4 时取最高的 m3u8
    static func bestDefinition(_ list: [JSON]) -> (url: String, isHLS: Bool, quality: String)? {
        func pick(_ key: String) -> JSON? {
            var best: JSON?
            for d in list where !d[key].string.isEmpty {
                if let b = best {
                    let dh = d["height"].int
                    let bh = b["height"].int
                    if dh < bh { continue }
                    if dh == bh && d["size"].int64 <= b["size"].int64 { continue }
                }
                best = d
            }
            return best
        }
        if let d = pick("url") {
            let u = d["url"].string
            let hls = u.substringBefore("?").lowercased().hasSuffix(".m3u8")
            return (url: u, isHLS: hls, quality: Self.quality(d))
        }
        if let d = pick("m3u8") {
            return (url: d["m3u8"].string, isHLS: true, quality: Self.quality(d))
        }
        return nil
    }

    /// 各档：默认档同 bestDefinition；其余为同类（有 mp4 时只列 mp4，否则列 m3u8）的其它清晰度，按高度、体积降序
    static func variants(_ list: [JSON]) -> [DomesticVariant] {
        guard let best = bestDefinition(list) else { return [] }
        let key = list.contains(where: { !$0["url"].string.isEmpty }) ? "url" : "m3u8"
        func label(_ d: JSON) -> String {
            let res = DomesticVariant.label(width: d["width"].int, height: d["height"].int)
            return [d["defName"].string, res].filter { !$0.isEmpty }.joined(separator: " ")
        }
        func variant(_ d: JSON) -> DomesticVariant {
            let u = d[key].string
            let hls = key == "m3u8" || u.substringBefore("?").lowercased().hasSuffix(".m3u8")
            return DomesticVariant(url: u, label: label(d), size: hls ? -1 : d["size"].int64, isHLS: hls)
        }
        let defs = list.filter { !$0[key].string.isEmpty }
        let first = defs.first(where: { $0[key].string == best.url }).map(variant)
            ?? DomesticVariant(url: best.url, label: best.quality, isHLS: best.isHLS)
        let rest = defs.sorted { a, b in
            let ha = a["height"].int
            let hb = b["height"].int
            return ha != hb ? ha > hb : a["size"].int64 > b["size"].int64
        }
        return DomesticVariant.normalized([first] + rest.map(variant))
    }

    private static func quality(_ d: JSON) -> String {
        let name = d["defName"].string
        if !name.isEmpty { return name }
        let h = d["height"].int
        return h > 0 ? "\(h)p" : ""
    }
}
