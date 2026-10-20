// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 imgur 解析。
import Foundation

/// Imgur：公开接口 api.imgur.com/post/v1/{media|albums}/<id>（网页版自带的 client_id）。
/// 单图 / 单视频 / 相册 / 画廊帖都取原始文件（图片原图、gifv 对应的 mp4）。
/// i.imgur.com 的直链要带 `Accept: */*`，否则会被重定向到网页。
struct ImgurParser: VideoParser {
    let platform = VideoPlatform.imgur

    static let clientID = "546c25a59c58ad7"
    static let albumRx = Rx(#"imgur\.com/a/(?:[^/?#\s]+-)?([A-Za-z0-9]+)"#, ignoreCase: true)
    static let galleryRx = Rx(#"imgur\.com/(?:gallery|t/[^/?#\s]+|topic/[^/?#\s]+|r/[^/?#\s]+)/(?:[^/?#\s]+-)?([A-Za-z0-9]+)"#, ignoreCase: true)
    static let mediaRx = Rx(#"(?<![A-Za-z0-9\-])(?:i\.|m\.|www\.)?imgur\.com/(?!(?:a|gallery|t|topic|r|user|upload|signin|register)/)(?:[^/?#\s]+-)?([A-Za-z0-9]{5,})"#, ignoreCase: true)

    struct Item: Equatable {
        let kind: MediaKind
        let url: String
        let ext: String
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var kind = link.kind
        var id = link.id
        if id.isEmpty, let detected = Self.detect(link.url) {
            kind = detected.kind
            id = detected.id
        }
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 Imgur 图片或相册 ID") }
        let data: JSON
        switch kind {
        case "album":
            data = try await fetch("albums", id: id)
        case "gallery":
            // 画廊帖可能只是一张图：相册接口 404 时退回单媒体接口
            do {
                data = try await fetch("albums", id: id)
            } catch let e as VideoParseError where e.kind == .notFound {
                data = try await fetch("media", id: id)
            }
        default:
            data = try await fetch("media", id: id)
        }
        let items = Self.items(data)
        if items.isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        return build(data: data, id: id, items: items, link: link)
    }

    private func fetch(_ endpoint: String, id: String) async throws -> JSON {
        let url = "https://api.imgur.com/post/v1/\(endpoint)/\(id)?client_id=\(Self.clientID)&include=media,account"
        let headers: [(String, String)] = [("Accept", "application/json"), ("Origin", "https://imgur.com"),
                                           ("Referer", "https://imgur.com/"), ("User-Agent", VideoHTTP.uaChrome)]
        let r = try await OverseasHTTP.send(.get(url, headers: headers), site: "Imgur")
        switch r.status {
        case 200: break
        case 404: throw VideoParseError(.notFound, "Imgur 内容不存在或已删除（HTTP 404）")
        case 403: throw VideoParseError(.blocked, "Imgur 拒绝了请求（HTTP 403），所在地区可能无法访问 Imgur")
        case 429: throw VideoParseError(.blocked, "Imgur 请求过于频繁（HTTP 429），请稍后重试")
        default: throw VideoParseError(.unknown, "Imgur 接口请求失败（HTTP \(r.status)）")
        }
        guard let json = r.json, json.isObject else { throw VideoParseError(.unknown, "Imgur 接口返回的不是合法 JSON") }
        return json
    }

    private func build(data: JSON, id: String, items: [Item], link: DetectedVideoLink) -> VideoParseResult {
        let headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://imgur.com/", "Accept": "*/*"]
        var title = data["title"].string.trimmed
        if title.isEmpty && items.count == 1 { title = data["media"][0]["metadata"]["title"].string.trimmed }
        let base = FileNames.base(title, fallback: "imgur_\(id)")
        let single = items.count == 1
        var medias: [VideoMedia] = []
        for (i, item) in items.enumerated() {
            let name = single ? "\(base).\(item.ext)" : "\(base)_\(i + 1).\(item.ext)"
            medias.append(VideoMedia(url: item.url, kind: item.kind, fileName: name, headers: headers))
        }
        let cover = items.first(where: { $0.kind == .image })?.url ?? ""
        var url = data["url"].string
        if url.isEmpty { url = link.url }
        var text = data["description"].string
        if text.contains("Discover the magic of the internet at Imgur") { text = "" }
        let account = data["account"]
        return VideoParseResult(platform: platform, title: title.isEmpty ? "Imgur \(id)" : title,
                                author: account["username"].string, avatar: account["avatar_url"].string, cover: cover,
                                text: text, timestamp: Self.parseTime(data["created_at"].string), url: url, medias: medias)
    }

    // MARK: 纯逻辑

    /// 链接 → (album|gallery|media, id)；供 Reddit 等转交时使用
    static func detect(_ url: String) -> (kind: String, id: String)? {
        if let id = albumRx.first(in: url) { return ("album", id) }
        if let id = galleryRx.first(in: url) { return ("gallery", id) }
        if let id = mediaRx.first(in: url) { return ("media", id) }
        return nil
    }

    /// 接口 media[] → 下载项（视频 / gifv 为 mp4，图片为原图）
    static func items(_ data: JSON) -> [Item] {
        var out: [Item] = []
        for m in data["media"].array {
            let url = m["url"].string
            guard !url.isEmpty else { continue }
            var ext = m["ext"].string.lowercased()
            if ext.isEmpty { ext = (url.substringBefore("?") as NSString).pathExtension.lowercased() }
            let isVideo = m["type"].string == "video" || ext == "mp4" || ext == "webm" || ext == "gifv"
            if isVideo {
                let mp4 = ext == "gifv" ? Rx(#"\.gifv(?=$|[?#])"#).replacing(in: url, with: ".mp4") : url
                let videoExt = ext == "webm" ? "webm" : "mp4"
                out.append(Item(kind: .video, url: mp4, ext: videoExt))
            } else {
                let imageExt = ext == "jpeg" ? "jpg" : (ext.isEmpty ? "jpg" : ext)
                out.append(Item(kind: .image, url: url, ext: imageExt))
            }
        }
        return out
    }

    /// ISO 8601（可带毫秒）→ 秒
    static func parseTime(_ s: String) -> Int64 {
        guard !s.isEmpty else { return 0 }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
        return 0
    }
}
