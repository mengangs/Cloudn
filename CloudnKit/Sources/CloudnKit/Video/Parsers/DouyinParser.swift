// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 DouyinParser。
import Foundation

/// 抖音：纯 HTTP 拿到的是 byted_acrawler JS 挑战页，作品数据只有在真实浏览器内核跑完挑战后才出现。
/// 主路线：隐藏 WKWebView 打开 www.douyin.com/{video|note}/{id}，在文档开始前钩住页面自己发出的
/// aweme/detail 响应（视频直链在那里）；图文的作品图从 DOM 取。
/// 回退：iesdouyin 分享页的 window._ROUTER_DATA（抖音偶尔会放行）。
struct DouyinParser: VideoParser {
    let platform = VideoPlatform.douyin
    let extractor: WebPageExtractor?

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        if link.kind == "user" { return try await parseUser(link, cookie: cookie) }
        let type = Rx(#"/(?:share/)?(note|slides)/"#).first(in: link.url) == nil ? "video" : "note"
        guard let extractor else { return try await parseSSR(link, type: type) }
        return try await Self.race(web: { await webRoute(link, type: type, cookie: cookie, extractor: extractor) },
                                   share: { try await parseSSR(link, type: type) })
    }

    private func webRoute(_ link: DetectedVideoLink, type: String, cookie: String, extractor: WebPageExtractor) async -> VideoParseResult? {
        guard let text = await extractor.extract(url: "https://www.douyin.com/\(type)/\(link.id)", userAgent: VideoHTTP.uaChrome, cookie: cookie,
                                                 documentStartScripts: [Self.detailHookJS], readyScript: Self.readyJS(type, id: link.id),
                                                 extractScript: Self.extractJS, timeout: 40),
              let payload = JSON(text: text), payload["error"].string.isEmpty else { return nil }
        return await build(link, payload)
    }

    /// 两条路线同时跑：隐藏浏览器要过 JS 挑战，稳但慢（最长等 40 秒）；分享页只要一次普通请求，抖音放行时一秒左右就有结果。
    /// 谁先拿到带媒体的结果用谁，另一条随即取消。都没拿到媒体时与以前一致：浏览器失败后用分享页的结果，或报分享页的错
    static func race(web: @escaping @Sendable () async -> VideoParseResult?,
                     share: @escaping @Sendable () async throws -> VideoParseResult) async throws -> VideoParseResult {
        enum Route: Sendable {
            case web(VideoParseResult?)
            case share(Result<VideoParseResult, Error>)
        }
        let start = Date()
        return try await withThrowingTaskGroup(of: Route.self) { group in
            group.addTask { .web(await web()) }
            group.addTask {
                do { return .share(.success(try await share())) } catch { return .share(.failure(error)) }
            }
            var shareOutcome: Result<VideoParseResult, Error>?
            var webFailed = false
            while let route = try await group.next() {
                switch route {
                case .web(let result?):
                    group.cancelAll()
                    Log.info("抖音：隐藏浏览器先拿到结果，用时 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒")
                    return result
                case .web(nil):
                    webFailed = true
                case .share(let outcome):
                    if case .success(let result) = outcome, !result.medias.isEmpty {
                        group.cancelAll()
                        Log.info("抖音：分享页先拿到结果，用时 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒")
                        return result
                    }
                    shareOutcome = outcome
                }
                if webFailed, let shareOutcome { return try shareOutcome.get() }
            }
            throw VideoParseError(.unknown, "抖音解析失败")
        }
    }

