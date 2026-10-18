// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 BilibiliParser。
import Foundation

/// 哔哩哔哩：已登录优先取 DASH 高清（音视频分轨，下载后在 iOS 端用 AVFoundation 合轨），
/// 否则退回 `fnval=1` 的单文件 mp4 直链（清晰度较低）。
struct BilibiliParser: VideoParser {
    let platform = VideoPlatform.bilibili

    static let viewURL = "https://api.bilibili.com/x/web-interface/view"
    static let playURL = "https://api.bilibili.com/x/player/playurl"
    static let navURL = "https://api.bilibili.com/x/web-interface/nav"

    static func headers(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.bilibili.com/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    static func nickname(cookie: String) async -> String? {
        guard !cookie.isEmpty, let json = try? await VideoHTTP.getJSON(navURL, headers: headers(cookie), what: "B站登录态校验"),
              json["data"]["isLogin"].bool else { return nil }
        let name = json["data"]["uname"].string
        return name.isEmpty ? "B站用户" : name
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let query = link.id.lowercased().hasPrefix("bv") ? "bvid=\(link.id)" : "aid=\(link.id.dropFirst(2))"
        let view = try await VideoHTTP.getJSON("\(Self.viewURL)?\(query)", headers: Self.headers(cookie), what: "B站视频信息")
        guard view["code"].int == 0 else {
            throw VideoParseError(.notFound, "B站视频信息接口返回 code=\(view["code"].int) \(view["message"].string)")
        }
        let data = view["data"]
        let bvid = data["bvid"].string
        // 多 P 视频：按链接里的 ?p= 取对应分 P
        let pageIndex = max(0, (Int(Rx(#"[?&]p=(\d+)"#).first(in: link.url) ?? "1") ?? 1) - 1)
        let pages = data["pages"].array
        let page = pageIndex < pages.count ? pages[pageIndex] : pages.first ?? JSON(nil)
        let cid = page["cid"].int64 > 0 ? page["cid"].int64 : data["cid"].int64
        guard !bvid.isEmpty, cid > 0 else { throw VideoParseError(.unknown, "B站视频信息缺少 bvid/cid") }

        var title = data["title"].string
        if pages.count > 1 { title += " P\(pageIndex + 1) \(page["part"].string)" }
        let base = FileNames.base(title, fallback: "bilibili_\(bvid)")

        var media: VideoMedia?
        if !cookie.isEmpty, let dash = try? await dashStream(bvid: bvid, cid: cid, cookie: cookie) {
            media = VideoMedia(url: dash.video, kind: .video, fileName: "\(base).mp4", headers: Self.headers(cookie),
                               quality: "\(Self.qualityLabel(dash.quality))（分轨，下载后合并）", audioURL: dash.audio)
        }
        if media == nil {
            let play = try await VideoHTTP.getJSON(
                "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=80&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1",
                headers: Self.headers(cookie), what: "B站取直链")
            let first = play["data"]["durl"][0]
            let url = first["url"].string
            guard !url.isEmpty else {
                throw VideoParseError(.unsupported, "B站未返回可下载的视频流（可能是番剧/付费内容）")
            }
            media = VideoMedia(url: url, kind: .video, fileName: "\(base).mp4", size: first["size"].int64 > 0 ? first["size"].int64 : -1,
                               headers: Self.headers(cookie), quality: Self.qualityLabel(play["data"]["quality"].int))
        }
        let owner = data["owner"]
        return VideoParseResult(platform: platform, title: title, author: owner["name"].string, avatar: owner["face"].string,
                                cover: data["pic"].string, text: data["desc"].string, timestamp: data["pubdate"].int64,
                                url: "https://www.bilibili.com/video/\(bvid)", medias: media.map { [$0] } ?? [])
    }

    private func dashStream(bvid: String, cid: Int64, cookie: String) async throws -> (video: String, audio: String, quality: Int)? {
        let json = try await VideoHTTP.getJSON("\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=120&fnval=4048&fnver=0&fourk=1",
                                               headers: Self.headers(cookie), what: "B站取 DASH 直链")
        let dash = json["data"]["dash"]
        // 优先 H.264（codecid 7）：AVFoundation 对 AV1 的支持依赖机型；同档内取最高清晰度
        let videos = dash["video"].array
        let preferred = videos.filter { $0["codecid"].int == 7 }
        guard let video = (preferred.isEmpty ? videos : preferred).max(by: { $0["id"].int < $1["id"].int }),
              let audio = dash["audio"].array.max(by: { $0["id"].int < $1["id"].int }) else { return nil }
        let v = video.string("baseUrl", "base_url")
        let a = audio.string("baseUrl", "base_url")
        guard !v.isEmpty, !a.isEmpty else { return nil }
        return (v, a, video["id"].int)
    }

    static func qualityLabel(_ qn: Int) -> String {
        switch qn {
        case 6, 7: return "240P"
        case 16: return "360P"
        case 32: return "480P"
        case 64: return "720P"
        case 74: return "720P60"
        case 80: return "1080P"
        case 112: return "1080P+"
        case 116: return "1080P60"
        case 120: return "4K"
        default: return qn > 0 ? "画质 \(qn)" : ""
        }
    }
}
