// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 douban 解析。
import Foundation

/// 豆瓣小组话题：移动版内部接口 `m.douban.com/rexxar/api/v2/group/topic/{id}`（必须带 UA，否则 418）。
/// 视频取 video_info.video_url；图片取 photos[].image.large（缺失退回 normal），动图取等效的 mp4。
/// 图床有防盗链：下载必须带 Referer `https://www.douban.com/`。
/// 分享短链 douc.cc / doubanapp/dispatch 在解析器内自行展开（kind = "share"）。
struct DoubanParser: VideoParser {
    let platform = VideoPlatform.douban

    static let apiUA = VideoHTTP.uaIPhone
    static let imageReferer = "https://www.douban.com/"

    private var mediaHeaders: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.imageReferer] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var id = link.id
        if link.kind == "share" {
            // douc.cc 短码：用捕获到的短码重建（分享文案里链接后常紧跟中文）
            let start = (link.url.contains("douc.cc") && !link.id.isEmpty) ? "https://douc.cc/\(link.id)" : link.url
            id = try await resolveShare(start)
        }

        var headers: [(String, String)] = [("User-Agent", Self.apiUA), ("Referer", "https://m.douban.com/")]
        if !cookie.isEmpty { headers.append(("Cookie", cookie)) }
        let r = try await VideoHTTP.send(.get("https://m.douban.com/rexxar/api/v2/group/topic/\(id)", headers: headers))
        guard r.status == 200 else { throw Self.apiError(status: r.status, body: r.json) }
        guard let data = r.json, data.isObject else { throw VideoParseError(.unknown, "豆瓣话题返回的不是合法 JSON") }
        return try build(data, id: id)
    }

    private func build(_ data: JSON, id: String) throws -> VideoParseResult {
        let title = data["title"].string
        let base = FileNames.base(title, fallback: "douban_\(id)")
        var medias: [VideoMedia] = []
        let video = data["video_info"]["video_url"].string
        if !video.isEmpty {
            medias.append(VideoMedia(url: video, kind: .video, fileName: "\(base).mp4", headers: mediaHeaders))
        }
        for (i, photo) in Self.photos(data).enumerated() {
            let name = "\(base)_\(i + 1).\(photo.ext)"
            medias.append(VideoMedia(url: photo.url, kind: photo.animated ? .video : .image, fileName: name,
                                     headers: mediaHeaders, quality: photo.animated ? "动图" : "大图"))
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let author = data["author"]
        let cover = data["video_info"]["cover_url"].string.nilIfBlank ?? (medias.first(where: { $0.kind == .image })?.url ?? "")
        return VideoParseResult(platform: platform, title: title, author: author["name"].string, avatar: author["avatar"].string,
                                cover: cover, text: DomesticHTML.text(data["content"].string),
                                url: "https://www.douban.com/group/topic/\(id)/", medias: medias)
    }

    private func resolveShare(_ url: String) async throws -> String {
        var current = url
        for _ in 0..<5 {
            if let id = Self.topicID(in: current) { return id }
            guard let next = try await VideoHTTP.expandRedirect(current, headers: ["User-Agent": Self.apiUA]) else { break }
            current = next
        }
        if let id = Self.topicID(in: current) { return id }
        throw VideoParseError(.unsupported, "暂不支持该豆瓣链接，目前仅支持小组话题")
    }

    // MARK: 纯逻辑

    /// /group/topic/<id> 与 /topic/<id> 同一套 ID；dispatch 链接的 uri 参数里也可能直接带着
    static func topicID(in url: String) -> String? {
        if let id = Rx(#"douban\.com/(?:group/)?topic/(\d+)"#, ignoreCase: true).first(in: url) { return id }
        let decoded = url.removingPercentEncoding ?? url
        return Rx(#"[?&]uri=/?(?:group/)?topic/(\d+)"#, ignoreCase: true).first(in: decoded)
    }

    static func apiError(status: Int, body: JSON?) -> VideoParseError {
        let localized = body?["localized_message"].string ?? ""
        let msg = body?["msg"].string ?? ""
        let detail: String
        if !localized.isEmpty {
            detail = "豆瓣：\(localized)"
        } else if !msg.isEmpty {
            detail = "获取豆瓣话题失败：\(msg)"
        } else {
            detail = "获取豆瓣话题失败（HTTP \(status)）"
        }
        switch status {
        case 404, 410: return VideoParseError(.notFound, detail)
        case 418, 429: return VideoParseError(.blocked, detail)
        default: return VideoParseError(.unsupported, detail)
        }
    }

    struct Photo: Equatable {
        let url: String
        let ext: String
        let animated: Bool
    }

    /// 动图的 large 是体积极大的原始 GIF，改取豆瓣同时给的 mp4
    static func photos(_ data: JSON) -> [Photo] {
        var result: [Photo] = []
        for photo in data["photos"].array {
            let image = photo["image"]
            let animatedURL = image["video"]["url"].string
            if image["is_animated"].bool && !animatedURL.isEmpty {
                result.append(Photo(url: animatedURL, ext: "mp4", animated: true))
                continue
            }
            let url = image["large"]["url"].string.nilIfBlank ?? image["normal"]["url"].string
            guard !url.isEmpty else { continue }
            result.append(Photo(url: url, ext: DomesticHTML.imageExtension(url), animated: false))
        }
        return result
    }
}
