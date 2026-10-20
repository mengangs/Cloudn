// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 bluesky 解析。
import Foundation

/// Bluesky：公开 AppView 接口 app.bsky.feed.getPostThread（匿名即可）。
/// 图片取 feed_fullsize；视频优先作者 PDS 上的原始 blob（整段 mp4，先查 plc.directory / did:web 拿 PDS 地址），
/// 拿不到再用 video.bsky.app 的 HLS。自己没有媒体时取引用帖里的媒体；Tenor GIF 按图片下载。
struct BlueskyParser: VideoParser {
    let platform = VideoPlatform.bluesky

    static let postRx = Rx(#"bsky\.app/profile/([^/\s?#]+)/post/([A-Za-z0-9]+)"#, ignoreCase: true)
    static let referer = "https://bsky.app/"

    struct Item: Equatable {
        let kind: MediaKind
        /// 图片直链；视频为 HLS 播放列表
        let url: String
        var did = ""
        var cid = ""
        var mimeType = ""
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        guard let target = Self.handleAndID(link.url) else {
            throw VideoParseError(.unsupported, "无法从链接中识别 Bluesky 帖子")
        }
        let post = try await fetchPost(handle: target.handle, id: target.id)
        let items = Self.items(post)
        if items.isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }

        let headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer]
        let text = post["record"]["text"].string
        let title = text.isEmpty ? "Bluesky \(target.id)" : String(text.replacingOccurrences(of: "\n", with: " ").prefix(40))
        let base = FileNames.base(title, fallback: "bluesky_\(target.id)")
        let single = items.count == 1
        var endpoints: [String: String] = [:]
        var medias: [VideoMedia] = []
        for (i, item) in items.enumerated() {
            let stem = single ? base : "\(base)_\(i + 1)"
            if item.kind == .image {
                let ext = Self.imageExtension(item.url)
                medias.append(VideoMedia(url: item.url, kind: .image, fileName: "\(stem).\(ext)", headers: headers, quality: "原图"))
                continue
            }
            var blob = ""
            if !item.did.isEmpty && !item.cid.isEmpty && Self.blobExtension(item.mimeType) != nil {
                if endpoints[item.did] == nil { endpoints[item.did] = await pdsEndpoint(did: item.did) }
                let endpoint = endpoints[item.did] ?? ""
                if !endpoint.isEmpty { blob = Self.blobURL(endpoint: endpoint, did: item.did, cid: item.cid) }
            }
            if !blob.isEmpty {
                let ext = Self.blobExtension(item.mimeType) ?? "mp4"
                medias.append(VideoMedia(url: blob, kind: .video, fileName: "\(stem).\(ext)", headers: headers, quality: "原始文件"))
            } else if !item.url.isEmpty {
                medias.append(VideoMedia(url: item.url, kind: .video, fileName: "\(stem).mp4", isHLS: true, headers: headers, quality: "HLS"))
            }
        }
        if medias.isEmpty { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let author = post["author"]
        let handle = author["handle"].string
        let url = "https://bsky.app/profile/\(handle.isEmpty ? target.handle : handle)/post/\(target.id)"
        let cover = items.first(where: { $0.kind == .image })?.url ?? post["embed"]["thumbnail"].string
        var name = author["displayName"].string
        if name.isEmpty { name = handle }
        return VideoParseResult(platform: platform, title: title, author: name, avatar: author["avatar"].string, cover: cover,
                                text: text, timestamp: ImgurParser.parseTime(post["record"]["createdAt"].string),
                                url: url, medias: medias)
    }

    private func fetchPost(handle: String, id: String) async throws -> JSON {
        let uri = "at://\(handle)/app.bsky.feed.post/\(id)"
        let url = "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri=\(uri.urlQueryEncoded)&depth=0&parentHeight=0"
        let headers: [(String, String)] = [("Accept", "application/json"), ("User-Agent", VideoHTTP.uaChrome)]
        let r = try await OverseasHTTP.send(.get(url, headers: headers), site: "Bluesky")
        let json = r.json ?? JSON(nil)
        if !r.isSuccess {
            let error = json["error"].string
            if r.status == 400 && (error == "NotFound" || error == "InvalidRequest") {
                throw VideoParseError(.notFound, "帖子或用户不存在")
            }
            if r.status == 429 { throw VideoParseError(.blocked, "Bluesky 请求过于频繁（HTTP 429），请稍后重试") }
            let suffix = error.isEmpty ? "" : "：" + error
            throw VideoParseError(.unknown, "Bluesky 接口请求失败（HTTP \(r.status)）" + suffix)
        }
        return try Self.threadPost(json)
    }

