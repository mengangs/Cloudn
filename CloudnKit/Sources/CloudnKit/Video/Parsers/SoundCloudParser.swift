// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 soundcloud 解析。
import Foundation

/// SoundCloud：单曲；歌单 / 专辑（sets）列出曲目条目，逐条再解析。
/// 1. client_id：首页内嵌的 `__sc_hydration`（apiClient）里直接有；没有再逐个下载站点 JS，正则抠 `client_id:"…"`；
/// 2. `api-v2.soundcloud.com/resolve?url=` 把页面地址解析成曲目；
/// 3. media.transcodings 里优先渐进式 mp3，其次 HLS（aac → mp3 → opus），请求其 url 拿真实地址。
/// 只有 30 秒试听（snipped，Go+ 专享）的曲目直接报错。分享短链 `on.soundcloud.com/xxx` 走统一的短链展开。
struct SoundCloudParser: VideoParser {
    let platform = VideoPlatform.soundcloud

    static let apiBase = "https://api-v2.soundcloud.com/"

    struct Transcoding: Equatable {
        let url: String
        let preset: String
        let protocolName: String
        let mimeType: String
        let snipped: Bool

        var isHLS: Bool { protocolName != "progressive" }
    }

    private var headers: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://soundcloud.com/", "Origin": "https://soundcloud.com",
         "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var clientID = try await Self.clientIDCache.get(refresh: false) { try await self.loadClientID() }
        let apiURL = Self.infoURL(kind: link.kind, id: link.id)
        guard !apiURL.isEmpty else { throw VideoParseError(.unsupported, "无法识别 SoundCloud 链接") }

        // client_id 过期（401/403）时刷新一次
        var r = try await api(apiURL, clientID: clientID, extra: [])
        if r.status == 401 || r.status == 403 {
            clientID = try await Self.clientIDCache.get(refresh: true) { try await self.loadClientID() }
            r = try await api(apiURL, clientID: clientID, extra: [])
        }
        try Self.check(r, what: "SoundCloud 曲目")
        guard let info = r.json, info.isObject else { throw VideoParseError(.unknown, "SoundCloud 接口返回的不是合法 JSON") }

        let kind = info["kind"].string
        if kind == "playlist" || kind == "system-playlist" {
            return try await parseSet(info, clientID: clientID)
        }
        if kind == "user" { throw VideoParseError(.unsupported, "这是 SoundCloud 用户主页，请复制单曲链接") }
        guard kind == "track" || kind.isEmpty else { throw VideoParseError(.unsupported, "暂不支持该类型的 SoundCloud 链接") }

        let transcoding = try Self.pickTranscoding(info)
        var extra: [(String, String)] = []
        let auth = info["track_authorization"].string
        if !auth.isEmpty { extra.append(("track_authorization", auth)) }
        let secret = info["secret_token"].string.nilIfBlank ?? Self.secretToken(in: link.id)
        if !secret.isEmpty { extra.append(("secret_token", secret)) }
        let streamResponse = try await api(transcoding.url, clientID: clientID, extra: extra)
        try Self.check(streamResponse, what: "SoundCloud 音频地址")
        let streamURL = streamResponse.json?["url"].string ?? ""
        guard !streamURL.isEmpty else { throw VideoParseError(.unknown, "SoundCloud 没有返回音频地址") }

