// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 facebook 解析。
import Foundation

/// Facebook：视频 / Reels / 图片帖。
/// 页面里的 `<script type="application/json" data-sjs>` 是 Relay 预取数据，视频节点上有
/// browser_native_hd_url / browser_native_sd_url / playable_url(_quality_hd)、DASH 清单（manifest_xml）
/// 以及 videoDeliveryResponseResult.progressive_urls；图片节点是 __typename == "Photo"。
/// 1. 纯 HTTP 取页面（桌面 UA，带浏览器导航头）解析上述数据；
/// 2. 取不到（登录墙 / 数据改由接口异步下发）时用隐藏浏览器打开页面，读同样的脚本数据，
///    并钩住页面自己发出的 /api/graphql/ 响应。
/// 分享链（/share/v|r|p/、fb.watch）在解析器里逐跳展开。
struct FacebookParser: VideoParser {
    let platform = VideoPlatform.facebook
    let extractor: WebPageExtractor?

    init(extractor: WebPageExtractor? = nil) {
        self.extractor = extractor
    }

    /// yt-dlp：浏览器 UA 下载会被限速，换成抓取器 UA
    static let mediaUA = "facebookexternalhit/1.1"

    // MARK: 数据模型（纯数据，便于离线测试）

    struct Video {
        var id = ""
        var hd: [String] = []
        var sd: [String] = []
        var manifests: [String] = []
        var hls: [String] = []
        var thumbnail = ""
        var title = ""
        var text = ""
        var owner = ""
        var timestamp: Int64 = 0

        var isEmpty: Bool { hd.isEmpty && sd.isEmpty && manifests.isEmpty && hls.isEmpty }
        var key: String {
            if !id.isEmpty { return id }
            let all: [String] = hd + sd + hls
            return all.first ?? ""
        }

        mutating func merge(_ o: Video) {
            for u in o.hd where !hd.contains(u) { hd.append(u) }
            for u in o.sd where !sd.contains(u) { sd.append(u) }
            for u in o.manifests where !manifests.contains(u) { manifests.append(u) }
            for u in o.hls where !hls.contains(u) { hls.append(u) }
            if thumbnail.isEmpty { thumbnail = o.thumbnail }
            if title.isEmpty { title = o.title }
            if text.isEmpty { text = o.text }
            if owner.isEmpty { owner = o.owner }
            if timestamp == 0 { timestamp = o.timestamp }
        }
    }

    struct Photo: Equatable {
        var id = ""
        var url = ""
        var area = 0
    }

    struct DashRep: Equatable {
        var isAudio = false
        var height = 0
        var bandwidth = 0
        var url = ""
    }

    /// 选定的一条视频下载方式
    struct Playback: Equatable {
        var url = ""
        var audioURL = ""
        var isHLS = false
        var quality = ""
    }

    enum Item {
        case video(Video)
        case photo(Photo)
    }

    /// 页面元信息
    struct PageMeta {
        var title = ""
        var description = ""
        var image = ""
        var video = ""
        var loginWall = false
        var interstitial = ""
    }

    // MARK: 解析入口

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var kind = link.kind
        var id = link.id
        var url = link.url
        if kind == "share" || kind == "short" {
            let finalURL = try await Self.resolveShare(url)
            url = finalURL
            if let c = Self.classify(finalURL), c.kind != "share" {
                kind = c.kind
                id = c.id
            } else {
                kind = "post"
                id = ""
            }
        }
        let pageURL = Self.pageURL(kind: kind, id: id, url: url)

        // 1. 纯 HTTP
        var meta = PageMeta()
        var httpError: Error?
        do {
            let html = try await fetchPage(pageURL, cookie: cookie)
            meta = Self.pageMeta(html)
            let collector = FacebookCollector()
            for blob in Self.sjsBlobs(in: html) { collector.add(blob) }
            if let result = build(kind: kind, id: id, pageURL: pageURL, collector: collector, meta: meta, domVideos: []) {
                return result
            }
        } catch let e as CancellationError {
            throw e
        } catch {
            httpError = error
        }

