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
        let type = Rx(#"/(?:share/)?(note|slides)/"#).first(in: link.url) == nil ? "video" : "note"
        if let extractor,
           let text = await extractor.extract(url: "https://www.douyin.com/\(type)/\(link.id)", userAgent: VideoHTTP.uaChrome,
                                              documentStartScripts: [Self.detailHookJS], readyScript: Self.readyJS(type),
                                              extractScript: Self.extractJS, timeout: 40),
           let payload = JSON(text: text), payload["error"].string.isEmpty {
            if let result = build(link, payload) { return result }
        }
        return try await parseSSR(link, type: type)
    }

    private var mediaHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaIPhone, "Referer": "https://www.douyin.com/"]
    }

    private func build(_ link: DetectedVideoLink, _ p: JSON) -> VideoParseResult? {
        var images = p["images"].array.map { $0.string }.filter { !$0.isEmpty }
        if images.isEmpty { images = p["domImages"].array.map { $0.string }.filter { !$0.isEmpty } }
        let video = p["video"].string
        guard !images.isEmpty || !video.isEmpty else { return nil }
        let title = p["title"].string
        let base = FileNames.base(title, fallback: "douyin_\(link.id)")
        let medias: [VideoMedia]
        if !images.isEmpty {
            medias = images.enumerated().map { i, url in
                VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1)\(Self.imageExtension(url))", headers: mediaHeaders)
            }
        } else {
            medias = [VideoMedia(url: video, kind: .video, fileName: "\(base).mp4", headers: mediaHeaders)]
        }
        let cover = p["cover"].string
        return VideoParseResult(platform: platform, title: title, author: p["author"].string,
                                cover: cover.isEmpty ? (images.first ?? "") : cover, url: link.url, medias: medias)
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
            }
        } else {
            let play = item["video"].object("play_addr", "playAddr")
            if let url = play.arrayValue("url_list", "urlList").map({ $0.string }).first(where: { !$0.isEmpty }) {
                // playwm → play：去水印的关键一步
                medias.append(VideoMedia(url: url.replacingOccurrences(of: "playwm", with: "play"), kind: .video,
                                         fileName: "\(base).mp4", headers: mediaHeaders))
            }
            cover = item["video"]["cover"]["url_list"][0].string
        }
        let author = item["author"]
        return VideoParseResult(platform: platform, title: title, author: author["nickname"].string,
                                avatar: author.object("avatar_thumb", "avatar_medium")["url_list"][0].string,
                                cover: cover, timestamp: item["create_time"].int64, url: link.url, medias: medias)
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

    static func readyJS(_ type: String) -> String {
        if type == "video" {
            return "(function(){var r=window.__cloudnAwemeDetail;return (typeof r==='string'&&r.length>0);})()"
        }
        return #"""
        (function () {
          var imgs = document.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            var s = imgs[i].src || '';
            if (s.indexOf('douyinpic.com') >= 0 && s.indexOf('WEBPC_RELATED') < 0 &&
                (s.indexOf('tplv-dy-aweme-images') >= 0 || s.indexOf('PackSourceEnum_AWEME_DETAIL') >= 0)) return true;
          }
          return !!window.__cloudnAwemeDetail;
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
        function firstUrl(n) { if (!n) return ''; var l = n.url_list || n.urlList; return (l && l.length) ? String(l[0] || '') : ''; }
        var v = (d && d.video) || null, video = '';
        if (v) {
          video = firstUrl(v.play_addr) || firstUrl(v.playAddr) || firstUrl(v.play_addr_h264);
          if (!video && v.bit_rate) { for (var i = 0; i < v.bit_rate.length; i++) { var c = firstUrl(v.bit_rate[i].play_addr); if (c) { video = c; break; } } }
          video = video.replace('/playwm/', '/play/');
        }
        var images = [];
        var src = (d && (d.images || (d.image_post_info && d.image_post_info.images))) || null;
        if (src) { for (var j = 0; j < src.length; j++) { var it = src[j]; var u = firstUrl(it) || firstUrl(it.display_image) || firstUrl(it.owner_watermark_image); if (u) images.push(u); } }
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
          video: video, images: images, domImages: domImages,
          cover: (v && (firstUrl(v.cover) || firstUrl(v.origin_cover))) || ''
        });
      } catch (e) { return JSON.stringify({ error: 'js: ' + e }); }
    })()
    """#
}
