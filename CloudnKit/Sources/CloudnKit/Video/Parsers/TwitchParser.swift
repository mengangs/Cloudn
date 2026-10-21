// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 twitch 解析。
import Foundation

/// Twitch：只支持剪辑（clip）与回放（VOD），不支持直播。
/// - 剪辑：GQL（网页端公开 Client-ID）取 videoQualities + playbackAccessToken，直链 mp4 拼上 sig/token；
/// - 回放：GQL 取 videoPlaybackAccessToken，向 usher.ttvnw.net 要 HLS 主播放列表（只要 H.264，兼容性最好）。
struct TwitchParser: VideoParser {
    let platform = VideoPlatform.twitch

    static let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
    static let gqlURL = "https://gql.twitch.tv/gql"
    static let clipQueryHash = "2db6a3b20eabf510bd3cf465ae2408834b59eb6b8af89ca73ab1486cacecfb63"
    static let playerParams = #"params: {platform: "web", playerBackend: "mediaplayer", playerType: "site"}"#

    struct ClipStream: Equatable {
        let url: String
        let quality: String
    }

    private var mediaHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.twitch.tv/", "Origin": "https://www.twitch.tv"]
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        switch link.kind {
        case "clip": return try await parseClip(link.id)
        case "vod": return try await parseVOD(link.id)
        default: throw VideoParseError(.unsupported, "暂不支持 Twitch 直播与频道页，请复制剪辑（clip）或回放（videos）链接")
        }
    }

    // MARK: 剪辑

    private func parseClip(_ slug: String) async throws -> VideoParseResult {
        guard !slug.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 Twitch 剪辑") }
        // 先走参考实现的持久化查询；哈希失效时退回等价的明文查询
        let persistedQuery: [String: Any] = ["version": 1, "sha256Hash": Self.clipQueryHash]
        let variables: [String: Any] = ["slug": slug]
        let operation: [String: Any] = [
            "operationName": "ShareClipRenderStatus",
            "variables": variables,
            "extensions": ["persistedQuery": persistedQuery] as [String: Any]
        ]
        let persisted: [[String: Any]] = [operation]
        var clip = JSON(nil)
        if let json = try? await gql(persisted) {
            clip = json[0]["data"]["clip"]
        }
        if !clip.isObject || Self.bestClipStream(clip) == nil {
            let json = try await gql(["query": Self.clipQuery(slug: slug)])
            clip = json["data"]["clip"]
            if !clip.isObject {
                if let message = json["errors"][0]["message"].string.nilIfBlank {
                    throw VideoParseError(.unknown, "Twitch 接口返回错误：\(message)")
                }
                throw VideoParseError(.notFound, "Twitch 剪辑不存在或已删除")
            }
        }
        let streams = Self.clipStreams(clip)
        guard !streams.isEmpty else {
            throw VideoParseError(.unsupported, "这个 Twitch 剪辑没有可下载的播放地址")
        }

        let title = clip["title"].string
        let base = FileNames.base(title, fallback: "twitch_clip_\(slug)")
        let medias = OverseasVariants.medias(streams.map { OverseasVariants.Option(url: $0.url, quality: $0.quality) },
                                             stem: base, group: "video", headers: mediaHeaders)
        let asset = clip["assets"][0]
        let cover = asset["thumbnailURL"].string.nilIfBlank ?? clip["thumbnailURL"].string
        let broadcaster = clip["broadcaster"]
        return VideoParseResult(platform: platform, title: title, author: broadcaster.string("displayName", "login"),
                                avatar: broadcaster["profileImageURL"].string, cover: cover,
                                timestamp: Self.parseISO8601(clip["createdAt"].string),
                                url: "https://clips.twitch.tv/\(slug)", medias: medias)
    }

    // MARK: 回放

    private func parseVOD(_ id: String) async throws -> VideoParseResult {
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 Twitch 回放 ID") }
        let json = try await gql(["query": Self.vodQuery(id: id)])
        let token = json["data"]["videoPlaybackAccessToken"]
        let video = json["data"]["video"]
        guard token.isObject, !token["value"].string.isEmpty else {
            if json["data"].isObject && !video.isObject {
                throw VideoParseError(.notFound, "Twitch 回放不存在或已删除")
            }
            if let message = json["errors"][0]["message"].string.nilIfBlank {
                throw VideoParseError(.unknown, "Twitch 接口返回错误：\(message)")
            }
            throw VideoParseError(.unknown, "Twitch 回放播放令牌获取失败")
        }

        let playlist = Self.usherURL(id: id, token: token["value"].string, signature: token["signature"].string,
                                     random: Int.random(in: 1_000_000..<10_000_000))
        // 预取一次主播放列表：订阅者专享等限制在这里以 403 + JSON 报出来
        let r = try await OverseasHTTP.send(.get(playlist, headers: mediaHeaders.sortedPairs), site: "Twitch")
        if !r.isSuccess {
            throw Self.usherError(status: r.status, body: r.json ?? JSON(nil))
        }

        let title = video["title"].string
        let base = FileNames.base(title, fallback: "twitch_v\(id)")
        let media = VideoMedia(url: playlist, kind: .video, fileName: "\(base).mp4", isHLS: true, headers: mediaHeaders,
                               quality: "源画质（HLS）")
        let owner = video["owner"]
        return VideoParseResult(platform: platform, title: title, author: owner.string("displayName", "login"),
                                avatar: owner["profileImageURL"].string, cover: Self.vodThumbnail(video),
                                timestamp: Self.parseISO8601(video["publishedAt"].string),
                                url: "https://www.twitch.tv/videos/\(id)", medias: [media])
    }

    private func gql(_ body: Any) async throws -> JSON {
        let request = HTTPRequest(url: Self.gqlURL, method: "POST",
                                  headers: [("Client-ID", Self.clientID), ("Content-Type", "text/plain;charset=UTF-8"),
                                            ("User-Agent", VideoHTTP.uaChrome), ("Origin", "https://www.twitch.tv"),
                                            ("Referer", "https://www.twitch.tv/")],
                                  body: JSON.serialize(body))
        let r = try await OverseasHTTP.send(request, site: "Twitch")
        switch r.status {
        case 200..<300: break
        case 429: throw VideoParseError(.blocked, "Twitch 接口请求过于频繁（HTTP 429），请稍后重试")
        default: throw VideoParseError(.unknown, "Twitch 接口请求失败（HTTP \(r.status)）")
        }
        guard let json = r.json else { throw VideoParseError(.unknown, "Twitch 接口返回的不是合法 JSON") }
        return json
    }

    // MARK: 纯逻辑

    static func clipQuery(slug: String) -> String {
        let s = gqlString(slug)
        return "{ clip(slug: \(s)) { id title createdAt thumbnailURL broadcaster { login displayName } "
            + "playbackAccessToken(\(playerParams)) { signature value } "
            + "videoQualities { quality frameRate sourceURL } } }"
    }

    static func vodQuery(id: String) -> String {
        let s = gqlString(id)
        return "{ video(id: \(s)) { id title publishedAt lengthSeconds previewThumbnailURL(width: 1280, height: 720) "
            + "owner { login displayName } } "
            + "videoPlaybackAccessToken(id: \(s), \(playerParams)) { value signature } }"
    }

    /// GQL 字符串字面量（转义引号与反斜杠）
    static func gqlString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// 剪辑：assets[0]（横屏原始比例）或旧结构的 videoQualities 里取最高清，拼上 sig/token
    static func bestClipStream(_ clip: JSON) -> ClipStream? {
        clipStreams(clip).first
    }

    /// 剪辑的各档清晰度：按 (分辨率, 帧率) 从高到低（同值保持原顺序），每档都拼上 sig/token
    static func clipStreams(_ clip: JSON) -> [ClipStream] {
        var qualities = clip["assets"][0]["videoQualities"].array
        if qualities.isEmpty { qualities = clip["videoQualities"].array }
        var list: [(index: Int, height: Int, fps: Double, item: JSON)] = []
        for (i, q) in qualities.enumerated() where !q["sourceURL"].string.isEmpty {
            list.append((i, Int(q["quality"].string) ?? 0, q["frameRate"].double, q))
        }
        list.sort {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            return $0.index < $1.index
        }
        let token = clip["playbackAccessToken"]
        let signature = token["signature"].string
        let value = token["value"].string
        return list.map { entry in
            var url = entry.item["sourceURL"].string
            if !signature.isEmpty && !value.isEmpty {
                let sep = url.contains("?") ? "&" : "?"
                url += "\(sep)sig=\(signature.urlQueryEncoded)&token=\(value.urlQueryEncoded)"
            }
            let quality = entry.item["quality"].string
            let fps = Int(entry.fps.rounded())
            let label = Int(quality) == nil ? quality : (fps > 30 ? "\(quality)P\(fps)" : "\(quality)P")
            return ClipStream(url: url, quality: label)
        }
    }

    static func usherURL(id: String, token: String, signature: String, random: Int) -> String {
        let pairs: [(String, String)] = [
            ("allow_source", "true"), ("allow_audio_only", "true"), ("allow_spectre", "true"), ("p", String(random)),
            ("platform", "web"), ("player", "twitchweb"), ("supported_codecs", "h264"),
            ("playlist_include_framerate", "true"), ("sig", signature), ("token", token)
        ]
        let query = pairs.map { "\($0.0)=\($0.1.urlQueryEncoded)" }.joined(separator: "&")
        return "https://usher.ttvnw.net/vod/\(id).m3u8?\(query)"
    }

    /// usher 的错误体：`[{"error":"...","error_code":"vod_manifest_restricted"}]`
    static func usherError(status: Int, body: JSON) -> VideoParseError {
        let info = body.isArray ? body[0] : body
        let code = info["error_code"].string
        if code == "vod_manifest_restricted" || code == "unauthorized_entitlements" {
            return VideoParseError(.unsupported, "该 Twitch 回放仅限频道订阅者观看，暂不支持下载")
        }
        let message = info["error"].string
        if status == 404 { return VideoParseError(.notFound, "Twitch 回放不存在或已删除") }
        if !message.isEmpty { return VideoParseError(.unknown, "Twitch：\(message)（\(code)）") }
        return VideoParseError(.unknown, "Twitch 回放播放列表获取失败（HTTP \(status)）")
    }

    /// 回放封面：处理中的 404 占位图不要
    static func vodThumbnail(_ video: JSON) -> String {
        let url = video["previewThumbnailURL"].string
        if url.contains("/404_processing_") { return "" }
        return url
    }

    static func parseISO8601(_ s: String) -> Int64 {
        guard !s.isEmpty else { return 0 }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
        return 0
    }
}