        let title = info["title"].string
        let trackID = info["id"].string
        let base = FileNames.base(title, fallback: "soundcloud_\(trackID)")
        let ext = Self.fileExtension(transcoding)
        let mediaHeaders = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://soundcloud.com/"]
        let media = VideoMedia(url: streamURL, kind: .audio, fileName: "\(base).\(ext)", isHLS: transcoding.isHLS,
                               headers: mediaHeaders, quality: Self.qualityLabel(transcoding))
        let user = info["user"]
        return VideoParseResult(platform: platform, title: title, author: user["username"].string,
                                avatar: user["avatar_url"].string, cover: Self.artwork(info),
                                text: info["description"].string, timestamp: Self.parseTime(info["created_at"].string),
                                url: info["permalink_url"].string, medias: [media])
    }

    /// 歌单 / 专辑：响应里只有前几首是完整曲目，其余只有 id，按 50 个一批用 `/tracks?ids=` 补全
    private func parseSet(_ info: JSON, clientID: String) async throws -> VideoParseResult {
        let missing = Self.stubTrackIDs(info)
        let playlistID = info["id"].string
        let secret = info["secret_token"].string
        var fetched: [String: JSON] = [:]
        // 进度按曲目算：响应里已完整的 + 已补全的 / 歌单曲目总数
        let total = info["tracks"].array.count
        let complete = total - missing.count
        CollectionProgress.report(fetched: complete, total: total)
        var stopped = false
        for batch in Self.batches(missing, size: 50) {
            if CollectionProgress.isStopRequested {
                stopped = true
                break
            }
            var extra: [(String, String)] = [("ids", batch.joined(separator: ","))]
            if !playlistID.isEmpty { extra.append(("playlistId", playlistID)) }
            if !secret.isEmpty { extra.append(("playlistSecretToken", secret)) }
            guard let r = try? await api(Self.apiBase + "tracks", clientID: clientID, extra: extra), r.isSuccess,
                  let json = r.json else { continue }
            for t in json.array {
                let id = t["id"].string
                if !id.isEmpty { fetched[id] = t }
            }
            CollectionProgress.report(fetched: complete + fetched.count, total: total)
        }
        let entries = Self.setEntries(info, fetched: fetched, resolvedOnly: stopped)
        guard !entries.isEmpty else { throw VideoParseError(.unsupported, "这个 SoundCloud 歌单/专辑里没有曲目") }
        let title = info["title"].string
        let user = info["user"]
        return VideoParseResult(platform: platform, title: title.isEmpty ? "SoundCloud 歌单 \(playlistID)" : title,
                                author: user["username"].string, avatar: user["avatar_url"].string,
                                cover: Self.artwork(info), text: info["description"].string,
                                timestamp: Self.parseTime(info["created_at"].string), url: info["permalink_url"].string,
                                notice: stopped ? "已停止加载，列出了已获取的 \(entries.count) 首曲目" : "", entries: entries)
    }

    private func api(_ url: String, clientID: String, extra: [(String, String)]) async throws -> HTTPResponse {
        var query = [("client_id", clientID)] + extra
        query = query.filter { !$0.1.isEmpty }
        let joined = query.map { "\($0.0)=\($0.1.urlQueryEncoded)" }.joined(separator: "&")
        let sep = url.contains("?") ? "&" : "?"
        return try await OverseasHTTP.send(.get(url + sep + joined, headers: headers.sortedPairs), site: "SoundCloud")
    }

    /// 首页 hydration → 站点 JS（倒序，client_id 一般在最后几个包里）
    private func loadClientID() async throws -> String {
        let home = try await OverseasHTTP.send(.get("https://soundcloud.com/", headers: headers.sortedPairs), site: "SoundCloud")
        try Self.check(home, what: "SoundCloud 首页")
        let html = home.text
        if let id = Self.clientID(inHydration: html) { return id }
        for src in Self.scriptURLs(in: html).reversed() {
            guard let r = try? await OverseasHTTP.send(.get(src, headers: headers.sortedPairs), site: "SoundCloud"),
                  r.isSuccess else { continue }
            if let id = Self.clientID(inScript: r.text) { return id }
        }
        throw VideoParseError(.unknown, "无法获取 SoundCloud 的 client_id，请稍后重试")
    }

    // MARK: client_id 缓存

    final class ClientIDCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""

        func get(refresh: Bool, loader: @Sendable () async throws -> String) async throws -> String {
            if !refresh, let cached = current(), !cached.isEmpty { return cached }
            let fresh = try await loader()
            store(fresh)
            return fresh
        }

        private func current() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        private func store(_ v: String) {
            lock.lock()
            value = v
            lock.unlock()
        }
    }

    static let clientIDCache = ClientIDCache()

    // MARK: 纯逻辑

    /// 曲目接口地址：页面路径走 resolve，api 链接直接用曲目 ID
    static func infoURL(kind: String, id: String) -> String {
        guard !id.isEmpty else { return "" }
        if kind == "api" {
            return apiBase + "tracks/" + id
        }
        return apiBase + "resolve?url=" + ("https://soundcloud.com/" + id).urlQueryEncoded
    }

    /// 私密曲目分享链接里的 `s-xxxx` 段
    static func secretToken(in path: String) -> String {
        Rx(#"(?:^|/)(s-[A-Za-z0-9]+)$"#).first(in: path) ?? ""
    }

    /// 歌单里缺 permalink_url / title 的曲目 id（只有 id 的占位）
    static func stubTrackIDs(_ info: JSON) -> [String] {
        info["tracks"].array.filter { $0["permalink_url"].string.isEmpty || $0["title"].string.isEmpty }
            .map { $0["id"].string }.filter { !$0.isEmpty }
    }

    static func batches(_ ids: [String], size: Int) -> [[String]] {
        guard size > 0 else { return [ids] }
        var out: [[String]] = []
        var i = 0
        while i < ids.count {
            out.append(Array(ids[i..<min(i + size, ids.count)]))
            i += size
        }
        return out
    }

    /// 歌单曲目 → 条目（补全过的优先）；没有页面地址时用 api-v2 曲目地址（链接规则 kind "api" 能识别）。
    /// resolvedOnly：用户提前停止时只列出已拿到完整信息的曲目
    static func setEntries(_ info: JSON, fetched: [String: JSON], resolvedOnly: Bool = false) -> [VideoEntry] {
        let secret = info["secret_token"].string
        var out: [VideoEntry] = []
        for stub in info["tracks"].array {
            let id = stub["id"].string
            let track = fetched[id] ?? stub
            if resolvedOnly && fetched[id] == nil && (stub["permalink_url"].string.isEmpty || stub["title"].string.isEmpty) { continue }
            var url = track["permalink_url"].string
            if url.isEmpty {
                guard !id.isEmpty else { continue }
                url = apiBase + "tracks/" + id
                if !secret.isEmpty { url += "?secret_token=" + secret }
            }
            let title = track["title"].string.nilIfBlank ?? "SoundCloud \(id)"
            let ms = track["duration"].double
            let hasArt = !track["artwork_url"].string.isEmpty || !track["user"]["avatar_url"].string.isEmpty
            out.append(VideoEntry(title: title, url: url, duration: ms > 0 ? ms / 1000 : nil,
                                  cover: hasArt ? artwork(track) : ""))
        }
        return out
    }

    static func clientID(inHydration html: String) -> String? {
        Rx(#""hydratable"\s*:\s*"apiClient"\s*,\s*"data"\s*:\s*\{\s*"id"\s*:\s*"([0-9a-zA-Z]{32})""#).first(in: html)
    }

    static func clientID(inScript js: String) -> String? {
        Rx(#"client_id\s*:\s*"([0-9a-zA-Z]{32})""#).first(in: js)
            ?? Rx(#"client_id=([0-9a-zA-Z]{32})"#).first(in: js)
    }

    /// 页面里的 `<script src="…">`，只要 SoundCloud 自家 CDN（sndcdn.com）上的
    static func scriptURLs(in html: String) -> [String] {
        Rx(#"<script[^>]+src="([^"]+)""#).allMatches(in: html).map { $0[1] }
            .map { VideoHTTP.absolutize(base: "https://soundcloud.com/", $0) }
            .filter { url in
                guard let host = URL(string: url)?.host?.lowercased() else { return false }
                return host == "sndcdn.com" || host.hasSuffix(".sndcdn.com") || host.hasSuffix("soundcloud.com")
            }
    }

    static func transcodings(_ info: JSON) -> [Transcoding] {
        info["media"]["transcodings"].array.compactMap { (t: JSON) -> Transcoding? in
            let url = t["url"].string
            let preset = t["preset"].string
            guard !url.isEmpty, !preset.isEmpty else { return nil }
            var proto = t["format"]["protocol"].string
            if proto.isEmpty { proto = "progressive" }
            let isDRM = proto.hasPrefix("ctr-") || proto.hasPrefix("cbc-")
            if !isDRM && proto != "hls" && url.contains("/hls") { proto = "hls" }
            let snipped = t["snipped"].bool || url.contains("/preview/")
            return Transcoding(url: url, preset: preset, protocolName: proto, mimeType: t["format"]["mime_type"].string,
                               snipped: snipped)
        }
    }

    /// 渐进式 mp3 优先；否则 HLS（aac → mp3 → opus）；跳过 DRM（ctr-/cbc-）、损坏的 abr 与 30 秒试听
    static func pickTranscoding(_ info: JSON) throws -> Transcoding {
        let all = transcodings(info)
        let usable = all.filter { t in
            let base = t.preset.substringBefore("_")
            let drm = t.protocolName.hasPrefix("ctr-") || t.protocolName.hasPrefix("cbc-") || t.protocolName == "encrypted-hls"
            return !drm && base != "abr" && (t.protocolName == "progressive" || t.protocolName == "hls")
        }
        let full = usable.filter { !$0.snipped }
        let order: [(String, String)] = [
            ("progressive", "mp3"), ("progressive", "aac"), ("hls", "aac"), ("hls", "mp3"), ("progressive", "opus"), ("hls", "opus")
        ]
        for (proto, codec) in order {
            if let t = full.first(where: { $0.protocolName == proto && $0.preset.substringBefore("_") == codec }) { return t }
        }
        if let any = full.first { return any }

        let policy = info["policy"].string
        if !usable.isEmpty || policy == "SNIP" {
            throw VideoParseError(.unsupported, "这首曲目只能试听 30 秒（SoundCloud Go+ 会员专享），无法下载完整音频")
        }
        if policy == "BLOCK" {
            throw VideoParseError(.unsupported, "这首 SoundCloud 曲目在当前地区不可收听")
        }
        if all.contains(where: { $0.protocolName.hasPrefix("ctr-") || $0.protocolName.hasPrefix("cbc-") }) {
            throw VideoParseError(.unsupported, "这首 SoundCloud 曲目只提供加密（DRM）音频，无法下载")
        }
        throw VideoParseError(.unsupported, "这首 SoundCloud 曲目没有可下载的音频")
    }

    static func fileExtension(_ t: Transcoding) -> String {
        let codec = t.preset.substringBefore("_")
        switch codec {
        case "mp3": return "mp3"
        case "aac": return "m4a"
        case "opus": return t.isHLS ? "opus" : "ogg"
        default:
            if t.mimeType.contains("mpeg") { return "mp3" }
            if t.mimeType.contains("mp4") { return "m4a" }
            return "mp3"
        }
    }

    /// `mp3_1_0` / `aac_160k` / `opus_0_0` → 「MP3」「AAC 160k」……
    static func qualityLabel(_ t: Transcoding) -> String {
        let parts = t.preset.split(separator: "_").map(String.init)
        let codec = (parts.first ?? "").uppercased()
        let rate = parts.first(where: { $0.hasSuffix("k") && Int($0.dropLast()) != nil }) ?? ""
        var label = rate.isEmpty ? codec : "\(codec) \(rate)"
        if t.isHLS { label += "（HLS）" }
        return label
    }

    /// 封面：artwork_url（没有用头像）换成 t500x500 大图
    static func artwork(_ info: JSON) -> String {
        let raw = info["artwork_url"].string.nilIfBlank ?? info["user"]["avatar_url"].string
        guard !raw.isEmpty else { return "" }
        return Rx(#"-(?:large|t\d+x\d+|crop|small|badge|tiny|mini)\.(jpg|png)"#).replacing(in: raw, with: "-t500x500.$1")
    }

    static func parseTime(_ s: String) -> Int64 {
        guard !s.isEmpty else { return 0 }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        g.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return g.date(from: s).map { Int64($0.timeIntervalSince1970) } ?? 0
    }

    static func check(_ r: HTTPResponse, what: String) throws {
        if r.isSuccess { return }
        switch r.status {
        case 404, 410: throw VideoParseError(.notFound, "\(what)不存在或已删除（HTTP \(r.status)）")
        case 401, 403: throw VideoParseError(.unknown, "\(what)拒绝访问（HTTP \(r.status)），可能是私密曲目或地区限制")
        case 429: throw VideoParseError(.blocked, "SoundCloud 请求过于频繁（HTTP 429），请稍后重试")
        default: throw VideoParseError(.unknown, "\(what)请求失败（HTTP \(r.status)）")
        }
    }
}