        // 2. 隐藏浏览器
        if let extractor,
           let text = await extractor.extract(url: pageURL, userAgent: VideoHTTP.uaChrome, cookie: cookie,
                                              documentStartScripts: [Self.hookJS], readyScript: Self.readyJS,
                                              extractScript: Self.extractJS, timeout: 35),
           let payload = JSON(text: text), payload["error"].string.isEmpty {
            let collector = FacebookCollector()
            for blob in payload["blobs"].array { collector.add(blob.string) }
            for response in payload["graphql"].array {
                for line in response.string.split(separator: "\n") { collector.add(String(line)) }
            }
            var webMeta = PageMeta()
            webMeta.title = payload["title"].string
            webMeta.description = payload["description"].string
            webMeta.image = payload["image"].string
            webMeta.video = payload["ogVideo"].string
            webMeta.loginWall = payload["loginWall"].bool
            if webMeta.title.isEmpty { webMeta.title = meta.title }
            if webMeta.description.isEmpty { webMeta.description = meta.description }
            if webMeta.image.isEmpty { webMeta.image = meta.image }
            let domVideos = payload["videos"].array.map { $0.string }.filter { $0.hasPrefix("http") }
            if let result = build(kind: kind, id: id, pageURL: pageURL, collector: collector, meta: webMeta, domVideos: domVideos) {
                return result
            }
            if webMeta.loginWall { meta.loginWall = true }
        }

