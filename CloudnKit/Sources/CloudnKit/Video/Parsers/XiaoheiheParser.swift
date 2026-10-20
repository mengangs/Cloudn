// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 xiaoheihe 解析。
import Foundation

/// 小黑盒：帖子数据来自 api.xiaoheihe.cn/bbs/app/link/tree（query 里带 hkey/_time/nonce 签名）。
/// ParseHub 还会先向第三方数美设备指纹服务换一个 x_xhh_tokenid Cookie —— 我们不访问第三方主机：
/// 1. 先只带签名、不带 tokenid 直接请求接口；
/// 2. 接口不放行（lack_token / 验证码 / 非 JSON）时，用隐藏浏览器打开官方帖子页，
///    让页面自己跑完指纹与签名流程，在文档开始前钩住页面发出的 link/tree 响应取数；
///    钩不到再从渲染后的 DOM 里取图片 / 视频。
struct XiaoheiheParser: VideoParser {
    let platform = VideoPlatform.xiaoheihe
    let extractor: WebPageExtractor?

    init(extractor: WebPageExtractor? = nil) {
        self.extractor = extractor
    }

    static let apiURL = "https://api.xiaoheihe.cn/bbs/app/link/tree"
    static let apiPath = "/bbs/app/link/tree"

    /// 映射后的帖子（纯数据，便于离线测试）
    struct Post {
        var title = ""
        var text = ""
        var author = ""
        var avatar = ""
        var timestamp: Int64 = 0
        var cover = ""
        var videos: [String] = []
        var images: [String] = []
    }

    private var mediaHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.xiaoheihe.cn/"]
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id.isEmpty ? (Self.linkID(from: link.url) ?? "") : link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法识别小黑盒帖子链接") }
        let pageURL = "https://www.xiaoheihe.cn/app/bbs/link/\(id)"

        // 1. 纯接口（不带设备指纹）
        var apiError: VideoParseError?
        var linkJSON: JSON?
        do {
            linkJSON = try await fetchAPI(id, cookie: cookie)
        } catch let e as VideoParseError {
            apiError = e
        }
        if let linkJSON {
            // 接口放行了：有没有媒体以接口为准，不再开浏览器
            if let post = Self.post(fromLink: linkJSON), !(post.videos.isEmpty && post.images.isEmpty) {
                return build(id: id, pageURL: pageURL, post: post, notice: "")
            }
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
        }

