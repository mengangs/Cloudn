// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 youtube 解析（extractor/youtube/_base.py、_video.py）。
import Foundation

/// 一个 innertube 客户端（`/youtubei/v1/player` 请求里冒充的身份），取值与 yt-dlp INNERTUBE_CLIENTS 一致
struct YouTubeClient: Equatable, Sendable {
    let key: String
    let name: String
    let version: String
    /// INNERTUBE_CONTEXT_CLIENT_NAME（请求头 X-YouTube-Client-Name）
    let nameID: Int
    let userAgent: String
    let extra: [String: String]
    /// 返回的地址带 signatureCipher / n 挑战，必须借助播放器 JS 求解
    let requiresJS: Bool
    let embedded: Bool

    /// 不需要 PO Token、不需要播放器 JS：yt-dlp 在没有 JS 运行时的默认客户端（「儿童」内容不可用）
    static let visionOS = YouTubeClient(
        key: "visionos", name: "VISIONOS", version: "1.02", nameID: 101,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        extra: ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"],
        requiresJS: false, embedded: false)

    /// 不需要 PO Token，但签名与 n 参数要用播放器 JS 求解：yt-dlp 有 JS 运行时时的首选客户端
    static let tvSamsung = YouTubeClient(
        key: "tv_samsung", name: "TVHTML5", version: "5.20260707", nameID: 7,
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        extra: ["deviceMake": "Samsung", "deviceModel": "UKS9800", "osName": "Tizen", "osVersion": "2.4.0"],
        requiresJS: true, embedded: false)

    /// 内嵌播放器：能绕过部分年龄限制 / 儿童内容限制；需要播放器 JS
    static let webEmbedded = YouTubeClient(
        key: "web_embedded", name: "WEB_EMBEDDED_PLAYER", version: "2.20260708.00.00", nameID: 56,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
        extra: [:], requiresJS: true, embedded: true)
}

/// 一次解析里跨请求共享的状态（只在单个 parse 调用内使用）
final class YouTubeSession {
    let videoID: String
    var ytcfg = JSON(nil)
    var initialResponse = JSON(nil)
    var visitorData = ""
    var playerID = ""
    var timestamp = 0
    var embedLoaded = false
    var embedFlags = ""
    var embedVersion = ""

    init(videoID: String) { self.videoID = videoID }
}

/// YouTube：innertube `/youtubei/v1/player` 接口，按 yt-dlp 的客户端策略依次尝试：
/// 1. visionos —— 不要 PO Token、不要 JS，直链可直接下载；
/// 2. tv_samsung —— 不要 PO Token，但签名 / n 参数要在 JavaScriptCore 里跑播放器脚本求解；
/// 3. web_embedded —— 只在遇到年龄限制 / 儿童内容时补试。
/// iOS 只能合并 H.264/HEVC 的 mp4 + AAC 的 m4a，因此只挑这两类分轨（≤1080p 优先 H.264），
/// 另给 itag 18 之类的音视频合一 mp4 兜底，以及一份纯音频 m4a。
struct YouTubeParser: VideoParser {
    let platform = VideoPlatform.youtube

    static let playerAPI = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    /// 同意 Cookie（欧盟地区否则会跳同意页）+ 固定英文界面，与 yt-dlp 的 _initialize_consent / _initialize_pref 一致
    static let consentCookie = "SOCS=CAI; PREF=hl=en&tz=UTC"