        if !meta.interstitial.isEmpty {
            throw VideoParseError(.notFound, "Facebook 提示：\(meta.interstitial)")
        }
        if meta.loginWall {
            throw OverseasHTTP.loginRequired("Facebook", reason: "Facebook 未返回媒体数据")
        }
        if let httpError { throw httpError }
        throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频（也可能需要登录 Facebook 才能查看）")
    }

    // MARK: 账号校验

    /// Facebook 没有轻量的网页账号接口：取首页，看 CurrentUserInitialData 里的 USER_ID 是否就是 Cookie 里的 c_user
    static func validate(cookie: String) async -> String? {
        let cUser = CookieUtil.value(of: "c_user", in: cookie) ?? ""
        let request = HTTPRequest.get("https://www.facebook.com/", headers: navigationHeaders(cookie: cookie).sortedPairs)
        return await OverseasAccount.probe(.facebook, cookie: cookie, request) { r in
            Self.probeResult(status: r.status, html: r.text, finalURL: r.url, cUser: cUser)
        }
    }

    /// 跳到登录 / 安全检查页，或 USER_ID 为 0（游客）算失效；拿不到页面数据（风控、改版）说不准
    static func probeResult(status: Int, html: String, finalURL: String, cUser: String) -> OverseasAccount.Probe {
        let lower = finalURL.lowercased()
        if lower.contains("/login") || lower.contains("/checkpoint") { return .invalid }
        guard (200..<300).contains(status) else { return .unknown }
        let block = Rx(#""CurrentUserInitialData",\[\],(\{[^{}]*\})"#).first(in: html).flatMap { JSON(text: $0) }
        var uid = block?["USER_ID"].string ?? ""
        if uid.isEmpty { uid = Rx(#""USER_ID":"(\d+)""#).first(in: html) ?? "" }
        if uid.isEmpty { return .unknown }
        if uid == "0" { return .invalid }
        guard uid == cUser else { return .unknown }
        return .valid(block?["NAME"].string ?? "")
    }

    static func navigationHeaders(cookie: String) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": VideoHTTP.uaChrome,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Sec-Fetch-Dest": "document", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Site": "none", "Sec-Fetch-User": "?1",
            "Upgrade-Insecure-Requests": "1",
            "sec-ch-ua-mobile": "?0", "sec-ch-ua-platform": "\"Windows\""
        ]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func fetchPage(_ url: String, cookie: String) async throws -> String {
        let r = try await OverseasHTTP.send(.get(url, headers: Self.navigationHeaders(cookie: cookie).sortedPairs), site: "Facebook")
        if r.status == 404 { throw VideoParseError(.notFound, "Facebook 内容不存在（HTTP 404）") }
        try VideoHTTP.requireSuccess(r, "Facebook 页面")
        return r.text
    }

    /// 分享链逐跳展开（不自动跟随，便于从登录跳转里取回 next）；拿不到 3xx 时看页面的 og:url / canonical
    static func resolveShare(_ url: String) async throws -> String {
        var current = url
        for _ in 0..<6 {
            let r = try await OverseasHTTP.send(.get(current, headers: navigationHeaders(cookie: "").sortedPairs, followRedirects: false),
                                                site: "Facebook")
            if (300..<400).contains(r.status), let loc = r.header("Location") {
                let next = unwrapLogin(VideoHTTP.absolutize(base: current, loc))
                if let c = classify(next), c.kind != "share" { return next }
                if next == current { break }
                current = next
                continue
            }
            if r.isSuccess, let canonical = canonicalURL(r.text), let c = classify(canonical), c.kind != "share" {
                return canonical
            }
            break
        }
        return current
    }

    // MARK: 纯逻辑：链接

    static let linkRules: [(kind: String, rx: Rx)] = [
        ("share", Rx(#"(?<![A-Za-z0-9.\-])fb\.watch/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        ("share", Rx(#"facebook\.com/share/(?:[vrp]/)?([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        ("video", Rx(#"facebook\.com/(?:[^\s?#]*/)?reel/(\d+)"#, ignoreCase: true)),
        ("video", Rx(#"facebook\.com/(?:watch(?:/live)?/?|video\.php|video/video\.php|video/embed)\?(?:[^\s#]*?&)?(?:v|video_id)=(\d+)"#, ignoreCase: true)),
        ("video", Rx(#"facebook\.com/[^/\s?#]+/videos/(?:[^/\s?#]+/)?(\d+)"#, ignoreCase: true)),
        ("photo", Rx(#"facebook\.com/photo(?:\.php)?/?\?(?:[^\s#]*?&)?fbid=(\d+)"#, ignoreCase: true)),
        ("photo", Rx(#"facebook\.com/[^/\s?#]+/photos/(?:[^/\s?#]+/)?(\d+)"#, ignoreCase: true)),
        ("post", Rx(#"facebook\.com/(?:[^/\s?#]+/posts/|groups/[^/\s?#]+/(?:permalink|posts)/|(?:permalink|story)\.php\?(?:[^\s#]*?&)?story_fbid=)(pfbid[A-Za-z0-9]+|\d+)"#, ignoreCase: true))
    ]

    /// 链接 → (类型, id)；与 VideoLinkParser 里的 Facebook 规则一致
    static func classify(_ url: String) -> (kind: String, id: String)? {
        for rule in linkRules {
            if let id = rule.rx.first(in: url), !id.isEmpty { return (rule.kind, id) }
        }
        return nil
    }

    /// 登录跳转（/login/?next=…）里取回真正的目标地址
    static func unwrapLogin(_ url: String) -> String {
        guard url.contains("/login"), let comps = URLComponents(string: url),
              let next = comps.queryItems?.first(where: { $0.name == "next" })?.value, next.hasPrefix("http") else { return url }
        return next
    }

    static func canonicalURL(_ html: String) -> String? {
        if let og = OverseasHTTP.metaContent("og:url", in: html).first { return og }
        for tag in DomesticHTML.openTags("link", in: html) where (DomesticHTML.attribute("rel", in: tag) ?? "").lowercased() == "canonical" {
            if let href = DomesticHTML.attribute("href", in: tag), href.hasPrefix("http") { return href }
        }
        return nil
    }

    /// 实际抓取的页面：m./web./mbasic. 统一成 www；Reels 按 yt-dlp 走 watch 页
    static func pageURL(kind: String, id: String, url: String) -> String {
        if kind == "video" && url.range(of: "/reel/") != nil {
            return "https://www.facebook.com/watch/?v=\(id)&_rdr"
        }
        let normalized = Rx(#"^(?:https?://)?(?:[A-Za-z0-9\-]+\.)?facebook\.com"#, ignoreCase: true)
            .replacing(in: url, with: "https://www.facebook.com")
        return normalized.hasPrefix("http") ? normalized : "https://" + normalized
    }

    // MARK: 纯逻辑：页面

    static func sjsBlobs(in html: String) -> [String] {
        Rx(#"<script\b[^>]*\bdata-sjs\b[^>]*>(.*?)</script>"#, ignoreCase: true, dotAll: true)
            .allMatches(in: html).map { $0[1] }
    }

    static func pageMeta(_ html: String) -> PageMeta {
        var m = PageMeta()
        m.title = OverseasHTTP.metaContent("og:title", in: html).first ?? ""
        m.description = OverseasHTTP.metaContent("og:description", in: html).first
            ?? OverseasHTTP.metaContent("description", in: html).first ?? ""
        m.image = OverseasHTTP.metaContent("og:image", in: html).first ?? ""
        m.video = OverseasHTTP.metaContent("og:video:secure_url", in: html).first
            ?? OverseasHTTP.metaContent("og:video", in: html).first ?? ""
        m.loginWall = html.contains("id=\"login_form\"") || html.contains(">You must log in to continue")
            || html.contains("id=\"loginbutton\"")
        if let msg = Rx(#"class="[^"]*uiInterstitialContent[^"]*"><div>(.*?)</div>"#, dotAll: true).first(in: html) {
            m.interstitial = DomesticHTML.text(msg)
        }
        return m
    }

    /// 按链接类型挑出这条内容的媒体
    static func select(kind: String, id: String, collector: FacebookCollector) -> [Item] {
        let videos = collector.videos
        let photos = collector.photos
        let group = collector.attachmentIDs.compactMap { aid -> Item? in
            if let v = videos.first(where: { $0.id == aid }) { return .video(v) }
            if let p = photos.first(where: { $0.id == aid }) { return .photo(p) }
            return nil
        }
        switch kind {
        case "video":
            if let v = videos.first(where: { $0.id == id }) { return [.video(v)] }
            if group.contains(where: { if case .video = $0 { return true } else { return false } }) { return group }
            return videos.first.map { [.video($0)] } ?? []
        case "photo":
            if let p = photos.first(where: { $0.id == id }) { return [.photo(p)] }
            if let v = videos.first(where: { $0.id == id }) { return [.video(v)] }
            return photos.first.map { [.photo($0)] } ?? []
        default:
            if !group.isEmpty { return group }
            if let v = videos.first { return [.video(v)] }
            return photos.first.map { [.photo($0)] } ?? []
        }
    }

    /// 一条视频的最佳下载方式：DASH 画质高于渐进式且有分轨音频时用 DASH（视频 + 音频合轨），否则渐进式 HD/SD，最后 HLS
    static func bestStream(_ v: Video) -> Playback? {
        var reps: [DashRep] = []
        for m in v.manifests { reps += dashRepresentations(m) }
        let videoReps: [DashRep] = reps.filter { !$0.isAudio }
        let audioReps: [DashRep] = reps.filter { $0.isAudio }
        let dashVideo: DashRep? = videoReps.max { (a: DashRep, b: DashRep) -> Bool in
            if a.height != b.height { return a.height < b.height }
            return a.bandwidth < b.bandwidth
        }
        let dashAudio: DashRep? = audioReps.max { $0.bandwidth < $1.bandwidth }
        let progressive = v.hd.first ?? v.sd.first
        let progressiveHeight = v.hd.isEmpty ? 360 : 720
        if let dv = dashVideo {
            let better = progressive == nil || (dashAudio != nil && dv.height > progressiveHeight)
            if better {
                let q = dv.height > 0 ? "\(dv.height)p" : ""
                return Playback(url: dv.url, audioURL: dashAudio?.url ?? "", isHLS: false, quality: q)
            }
        }
        if let p = progressive {
            return Playback(url: p, audioURL: "", isHLS: false, quality: v.hd.isEmpty ? "SD" : "HD")
        }
        if let h = v.hls.first {
            return Playback(url: h, audioURL: "", isHLS: true, quality: "HLS")
        }
        return nil
    }

    /// DASH 清单（MPD XML）→ 各路表示；FB 的每个 Representation 的 BaseURL 都是完整的 mp4 文件
    static func dashRepresentations(_ manifest: String) -> [DashRep] {
        var xml = manifest
        if !xml.contains("<") {
            xml = (xml.replacingOccurrences(of: "+", with: " ").removingPercentEncoding) ?? xml
        }
        var out: [DashRep] = []
        let setRx = Rx(#"<AdaptationSet\b([^>]*)>(.*?)</AdaptationSet>"#, dotAll: true)
        let repRx = Rx(#"<Representation\b([^>]*?)(?:/>|>(.*?)</Representation>)"#, dotAll: true)
        let baseRx = Rx(#"<BaseURL[^>]*>(.*?)</BaseURL>"#, dotAll: true)
        for set in setRx.allMatches(in: xml) {
            let setTag = "<a " + set[1] + ">"
            let setType = (DomesticHTML.attribute("mimeType", in: setTag) ?? "") + " " + (DomesticHTML.attribute("contentType", in: setTag) ?? "")
            for rep in repRx.allMatches(in: set[2]) {
                let repTag = "<r " + rep[1] + ">"
                let repType = (DomesticHTML.attribute("mimeType", in: repTag) ?? "") + " " + setType
                guard let base = baseRx.first(in: rep[2]) else { continue }
                let url = DomesticHTML.unescape(base.trimmed)
                guard url.hasPrefix("http") else { continue }
                var r = DashRep()
                r.isAudio = repType.lowercased().contains("audio")
                r.height = Int(DomesticHTML.attribute("height", in: repTag) ?? "") ?? 0
                r.bandwidth = Int(DomesticHTML.attribute("bandwidth", in: repTag) ?? "") ?? 0
                r.url = url
                out.append(r)
            }
        }
        return out
    }

    /// 图片地址可用性：og:image 里的 lookaside 抓取器地址多半取不到
    static func usableImage(_ url: String) -> Bool {
        url.hasPrefix("http") && url.contains("fbcdn") && !url.contains("lookaside") && !url.contains("rsrc.php")
    }

    static func cleanTitle(_ s: String) -> String {
        Rx(#"\s*\|\s*Facebook$"#).replacing(in: DomesticHTML.unescape(s), with: "").trimmed
    }

    // MARK: 组装

    private func build(kind: String, id: String, pageURL: String, collector: FacebookCollector, meta: PageMeta,
                       domVideos: [String]) -> VideoParseResult? {
        var items = Self.select(kind: kind, id: id, collector: collector)
        if items.isEmpty {
            // 兜底：og:video / 页面 <video> 直链 / og:image
            let video = [meta.video].filter { $0.hasPrefix("http") } + domVideos
            if let v = video.first {
                var one = Video()
                one.id = id
                one.sd = [DomesticHTML.unescape(v)]
                items = [.video(one)]
            } else if kind != "video", Self.usableImage(meta.image) {
                items = [.photo(Photo(id: id, url: DomesticHTML.unescape(meta.image), area: 0))]
            }
        }
        guard !items.isEmpty else { return nil }

        let headers = ["User-Agent": Self.mediaUA]
        var firstVideo: Video?
        for item in items {
            if case .video(let v) = item { firstVideo = v; break }
        }
        let rawTitle = firstVideo?.title.nilIfBlank ?? Self.cleanTitle(meta.title)
        let text = firstVideo?.text.nilIfBlank ?? DomesticHTML.unescape(meta.description)
        let title = rawTitle.isEmpty ? String(text.prefix(40)) : rawTitle
        let base = FileNames.base(title, fallback: "facebook_\(id.isEmpty ? "post" : id)")
        let single = items.count == 1
        var medias: [VideoMedia] = []
        var cover = firstVideo?.thumbnail ?? ""
        for (i, item) in items.enumerated() {
            let suffix = single ? "" : "_\(i + 1)"
            switch item {
            case .video(let v):
                guard let s = Self.bestStream(v) else { continue }
                medias.append(VideoMedia(url: s.url, kind: .video, fileName: "\(base)\(suffix).mp4", isHLS: s.isHLS,
                                         headers: headers, quality: s.quality, audioURL: s.audioURL))
            case .photo(let p):
                let ext = DomesticHTML.imageExtension(p.url)
                if cover.isEmpty { cover = p.url }
                medias.append(VideoMedia(url: p.url, kind: .image, fileName: "\(base)\(suffix).\(ext)", headers: headers))
            }
        }
        guard !medias.isEmpty else { return nil }
        if cover.isEmpty && Self.usableImage(meta.image) { cover = DomesticHTML.unescape(meta.image) }
        return VideoParseResult(platform: platform, title: title, author: firstVideo?.owner ?? "", cover: cover,
                                text: text, timestamp: firstVideo?.timestamp ?? 0, url: pageURL, medias: medias)
    }

    // MARK: 隐藏浏览器脚本

    /// 文档开始前注入：页面自己请求的 /api/graphql/ 响应里含视频地址的，存到 window.__cloudnFbGraphQL
    static let hookJS = #"""
    (function () {
      try {
        if (window.__cloudnFbHook) return;
        window.__cloudnFbHook = true;
        window.__cloudnFbStart = Date.now();
        window.__cloudnFbGraphQL = [];
        var keys = ['playable_url', 'browser_native_', 'dash_manifest', 'progressive_url', 'manifest_xml'];
        var keep = function (url, text) {
          try {
            if (!text || String(url || '').indexOf('graphql') < 0) return;
            for (var i = 0; i < keys.length; i++) {
              if (text.indexOf(keys[i]) >= 0) {
                if (window.__cloudnFbGraphQL.length < 20) window.__cloudnFbGraphQL.push(text);
                return;
              }
            }
          } catch (e) {}
        };
        var rawOpen = XMLHttpRequest.prototype.open;
        var rawSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { this.__cloudnUrl = String(url || ''); } catch (e) {}
          return rawOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
          var xhr = this;
          try {
            xhr.addEventListener('load', function () {
              if (xhr.status !== 200) return;
              var text = '';
              try { text = xhr.responseText || ''; } catch (e) {}
              keep(xhr.__cloudnUrl, text);
            });
          } catch (e) {}
          return rawSend.apply(this, arguments);
        };
        if (window.fetch) {
          var rawFetch = window.fetch;
          window.fetch = function (input) {
            var url = (typeof input === 'string') ? input : (input && input.url) || '';
            return rawFetch.apply(this, arguments).then(function (resp) {
              try { if (String(url).indexOf('graphql') >= 0) resp.clone().text().then(function (t) { keep(url, t); }); } catch (e) {}
              return resp;
            });
          };
        }
      } catch (e) {}
    })();
    """#

    /// 钩到含视频地址的接口响应，或页面脚本里已有媒体数据即就绪；页面加载完 10 秒后无论如何收尾
    static let readyJS = #"""
    (function () {
      if (window.__cloudnFbGraphQL && window.__cloudnFbGraphQL.length > 0) return true;
      if (document.readyState !== 'complete') return false;
      var ss = document.querySelectorAll('script[type="application/json"]');
      for (var i = 0; i < ss.length; i++) {
        var t = ss[i].textContent || '';
        if (t.indexOf('browser_native_') >= 0 || t.indexOf('playable_url') >= 0 || t.indexOf('progressive_url') >= 0) return true;
      }
      var start = window.__cloudnFbStart || 0;
      return start > 0 && (Date.now() - start) > 10000;
    })()
    """#

    static let extractJS = #"""
    (function () {
      try {
        var keys = ['playable_url', 'browser_native_', 'dash_manifest', 'progressive_url', 'manifest_xml', '"Photo"', 'all_subattachments'];
        var blobs = [];
        var ss = document.querySelectorAll('script[type="application/json"]');
        for (var i = 0; i < ss.length; i++) {
          var t = ss[i].textContent || '';
          for (var k = 0; k < keys.length; k++) { if (t.indexOf(keys[k]) >= 0) { blobs.push(t); break; } }
        }
        var meta = function (p) {
          var el = document.querySelector('meta[property="' + p + '"]') || document.querySelector('meta[name="' + p + '"]');
          return el ? (el.getAttribute('content') || '') : '';
        };
        var videos = [];
        var vs = document.querySelectorAll('video');
        for (var j = 0; j < vs.length; j++) {
          var s = vs[j].currentSrc || vs[j].src || '';
          if (s && s.indexOf('blob:') !== 0 && videos.indexOf(s) < 0) videos.push(s);
        }
        var body = document.body ? (document.body.innerText || '') : '';
        return JSON.stringify({
          blobs: blobs, graphql: window.__cloudnFbGraphQL || [], videos: videos,
          title: meta('og:title') || document.title || '', description: meta('og:description') || meta('description'),
          image: meta('og:image'), ogVideo: meta('og:video:secure_url') || meta('og:video'),
          loginWall: blobs.length === 0 && (!!document.getElementById('login_form') || body.indexOf('You must log in') >= 0)
        });
      } catch (e) { return JSON.stringify({ error: 'js: ' + e }); }
    })()
    """#
}

/// 遍历 Relay 预取数据（保持键顺序），收集视频节点、图片节点与帖子附件顺序
final class FacebookCollector {
    private(set) var videos: [FacebookParser.Video] = []
    private(set) var photos: [FacebookParser.Photo] = []
    /// 第一个帖子附件组里的媒体 id（按出现顺序）
    private(set) var attachmentIDs: [String] = []

    private static let interesting = ["playable_url", "browser_native_", "dash_manifest", "progressive_url", "manifest_xml",
                                      "hd_src", "sd_src", "\"Photo\"", "all_subattachments"]
    private static let videoKeys = ["browser_native_hd_url", "browser_native_sd_url", "playable_url", "playable_url_quality_hd",
                                    "videoDeliveryLegacyFields", "videoDeliveryResponseFragment", "dash_manifest",
                                    "dash_manifest_xml_string", "hd_src", "sd_src", "hd_src_no_ratelimit", "sd_src_no_ratelimit"]

    func add(_ text: String) {
        let trimmed = text.trimmed
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return }
        guard Self.interesting.contains(where: { trimmed.contains($0) }) else { return }
        guard let root = JSLiteral.parse(trimmed) else { return }
        walk(root, depth: 0)
    }

    private func walk(_ node: JSLiteral, depth: Int) {
        guard depth < 400 else { return }
        switch node {
        case .object(let pairs):
            let isVideo = pairs.contains(where: { Self.videoKeys.contains($0.0) })
            if isVideo { addVideo(node) }
            if node["__typename"]?.stringValue == "Photo" { addPhoto(node) }
            if attachmentIDs.isEmpty { noteAttachments(node) }
            for (k, v) in pairs {
                // 视频节点的投递字段已在 addVideo 里读过，不再单独当成视频
                if isVideo && (k == "videoDeliveryLegacyFields" || k == "videoDeliveryResponseFragment") { continue }
                walk(v, depth: depth + 1)
            }
        case .array(let items):
            for v in items { walk(v, depth: depth + 1) }
        default:
            break
        }
    }

    private func addVideo(_ node: JSLiteral) {
        let v = Self.video(from: node.json)
        guard !v.isEmpty else { return }
        let key = v.key
        if let i = videos.firstIndex(where: { $0.key == key }) {
            videos[i].merge(v)
        } else {
            videos.append(v)
        }
    }

    static func video(from j: JSON) -> FacebookParser.Video {
        var v = FacebookParser.Video()
        v.id = j.string("videoId", "video_id", "id")
        let legacy = j["videoDeliveryLegacyFields"]
        for src in [j, legacy] {
            for key in ["browser_native_hd_url", "playable_url_quality_hd", "hd_src_no_ratelimit", "hd_src"] {
                let u = src[key].string
                if u.hasPrefix("http") && !u.contains(".mpd") && !v.hd.contains(u) { v.hd.append(u) }
            }
            for key in ["browser_native_sd_url", "playable_url", "sd_src_no_ratelimit", "sd_src"] {
                let u = src[key].string
                if u.hasPrefix("http") && !u.contains(".mpd") && !v.sd.contains(u) { v.sd.append(u) }
            }
            for key in ["dash_manifest", "dash_manifest_xml_string", "manifest_xml"] {
                let m = src[key].string
                if !m.isEmpty && !v.manifests.contains(m) { v.manifests.append(m) }
            }
        }
        let result = j["videoDeliveryResponseFragment"]["videoDeliveryResponseResult"]
        for d in result["dash_manifests"].array {
            let m = d["manifest_xml"].string
            if !m.isEmpty && !v.manifests.contains(m) { v.manifests.append(m) }
        }
        for p in result["progressive_urls"].array {
            let u = p["progressive_url"].string
            guard u.hasPrefix("http") else { continue }
            if p["metadata"]["quality"].string.lowercased() == "hd" {
                if !v.hd.contains(u) { v.hd.append(u) }
            } else if !v.sd.contains(u) {
                v.sd.append(u)
            }
        }
        for h in result["hls_playlist_urls"].array {
            let u = h["hls_playlist_url"].string
            if u.hasPrefix("http") && !v.hls.contains(u) { v.hls.append(u) }
        }
        v.thumbnail = j["thumbnailImage"]["uri"].string
        if v.thumbnail.isEmpty { v.thumbnail = j["preferred_thumbnail"]["image"]["uri"].string }
        v.title = j["name"].string
        v.text = j["savable_description"]["text"].string
        v.owner = j["owner"]["name"].string
        v.timestamp = j["publish_time"].int64
        if v.timestamp == 0 { v.timestamp = j["creation_time"].int64 }
        return v
    }

    private func addPhoto(_ node: JSLiteral) {
        guard let p = Self.photo(from: node.json), !p.url.isEmpty else { return }
        if let i = photos.firstIndex(where: { $0.id == p.id && !p.id.isEmpty }) {
            if p.area > photos[i].area { photos[i] = p }
        } else {
            photos.append(p)
        }
    }

    /// Photo 节点：直接子对象里带 uri 的图片中面积最大的一张
    static func photo(from j: JSON) -> FacebookParser.Photo? {
        guard let dict = j.dictionary else { return nil }
        var best = FacebookParser.Photo()
        best.id = j["id"].string
        for key in dict.keys.sorted() {
            let child = j[key]
            let uri = child["uri"].string
            guard uri.hasPrefix("http") else { continue }
            let area = child["width"].int * child["height"].int
            if best.url.isEmpty || area > best.area {
                best.url = uri
                best.area = area
            }
        }
        return best.url.isEmpty ? nil : best
    }

    /// 帖子附件：all_subattachments.nodes[].media（多图 / 多视频），否则 attachment.media（单个）
    private func noteAttachments(_ node: JSLiteral) {
        var ids: [String] = []
        if let subs = node["all_subattachments"]?["nodes"] {
            for n in subs.items {
                let id = n["media"]?["id"]?.stringValue ?? ""
                if !id.isEmpty && !ids.contains(id) { ids.append(id) }
            }
        } else if let media = node["attachment"]?["media"] {
            let type = media["__typename"]?.stringValue ?? ""
            let id = media["id"]?.stringValue ?? ""
            if (type == "Photo" || type == "Video") && !id.isEmpty { ids = [id] }
        }
        if !ids.isEmpty { attachmentIDs = ids }
    }
}
