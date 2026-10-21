// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 vimeo 解析。
import Foundation

/// Vimeo：播放器配置 JSON（`player.vimeo.com/video/{id}/config`，取不到再从播放器页面里抠 `playerConfig = {...}`）。
/// - 有渐进式 mp4（request.files.progressive）就取最高清的一档；
/// - 否则取 HLS：默认 CDN 的主播放列表，把 `/sep/video/`（音视频分离）换成 `/video/`（音视频合流），交给 HLS 引擎。
/// 不公开（unlisted）视频需要链接里的哈希（`vimeo.com/{id}/{hash}` 或 `?h=hash`）。
struct VimeoParser: VideoParser {
    let platform = VideoPlatform.vimeo

    struct Stream: Equatable {
        let url: String
        let isHLS: Bool
        let quality: String
    }

    private var pageHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://vimeo.com/", "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
    }

    private var mediaHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://player.vimeo.com/", "Origin": "https://player.vimeo.com"]
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id.isEmpty ? (Self.videoID(from: link.url) ?? "") : link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 Vimeo 视频 ID") }
        let hash = Self.unlistedHash(from: link.url)

        let config = try await fetchConfig(id: id, hash: hash)
        try Self.checkConfig(config)
        let streams = Self.streams(config)
        guard !streams.isEmpty else {
            throw VideoParseError(.unsupported, "这个 Vimeo 视频没有可下载的播放地址（可能是直播或付费内容）")
        }

        let video = config["video"]
        let title = video["title"].string
        let base = FileNames.base(title, fallback: "vimeo_\(id)")
        let options = streams.map { OverseasVariants.Option(url: $0.url, quality: $0.quality, isHLS: $0.isHLS) }
        let medias = OverseasVariants.medias(options, stem: base, group: "video", headers: mediaHeaders)
        let pageURL = hash.isEmpty ? "https://vimeo.com/\(id)" : "https://vimeo.com/\(id)/\(hash)"
        return VideoParseResult(platform: platform, title: title, author: video["owner"]["name"].string,
                                avatar: video["owner"]["img"].string, cover: Self.thumbnail(video), url: pageURL,
                                medias: medias)
    }

    /// 先请求 JSON 配置接口；失败再取播放器页面，从内嵌脚本里抠配置
    private func fetchConfig(id: String, hash: String) async throws -> JSON {
        let query = hash.isEmpty ? "" : "?h=\(hash)"
        let configURL = "https://player.vimeo.com/video/\(id)/config\(query)"
        let r = try await OverseasHTTP.send(.get(configURL, headers: pageHeaders.sortedPairs), site: "Vimeo")
        if r.isSuccess, let json = r.json, json["video"].isObject || json["view"].int != 0 {
            return json
        }
        if Self.isPrivacyBlocked(r.text) { throw Self.privacyError }

        let playerURL = "https://player.vimeo.com/video/\(id)\(query)"
        let page = try await OverseasHTTP.send(.get(playerURL, headers: pageHeaders.sortedPairs), site: "Vimeo")
        if Self.isPrivacyBlocked(page.text) { throw Self.privacyError }
        if page.isSuccess, let json = Self.playerConfig(in: page.text) {
            return json
        }
        switch max(r.status, page.status) {
        case 404, 410: throw VideoParseError(.notFound, "Vimeo 视频不存在或已删除")
        case 401, 403:
            if hash.isEmpty {
                throw VideoParseError(.unknown, "Vimeo 拒绝了请求（HTTP \(max(r.status, page.status))）：如果是不公开视频，请复制带哈希的完整分享链接")
            }
            throw VideoParseError(.blocked, "Vimeo 拒绝了请求（HTTP \(max(r.status, page.status))），所在网络的 IP 可能被限制")
        case 429: throw VideoParseError(.blocked, "Vimeo 请求过于频繁（HTTP 429），请稍后重试")
        default: throw VideoParseError(.unknown, "Vimeo 播放器配置获取失败（HTTP \(r.status)）")
        }
    }

    static let privacyError = VideoParseError(.unsupported, "该 Vimeo 视频设置了隐私限制，只能在作者指定的网站内嵌播放，无法直接下载")

    // MARK: 纯逻辑

    /// 仅允许在指定网站内嵌播放的视频：没有白名单站点做 Referer 就拿不到
    static func isPrivacyBlocked(_ text: String) -> Bool {
        text.contains("Because of its privacy settings, this video cannot be played here")
            || text.contains("privacy settings, this video cannot be played")
    }

    /// 链接里的视频 ID（vimeo.com/123、vimeo.com/channels/x/123、player.vimeo.com/video/123）
    static func videoID(from url: String) -> String? {
        if let id = Rx(#"player\.vimeo\.com/video/(\d+)"#, ignoreCase: true).first(in: url) { return id }
        // 合集里的视频：路径里的第一个数字是合集 ID
        if let id = Rx(#"vimeo\.com/(?:showcase|album)/[^/\s?#]+/video/(\d+)"#, ignoreCase: true).first(in: url) { return id }
        return Rx(#"vimeo\.com/(?:[^\s?#]*?/)??(\d+)(?=[/?#]|$)"#, ignoreCase: true).first(in: url)
    }

    /// 不公开视频的哈希：`vimeo.com/{id}/{hash}` 或查询参数 `h=`
    static func unlistedHash(from url: String) -> String {
        if let h = Rx(#"[?&]h=([0-9a-f]+)"#, ignoreCase: true).first(in: url) { return h }
        if let h = Rx(#"vimeo\.com/(?:[^\s?#]*?/)??\d+/([0-9a-f]{10})(?=[/?#]|$)"#, ignoreCase: true).first(in: url) { return h }
        return ""
    }

    /// 播放器页面里的 `window.playerConfig = {...}`（旧页面是 `config = {...}`）
    static func playerConfig(in html: String) -> JSON? {
        guard let rx = try? NSRegularExpression(pattern: #"\b(?:playerC|c)onfig\s*=\s*\{"#) else { return nil }
        let ns = html as NSString
        for m in rx.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let start = m.range.location + m.range.length - 1
            let rest = ns.substring(from: start)
            guard let literal = JSLiteral.parse(rest) else { continue }
            let json = literal.json
            if json["video"].isObject || json["request"].isObject { return json }
        }
        return nil
    }

    /// 配置里的错误状态：view 4 = 需要密码，其余带 message 的按原文提示
    static func checkConfig(_ config: JSON) throws {
        switch config["view"].int {
        case 4: throw VideoParseError(.unsupported, "这个 Vimeo 视频设置了密码，暂不支持")
        default: break
        }
        if !config["video"].isObject {
            let message = config["message"].string
            if !message.isEmpty { throw VideoParseError(.unknown, "Vimeo：\(message)") }
            throw VideoParseError(.unknown, "Vimeo 播放器配置里没有视频信息")
        }
        let liveStatus = config["video"]["live_event"]["status"].string
        if liveStatus == "started" || liveStatus == "pending" || liveStatus == "active" {
            throw VideoParseError(.unsupported, "暂不支持下载 Vimeo 直播")
        }
    }

    /// 可选的各档：有渐进式 mp4 时全部列出（最高清在前），否则只有 bestStream 那一条
    static func streams(_ config: JSON) -> [Stream] {
        let progressive = progressiveStreams(config)
        if !progressive.isEmpty { return progressive }
        return bestStream(config).map { [$0] } ?? []
    }

    /// 渐进式 mp4 各档：按 (高度, 码率) 从高到低，同值保持原顺序
    static func progressiveStreams(_ config: JSON) -> [Stream] {
        let files = config["request"]["files"].isObject ? config["request"]["files"] : config["video"]["files"]
        var list: [(index: Int, height: Int, bitrate: Int, file: JSON)] = []
        for (i, f) in files["progressive"].array.enumerated() where !f["url"].string.isEmpty {
            list.append((i, f["height"].int, f["bitrate"].int, f))
        }
        list.sort {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.bitrate != $1.bitrate { return $0.bitrate > $1.bitrate }
            return $0.index < $1.index
        }
        return list.map { item in
            let quality = item.height > 0 ? "\(item.height)P" : item.file["quality"].string.uppercased()
            return Stream(url: item.file["url"].string, isHLS: false, quality: quality)
        }
    }

    /// 渐进式 mp4 取最高清；没有再取 HLS（默认 CDN 优先，avc_url 优先：只含 H.264，兼容性最好）
    static func bestStream(_ config: JSON) -> Stream? {
        let files = config["request"]["files"].isObject ? config["request"]["files"] : config["video"]["files"]
        if let best = progressiveStreams(config).first { return best }

        let hls = files["hls"]
        let cdns = hls["cdns"]
        var candidates: [JSON] = []
        let defaultCDN = hls["default_cdn"].string
        if !defaultCDN.isEmpty && cdns[defaultCDN].isObject { candidates.append(cdns[defaultCDN]) }
        for key in cdns.keys.sorted() where key != defaultCDN { candidates.append(cdns[key]) }
        for cdn in candidates {
            let avc = cdn["avc_url"].string
            let raw = avc.isEmpty ? cdn["url"].string : avc
            guard !raw.isEmpty else { continue }
            return Stream(url: muxedManifest(raw), isHLS: true, quality: "HLS")
        }
        // 已结束直播的存档源文件
        let archive = config["video"]["live_event"]["archive"]
        if archive["status"].string == "done", !archive["source_url"].string.isEmpty {
            return Stream(url: archive["source_url"].string, isHLS: false, quality: "源文件")
        }
        return nil
    }

    /// `/sep/video/` 是音视频分离的清单（HLS 引擎只会取视频轨），换成 `/video/` 得到合流清单
    static func muxedManifest(_ url: String) -> String {
        url.replacingOccurrences(of: "/sep/video/", with: "/video/")
    }

    /// 封面：thumbs 里尺寸最大的一张，没有再取 base / thumbnail_url
    static func thumbnail(_ video: JSON) -> String {
        let thumbs = video["thumbs"]
        var bestKey = -1
        var bestURL = ""
        for key in thumbs.keys {
            guard let size = Int(key) else { continue }
            let url = thumbs[key].string
            if size > bestKey && !url.isEmpty {
                bestKey = size
                bestURL = url
            }
        }
        if !bestURL.isEmpty { return bestURL }
        return thumbs["base"].string.nilIfBlank ?? video.string("thumbnail_url", "thumbnail")
    }
}
