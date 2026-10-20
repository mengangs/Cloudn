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
        guard let best = Self.bestDefinition(info["definitions"].array) else {
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
        }
        let title = info["videoTitle"].string
        let base = FileNames.base(title, fallback: "huya_\(id)")
        let media = VideoMedia(url: best.url, kind: .video, fileName: "\(base).mp4", isHLS: best.isHLS, headers: headers,
                               quality: best.quality)
        let author = info["nickName"].string.nilIfBlank ?? info["actorNick"].string
        let cover = info["videoBigCover"].string.nilIfBlank ?? info["videoCover"].string
        return VideoParseResult(platform: platform, title: title, author: author, avatar: info["actorAvatarUrl"].string,
                                cover: cover, text: DomesticHTML.text(moment["content"].string), timestamp: moment["cTime"].int64,
                                url: "https://www.huya.com/video/play/\(id).html", medias: [media])
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

    private static func quality(_ d: JSON) -> String {
        let name = d["defName"].string
        if !name.isEmpty { return name }
        let h = d["height"].int
        return h > 0 ? "\(h)p" : ""
    }
}