    /// did:plc → plc.directory；did:web → /.well-known/did.json；取 AtprotoPersonalDataServer
    private func pdsEndpoint(did: String) async -> String {
        let docURL: String
        if did.hasPrefix("did:web:") {
            docURL = "https://\(did.dropFirst("did:web:".count))/.well-known/did.json"
        } else {
            docURL = "https://plc.directory/\(did)"
        }
        let request = HTTPRequest.get(docURL, headers: [("Accept", "application/json"), ("User-Agent", VideoHTTP.uaChrome)])
        guard let r = try? await OverseasHTTP.send(request, site: "Bluesky"), r.isSuccess, let doc = r.json else { return "" }
        return Self.pdsEndpoint(fromDIDDocument: doc)
    }

    // MARK: 纯逻辑

    static func handleAndID(_ url: String) -> (handle: String, id: String)? {
        guard let m = postRx.firstMatch(in: url) else { return nil }
        let handle = m[1].removingPercentEncoding ?? m[1]
        return (handle, m[2])
    }

    static func threadPost(_ json: JSON) throws -> JSON {
        let thread = json["thread"]
        let type = thread["$type"].string
        if type.hasSuffix("#notFoundPost") { throw VideoParseError(.notFound, "帖子不存在或已删除") }
        if type.hasSuffix("#blockedPost") { throw VideoParseError(.unknown, "作者屏蔽了该帖子的查看") }
        let post = thread["post"]
        guard post.isObject else { throw VideoParseError(.notFound, "帖子不存在或不可见") }
        return post
    }

    /// 帖子视图 → 媒体；自己没有就取引用帖（record / recordWithMedia 里的嵌入）
    static func items(_ post: JSON) -> [Item] {
        let did = post["author"]["did"].string
        let own = embedItems(post["embed"], did: did, record: post["record"]["embed"])
        if !own.isEmpty { return own }
        let recordView = post["embed"]["record"]
        let quoted = recordView["record"].isObject ? recordView["record"] : recordView
        guard quoted.isObject else { return [] }
        let quotedDID = quoted["author"]["did"].string
        var out: [Item] = []
        for (i, embed) in quoted["embeds"].array.enumerated() {
            let record = i == 0 ? quoted["value"]["embed"] : JSON(nil)
            out.append(contentsOf: embedItems(embed, did: quotedDID, record: record))
        }
        return out
    }

    /// 单个嵌入视图；record 是同一嵌入的原始记录（取视频 blob 的 cid 与 mimeType）
    static func embedItems(_ embed: JSON, did: String, record: JSON) -> [Item] {
        let type = embed["$type"].string
        if type.hasPrefix("app.bsky.embed.images") {
            var out: [Item] = []
            for image in embed["images"].array {
                var url = image["fullsize"].string
                if url.isEmpty { url = image["thumb"].string }
                if !url.isEmpty { out.append(Item(kind: .image, url: url)) }
            }
            return out
        }
        if type.hasPrefix("app.bsky.embed.video") {
            var cid = embed["cid"].string
            if cid.isEmpty { cid = record["video"]["ref"]["$link"].string }
            let playlist = embed["playlist"].string
            if playlist.isEmpty && cid.isEmpty { return [] }
            var mime = record["video"]["mimeType"].string
            if mime.isEmpty { mime = "video/mp4" }
            return [Item(kind: .video, url: playlist, did: did, cid: cid, mimeType: mime)]
        }
        if type.hasPrefix("app.bsky.embed.recordWithMedia") {
            return embedItems(embed["media"], did: did, record: record["media"])
        }
        if type.hasPrefix("app.bsky.embed.external") {
            let uri = embed["external"]["uri"].string
            let host = URL(string: uri)?.host?.lowercased() ?? ""
            let path = (URL(string: uri)?.path ?? "").lowercased()
            if host == "media.tenor.com" && path.hasSuffix(".gif") { return [Item(kind: .image, url: uri)] }
        }
        return []
    }

    static func pdsEndpoint(fromDIDDocument doc: JSON) -> String {
        for service in doc["service"].array where service["type"].string == "AtprotoPersonalDataServer" {
            let endpoint = service["serviceEndpoint"].string
            if endpoint.hasPrefix("https://") { return endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint }
        }
        return "https://bsky.social"
    }

    static func blobURL(endpoint: String, did: String, cid: String) -> String {
        "\(endpoint)/xrpc/com.atproto.sync.getBlob?did=\(did.urlQueryEncoded)&cid=\(cid.urlQueryEncoded)"
    }

    /// 只有 iOS 能直接播放的容器才下原始 blob，其余（如 webm）走 HLS
    static func blobExtension(_ mime: String) -> String? {
        switch mime.lowercased() {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return nil
        }
    }

    /// `.../feed_fullsize/plain/<did>/<cid>@jpeg` → jpg
    static func imageExtension(_ url: String) -> String {
        let fmt = url.substringAfterLast("@", default: "").lowercased()
        switch fmt {
        case "jpeg", "jpg": return "jpg"
        case "png", "webp", "gif": return fmt
        default: return DomesticHTML.imageExtension(url)
        }
    }
}
