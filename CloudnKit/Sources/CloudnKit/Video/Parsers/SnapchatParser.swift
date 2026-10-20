// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 snapchat 解析。
import Foundation

/// Snapchat Spotlight：页面 __NEXT_DATA__ → pageProps.spotlightFeed.spotlightStories 里与链接 ID 相同的一条，
/// 取 videoMetadata.contentUrl（无水印 mp4）。分享短链（t.snapchat.com）在解析器里展开；
/// 落到公开故事页时取 story.snapList 里的每一段；都没有再看页面 JSON-LD 的 contentUrl。
struct SnapchatParser: VideoParser {
    let platform = VideoPlatform.snapchat

    static let spotlightRx = Rx(#"snapchat\.com/(?:@[\w.\-]+/)?spotlight/([\w\-]+)"#, ignoreCase: true)

    struct Item: Equatable {
        let kind: MediaKind
        let url: String
    }

    /// 解析出的作品（纯数据，便于离线测试）
    struct Snap: Equatable {
        var title = ""
        var text = ""
        var author = ""
        var cover = ""
        var timestamp: Int64 = 0
        var items: [Item] = []
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var pageURL = link.url
        var id = link.kind == "share" ? "" : link.id
        if link.kind == "share" {
            pageURL = try await OverseasHTTP.expandShareLink(link.url, until: Self.spotlightRx, site: "Snapchat")
            id = Self.spotlightRx.first(in: pageURL) ?? ""
        }
        let headers: [(String, String)] = [("Accept-Language", "en-US,en;q=0.9"), ("User-Agent", VideoHTTP.uaChrome)]
        let r = try await OverseasHTTP.send(.get(pageURL, headers: headers), site: "Snapchat")
        if r.status == 404 { throw VideoParseError(.notFound, "内容不存在或已删除（HTTP 404）") }
        guard r.isSuccess else { throw VideoParseError(.unknown, "Snapchat 页面请求失败（HTTP \(r.status)）") }
        let snap = Self.parsePage(r.text, id: id)
        if snap.items.isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }

        let mediaHeaders = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.snapchat.com/"]
        let fallbackID = id.isEmpty ? "snap" : String(id.prefix(16))
        let title = snap.title.isEmpty ? (snap.text.isEmpty ? "Snapchat \(fallbackID)" : String(snap.text.prefix(40))) : snap.title
        let base = FileNames.base(title, fallback: "snapchat_\(fallbackID)")
        let single = snap.items.count == 1
        var medias: [VideoMedia] = []
        for (i, item) in snap.items.enumerated() {
            let ext = item.kind == .video ? "mp4" : "jpg"
            let name = single ? "\(base).\(ext)" : "\(base)_\(i + 1).\(ext)"
            medias.append(VideoMedia(url: item.url, kind: item.kind, fileName: name, headers: mediaHeaders))
        }
        let url = id.isEmpty ? r.url : "https://www.snapchat.com/spotlight/\(id)"
        return VideoParseResult(platform: platform, title: title, author: snap.author, cover: snap.cover, text: snap.text,
                                timestamp: snap.timestamp, url: url, medias: medias)
    }

    // MARK: 纯逻辑

    static func nextData(_ html: String) -> JSON? {
        guard let raw = Rx(#"<script[^>]*\bid="__NEXT_DATA__"[^>]*>(.*?)</script>"#, dotAll: true).first(in: html) else { return nil }
        return JSON(text: raw)
    }

    static func parsePage(_ html: String, id: String) -> Snap {
        if let data = nextData(html) {
            let props = data["props"]["pageProps"]
            var snap = spotlight(props, id: id)
            if snap.items.isEmpty { snap = story(props) }
            if !snap.items.isEmpty { return snap }
        }
        // JSON-LD 兜底
        var snap = Snap()
        if let url = Rx(#""contentUrl"\s*:\s*"(https:[^"]+)""#).first(in: html) {
            let clean = url.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u0026", with: "&")
            snap.items = [Item(kind: .video, url: clean)]
            snap.title = OverseasHTTP.metaContent("og:title", in: html).first ?? ""
            snap.cover = OverseasHTTP.metaContent("og:image", in: html).first ?? ""
        }
        return snap
    }

    /// spotlightFeed.spotlightStories：优先 storyId 与链接 ID 相同的一条，否则第一条
    static func spotlight(_ props: JSON, id: String) -> Snap {
        let stories = props["spotlightFeed"]["spotlightStories"].array
        var chosen = stories.first(where: { !id.isEmpty && $0["story"]["storyId"]["value"].string == id })
        if chosen == nil { chosen = stories.first }
        guard let entry = chosen else { return Snap() }
        let meta = entry["metadata"]
        let video = meta["videoMetadata"]
        var snap = Snap()
        let url = video["contentUrl"].string
        if !url.isEmpty { snap.items = [Item(kind: .video, url: url)] }
        snap.title = video["name"].string
        snap.text = meta["description"].string.isEmpty ? video["description"].string : meta["description"].string
        snap.author = video["creator"]["personCreator"]["username"].string
        snap.cover = video["thumbnailUrl"].string
        snap.timestamp = Int64(video["uploadDateMs"].double / 1000)
        if snap.title == "Spotlight Snap" { snap.title = "" }
        return snap
    }

    /// 公开故事页：story.snapList[].snapUrls.mediaUrl（snapMediaType 1 为视频）
    static func story(_ props: JSON) -> Snap {
        var snap = Snap()
        let story = props["story"]
        for item in story["snapList"].array {
            let url = item["snapUrls"]["mediaUrl"].string
            guard !url.isEmpty else { continue }
            let kind: MediaKind = item["snapMediaType"].int == 1 ? .video : .image
            snap.items.append(Item(kind: kind, url: url))
        }
        snap.title = story["storyTitle"]["value"].string
        snap.author = props["userProfile"]["publicProfileInfo"]["username"].string
        if snap.author.isEmpty { snap.author = props["userProfile"]["userInfo"]["username"].string }
        return snap
    }
}