        // 2. 隐藏浏览器跑官方页面
        if let extractor,
           let text = await extractor.extract(url: pageURL, userAgent: VideoHTTP.uaChrome,
                                              documentStartScripts: [Self.hookJS], readyScript: Self.readyJS,
                                              extractScript: Self.extractJS, timeout: 35),
           let payload = JSON(text: text), payload["error"].string.isEmpty {
            if let linkText = payload["link"].string.nilIfBlank, let root = JSON(text: linkText),
               let post = Self.post(fromLink: root["result"]["link"]), !(post.videos.isEmpty && post.images.isEmpty) {
                return build(id: id, pageURL: pageURL, post: post, notice: "")
            }
            if let post = Self.post(fromDOM: payload["dom"]) {
                return build(id: id, pageURL: pageURL, post: post, notice: "接口数据未取到，媒体取自网页画面，可能不全或非原图")
            }
        }
        throw apiError ?? VideoParseError(.unknown, "小黑盒解析失败，请稍后重试")
    }

    // MARK: 接口

    private func fetchAPI(_ id: String, cookie: String) async throws -> JSON {
        let now = Int64(Date().timeIntervalSince1970)
        let nonce = Crypto.md5Hex("\(now)\(Double.random(in: 0..<1))").uppercased()
        let hkey = Self.hkey(path: Self.apiPath, time: now, nonce: nonce)
        let query = Self.query(linkID: id, hkey: hkey, time: now, nonce: nonce)
        let url = Self.apiURL + "?" + query.map { "\($0.0)=\($0.1.urlQueryEncoded)" }.joined(separator: "&")
        var headers: [String: String] = [
            "User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.xiaoheihe.cn/",
            "Origin": "https://www.xiaoheihe.cn", "Accept": "application/json, text/plain, */*"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let r = try await VideoHTTP.send(.get(url, headers: headers.sortedPairs))
        try VideoHTTP.requireSuccess(r, "小黑盒帖子接口")
        guard let body = r.json, body.isObject else { throw VideoParseError(.blocked, "小黑盒接口返回了非 JSON 响应（可能触发了风控）") }
        try Self.checkStatus(body)
        let link = body["result"]["link"]
        guard link.isObject else { throw VideoParseError(.notFound, "小黑盒没有返回该帖子的数据（可能已删除）") }
        return link
    }

    static func query(linkID: String, hkey: String, time: Int64, nonce: String) -> [(String, String)] {
        [
            ("os_type", "web"), ("app", "heybox"), ("client_type", "web"), ("version", "999.0.4"),
            ("web_version", "2.5"), ("x_client_type", "web"), ("x_app", "heybox_website"), ("heybox_id", ""),
            ("x_os_type", "Windows"), ("device_info", "Chrome"), ("link_id", linkID), ("owner_only", "1"),
            ("hkey", hkey), ("_time", String(time)), ("nonce", nonce)
        ]
    }

    /// 接口 status → 错误
    static func checkStatus(_ body: JSON) throws {
        let status = body["status"].string
        let msg = body["msg"].string
        switch status {
        case "ok": return
        case "login", "relogin":
            throw VideoParseError(.unknown, "该帖子需要登录小黑盒后才能查看" + (msg.isEmpty ? "" : "（\(msg)）"))
        case "show_captcha":
            throw VideoParseError(.blocked, "小黑盒要求过验证码，请稍后重试")
        case "lack_token":
            throw VideoParseError(.blocked, "小黑盒要求设备令牌" + (msg.isEmpty ? "" : "（\(msg)）"))
        case "failed":
            throw VideoParseError(.notFound, msg.isEmpty ? "小黑盒帖子不存在或已删除" : "小黑盒：\(msg)")
        default:
            throw VideoParseError(.unknown, "小黑盒接口返回异常状态：\(status.isEmpty ? "未知" : status)")
        }
    }

    // MARK: 签名（ParseHub XiaoHeiHeSign，method_key = "g" → 时间偏移 +1）

    static let charTable: [Character] = Array("AB45STUVWZEFGJ6CH01D237IXYPQRKLMN89")

    static func hkey(path: String, time: Int64, nonce: String) -> String {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let normalized = "/" + parts.joined(separator: "/") + "/"
        let mapped = [
            mapChars(String(time + 1), cut: 2),
            mapChars(normalized, cut: 0),
            mapChars(nonce, cut: 0)
        ]
        let interleaved = String(interleave(mapped).prefix(20))
        let md5 = Array(Crypto.md5Hex(interleaved))
        let tail: [Int] = md5.suffix(6).map { Int($0.unicodeScalars.first?.value ?? 0) }
        let mixed = mixColumns(tail)
        var sum = 0
        for v in mixed { sum += v }
        var suffix = String(sum % 100)
        if suffix.count < 2 { suffix = "0" + suffix }
        let prefix = mapChars(String(md5.prefix(5)), cut: 4)
        return prefix + suffix
    }

    /// 每个字符按码点取模映射到（截掉末尾 cut 位的）字符表
    static func mapChars(_ text: String, cut: Int) -> String {
        let table = Array(charTable.dropLast(cut))
        var out = ""
        for scalar in text.unicodeScalars {
            out.append(table[Int(scalar.value) % table.count])
        }
        return out
    }

    static func interleave(_ arrays: [String]) -> String {
        let chars = arrays.map { Array($0) }
        let maxLen = chars.map(\.count).max() ?? 0
        var out = ""
        for i in 0..<maxLen {
            for a in chars where i < a.count { out.append(a[i]) }
        }
        return out
    }

    private static func xtime(_ e: Int) -> Int {
        (e & 128) != 0 ? (((e << 1) ^ 27) & 0xFF) : (e << 1)
    }

    private static func mul3(_ e: Int) -> Int { xtime(e) ^ e }
    private static func mul6(_ e: Int) -> Int { mul3(xtime(e)) }
    private static func mul12(_ e: Int) -> Int { mul6(mul3(xtime(e))) }
    private static func mul14(_ e: Int) -> Int { mul12(e) ^ mul6(e) ^ mul3(e) }

    /// AES InvMixColumns 风格的列变换；超出 4 个的元素原样追加
    static func mixColumns(_ input: [Int]) -> [Int] {
        var e = input
        while e.count < 4 { e.append(0) }
        let a0 = mul14(e[0]) ^ mul12(e[1]) ^ mul6(e[2]) ^ mul3(e[3])
        let a1 = mul3(e[0]) ^ mul14(e[1]) ^ mul12(e[2]) ^ mul6(e[3])
        let a2 = mul6(e[0]) ^ mul3(e[1]) ^ mul14(e[2]) ^ mul12(e[3])
        let a3 = mul12(e[0]) ^ mul6(e[1]) ^ mul3(e[2]) ^ mul14(e[3])
        var out = [a0, a1, a2, a3]
        if e.count > 4 { out.append(contentsOf: e[4...]) }
        return out
    }

    // MARK: 纯逻辑

    /// link_id：?link_id=xxx 或 /link/xxx
    static func linkID(from url: String) -> String? {
        if let v = Rx(#"[?&]link_id=([A-Za-z0-9]+)"#).first(in: url) { return v }
        return Rx(#"/link/([A-Za-z0-9]+)"#).first(in: url)
    }

    /// 缩略图地址 → 原图：去掉 query，`/thumb.ext` → `.ext`
    static func originalImageURL(_ url: String) -> String {
        let path = url.substringBefore("?")
        return Rx(#"/thumb\.(\w+)$"#).replacing(in: path, with: ".$1")
    }

    /// 接口 result.link → 帖子
    static func post(fromLink link: JSON) -> Post? {
        guard link.isObject else { return nil }
        var post = Post()
        post.title = link["title"].string
        let user = link["user"]
        post.author = user.string("username", "nickname")
        post.avatar = user.string("avartar", "avatar")
        post.timestamp = link["create_at"].int64
        let rawText = link["text"].string
        let textList = JSON(text: rawText)?.array ?? []

        if link["has_video"].bool || !link["video_url"].string.isEmpty {
            let video = link["video_url"].string
            if !video.isEmpty { post.videos.append(video) }
            post.cover = link["video_thumb"].string
            post.text = textList.isEmpty ? rawText : body(of: textList)
            return post
        }
        post.text = body(of: textList)
        var images: [String] = []
        // 文章：正文 HTML 里内嵌的图片（data-original 才是原图）
        if let first = textList.first, first["type"].string == "html" {
            for tag in DomesticHTML.openTags("img", in: first["text"].string) {
                let src = DomesticHTML.attribute("data-original", in: tag) ?? DomesticHTML.attribute("src", in: tag) ?? ""
                guard src.hasPrefix("http") || src.hasPrefix("//") else { continue }
                images.append(originalImageURL(DomesticHTML.absolute(src)))
            }
        }
        for item in textList.dropFirst() where item["type"].string == "img" {
            let url = item["url"].string
            guard !url.isEmpty else { continue }
            images.append(originalImageURL(DomesticHTML.absolute(url)))
        }
        var seen = Set<String>()
        post.images = images.filter { seen.insert($0).inserted }
        post.cover = post.images.first ?? ""
        return post
    }

    /// 文本列表第一项是正文（html 或纯文本）
    private static func body(of textList: [JSON]) -> String {
        guard let first = textList.first else { return "" }
        let text = first["text"].string
        return first["type"].string == "html" ? DomesticHTML.text(text) : text.trimmed
    }

    /// 网页兜底：DOM 里取到的图片 / 视频
    static func post(fromDOM dom: JSON) -> Post? {
        var post = Post()
        post.title = dom["title"].string.replacingOccurrences(of: " - 小黑盒", with: "").trimmed
        post.videos = dom["videos"].array.map { $0.string }.filter { $0.hasPrefix("http") }
        var seen = Set<String>()
        post.images = dom["images"].array.map { originalImageURL($0.string) }
            .filter { $0.hasPrefix("http") && seen.insert($0).inserted }
        if post.videos.isEmpty && post.images.isEmpty { return nil }
        post.cover = dom["cover"].string
        return post
    }

    private func build(id: String, pageURL: String, post: Post, notice: String) -> VideoParseResult {
        let title = post.title.isEmpty ? String(post.text.prefix(40)) : post.title
        let base = FileNames.base(title, fallback: "xiaoheihe_\(id)")
        var medias: [VideoMedia] = []
        for (i, url) in post.videos.enumerated() {
            let name = post.videos.count == 1 ? "\(base).mp4" : "\(base)_v\(i + 1).mp4"
            let hls = url.contains(".m3u8")
            medias.append(VideoMedia(url: url, kind: .video, fileName: name, isHLS: hls, headers: mediaHeaders))
        }
        // 视频帖只要视频；图文 / 文章取全部图片（含 GIF）
        if post.videos.isEmpty {
            for (i, url) in post.images.enumerated() {
                let ext = DomesticHTML.imageExtension(url)
                let name = post.images.count == 1 ? "\(base).\(ext)" : "\(base)_\(i + 1).\(ext)"
                medias.append(VideoMedia(url: url, kind: .image, fileName: name, headers: mediaHeaders, quality: "原图"))
            }
        }
        return VideoParseResult(platform: platform, title: title, author: post.author, avatar: post.avatar,
                                cover: post.cover, text: post.text, timestamp: post.timestamp, url: pageURL,
                                medias: medias, notice: notice)
    }

    // MARK: 隐藏浏览器脚本

    /// 文档开始前注入：页面自己请求到的帖子接口响应（result.link 存在的那个）存到 window.__cloudnXhhLink
    static let hookJS = #"""
    (function () {
      try {
        if (window.__cloudnXhhHook) return;
        window.__cloudnXhhHook = true;
        window.__cloudnXhhStart = Date.now();
        var keep = function (url, text) {
          try {
            if (!text || String(url || '').indexOf('link') < 0) return;
            var o = JSON.parse(text);
            if (o && o.result && o.result.link && typeof o.result.link === 'object') window.__cloudnXhhLink = text;
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
              if (!text) { try { var r = xhr.response; if (r) text = (typeof r === 'string') ? r : JSON.stringify(r); } catch (e) {} }
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
              try { if (String(url).indexOf('link') >= 0) resp.clone().text().then(function (t) { keep(url, t); }); } catch (e) {}
              return resp;
            });
          };
        }
      } catch (e) {}
    })();
    """#

    /// 钩到接口响应即就绪；否则页面加载完 12 秒后用 DOM 兜底
    static let readyJS = #"""
    (function () {
      if (typeof window.__cloudnXhhLink === 'string' && window.__cloudnXhhLink.length > 0) return true;
      var start = window.__cloudnXhhStart || 0;
      return document.readyState === 'complete' && start > 0 && (Date.now() - start) > 12000;
    })()
    """#

    static let extractJS = #"""
    (function () {
      try {
        var images = [], videos = [];
        var imgs = document.querySelectorAll('img');
        for (var i = 0; i < imgs.length; i++) {
          var el = imgs[i];
          var s = el.getAttribute('data-original') || el.currentSrc || el.src || '';
          if (s.indexOf('max-c.com') < 0) continue;
          if (/avatar|avartar|emoji|icon|logo|level|medal|badge/i.test(s)) continue;
          if ((el.naturalWidth || 0) < 200 && !el.getAttribute('data-original')) continue;
          if (images.indexOf(s) < 0) images.push(s);
        }
        var vs = document.querySelectorAll('video, video source');
        for (var j = 0; j < vs.length; j++) {
          var v = vs[j].currentSrc || vs[j].src || '';
          if (v && v.indexOf('blob:') !== 0 && videos.indexOf(v) < 0) videos.push(v);
        }
        var og = document.querySelector('meta[property="og:image"]');
        return JSON.stringify({
          link: window.__cloudnXhhLink || '',
          dom: { title: document.title || '', images: images, videos: videos, cover: og ? (og.getAttribute('content') || '') : '' }
        });
      } catch (e) { return JSON.stringify({ error: 'js: ' + e }); }
    })()
    """#
}