    private var mediaHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaIPhone, "Referer": "https://www.douyin.com/"]
    }

    private func build(_ link: DetectedVideoLink, _ p: JSON) async -> VideoParseResult? {
        var images = p["images"].array.map { $0.string }.filter { !$0.isEmpty }
        // 与 images 一一对应：实况照片的那段视频，没有为空串
        var lives = p["lives"].array.map { $0.string }
        if images.isEmpty {
            images = p["domImages"].array.map { $0.string }.filter { !$0.isEmpty }
            lives = []
        }
        let video = p["video"].string
        guard !images.isEmpty || !video.isEmpty else { return nil }
        let title = p["title"].string
        let base = FileNames.base(title, fallback: "douyin_\(link.id)")
        let medias: [VideoMedia]
        if !images.isEmpty {
            var list: [VideoMedia] = []
            for (i, url) in images.enumerated() {
                list.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1)\(Self.imageExtension(url))", headers: mediaHeaders))
                if i < lives.count, let live = Self.liveMedia(lives[i], stem: "\(base)_\(i + 1)", headers: mediaHeaders) { list.append(live) }
            }
            medias = list
        } else {
            medias = await videoMedias(base: base, bitRates: p["bitRates"].array, fallback: video, uri: p["uri"].string,
                                       needCookie: p["needCookie"].bool)
        }
        let cover = p["cover"].string
        return VideoParseResult(platform: platform, title: title, author: p["author"].string,
                                cover: cover.isEmpty ? (images.first ?? "") : cover, timestamp: p["createTime"].int64,
                                url: link.url, medias: medias, authorID: p["authorID"].string, fileBase: base)
    }

    private func parseSSR(_ link: DetectedVideoLink, type: String) async throws -> VideoParseResult {
        let html = try await VideoHTTP.getText("https://www.iesdouyin.com/share/\(type)/\(link.id)/",
                                               headers: ["User-Agent": VideoHTTP.uaIPhone, "Referer": "https://www.iesdouyin.com/"],
                                               what: "抖音分享页")
        guard let routerText = VideoHTTP.extractInlineJSON(html, key: "window._ROUTER_DATA"), let router = JSON(text: routerText) else {
            throw VideoParseError(.blocked, "抖音拦截了本次请求（需要网页验证），请稍后重试")
        }
        let loader = router["loaderData"]
        let page = loader["video_(id)/page"].isObject ? loader["video_(id)/page"] : loader["note_(id)/page"]
        let item = page.object("videoInfoRes", "video_info_res").arrayValue("item_list", "itemList").first ?? JSON(nil)
        guard item.isObject else { throw VideoParseError(.notFound, "抖音没有返回该作品的数据（可能已删除或被风控）") }
        let title = item["desc"].string
        let base = FileNames.base(title, fallback: "douyin_\(link.id)")
        var medias: [VideoMedia] = []
        var cover = ""
        let images = item["images"].array
        if !images.isEmpty {
            for (i, img) in images.enumerated() {
                guard let url = img.arrayValue("url_list", "urlList").map({ $0.string }).first(where: { !$0.isEmpty }) else { continue }
                if cover.isEmpty { cover = url }
                medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1).jpg", headers: mediaHeaders, quality: "原图"))
                let live = Self.liveVideoURL(in: img)
                if let media = Self.liveMedia(live, stem: "\(base)_\(i + 1)", headers: mediaHeaders) { medias.append(media) }
            }
        } else {
            let play = item["video"].object("play_addr", "playAddr")
            // playwm → play：去水印的关键一步
            let url = play.arrayValue("url_list", "urlList").map({ $0.string }).first(where: { !$0.isEmpty }) ?? ""
            let uri = [play["uri"].string, item["video"]["vid"].string, item["video"]["download_addr"]["uri"].string].first { !$0.isEmpty } ?? ""
            medias += await videoMedias(base: base, bitRates: item["video"].arrayValue("bit_rate", "bitRate"),
                                        fallback: url.replacingOccurrences(of: "playwm", with: "play"), uri: uri,
                                        needCookie: item["video"]["is_need_set_cookie"].bool)
            cover = item["video"]["cover"]["url_list"][0].string
        }
        let author = item["author"]
        return VideoParseResult(platform: platform, title: title, author: author["nickname"].string,
                                avatar: author.object("avatar_thumb", "avatar_medium")["url_list"][0].string,
                                cover: cover, timestamp: item["create_time"].int64, url: link.url, medias: medias,
                                authorID: [author["unique_id"].string, author["short_id"].string].first { !$0.isEmpty } ?? "",
                                fileBase: base)
    }

    /// 实况图里的视频地址：字段名各版本不一，在这张图的数据里找第一个视频地址
    static func liveVideoURL(in node: JSON, depth: Int = 0) -> String {
        guard depth <= 6 else { return "" }
        if let text = node.raw as? String { return isVideoURL(text) ? text : "" }
        if let dict = node.raw as? [String: Any] {
            let keys = dict.keys.sorted { ($0 == "video" ? 0 : 1, $0) < ($1 == "video" ? 0 : 1, $1) }
            for key in keys {
                let found = liveVideoURL(in: node[key], depth: depth + 1)
                if !found.isEmpty { return found }
            }
        } else if node.raw is [Any] {
            for item in node.array {
                let found = liveVideoURL(in: item, depth: depth + 1)
                if !found.isEmpty { return found }
            }
        }
        return ""
    }

    static func isVideoURL(_ url: String) -> Bool {
        guard url.hasPrefix("http") else { return false }
        let path = url.substringBefore("?").lowercased()
        if [".jpg", ".jpeg", ".png", ".webp", ".heic", ".image"].contains(where: { path.hasSuffix($0) }) || path.contains("~tplv") { return false }
        return ["douyinvod", "aweme/v1/play", "video_id=", "mime_type=video", ".mp4"].contains { url.contains($0) }
    }

    /// 实况照片的视频部分：与图片同名加 _live 后缀，App 据此把两者配成一张实况照片存入相册
    static func liveMedia(_ url: String, stem: String, headers: [String: String]) -> VideoMedia? {
        guard !url.isEmpty else { return nil }
        return VideoMedia(url: url.replacingOccurrences(of: "/playwm/", with: "/play/").replacingOccurrences(of: "playwm", with: "play"),
                          kind: .video, fileName: "\(stem)_live.mp4", headers: headers, quality: "实况")
    }

    struct Quality: Equatable {
        let url: String
        let shortSide: Int
        let bitrate: Int
        let size: Int64
        let hevc: Bool

        var label: String { (shortSide > 0 ? "\(shortSide)P" : "默认") + (hevc ? " · HEVC" : "") }
    }

    /// 作品数据里的 bit_rate 列表 → 各档清晰度（最高在前）。同一分辨率只留一条：优先 H.264（兼容最好），同编码取码率高的
    static func qualities(_ bitRates: [JSON]) -> [Quality] {
        var best: [Int: Quality] = [:]
        for item in bitRates {
            let play = item.object("play_addr", "playAddr")
            // 图文作品的 video 其实是背景音乐（mp3 / douyinstatic），不算清晰度
            guard let url = play.arrayValue("url_list", "urlList").map({ $0.string }).first(where: { !$0.isEmpty }),
                  !url.contains("douyinstatic"), !url.substringBefore("?").hasSuffix(".mp3") else { continue }
            let side = min(play["width"].int, play["height"].int)
            let hevc = item["is_bytevc1"].int == 1 || item["is_h265"].int == 1
            let q = Quality(url: url.replacingOccurrences(of: "playwm", with: "play"), shortSide: side,
                            bitrate: item.has("bit_rate") ? item["bit_rate"].int : item["bitRate"].int,
                            size: play.has("data_size") ? play["data_size"].int64 : play["dataSize"].int64, hevc: hevc)
            if let current = best[side] {
                let better = (!q.hevc && current.hevc) || (q.hevc == current.hevc && q.bitrate > current.bitrate)
                if !better { continue }
            }
            best[side] = q
        }
        return best.keys.sorted(by: >).compactMap { best[$0] }
    }

    /// 视频的各档清晰度：有 bit_rate 列表就全列出来（最高画质默认选中）；
    /// 同时探测「原画」（上传者的原始文件，见 probeOriginal），比列表里最高档大时排在最前、默认选中。
    /// 列表为空时按分辨率逐档探测播放接口，取文件最大的那一档（参考 ParseHub）
    private func videoMedias(base: String, bitRates: [JSON], fallback: String, uri: String, needCookie: Bool = false) async -> [VideoMedia] {
        async let probedOriginal = Self.probeOriginal(uri: uri, needCookie: needCookie)
        var list = Self.qualities(bitRates)
        if list.isEmpty, !uri.isEmpty, let probed = await Self.probeBest(uri: uri) {
            list = [Quality(url: probed.url, shortSide: 0, bitrate: 0, size: probed.size, hevc: false)]
        }
        if list.isEmpty, !fallback.isEmpty {
            list = [Quality(url: fallback, shortSide: 0, bitrate: 0, size: -1, hevc: false)]
        }
        var labels = list.map(\.label)
        if list.count == 1 && list[0].shortSide == 0 { labels = [list[0].size > 0 ? "最高画质" : ""] }
        if let original = await probedOriginal, Self.shouldPromote(original: original.size, top: list.first?.size ?? -1) {
            list.insert(Quality(url: original.url, shortSide: 0, bitrate: 0, size: original.size, hevc: original.hevc), at: 0)
            labels.insert("原画" + (original.hevc ? " · HEVC" : ""), at: 0)
        }
        let group = list.count > 1 ? "video" : ""
        return list.enumerated().map { i, q in
            let suffix = q.shortSide > 0 ? "\(q.shortSide)P" : "v\(i + 1)"
            return VideoMedia(url: q.url, kind: .video, fileName: i == 0 ? "\(base).mp4" : "\(base)_\(suffix).mp4",
                              size: q.size > 0 ? q.size : -1, headers: mediaHeaders, quality: labels[i], variantGroup: group)
        }
    }

    /// 原画只在比列表里最高一档大（或那档大小未知）时提到最前：有的作品「超分」档反而比原文件大（参考 jiji262/douyin-downloader）
    static func shouldPromote(original: Int64, top: Int64) -> Bool {
        original > 1024 && (top <= 0 || original > top)
    }

    /// 原画：播放接口 ratio=default 会跳到上传者的原始文件（可能是 4K / 60 帧 HEVC），bit_rate 列表里没有它
    /// （参考 zyipeng/video-downloader、jiji262/douyin-downloader，MIT）。用 HEAD 跟随跳转，只认视频类型，
    /// 取跳转后的 CDN 地址与大小；不需要登录
    static func probeOriginal(uri: String, needCookie: Bool) async -> (url: String, size: Int64, hevc: Bool)? {
        guard !uri.isEmpty else { return nil }
        var url = "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(uri.formEncoded)&ratio=default&line=0&is_play_url=1"
            + "&watermark=0&source=PackSourceEnum_PUBLISH"
        if needCookie { url += "&ss_is_p_v_ss=1" }
        guard let r = try? await HTTPClient.shared.send(HTTPRequest(url: url, method: "HEAD", headers: [
            ("User-Agent", VideoHTTP.uaIPhone), ("Referer", "https://www.douyin.com/")
        ], timeout: 10)), r.isSuccess, (r.header("Content-Type") ?? "").lowercased().hasPrefix("video/") else { return nil }
        let size = Int64(r.header("Content-Length") ?? "") ?? 0
        guard size > 1024 else { return nil }
        let final = r.url.isEmpty ? url : r.url
        let lower = final.lowercased()
        return (final, size, lower.contains("bytevc1") || lower.contains("hevc") || lower.contains("h265"))
    }

    /// 逐档 HEAD 探测无水印播放接口，取 Content-Length 最大的
    static func probeBest(uri: String) async -> (url: String, size: Int64)? {
        var best: (url: String, size: Int64)?
        for ratio in ["1080p", "720p", "540p"] {
            let url = "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(uri.formEncoded)&ratio=\(ratio)&line=0"
            guard let r = try? await HTTPClient.shared.send(HTTPRequest(url: url, method: "HEAD", headers: [
                ("User-Agent", VideoHTTP.uaChrome), ("Referer", "https://www.douyin.com/")
            ], timeout: 10)), r.isSuccess else { continue }
            let size = Int64(r.header("Content-Length") ?? "") ?? 0
            if size > (best?.size ?? 0) { best = (url, size) }
        }
        return best
    }

    static func imageExtension(_ url: String) -> String {
        if url.contains(".webp") { return ".webp" }
        if url.contains(".png") { return ".png" }
        return ".jpg"
    }

    /// 文档开始前注入：把页面自己发出的 aweme/detail 响应原文存到 window.__cloudnAwemeDetail
    static let detailHookJS = #"""
    (function () {
      try {
        if (window.__cloudnHook) return;
        window.__cloudnHook = true;
        var keep = function (url, text) {
          if (url && url.indexOf('aweme/v1/web/aweme/detail') >= 0 && text) window.__cloudnAwemeDetail = text;
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
              try { if (url.indexOf('aweme/v1/web/aweme/detail') >= 0) resp.clone().text().then(function (t) { keep(url, t); }); } catch (e) {}
              return resp;
            });
          };
        }
      } catch (e) {}
    })();
    """#

    /// 视频：等到钩住作品接口的响应。图文：作品接口的响应（实况图的视频只在那里）到了就好；
    /// 页面没自己请求时，图片出现 1.5 秒后由页面代发一次（页面的安全脚本会给它补上签名参数），
    /// 再等不到就在图片出现 8 秒后只用页面上的图片
    static func readyJS(_ type: String, id: String) -> String {
        if type == "video" {
            return "(function(){var r=window.__cloudnAwemeDetail;return (typeof r==='string'&&r.length>0);})()"
        }
        let safeID = id.filter { $0.isNumber }
        return #"""
        (function () {
          if (window.__cloudnAwemeDetail) return true;
          var now = Date.now();
          var has = false;
          var imgs = document.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            var s = imgs[i].src || '';
            if (s.indexOf('douyinpic.com') >= 0 && s.indexOf('WEBPC_RELATED') < 0 &&
                (s.indexOf('tplv-dy-aweme-images') >= 0 || s.indexOf('PackSourceEnum_AWEME_DETAIL') >= 0)) { has = true; break; }
          }
          if (!has) return false;
          if (!window.__cloudnImgAt) window.__cloudnImgAt = now;
          if (!window.__cloudnAsked && now - window.__cloudnImgAt > 1500) {
            window.__cloudnAsked = true;
            try {
              var x = new XMLHttpRequest();
              x.open('GET', '/aweme/v1/web/aweme/detail/?device_platform=webapp&aid=6383&channel=channel_pc_web&aweme_id=\#(safeID)');
              x.withCredentials = true;
              x.send();
            } catch (e) {}
          }
          return now - window.__cloudnImgAt > 8000;
        })()
        """#
    }

    /// 返回 JSON 字符串（WKWebView 回传对象会变成字典，统一 stringify 便于两端解析）
    static let extractJS = #"""
    (function () {
      try {
        var raw = window.__cloudnAwemeDetail || '';
        var d = null;
        if (raw) { try { var root = JSON.parse(raw); d = root.aweme_detail || (root.data && root.data.aweme_detail) || null; } catch (e) {} }
        // 没钩到接口时，试页面内嵌的 RENDER_DATA（URL 编码的 JSON），找带 images 的作品对象
        function findAweme(n, depth) {
          if (!n || typeof n !== 'object' || depth > 8) return null;
          if (!Array.isArray(n) && Array.isArray(n.images) && n.images.length && (n.awemeId || n.aweme_id || n.desc !== undefined)) return n;
          var list = Array.isArray(n) ? n : Object.keys(n).map(function (k) { return n[k]; });
          for (var i = 0; i < list.length; i++) { var r = findAweme(list[i], depth + 1); if (r) return r; }
          return null;
        }
        if (!d) {
          try {
            var rd = document.getElementById('RENDER_DATA');
            if (rd && rd.textContent) d = findAweme(JSON.parse(decodeURIComponent(rd.textContent)), 0);
          } catch (e) {}
        }
        function firstUrl(n) { if (!n) return ''; var l = n.url_list || n.urlList; return (l && l.length) ? String(l[0] || '') : ''; }
        // 实况图的视频：字段名各版本不一（video.play_addr / playAddr / bit_rate…），在这张图的数据里找第一个视频地址
        function isVideoUrl(u) { return /^https?:/.test(u) && /douyinvod|aweme\/v1\/play|video_id=|mime_type=video|\.mp4/.test(u) && !/\.(jpe?g|png|webp|heic|image)/.test(u.split('?')[0]); }
        function liveVideo(n, depth) {
          depth = depth || 0;
          if (n === null || n === undefined || depth > 6) return '';
          if (typeof n === 'string') return isVideoUrl(n) ? n : '';
          if (typeof n !== 'object') return '';
          var keys = Array.isArray(n) ? null : Object.keys(n);
          if (keys) { keys.sort(function (a, b) { return (b === 'video' ? 1 : 0) - (a === 'video' ? 1 : 0); }); }
          var list = keys ? keys.map(function (k) { return n[k]; }) : n;
          for (var i = 0; i < list.length; i++) { var r = liveVideo(list[i], depth + 1); if (r) return r; }
          return '';
        }
        var v = (d && d.video) || null, video = '';
        if (v) {
          video = firstUrl(v.play_addr) || firstUrl(v.playAddr) || firstUrl(v.play_addr_h264);
          if (!video && v.bit_rate) { for (var i = 0; i < v.bit_rate.length; i++) { var c = firstUrl(v.bit_rate[i].play_addr); if (c) { video = c; break; } } }
          video = video.replace('/playwm/', '/play/');
        }
        var images = [], lives = [];
        var src = (d && (d.images || (d.image_post_info && d.image_post_info.images))) || null;
        if (src) { for (var j = 0; j < src.length; j++) { var it = src[j]; var u = firstUrl(it) || firstUrl(it.display_image) || firstUrl(it.owner_watermark_image); if (u) {
          images.push(u);
          lives.push(liveVideo(it).replace('/playwm/', '/play/'));
        } } }
        var domImages = [];
        var all = document.querySelectorAll('img');
        for (var k = 0; k < all.length; k++) {
          var s = all[k].src || '';
          if (s.indexOf('douyinpic') < 0 || s.indexOf('WEBPC_RELATED') >= 0) continue;
          if ((s.indexOf('tplv-dy-aweme-images') >= 0 || s.indexOf('PackSourceEnum_AWEME_DETAIL') >= 0) && domImages.indexOf(s) < 0) domImages.push(s);
        }
        var title = (d && d.desc) || '';
        if (!title) { var t = document.title || ''; var p = t.lastIndexOf(' - 抖音'); title = p > 0 ? t.substring(0, p) : t; }
        return JSON.stringify({
          title: title, author: (d && d.author && (d.author.nickname || d.author.unique_id)) || '',
          authorID: (d && d.author && (d.author.unique_id || d.author.short_id || d.author.uniqueId || d.author.shortId)) || '',
          createTime: (d && (d.create_time || d.createTime)) || 0,
          video: video, images: images, lives: lives, domImages: domImages,
          cover: (v && (firstUrl(v.cover) || firstUrl(v.origin_cover))) || '',
          bitRates: (v && (v.bit_rate || v.bitRate)) || [],
          uri: (v && ((v.play_addr && v.play_addr.uri) || v.vid || (v.download_addr && v.download_addr.uri))) || '',
          needCookie: !!(v && v.is_need_set_cookie)
        });
      } catch (e) { return JSON.stringify({ error: 'js: ' + e }); }
    })()
    """#
}