    static var pageHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Accept-Language": "en-US,en;q=0.9", "Cookie": consentCookie]
    }

    /// googlevideo 直链不校验 UA 与客户端是否一致（yt-dlp 也统一用浏览器 UA 下载）；
    /// 分轨地址整段请求会被限速，需按 ≤10 MB 的 Range 分块下载（下载器的多连接分块即满足）
    static var mediaHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome]
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        if link.kind == "playlist" { return try await parsePlaylist(link) }
        let id = Self.isVideoID(link.id) ? link.id : (Self.videoID(from: link.url) ?? "")
        guard Self.isVideoID(id) else { throw VideoParseError(.unsupported, "无法从链接中识别 YouTube 视频 ID") }
        let session = YouTubeSession(videoID: id)
        try await loadWatchPage(session)

        if let p = Self.playability(session.initialResponse), p.definitive { throw p.error }

        var plan: [YouTubeClient] = [.visionOS, .tvSamsung]
        var failures: [Playability] = []
        var lastError: VideoParseError?
        var complete: Built?
        var partial: Built?
        var index = 0
        while index < plan.count && complete == nil {
            let client = plan[index]
            index += 1
            if client.requiresJS && !YouTubeSignature.isSupported {
                if lastError == nil { lastError = YouTubeSignature.unsupportedError }
                continue
            }
            let outcome: Attempt
            do {
                outcome = try await attempt(client, session)
            } catch let error as VideoParseError {
                lastError = error
                continue
            }
            switch outcome {
            case .success(let built):
                if built.complete {
                    complete = built
                } else if partial == nil {
                    partial = built
                }
            case .failed(let p):
                if p.definitive { throw p.error }
                failures.append(p)
                if p.tryEmbedded && YouTubeSignature.isSupported && !plan.contains(.webEmbedded) {
                    plan.append(.webEmbedded)
                }
            }
        }

        guard let built = complete ?? partial else {
            if let p = failures.first(where: { !$0.botCheck }) ?? failures.first { throw p.error }
            if let p = Self.playability(session.initialResponse) { throw p.error }
            throw lastError ?? VideoParseError(.unknown, "YouTube 没有返回可下载的格式")
        }
        return result(id: id, built: built, session: session)
    }

    private func result(id: String, built: Built, session: YouTubeSession) -> VideoParseResult {
        let page = session.initialResponse
        let details = built.response["videoDetails"].isObject ? built.response["videoDetails"] : page["videoDetails"]
        let microSource = page["microformat"].isObject ? page : built.response
        let micro = microSource["microformat"]["playerMicroformatRenderer"]
        var title = details["title"].string
        if title.isEmpty { title = Self.text(micro["title"]) }
        let author = details["author"].string.nilIfBlank ?? micro["ownerChannelName"].string
        let date = micro["publishDate"].string.nilIfBlank ?? micro["uploadDate"].string
        var subtitles = Self.subtitles(built.response)
        if subtitles.isEmpty { subtitles = Self.subtitles(page) }
        return VideoParseResult(platform: platform, title: title.isEmpty ? "YouTube \(id)" : title, author: author,
                                cover: Self.thumbnail(details, id: id), text: details["shortDescription"].string,
                                timestamp: Self.parseDate(date), url: "https://www.youtube.com/watch?v=\(id)",
                                medias: built.medias, notice: built.notice, subtitles: subtitles)
    }

    // MARK: 请求

    struct Built {
        let response: JSON
        let medias: [VideoMedia]
        let notice: String
        /// 拿到了分轨的 mp4 画面（否则只有 360p 合一流或纯 HLS，值得再换个客户端试试）
        let complete: Bool
    }

    enum Attempt {
        case success(Built)
        case failed(Playability)
    }

    private func attempt(_ client: YouTubeClient, _ s: YouTubeSession) async throws -> Attempt {
        let pr = try await requestPlayer(client, s)
        let returned = pr["videoDetails"]["videoId"].string
        if !returned.isEmpty && returned != s.videoID { return .failed(Self.mismatch) }
        if let p = Self.playability(pr) { return .failed(p) }
        if let live = Self.liveError(pr) {
            return .failed(Playability(error: live, definitive: true, botCheck: false, tryEmbedded: false))
        }
        let built = try await build(pr, s)
        return .success(built)
    }

    /// 观看页：拿 ytcfg（访客 ID、播放器版本、签名时间戳）与 ytInitialPlayerResponse（元数据）。失败不致命
    private func loadWatchPage(_ s: YouTubeSession) async throws {
        let url = "https://www.youtube.com/watch?v=\(s.videoID)&bpctr=9999999999&has_verified=1"
        let r = try await OverseasHTTP.send(.get(url, headers: Self.pageHeaders.sortedPairs), site: "YouTube")
        guard r.isSuccess else { return }
        let html = r.text
        s.ytcfg = Self.ytcfg(in: html)
        s.initialResponse = Self.initialPlayerResponse(in: html)
        s.visitorData = Self.visitorData(s.ytcfg).nilIfBlank ?? s.initialResponse["responseContext"]["visitorData"].string
        if let id = Self.playerID(inConfig: s.ytcfg) { s.playerID = id }
    }

    private func requestPlayer(_ client: YouTubeClient, _ s: YouTubeSession) async throws -> JSON {
        var sts = 0
        if client.requiresJS { sts = try await signatureTimestamp(s) }
        var version = client.version
        var flags = ""
        if client.embedded {
            await loadEmbedConfig(s, client: client)
            if !s.embedVersion.isEmpty { version = s.embedVersion }
            flags = s.embedFlags
        }
        let body = Self.playerRequestBody(client: client, version: version, videoID: s.videoID,
                                          signatureTimestamp: sts, encryptedHostFlags: flags)
        let headers = Self.apiHeaders(client: client, version: version, visitorData: s.visitorData)
        let r = try await OverseasHTTP.send(.postJSON(Self.playerAPI, body, headers: headers.sortedPairs), site: "YouTube")
        guard r.isSuccess, let json = r.json else {
            switch r.status {
            case 429: throw VideoParseError(.blocked, "YouTube 请求过于频繁（HTTP 429）")
            case 403: throw VideoParseError(.unknown, "YouTube 拒绝了请求（HTTP 403），所在网络的 IP 可能被风控，可更换代理节点后重试")
            default: throw VideoParseError(.unknown, "YouTube 播放接口请求失败（HTTP \(r.status)）")
            }
        }
        if s.visitorData.isEmpty { s.visitorData = json["responseContext"]["visitorData"].string }
        return json
    }

    /// 内嵌页的 ytcfg：web_embedded 请求可能要带 encryptedHostFlags
    private func loadEmbedConfig(_ s: YouTubeSession, client: YouTubeClient) async {
        if s.embedLoaded { return }
        s.embedLoaded = true
        let url = "https://www.youtube.com/embed/\(s.videoID)?html5=1"
        let headers: [(String, String)] = [("User-Agent", client.userAgent), ("Referer", "https://www.reddit.com/"),
                                           ("Cookie", Self.consentCookie)]
        guard let r = try? await OverseasHTTP.send(.get(url, headers: headers), site: "YouTube"), r.isSuccess else { return }
        let cfg = Self.ytcfg(in: r.text)
        s.embedFlags = cfg["WEB_PLAYER_CONTEXT_CONFIGS"]["WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER"]["encryptedHostFlags"].string
        let cfgClient = cfg["INNERTUBE_CONTEXT"]["client"]
        if cfgClient["clientName"].string == client.name { s.embedVersion = cfgClient["clientVersion"].string }
        if s.playerID.isEmpty, let id = Self.playerID(inConfig: cfg) { s.playerID = id }
        if s.visitorData.isEmpty { s.visitorData = Self.visitorData(cfg) }
    }

    // MARK: 播放器脚本

    private func ensurePlayerID(_ s: YouTubeSession) async throws -> String {
        if !s.playerID.isEmpty { return s.playerID }
        let r = try await OverseasHTTP.send(.get("https://www.youtube.com/iframe_api", headers: Self.pageHeaders.sortedPairs),
                                            site: "YouTube")
        guard r.isSuccess, let id = Self.playerID(inIframeAPI: r.text) else {
            throw VideoParseError(.unknown, "获取 YouTube 播放器版本失败（HTTP \(r.status)）")
        }
        s.playerID = id
        return id
    }

    private func signatureTimestamp(_ s: YouTubeSession) async throws -> Int {
        if s.timestamp > 0 { return s.timestamp }
        let id = try await ensurePlayerID(s)
        var sts = 0
        if Self.playerID(inConfig: s.ytcfg) == id { sts = s.ytcfg["STS"].int }
        if sts <= 0, let cached = YouTubeSignature.cache.signatureTimestamp(for: id) { sts = cached }
        if sts <= 0 {
            let js = try await playerJS(id)
            sts = Self.signatureTimestamp(in: js)
        }
        s.timestamp = sts
        return sts
    }

    private func playerJS(_ id: String) async throws -> String {
        if let js = YouTubeSignature.cache.playerJS(for: id) { return js }
        let r = try await OverseasHTTP.send(.get(Self.playerURL(id: id), headers: Self.pageHeaders.sortedPairs), site: "YouTube")
        let js = r.text
        guard r.isSuccess, !js.isEmpty else { throw VideoParseError(.unknown, "下载 YouTube 播放器脚本失败（HTTP \(r.status)）") }
        YouTubeSignature.cache.storePlayer(js, timestamp: Self.signatureTimestamp(in: js), for: id)
        return js
    }

    private func solve(sig: [String], n: [String], _ s: YouTubeSession) async throws -> YouTubeSignature.Solution {
        if sig.isEmpty && n.isEmpty { return YouTubeSignature.Solution() }
        let id = try await ensurePlayerID(s)
        var js: String?
        if YouTubeSignature.cache.preprocessed(for: id) == nil {
            js = try await playerJS(id)
        }
        return try await YouTubeSignature.solve(playerID: id, playerJS: js, sig: sig, n: n)
    }

    // MARK: 组装媒体

    private func build(_ pr: JSON, _ s: YouTubeSession) async throws -> Built {
        let parsed = Self.formats(pr["streamingData"])
        let usable = YouTubeSignature.isSupported ? parsed.list : parsed.list.filter { !$0.needsJS }
        let choices = Self.choose(usable)
        let base = FileNames.base(pr["videoDetails"]["title"].string, fallback: "youtube_\(s.videoID)")

        if choices.isEmpty {
            if !parsed.hlsManifest.isEmpty {
                let media = try await hlsMedia(parsed.hlsManifest, base: base, s)
                return Built(response: pr, medias: [media], notice: "", complete: false)
            }
            throw Self.noFormatError(parsed)
        }

        var sigs: [String] = []
        var ns: [String] = []
        for c in choices {
            var used = [c.main]
            if let a = c.audio { used.append(a) }
            for f in used {
                if !f.sigChallenge.isEmpty { sigs.append(f.sigChallenge) }
                if !f.nChallenge.isEmpty { ns.append(f.nChallenge) }
            }
        }
        let solution = try await solve(sig: sigs, n: ns, s)
        let medias = Self.medias(choices, solution: solution, base: base)
        guard !medias.isEmpty else {
            throw VideoParseError(.unknown, "YouTube 播放地址的签名求解失败，播放器脚本可能已更新")
        }
        let complete = medias.contains { !$0.audioURL.isEmpty }
        return Built(response: pr, medias: medias, notice: Self.notice(parsed.list, choices: choices), complete: complete)
    }

    /// 只有 HLS 清单时兜底：清单路径里的 `/n/xxx/` 同样要求解
    private func hlsMedia(_ manifest: String, base: String, _ s: YouTubeSession) async throws -> VideoMedia {
        var url = manifest
        if let challenge = Self.manifestNChallenge(manifest) {
            guard YouTubeSignature.isSupported else { throw YouTubeSignature.unsupportedError }
            let solution = try await solve(sig: [], n: [challenge], s)
            guard let result = solution.n[challenge] else {
                throw VideoParseError(.unknown, "YouTube 播放地址的 n 参数求解失败，播放器脚本可能已更新")
            }
            url = url.replacingOccurrences(of: "/n/\(challenge)/", with: "/n/\(result)/")
        }
        return VideoMedia(url: url, kind: .video, fileName: "\(base).mp4", isHLS: true, headers: Self.mediaHeaders, quality: "HLS")
    }

    // MARK: 纯逻辑：链接

    static let idPatterns: [Rx] = [
        Rx(#"(?<![A-Za-z0-9\-])youtu\.be/([0-9A-Za-z_\-]{11})(?![0-9A-Za-z_\-])"#, ignoreCase: true),
        Rx(#"(?<![A-Za-z0-9\-])(?:(?:www|m|music)\.)?youtube(?:-nocookie)?\.com/(?:shorts|live|embed|v|e)/([0-9A-Za-z_\-]{11})(?![0-9A-Za-z_\-])"#, ignoreCase: true),
        Rx(#"(?<![A-Za-z0-9\-])(?:(?:www|m|music)\.)?youtube\.com/watch/?\?(?:[^\s#]*?&)?v=([0-9A-Za-z_\-]{11})(?![0-9A-Za-z_\-])"#, ignoreCase: true)
    ]

    static func videoID(from url: String) -> String? {
        for rx in idPatterns {
            if let id = rx.first(in: url) { return id }
        }
        return nil
    }

    static func isVideoID(_ s: String) -> Bool {
        Rx(#"^[0-9A-Za-z_\-]{11}$"#).matches(s)
    }

    // MARK: 纯逻辑：页面

    /// 从 `{` 开始截出配平的 JSON 对象文本（跳过字符串里的括号）
    static func objectLiteral(in text: String, at start: String.Index) -> String? {
        let utf8 = text.utf8
        guard start < utf8.endIndex, utf8[start] == UInt8(ascii: "{") else { return nil }
        var i = start
        var depth = 0
        var inString = false
        var escaped = false
        while i < utf8.endIndex {
            let c = utf8[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == UInt8(ascii: "\\") {
                    escaped = true
                } else if c == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") {
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return String(text[start...i]) }
            }
            i = utf8.index(after: i)
        }
        return nil
    }

    /// 页面里所有 `ytcfg.set({...})` 合并后的配置
    static func ytcfg(in html: String) -> JSON {
        var merged: [String: Any] = [:]
        var from = html.startIndex
        while let r = html.range(of: "ytcfg.set({", range: from..<html.endIndex) {
            let brace = html.index(before: r.upperBound)
            if let literal = objectLiteral(in: html, at: brace), let dict = JSON(text: literal)?.dictionary {
                merged.merge(dict) { _, new in new }
            }
            from = r.upperBound
        }
        return JSON(merged)
    }

    static func initialPlayerResponse(in html: String) -> JSON {
        guard let r = html.range(of: #"ytInitialPlayerResponse\s*=\s*\{"#, options: .regularExpression) else { return JSON(nil) }
        let brace = html.index(before: r.upperBound)
        guard let literal = objectLiteral(in: html, at: brace), let json = JSON(text: literal) else { return JSON(nil) }
        return json
    }

    static func visitorData(_ cfg: JSON) -> String {
        cfg["VISITOR_DATA"].string.nilIfBlank ?? cfg["INNERTUBE_CONTEXT"]["client"]["visitorData"].string
    }

    static func playerID(fromURL url: String) -> String? {
        Rx(#"/s/player/([0-9a-fA-F]{8,})/"#).first(in: url)
    }

    /// ytcfg 里的 PLAYER_JS_URL 或各 WEB_PLAYER_CONTEXT_CONFIGS 的 jsUrl
    static func playerID(inConfig cfg: JSON) -> String? {
        var candidates = [cfg["PLAYER_JS_URL"].string]
        let configs = cfg["WEB_PLAYER_CONTEXT_CONFIGS"]
        for key in configs.keys.sorted() { candidates.append(configs[key]["jsUrl"].string) }
        for c in candidates where !c.isEmpty {
            if let id = playerID(fromURL: c) { return id }
        }
        return nil
    }

    /// iframe_api 脚本里转义过的 `player\/xxxxxxxx\/`
    static func playerID(inIframeAPI text: String) -> String? {
        Rx(#"player\\?/([0-9a-fA-F]{8})\\?/"#).first(in: text)
    }

    /// 与 yt-dlp 一样固定用 main 变体（player_ias）
    static func playerURL(id: String) -> String {
        "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js"
    }

    static func signatureTimestamp(in js: String) -> Int {
        Int(Rx(#"(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})"#).first(in: js) ?? "") ?? 0
    }

    // MARK: 纯逻辑：请求

    static func playerRequestBody(client: YouTubeClient, version: String, videoID: String,
                                  signatureTimestamp: Int, encryptedHostFlags: String) -> [String: Any] {
        var info: [String: Any] = ["clientName": client.name, "clientVersion": version,
                                   "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": 0]
        if !client.userAgent.isEmpty { info["userAgent"] = client.userAgent }
        for (k, v) in client.extra { info[k] = v }
        var context: [String: Any] = ["client": info]
        if client.embedded { context["thirdParty"] = ["embedUrl": "https://www.reddit.com/"] }
        var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if signatureTimestamp > 0 { playback["signatureTimestamp"] = signatureTimestamp }
        if !encryptedHostFlags.isEmpty { playback["encryptedHostFlags"] = encryptedHostFlags }
        let playbackContext: [String: Any] = ["contentPlaybackContext": playback]
        return ["context": context, "videoId": videoID, "playbackContext": playbackContext,
                "contentCheckOk": true, "racyCheckOk": true]
    }

    static func apiHeaders(client: YouTubeClient, version: String, visitorData: String) -> [String: String] {
        var h = ["X-YouTube-Client-Name": String(client.nameID), "X-YouTube-Client-Version": version,
                 "Origin": "https://www.youtube.com", "Cookie": consentCookie]
        if !client.userAgent.isEmpty { h["User-Agent"] = client.userAgent }
        if !visitorData.isEmpty { h["X-Goog-Visitor-Id"] = visitorData }
        return h
    }

    // MARK: 纯逻辑：可播放状态

    struct Playability {
        let error: VideoParseError
        /// 换客户端也没用（不存在、私享、会员、地区限制、直播）
        let definitive: Bool
        /// IP 级风控（换客户端可能有用，最终报错时优先报别的原因）
        let botCheck: Bool
        /// 值得补试 web_embedded（年龄限制、儿童内容）
        let tryEmbedded: Bool
    }

    static let mismatch = Playability(
        error: VideoParseError(.unknown, "YouTube 返回了别的视频的数据，所在网络的 IP 可能被 YouTube 风控，请更换代理节点后重试"),
        definitive: false, botCheck: true, tryEmbedded: false)

    /// `simpleText` 或 `runs[].text`
    static func text(_ j: JSON) -> String {
        let simple = j["simpleText"].string
        if !simple.isEmpty { return simple }
        return j["runs"].array.map { $0["text"].string }.joined()
    }

    static func reasonText(_ pr: JSON) -> String {
        let ps = pr["playabilityStatus"]
        let pemr = ps["errorScreen"]["playerErrorMessageRenderer"]
        var reason = text(pemr["reason"])
        if reason.isEmpty { reason = ps["reason"].string }
        let sub = text(pemr["subreason"])
        if !sub.isEmpty { reason = reason.isEmpty ? sub : reason + ". " + sub }
        return reason.trimmed
    }

    static func isAgeGated(_ pr: JSON) -> Bool {
        let ps = pr["playabilityStatus"]
        if !ps["desktopLegacyAgeGateReason"].isNull { return true }
        let fields = [ps["status"].string.lowercased(), ps["reason"].string.lowercased()]
        let needles = ["confirm your age", "age-restricted", "inappropriate", "age_verification_required", "age_check_required"]
        return fields.contains { field in needles.contains { field.contains($0) } }
    }

    /// playabilityStatus 不是 OK 时给出面向用户的中文原因；OK 返回 nil
    static func playability(_ pr: JSON) -> Playability? {
        let ps = pr["playabilityStatus"]
        let status = ps["status"].string
        if status.isEmpty || status == "OK" { return nil }
        let reason = reasonText(pr)
        let lower = reason.lowercased()
        let suffix = reason.isEmpty ? "" : "（\(reason)）"

        if lower.contains("not a bot") || ps["errorScreen"]["playerCaptchaViewModel"].isObject {
            return Playability(error: VideoParseError(.unknown, "YouTube 要求登录以确认「不是机器人」：所在网络的 IP 被 YouTube 风控了，请更换网络或代理节点后重试"),
                               definitive: false, botCheck: true, tryEmbedded: false)
        }
        if lower.contains("try again later") {
            return Playability(error: VideoParseError(.unknown, "YouTube 暂时限制了所在网络的访问（通常一小时内恢复），请稍后再试或更换代理节点"),
                               definitive: false, botCheck: true, tryEmbedded: false)
        }
        if isAgeGated(pr) {
            return Playability(error: VideoParseError(.unsupported, "该视频有年龄限制，需要登录并通过年龄验证的 YouTube 账号才能观看，暂不支持"),
                               definitive: false, botCheck: false, tryEmbedded: true)
        }
        if lower.contains("private") {
            return Playability(error: VideoParseError(.unsupported, "这是私享（Private）视频，只有作者授权的账号才能观看"),
                               definitive: true, botCheck: false, tryEmbedded: false)
        }
        if lower.contains("members") || lower.contains("join this channel") {
            return Playability(error: VideoParseError(.unsupported, "这是频道会员专属视频，暂不支持"),
                               definitive: true, botCheck: false, tryEmbedded: false)
        }
        if lower.contains("country") || lower.contains("your region") || lower.contains("your location") {
            return Playability(error: VideoParseError(.unsupported, "该视频在所在网络的地区不可用（地区限制），可切换到其他地区的代理后重试"),
                               definitive: true, botCheck: false, tryEmbedded: false)
        }
        if lower.contains("made for kids") {
            return Playability(error: VideoParseError(.unsupported, "该视频为儿童内容，当前方式无法播放"),
                               definitive: false, botCheck: false, tryEmbedded: true)
        }
        switch status {
        case "ERROR":
            return Playability(error: VideoParseError(.notFound, "YouTube 视频不存在或已被删除\(suffix)"),
                               definitive: true, botCheck: false, tryEmbedded: false)
        case "LIVE_STREAM_OFFLINE":
            return Playability(error: VideoParseError(.unsupported, "直播尚未开始或已结束且没有回放，暂时没有可下载的视频"),
                               definitive: true, botCheck: false, tryEmbedded: false)
        case "LOGIN_REQUIRED":
            return Playability(error: VideoParseError(.unsupported, "该视频需要登录 YouTube 才能观看，暂不支持\(suffix)"),
                               definitive: false, botCheck: false, tryEmbedded: false)
        case "UNPLAYABLE":
            return Playability(error: VideoParseError(.unsupported, "该视频在 YouTube 上无法播放\(suffix)"),
                               definitive: false, botCheck: false, tryEmbedded: false)
        default:
            return Playability(error: VideoParseError(.unknown, "YouTube 无法播放该视频（\(status)）\(suffix)"),
                               definitive: false, botCheck: false, tryEmbedded: false)
        }
    }

    /// 直播 / 首映：只支持已结束并生成回放的
    static func liveError(_ pr: JSON) -> VideoParseError? {
        let d = pr["videoDetails"]
        if d["isUpcoming"].bool { return VideoParseError(.unsupported, "直播或首映尚未开始，暂时没有可下载的视频") }
        if d["isLive"].bool { return VideoParseError(.unsupported, "暂不支持下载正在进行的 YouTube 直播，请等直播结束生成回放后再试") }
        if d["isPostLiveDvr"].bool { return VideoParseError(.unsupported, "直播刚结束，回放仍在处理中，请稍后再试") }
        return nil
    }

    // MARK: 纯逻辑：格式

    struct Format: Equatable {
        var itag = 0
        /// 原始地址（带 signatureCipher 时是其中的 url，尚未拼签名）
        var url = ""
        var sigChallenge = ""
        var sigParam = "signature"
        var nChallenge = ""
        var mime = ""
        var codecs = ""
        var width = 0
        var height = 0
        var fps = 0
        var bitrate = 0
        var contentLength: Int64 = 0
        var audioPreference = 0
        var isDrc = false
        var progressive = false

        var needsJS: Bool { !sigChallenge.isEmpty || !nChallenge.isEmpty }
        /// 竖屏视频（Shorts）按短边算清晰度：1080×1920 是 1080p
        var resolution: Int { width > 0 && height > 0 ? min(width, height) : height }
        var isH264: Bool { codecs.hasPrefix("avc1") }
        var isHEVC: Bool { codecs.hasPrefix("hvc1") }
        /// mp4 封装的 AV1：只有带 AV1 硬解的新机型（A17 Pro / M3 及以上）能合并播放
        var isAV1MP4: Bool { mime == "video/mp4" && codecs.hasPrefix("av01") }
        /// AVFoundation 能合并的画面轨
        var isMP4Video: Bool { mime == "video/mp4" && (isH264 || isHEVC) }
        var isM4AAudio: Bool { mime == "audio/mp4" && codecs.hasPrefix("mp4a") }

        func videoRank() -> (Int, Int, Int, Int) { (resolution, fps, isH264 ? 1 : 0, bitrate) }
        func audioRank() -> (Int, Int, Int) { (audioPreference, isDrc ? 0 : 1, bitrate) }
    }

    struct Formats {
        var list: [Format] = []
        /// 既没有 url 也没有 signatureCipher（SABR-only）
        var missingURL = 0
        var drm = 0
        var hlsManifest = ""
    }

    /// form 编码的查询串（signatureCipher）→ 字典；同名键取第一个
    static func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first else { continue }
            let key = formDecode(String(first))
            let value = parts.count > 1 ? formDecode(String(parts[1])) : ""
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    static func formDecode(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func queryValue(_ url: String, _ name: String) -> String? {
        guard let q = url.firstIndex(of: "?") else { return nil }
        let query = String(url[url.index(after: q)...]).substringBefore("#")
        return parseQuery(query)[name]
    }

    static func replacingQuery(_ url: String, name: String, value: String) -> String {
        let rx = Rx("([?&])" + Rx.escape(name) + "=[^&#]*")
        let template = "$1" + NSRegularExpression.escapedTemplate(for: name + "=" + value.urlQueryEncoded)
        return rx.replacing(in: url, with: template)
    }

    static func manifestNChallenge(_ url: String) -> String? {
        guard let path = URL(string: url)?.path else { return nil }
        return Rx(#"/n/([^/]+)/"#).first(in: path + "/")
    }

    static func formats(_ streamingData: JSON) -> Formats {
        var out = Formats()
        out.hlsManifest = streamingData["hlsManifestUrl"].string
        let groups: [(JSON, Bool)] = [(streamingData["formats"], true), (streamingData["adaptiveFormats"], false)]
        for (group, progressive) in groups {
            for f in group.array {
                if !f["targetDurationSec"].isNull { continue }
                if f["type"].string == "FORMAT_STREAM_TYPE_OTF" { continue }
                if !f["drmFamilies"].isNull {
                    out.drm += 1
                    continue
                }
                if let format = parseFormat(f, progressive: progressive) {
                    out.list.append(format)
                } else {
                    out.missingURL += 1
                }
            }
        }
        return out
    }

    static func parseFormat(_ f: JSON, progressive: Bool) -> Format? {
        var format = Format()
        format.progressive = progressive
        format.itag = f["itag"].int
        var url = f["url"].string
        if url.isEmpty {
            let cipher = parseQuery(f["signatureCipher"].string.nilIfBlank ?? f["cipher"].string)
            url = cipher["url"] ?? ""
            format.sigChallenge = cipher["s"] ?? ""
            format.sigParam = (cipher["sp"] ?? "").nilIfBlank ?? "signature"
            if format.sigChallenge.isEmpty { return nil }
        }
        guard url.hasPrefix("http") else { return nil }
        format.url = url
        format.nChallenge = queryValue(url, "n") ?? ""

        let mimeType = f["mimeType"].string
        format.mime = mimeType.substringBefore(";").trimmed.lowercased()
        format.codecs = Rx(#"codecs="([^"]+)""#).first(in: mimeType) ?? ""
        format.width = f["width"].int
        format.height = f["height"].int
        format.fps = f["fps"].int
        let average = f["averageBitrate"].int
        format.bitrate = average > 0 ? average : f["bitrate"].int
        format.contentLength = f["contentLength"].int64
        format.isDrc = f["isDrc"].bool

        let track = f["audioTrack"]
        let display = track["displayName"].string.lowercased()
        if display.contains("descriptive") {
            format.audioPreference = -10
        } else if display.contains("original") {
            format.audioPreference = 10
        } else if track["audioIsDefault"].bool {
            format.audioPreference = 5
        } else if track.isObject {
            format.audioPreference = -1
        }
        return format
    }

    /// 挑出的一项下载
    struct Choice: Equatable {
        let kind: MediaKind
        let main: Format
        let audio: Format?
        let quality: String
        /// 文件名后缀（主视频为空）
        let suffix: String
    }

    static func bestVideo(_ list: [Format]) -> Format? {
        var best: Format?
        for f in list {
            guard let current = best else { best = f; continue }
            if f.videoRank() > current.videoRank() { best = f }
        }
        return best
    }

    static func bestAudio(_ list: [Format]) -> Format? {
        var best: Format?
        for f in list where f.isM4AAudio {
            guard let current = best else { best = f; continue }
            if f.audioRank() > current.audioRank() { best = f }
        }
        return best
    }

    static func label(_ f: Format) -> String {
        var s = "\(f.resolution)p"
        if f.fps > 30 { s += "\(f.fps)" }
        if f.isHEVC { s += " · HEVC" }
        return s
    }

    /// 各档清晰度（最高在前，作为默认）：每个分辨率一条 H.264 / HEVC 分轨（同档 H.264 优先）；
    /// 比它们更高的 AV1 档另列（只有新机型能播）；最后是音视频合一 mp4 与纯音频 m4a
    static func choose(_ all: [Format]) -> [Choice] {
        var out: [Choice] = []
        let audio = bestAudio(all)
        if let audio {
            let adaptive = all.filter { !$0.progressive && $0.resolution > 0 }
            let compatible = adaptive.filter { $0.isMP4Video }
            let resolutions = Set(compatible.map { $0.resolution }).sorted(by: >)
            for r in resolutions {
                let same = compatible.filter { $0.resolution == r }
                let h264 = same.filter { $0.isH264 }
                guard let best = bestVideo(h264.isEmpty ? same : h264) else { continue }
                out.append(Choice(kind: .video, main: best, audio: audio, quality: label(best), suffix: out.isEmpty ? "" : "_\(r)p"))
            }
            let top = resolutions.first ?? 0
            let av1 = adaptive.filter { $0.isAV1MP4 && $0.resolution > top }
            for r in Set(av1.map { $0.resolution }).sorted(by: >) {
                guard let best = bestVideo(av1.filter { $0.resolution == r }) else { continue }
                out.append(Choice(kind: .video, main: best, audio: audio, quality: label(best) + " · AV1（需 A17 Pro / M3 及以上机型）",
                                  suffix: "_\(r)p_av1"))
            }
        }
        let progressive = all.filter { $0.progressive && $0.mime == "video/mp4" }
        if let p = bestVideo(progressive) {
            let suffix = out.isEmpty ? "" : "_\(p.resolution)p"
            out.append(Choice(kind: .video, main: p, audio: nil, quality: "\(label(p))（音视频合一）", suffix: suffix))
        }
        if let audio {
            out.append(Choice(kind: .audio, main: audio, audio: nil, quality: "仅音频", suffix: ""))
        }
        return out
    }

    /// 拼上解出的签名、替换 n；缺了需要的结果返回 nil
    static func resolvedURL(_ f: Format, _ solution: YouTubeSignature.Solution) -> String? {
        var url = f.url
        if !f.sigChallenge.isEmpty {
            guard let sig = solution.sig[f.sigChallenge] else { return nil }
            url += (url.contains("?") ? "&" : "?") + f.sigParam + "=" + sig.urlQueryEncoded
        }
        if !f.nChallenge.isEmpty {
            guard let n = solution.n[f.nChallenge] else { return nil }
            url = replacingQuery(url, name: "n", value: n)
        }
        return url
    }

    static func medias(_ choices: [Choice], solution: YouTubeSignature.Solution, base: String) -> [VideoMedia] {
        var out: [VideoMedia] = []
        for c in choices {
            guard let url = resolvedURL(c.main, solution) else { continue }
            var audioURL = ""
            var size: Int64 = c.main.contentLength > 0 ? c.main.contentLength : -1
            if let a = c.audio {
                guard let resolved = resolvedURL(a, solution) else { continue }
                audioURL = resolved
                size = -1
            }
            let ext = c.kind == .audio ? "m4a" : "mp4"
            out.append(VideoMedia(url: url, kind: c.kind, fileName: "\(base)\(c.suffix).\(ext)", size: size,
                                  headers: mediaHeaders, quality: c.quality, audioURL: audioURL, variantGroup: "video"))
        }
        return out
    }

    /// 更高画质只有 VP9（webm，iOS 合并不了）时提示一句
    static func notice(_ list: [Format], choices: [Choice]) -> String {
        let offered = choices.filter { $0.kind == .video }.map { $0.main.resolution }.max() ?? 0
        let higher = list.contains { !$0.progressive && $0.mime.hasPrefix("video/") && !$0.isMP4Video && !$0.isAV1MP4 && $0.resolution > offered }
        if offered > 0 && higher {
            return "该视频更高的画质只有 VP9 编码，iOS 无法合并，已提供可用的最高画质（\(offered)p）"
        }
        return ""
    }

    static func noFormatError(_ parsed: Formats) -> VideoParseError {
        if parsed.list.isEmpty && parsed.drm > 0 {
            return VideoParseError(.unsupported, "该视频受 DRM 保护（如付费影片），无法下载")
        }
        if parsed.list.isEmpty && parsed.missingURL > 0 {
            return VideoParseError(.unknown, "YouTube 对当前会话只提供 SABR 流（没有直链），暂时无法下载，请稍后或更换代理节点再试")
        }
        if !YouTubeSignature.isSupported && parsed.list.contains(where: { $0.needsJS }) {
            return YouTubeSignature.unsupportedError
        }
        return VideoParseError(.unsupported, "YouTube 没有返回 iOS 可合并的 MP4 / M4A 格式")
    }

    // MARK: 纯逻辑：元数据

    static func thumbnail(_ details: JSON, id: String) -> String {
        var best = ""
        var bestWidth = -1
        for t in details["thumbnail"]["thumbnails"].array {
            let url = t["url"].string
            if !url.isEmpty && t["width"].int > bestWidth {
                bestWidth = t["width"].int
                best = url
            }
        }
        return best.isEmpty ? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg" : best
    }

    /// `2024-05-01T08:00:00-07:00` 或 `2024-05-01`
    static func parseDate(_ s: String) -> Int64 {
        guard !s.isEmpty else { return 0 }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970) }
        f.formatOptions = [.withFullDate]
        if let d = f.date(from: String(s.prefix(10))) { return Int64(d.timeIntervalSince1970) }
        return 0
    }
}
