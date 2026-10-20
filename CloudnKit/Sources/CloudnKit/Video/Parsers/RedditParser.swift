// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 reddit 解析。
import Foundation

/// Reddit：帖子 JSON（`/comments/<id>/.json`），未登录先到 old.reddit 领游客 Cookie（loid），同 yt-dlp。
/// - v.redd.it 视频：HLS 主列表是音视频合流时直接下 HLS；新视频的 HLS 把音轨拆成独立 rendition
///   （下载引擎只取视频变体会没声音），这时改用 DASHPlaylist.mpd 里的整段 mp4 视频 + 音频分轨合轨；
///   都拿不到时退回 fallback_url（无音轨）。
/// - 图集：gallery_data 定顺序、media_metadata 取 i.redd.it 原图；文字帖内嵌图按正文出现顺序。
/// - 直链图片 / imgur gifv；imgur 相册、帖子交给 ImgurParser。
struct RedditParser: VideoParser {
    let platform = VideoPlatform.reddit

    static let postRx = Rx(#"reddit(?:media)?\.com/(?:(?:r|u|user)/[^/\s?#]+/)?comments/([A-Za-z0-9]+)"#, ignoreCase: true)
    static let shortRx = Rx(#"(?<![A-Za-z0-9.\-])redd\.it/([A-Za-z0-9]+)"#, ignoreCase: true)
    static let vreddRx = Rx(#"v\.redd\.it/([A-Za-z0-9]+)"#, ignoreCase: true)
    static let referer = "https://www.reddit.com/"
    /// 打开「受限社区」的开关（同 yt-dlp：_options={"pref_gated_sr_optin": true}）
    static let optionsCookie = "%7B%22pref_gated_sr_optin%22%3A%20true%7D"

    /// 帖子里的一项媒体（纯数据，便于离线测试）
    struct Item: Equatable {
        enum Kind: Equatable { case image, video, redditVideo }
        let kind: Kind
        /// 图片 / 普通视频直链；v.redd.it 视频为 fallback_url（只有画面）
        let url: String
        var hls: String = ""
        var dash: String = ""
        var height: Int = 0
        /// nil 表示接口没说
        var hasAudio: Bool?
    }

    /// v.redd.it 视频最终选定的下载方式
    struct ResolvedVideo: Equatable {
        let url: String
        var isHLS = false
        var audioURL = ""
        var quality = ""
        /// 只拿到无音轨的画面
        var silent = false
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var id = link.kind == "share" ? "" : link.id
        var vredd = ""
        if id.isEmpty {
            id = Self.postID(from: link.url) ?? ""
        }
        if id.isEmpty {
            vredd = Self.vreddRx.first(in: link.url) ?? ""
            let target = try await OverseasHTTP.expandShareLink(link.url, until: Self.postRx, site: "Reddit")
            id = Self.postID(from: target) ?? ""
        }
        if id.isEmpty && !vredd.isEmpty {
            // v.redd.it 没跳到帖子：直接按视频 ID 取流
            return try await buildBareVideo(vredd, link: link)
        }
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 Reddit 帖子 ID") }

        let post = try await fetchPost(id: id, cookie: cookie)
        let items = Self.items(post)
        if items.isEmpty {
            if let delegated = try await delegateImgur(post) { return delegated }
            if !post["removed_by_category"].string.isEmpty {
                throw VideoParseError(.notFound, "帖子已被删除或移除")
            }
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
        }
        return try await build(post: post, id: id, items: items)
    }

    // MARK: 请求

    private func fetchPost(id: String, cookie: String) async throws -> JSON {
        var jar = cookie
        if CookieUtil.value(of: "over18", in: jar) == nil { jar = CookieUtil.setting("over18", "1", in: jar) }
        if CookieUtil.value(of: "_options", in: jar) == nil { jar = CookieUtil.setting("_options", Self.optionsCookie, in: jar) }
        let api = "https://www.reddit.com/comments/\(id)/.json?raw_json=1"
        var r = try await OverseasHTTP.send(.get(api, headers: headers(jar: jar)), site: "Reddit")
        if r.json == nil && CookieUtil.value(of: "reddit_session", in: jar) == nil {
            // 未登录被拦：先到 old.reddit 领 loid 游客 Cookie 再试一次
            let home = try? await OverseasHTTP.send(.get("https://old.reddit.com/", headers: headers(jar: jar)), site: "Reddit")
            if let home { jar = OverseasHTTP.merge(jar, home.cookies) }
            r = try await OverseasHTTP.send(.get(api, headers: headers(jar: jar)), site: "Reddit")
        }
        guard let json = r.json else {
            switch r.status {
            case 404, 410: throw VideoParseError(.notFound, "帖子不存在（HTTP \(r.status)）")
            case 403, 429:
                throw VideoParseError(.blocked, "Reddit 拒绝了匿名请求（HTTP \(r.status)），请稍后重试或切换网络")
            default: throw VideoParseError(.unknown, "Reddit 接口请求失败（HTTP \(r.status)）")
            }
        }
        return try Self.postData(json)
    }

    private func headers(jar: String) -> [(String, String)] {
        [("Accept", "application/json, text/html;q=0.9, */*;q=0.8"), ("Accept-Language", "en-US,en;q=0.9"),
         ("Cookie", jar), ("User-Agent", VideoHTTP.uaChrome)]
    }

    private var mediaHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer, "Accept": "*/*"]
    }

    private func fetchText(_ url: String) async -> String? {
        let request = HTTPRequest.get(url, headers: mediaHeaders.sortedPairs)
        guard let r = try? await OverseasHTTP.send(request, site: "Reddit"), r.isSuccess else { return nil }
        let text = r.text
        return text.isEmpty ? nil : text
    }

    /// v.redd.it：合流 HLS → DASH 整段 mp4 + 音频 → fallback_url（无声）
    private func resolve(_ item: Item) async -> ResolvedVideo? {
        let heightLabel = item.height > 0 ? "\(item.height)p" : ""
        if item.hasAudio == false && !item.url.isEmpty {
            return ResolvedVideo(url: item.url, quality: heightLabel)
        }
        var hlsReachable = false
        if !item.hls.isEmpty, let master = await fetchText(item.hls) {
            hlsReachable = true
            if !Self.hlsHasSeparateAudio(master) {
                return ResolvedVideo(url: item.hls, isHLS: true, quality: "HLS")
            }
        }
        if !item.dash.isEmpty, let mpd = await fetchText(item.dash) {
            let tracks = Self.dashTracks(mpd, baseURL: item.dash)
            if !tracks.video.isEmpty {
                let label = tracks.height > 0 ? "\(tracks.height)p" : heightLabel
                let silent = tracks.audio.isEmpty && item.hasAudio == true
                return ResolvedVideo(url: tracks.video, audioURL: tracks.audio, quality: label, silent: silent)
            }
        }
        if !item.url.isEmpty {
            return ResolvedVideo(url: item.url, quality: heightLabel, silent: item.hasAudio != false)
        }
        if hlsReachable {
            return ResolvedVideo(url: item.hls, isHLS: true, quality: "HLS", silent: true)
        }
        return nil
    }

    /// 帖子链接是 imgur 相册 / 帖子页：交给 Imgur 解析，平台仍按 Imgur 展示
    private func delegateImgur(_ post: JSON) async throws -> VideoParseResult? {
        let url = Self.unescape(post["url"].string)
        guard let target = ImgurParser.detect(url) else { return nil }
        let link = DetectedVideoLink(platform: .imgur, kind: target.kind, id: target.id, url: url)
        return try await ImgurParser().parse(link, cookie: "")
    }

    // MARK: 组装

    private func build(post: JSON, id: String, items: [Item]) async throws -> VideoParseResult {
        let title = post["title"].string
        let base = FileNames.base(title, fallback: "reddit_\(id)")
        let single = items.count == 1
        var medias: [VideoMedia] = []
        var silentCount = 0
        for (i, item) in items.enumerated() {
            let stem = single ? base : "\(base)_\(i + 1)"
            switch item.kind {
            case .image:
                let ext = DomesticHTML.imageExtension(item.url)
                medias.append(VideoMedia(url: item.url, kind: .image, fileName: "\(stem).\(ext)", headers: mediaHeaders))
            case .video:
                medias.append(VideoMedia(url: item.url, kind: .video, fileName: "\(stem).mp4", headers: mediaHeaders))
            case .redditVideo:
                guard let v = await resolve(item) else { continue }
                if v.silent { silentCount += 1 }
                medias.append(VideoMedia(url: v.url, kind: .video, fileName: "\(stem).mp4", isHLS: v.isHLS,
                                         headers: mediaHeaders, quality: v.quality, audioURL: v.audioURL))
            }
        }
        if medias.isEmpty { throw VideoParseError(.unknown, "视频还在处理中或无法获取播放地址，请稍后重试") }
        let notice = silentCount > 0 ? "未能获取 Reddit 视频的音轨，下载的视频可能没有声音" : ""
        let permalink = post["permalink"].string
        let url = permalink.isEmpty ? "https://www.reddit.com/comments/\(id)/" : "https://www.reddit.com" + permalink
        let author = post["author"].string
        return VideoParseResult(platform: platform, title: title.isEmpty ? "Reddit \(id)" : title,
                                author: author == "[deleted]" ? "" : author, cover: Self.cover(post),
                                text: post["selftext"].string, timestamp: Int64(post["created_utc"].double), url: url,
                                medias: medias, notice: notice)
    }

    private func buildBareVideo(_ videoID: String, link: DetectedVideoLink) async throws -> VideoParseResult {
        var item = Item(kind: .redditVideo, url: "")
        item.hls = "https://v.redd.it/\(videoID)/HLSPlaylist.m3u8"
        item.dash = "https://v.redd.it/\(videoID)/DASHPlaylist.mpd"
        guard let v = await resolve(item) else {
            throw VideoParseError(.notFound, "无法获取该 v.redd.it 视频，请复制帖子链接后重试")
        }
        let media = VideoMedia(url: v.url, kind: .video, fileName: "reddit_\(videoID).mp4", isHLS: v.isHLS,
                               headers: mediaHeaders, quality: v.quality, audioURL: v.audioURL)
        let notice = v.silent ? "未能获取 Reddit 视频的音轨，下载的视频可能没有声音" : ""
        return VideoParseResult(platform: platform, title: "Reddit 视频 \(videoID)", url: link.url, medias: [media], notice: notice)
    }

    // MARK: 纯逻辑

    static func postID(from url: String) -> String? {
        if let id = postRx.first(in: url) { return id }
        return shortRx.first(in: url)
    }

    /// `.json` 响应 → 帖子 data；403 的 reason 映射成可读提示
    static func postData(_ json: JSON) throws -> JSON {
        if json["error"].int == 403 || json["reason"].string.isEmpty == false {
            switch json["reason"].string {
            case "quarantined": throw VideoParseError(.unknown, "该社区已被隔离，需要已确认进入的 Reddit 账号才能查看（暂不支持登录 Reddit）")
            case "private": throw VideoParseError(.unknown, "该社区为私密社区，需要已获准的 Reddit 账号才能查看（暂不支持登录 Reddit）")
            case "banned": throw VideoParseError(.notFound, "该社区已被封禁")
            default: throw VideoParseError(.blocked, "Reddit 拒绝访问（\(json["reason"].string)）")
            }
        }
        if json["error"].int == 404 { throw VideoParseError(.notFound, "帖子不存在") }
        let post = json[0]["data"]["children"][0]["data"]
        guard post.isObject else { throw VideoParseError(.notFound, "帖子不存在或不可见") }
        return post
    }

    /// 帖子 → 媒体；自己没有就看被转帖的原帖
    static func items(_ post: JSON) -> [Item] {
        let own = ownItems(post)
        if !own.isEmpty { return own }
        for parent in post["crosspost_parent_list"].array {
            let inner = ownItems(parent)
            if !inner.isEmpty { return inner }
        }
        return []
    }

    static func ownItems(_ post: JSON) -> [Item] {
        for key in ["secure_media", "media"] {
            let video = post[key]["reddit_video"]
            if video.isObject, let item = videoItem(video) { return [item] }
        }
        let gallery = galleryItems(post)
        if !gallery.isEmpty { return gallery }
        if let direct = directItem(post["url"].string) { return [direct] }
        let inline = inlineItems(post)
        if !inline.isEmpty { return inline }
        let preview = post["preview"]["reddit_video_preview"]
        if preview.isObject, let item = videoItem(preview) { return [item] }
        if post["post_hint"].string == "image" {
            let src = unescape(post["preview"]["images"][0]["source"]["url"].string)
            if !src.isEmpty { return [Item(kind: .image, url: src)] }
        }
        return []
    }

    /// reddit_video / reddit_video_preview → v.redd.it 视频项（缺的播放列表按视频 ID 补全）
    static func videoItem(_ v: JSON) -> Item? {
        let fallback = unescape(v["fallback_url"].string)
        let hls = unescape(v["hls_url"].string)
        let dash = unescape(v["dash_url"].string)
        if fallback.isEmpty && hls.isEmpty && dash.isEmpty { return nil }
        let videoID = vreddRx.first(in: fallback) ?? ""
        var item = Item(kind: .redditVideo, url: fallback)
        item.hls = hls
        item.dash = dash
        if item.hls.isEmpty && !videoID.isEmpty { item.hls = "https://v.redd.it/\(videoID)/HLSPlaylist.m3u8" }
        if item.dash.isEmpty && !videoID.isEmpty { item.dash = "https://v.redd.it/\(videoID)/DASHPlaylist.mpd" }
        item.height = v["height"].int
        if v["is_gif"].bool {
            item.hasAudio = false
        } else if v.has("has_audio") {
            item.hasAudio = v["has_audio"].bool
        }
        return item
    }

    /// 图集：gallery_data.items 定顺序
    static func galleryItems(_ post: JSON) -> [Item] {
        let meta = post["media_metadata"]
        guard meta.isObject else { return [] }
        var out: [Item] = []
        for entry in post["gallery_data"]["items"].array {
            let mediaID = entry["media_id"].string
            guard !mediaID.isEmpty, let item = metadataItem(meta[mediaID]) else { continue }
            out.append(item)
        }
        return out
    }

    /// 文字帖正文里内嵌的图片/视频：按在正文中出现的先后排序
    static func inlineItems(_ post: JSON) -> [Item] {
        let meta = post["media_metadata"]
        guard meta.isObject else { return [] }
        let text = (post["selftext"].string + "\n" + post["selftext_html"].string) as NSString
        var keyed: [(pos: Int, key: String)] = []
        for key in meta.keys {
            let r = text.range(of: key)
            let pos = r.location == NSNotFound ? Int.max : r.location
            keyed.append((pos, key))
        }
        keyed.sort { a, b in a.pos == b.pos ? a.key < b.key : a.pos < b.pos }
        var out: [Item] = []
        for entry in keyed {
            if let item = metadataItem(meta[entry.key]) { out.append(item) }
        }
        return out
    }

    /// media_metadata 的一项：Image → i.redd.it 原图；AnimatedImage → mp4（没有就 gif）；RedditVideo → 播放列表
    static func metadataItem(_ m: JSON) -> Item? {
        let status = m["status"].string
        if !status.isEmpty && status != "valid" { return nil }
        let mediaID = m["id"].string
        switch m["e"].string {
        case "Image":
            let ext = mimeExtension(m["m"].string)
            if !mediaID.isEmpty && !ext.isEmpty { return Item(kind: .image, url: "https://i.redd.it/\(mediaID).\(ext)") }
            let source = unescape(m["s"]["u"].string)
            return source.isEmpty ? nil : Item(kind: .image, url: source)
        case "AnimatedImage":
            let mp4 = unescape(m["s"]["mp4"].string)
            if !mp4.isEmpty {
                var item = Item(kind: .video, url: mp4)
                item.hasAudio = false
                return item
            }
            let gif = unescape(m["s"]["gif"].string)
            return gif.isEmpty ? nil : Item(kind: .image, url: gif)
        case "RedditVideo":
            let hls = unescape(m["hlsUrl"].string)
            let dash = unescape(m["dashUrl"].string)
            if hls.isEmpty && dash.isEmpty { return nil }
            var item = Item(kind: .redditVideo, url: "")
            item.hls = hls
            item.dash = dash
            item.height = m["y"].int
            return item
        default:
            return nil
        }
    }

    /// 帖子链接本身就是图片 / imgur gifv / mp4 直链
    static func directItem(_ raw: String) -> Item? {
        let url = unescape(raw)
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        let path = (URL(string: url)?.path ?? "").lowercased()
        if host.hasSuffix("imgur.com") && path.hasSuffix(".gifv") {
            let mp4 = Rx(#"\.gifv(?=$|[?#])"#, ignoreCase: true).replacing(in: url, with: ".mp4")
            return Item(kind: .video, url: mp4)
        }
        if host.hasSuffix("imgur.com") && path.hasSuffix(".mp4") { return Item(kind: .video, url: url) }
        let imageExts = [".jpg", ".jpeg", ".png", ".gif", ".webp"]
        if imageExts.contains(where: { path.hasSuffix($0) }) { return Item(kind: .image, url: url) }
        return nil
    }

    static func mimeExtension(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpg", "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return ""
        }
    }

    /// HLS 主列表里有带 URI 的音频 rendition：音轨是分开的
    static func hlsHasSeparateAudio(_ master: String) -> Bool {
        for raw in master.components(separatedBy: .newlines) {
            let line = raw.trimmed
            if line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") && line.contains("URI=") { return true }
        }
        return false
    }

    /// DASH 清单 → 最高画质的视频 BaseURL（整段 mp4）与码率最高的音频 BaseURL
    static func dashTracks(_ mpd: String, baseURL: String) -> (video: String, height: Int, audio: String) {
        var video = ""
        var videoHeight = -1
        var videoRate = -1
        var audio = ""
        var audioRate = -1
        let repRx = Rx(#"<Representation\b([^>]*)>(.*?)</Representation>"#, dotAll: true)
        let baseRx = Rx(#"<BaseURL>\s*([^<]+?)\s*</BaseURL>"#)
        for chunk in mpd.components(separatedBy: "<AdaptationSet").dropFirst() {
            let header = chunk.substringBefore(">")
            let setIsAudio = header.contains("contentType=\"audio\"") || header.contains("mimeType=\"audio")
            for rep in repRx.allMatches(in: chunk) {
                let attrs = rep[1]
                guard let base = baseRx.first(in: rep[2]) else { continue }
                let url = VideoHTTP.absolutize(base: baseURL, DomesticHTML.unescape(base))
                let rate = Int(Rx(#"\bbandwidth="(\d+)""#).first(in: attrs) ?? "") ?? 0
                let isAudio = setIsAudio || attrs.contains("mimeType=\"audio")
                if isAudio {
                    if rate > audioRate {
                        audioRate = rate
                        audio = url
                    }
                } else {
                    let height = Int(Rx(#"\bheight="(\d+)""#).first(in: attrs) ?? "") ?? 0
                    if height > videoHeight || (height == videoHeight && rate > videoRate) {
                        videoHeight = height
                        videoRate = rate
                        video = url
                    }
                }
            }
        }
        return (video, max(videoHeight, 0), audio)
    }

    static func cover(_ post: JSON) -> String {
        let source = unescape(post["preview"]["images"][0]["source"]["url"].string)
        if !source.isEmpty { return source }
        let thumb = post["thumbnail"].string
        return thumb.hasPrefix("http") ? thumb : ""
    }

    /// 没带 raw_json 时接口里的 URL 是 HTML 转义过的（&amp;）
    static func unescape(_ s: String) -> String {
        s.contains("&") ? DomesticHTML.unescape(s) : s
    }
}

extension OverseasHTTP {
    /// 逐跳展开分享短链（不下载最终页面），直到地址匹配 `target` 或不再跳转；返回最后到达的地址。
    /// 中间常有不认识的跳板域名（如 api.pinterest.com），所以不走 VideoParseService 的统一短链流程。
    static func expandShareLink(_ url: String, until target: Rx, site: String,
                                userAgent: String = VideoHTTP.uaChrome) async throws -> String {
        var current = url
        for _ in 0..<6 {
            if target.matches(current) { return current }
            let request = HTTPRequest.get(current, headers: [("User-Agent", userAgent)], followRedirects: false)
            let r = try await send(request, site: site)
            guard (300..<400).contains(r.status), let location = r.header("Location"), !location.isEmpty else { return current }
            current = VideoHTTP.absolutize(base: current, location)
        }
        return current
    }

    /// HTML 里 `<meta property|name="key" content="...">` 的值（属性先后顺序不限）
    static func metaContent(_ key: String, in html: String) -> [String] {
        var out: [String] = []
        for tag in DomesticHTML.openTags("meta", in: html) {
            let name = DomesticHTML.attribute("property", in: tag) ?? DomesticHTML.attribute("name", in: tag) ?? ""
            guard name.lowercased() == key.lowercased(), let content = DomesticHTML.attribute("content", in: tag),
                  !content.isEmpty, !out.contains(content) else { continue }
            out.append(content)
        }
        return out
    }
}
