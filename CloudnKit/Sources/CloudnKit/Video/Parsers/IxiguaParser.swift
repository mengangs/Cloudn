// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 ixigua 与 parse-video（MIT，wujunwei928/parse-video）的 xigua 解析。
import Foundation

/// 西瓜视频：
/// - 主路线（yt-dlp）：PC 作品页 `www.ixigua.com/{id}` 的 `<script id="SSR_HYDRATED_DATA">`
///   → anyVideo.gidInformation.packerData.video.videoResource；main_url 为 base64。
///   优先最高清：DASH 分轨（dynamic_video）比整段 mp4（video_list）更高时取分轨，交给 App 合轨。
/// - 回退（parse-video）：`m.ixigua.com/douyin/share/video/{id}` 的 window._ROUTER_DATA（抖音分享页同构），play_addr 去水印。
/// 分享短链 v.ixigua.com/xxx 在解析器内展开（kind = "share"）。
struct IxiguaParser: VideoParser {
    let platform = VideoPlatform.ixigua

    static let idRx = Rx(#"(?:ixigua\.com/(?:video/|douyin/share/video/)?|douyin\.com/(?:share/)?video/)(\d{8,})"#, ignoreCase: true)

    /// parse-video 里随请求带的游客 Cookie（PC 页没有 Cookie 时只回 JS 挑战页）
    static let visitorCookie = "MONITOR_WEB_ID=7892c49b-296e-4499-8704-e47c1b150c18; ixigua-a-s=1; ttcid=af99669b6304453480454f150701d5c226; BD_REF=1; __ac_nonce=060d88ff000a75e8d17eb; __ac_signature=_02B4Z6wo00f01kX9ZpgAAIDAKIBBQUIPYT5F2WIAAPG2ad; ttwid=1%7CcIsVF_3vqSIk4XErhPB0H2VaTxT0tdsTMRbMjrJOPN8%7C1624806049%7C08ce7dd6f7d20506a41ba0a331ef96a6505d96731e6ad9f6c8c709f53f227ab1"

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome] }
    private var pageHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Cookie": Self.visitorCookie, "Referer": "https://www.ixigua.com/"]
    }
    private var mediaHeaders: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.ixigua.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var id = link.id
        if link.kind == "share" {
            let start = link.id.isEmpty ? link.url : "https://v.ixigua.com/\(link.id)/"
            id = try await resolveShare(start)
        }
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法识别西瓜视频链接") }

        if let result = try? await parsePC(id) { return result }
        return try await parseShare(id)
    }

    private func resolveShare(_ url: String) async throws -> String {
        var current = url
        for _ in 0..<5 {
            guard let next = try await VideoHTTP.expandRedirect(current, headers: headers) else { break }
            current = next
            if let id = Self.idRx.first(in: current) { return id }
        }
        if let id = Self.idRx.first(in: current) { return id }
        throw VideoParseError(.unsupported, "西瓜视频分享链接展开失败，请复制完整链接后重试")
    }

    private func parsePC(_ id: String) async throws -> VideoParseResult? {
        let html = try await VideoHTTP.getText("https://www.ixigua.com/\(id)", headers: pageHeaders, what: "西瓜视频作品页")
        guard let video = Self.packerVideo(fromHTML: html) else { return nil }
        guard let best = Self.bestMedia(video["videoResource"]) else { return nil }
        let title = video["title"].string
        let base = FileNames.base(title, fallback: "ixigua_\(id)")
        let media = VideoMedia(url: best.url, kind: .video, fileName: "\(base).mp4", headers: mediaHeaders,
                               quality: best.quality, audioURL: best.audioURL)
        let user = video["user_info"]
        let cover = video.string("poster_url", "cover_url")
        return VideoParseResult(platform: platform, title: title, author: user["name"].string, avatar: user["avatar_url"].string,
                                cover: cover, text: video["video_abstract"].string, timestamp: video["video_publish_time"].int64,
                                url: "https://www.ixigua.com/\(id)", medias: [media])
    }

    private func parseShare(_ id: String) async throws -> VideoParseResult {
        let url = "https://m.ixigua.com/douyin/share/video/\(id)?aweme_type=107&schema_type=1&utm_source=copy&utm_campaign=client_share&utm_medium=android&app=aweme"
        let html = try await VideoHTTP.getText(url, headers: pageHeaders, what: "西瓜视频分享页")
        guard let item = Self.routerItem(fromHTML: html) else {
            throw VideoParseError(.blocked, "西瓜视频拦截了本次请求或作品已删除，请稍后重试")
        }
        guard let play = Self.routerPlayURL(item) else {
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
        }
        let title = item["desc"].string
        let base = FileNames.base(title, fallback: "ixigua_\(id)")
        let author = item["author"]
        let media = VideoMedia(url: play, kind: .video, fileName: "\(base).mp4", headers: mediaHeaders)
        return VideoParseResult(platform: platform, title: title, author: author["nickname"].string,
                                avatar: author["avatar_thumb"]["url_list"][0].string,
                                cover: item["video"]["cover"]["url_list"][0].string, timestamp: item["create_time"].int64,
                                url: "https://www.ixigua.com/\(id)", medias: [media])
    }

    // MARK: 纯逻辑

    /// SSR_HYDRATED_DATA（JS 字面量，含 undefined）→ packerData.video
    static func packerVideo(fromHTML html: String) -> JSON? {
        let rx = Rx(#"<script[^>]*\bid\s*=\s*["']SSR_HYDRATED_DATA["'][^>]*>(.*?)</script>"#, ignoreCase: true, dotAll: true)
        guard var text = rx.first(in: html)?.trimmed else { return nil }
        if let eq = text.range(of: "_SSR_HYDRATED_DATA") {
            text = String(text[eq.upperBound...]).trimmed
            if text.hasPrefix("=") { text.removeFirst() }
        }
        guard let literal = JSLiteral.parse(text) else { return nil }
        let video = literal.json["anyVideo"]["gidInformation"]["packerData"]["video"]
        return video.isObject ? video : nil
    }

    /// main_url 是 base64 编码的直链
    static func decodeMainURL(_ value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("//") { return value }
        guard let data = Crypto.base64Decode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Candidate {
        let url: String
        let height: Int
        let size: Int64
        let bitrate: Int64
        let definition: String
    }

    private static func candidate(_ m: JSON) -> Candidate? {
        let url = decodeMainURL(m["main_url"].string)
        guard !url.isEmpty else { return nil }
        let bitrate = m["real_bitrate"].int64 > 0 ? m["real_bitrate"].int64 : m["bitrate"].int64
        return Candidate(url: url, height: m["vheight"].int, size: m["size"].int64, bitrate: bitrate,
                         definition: m["definition"].string)
    }

    private static func better(_ a: Candidate, than b: Candidate) -> Bool {
        if a.height != b.height { return a.height > b.height }
        if a.bitrate != b.bitrate { return a.bitrate > b.bitrate }
        return a.size > b.size
    }

    private static func pickBest(_ list: [Candidate]) -> Candidate? {
        var best: Candidate?
        for c in list {
            if let b = best, !better(c, than: b) { continue }
            best = c
        }
        return best
    }

    /// videoResource 下各档（normal / hdr …）的整段 mp4 与 DASH 分轨里挑最高清
    static func bestMedia(_ resource: JSON) -> (url: String, audioURL: String, quality: String)? {
        var progressive: [Candidate] = []
        var dashVideos: [Candidate] = []
        var dashAudios: [Candidate] = []
        for key in resource.keys.sorted() {
            let group = resource[key]
            guard group.isObject else { continue }
            let list = group["video_list"]
            for k in list.keys.sorted() {
                if let c = candidate(list[k]) { progressive.append(c) }
            }
            for v in group["dynamic_video"]["dynamic_video_list"].array {
                if let c = candidate(v) { dashVideos.append(c) }
            }
            for a in group["dynamic_video"]["dynamic_audio_list"].array {
                if let c = candidate(a) { dashAudios.append(c) }
            }
        }
        let bestProgressive = pickBest(progressive)
        let bestDash = pickBest(dashVideos)
        var bestAudio: Candidate?
        for a in dashAudios {
            if let b = bestAudio, a.bitrate < b.bitrate || (a.bitrate == b.bitrate && a.size <= b.size) { continue }
            bestAudio = a
        }
        if let dash = bestDash, let audio = bestAudio {
            let progressiveHeight = bestProgressive?.height ?? 0
            if bestProgressive == nil || dash.height > progressiveHeight {
                return (url: dash.url, audioURL: audio.url, quality: Self.quality(dash))
            }
        }
        guard let p = bestProgressive else { return nil }
        return (url: p.url, audioURL: "", quality: Self.quality(p))
    }

    private static func quality(_ c: Candidate) -> String {
        if c.height > 0 { return "\(c.height)p" }
        return c.definition
    }

    /// m.ixigua.com 抖音同构分享页的 _ROUTER_DATA → item_list[0]
    static func routerItem(fromHTML html: String) -> JSON? {
        guard let text = VideoHTTP.extractInlineJSON(html, key: "window._ROUTER_DATA"), let router = JSON(text: text) else { return nil }
        let page = router["loaderData"]["video_(id)/page"]
        let item = page.object("videoInfoRes", "video_info_res").arrayValue("item_list", "itemList").first ?? JSON(nil)
        return item.isObject ? item : nil
    }

    /// play_addr 首个地址，playwm → play 去水印
    static func routerPlayURL(_ item: JSON) -> String? {
        let play = item["video"].object("play_addr", "playAddr")
        guard let url = play.arrayValue("url_list", "urlList").map({ $0.string }).first(where: { !$0.isEmpty }) else { return nil }
        return url.replacingOccurrences(of: "playwm", with: "play")
    }
}
