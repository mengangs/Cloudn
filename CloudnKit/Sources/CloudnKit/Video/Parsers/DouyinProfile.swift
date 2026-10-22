// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 抖音主页（www.douyin.com/user/{sec_uid}）批量：作品列表接口 aweme/v1/web/aweme/post 需要 a_bogus 签名，
/// 不自己实现——隐藏浏览器打开主页，钩住页面自己发出的分页响应，并自动下滑翻页，直到没有更多 / 到上限 / 超时。
extension DouyinParser {
    struct UserPosts {
        let entries: [VideoEntry]
        let nickname: String
        /// 最后一页仍有更多（被上限 / 超时 / 未登录限制截断）
        let hasMore: Bool
    }

    func parseUser(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let pageURL = Self.userPageURL(link.id)
        guard let extractor else {
            throw VideoParseError(.unsupported, "抖音主页需要用 App 内置的网页内核加载作品列表，当前环境不支持")
        }
        let hook = ProfileCollectionJS.hookScript(urlMarker: "aweme/v1/web/aweme/post", handler: Self.userPostHandlerJS,
                                                  cardSelector: Self.userCardSelector)
        let raw = await extractor.extract(url: pageURL, userAgent: VideoHTTP.uaChrome, cookie: cookie,
                                          documentStartScripts: [hook], readyScript: ProfileCollectionJS.readyScript,
                                          progressScript: ProfileCollectionJS.progressScript,
                                          extractScript: Self.userExtractJS, timeout: ProfileCollectionJS.extractorTimeout)
        guard let text = raw, let payload = JSON(text: text), payload["error"].string.isEmpty else {
            throw VideoParseError(.blocked, "抖音主页加载失败（可能需要网页验证），请稍后重试")
        }
        let posts = Self.userPosts([payload])
        guard !posts.entries.isEmpty else {
            throw VideoParseError(.notFound, "没有取到该抖音用户的作品（主页可能不公开、没有作品，或抖音要求验证）")
        }
        var nickname = posts.nickname
        if nickname.isEmpty { nickname = Self.nickname(fromPageTitle: payload["pageTitle"].string) }
        let title = nickname.isEmpty ? "抖音用户的作品" : "\(nickname) 的作品"
        CollectionProgress.report(fetched: posts.entries.count)
        var notice = ""
        if CollectionProgress.isStopRequested && posts.hasMore {
            notice = ProfileCollectionJS.stoppedNotice(posts.entries.count)
        } else if posts.entries.count >= ProfileCollectionJS.maxItems {
            notice = "作品较多，只列出了前 \(posts.entries.count) 个"
        } else if posts.hasMore || (!Self.isLoggedIn(cookie: cookie) && posts.entries.count <= Self.guestPageSize) {
            // 未登录时网页版常常只给第一页（约 18 个），还报「没有更多」
            notice = Self.isLoggedIn(cookie: cookie)
                ? "只加载到前 \(posts.entries.count) 个作品（抖音要求验证或加载超时），可稍后重试"
                : "未登录抖音时网页版通常只给第一页作品，到「我的」页登录抖音后可获取全部"
        }
        return VideoParseResult(platform: platform, title: title, author: nickname, cover: posts.entries.first?.cover ?? "",
                                url: pageURL, notice: notice, entries: posts.entries)
    }

    static func userPageURL(_ secUID: String) -> String { "https://www.douyin.com/user/\(secUID)" }

    /// 未登录时主页第一页的作品数
    static let guestPageSize = 20

    /// 网页登录后才有 sessionid（游客没有）
    static func isLoggedIn(cookie: String) -> Bool {
        cookie.range(of: #"(^|;\s*)sessionid(_ss)?=[^;]+"#, options: .regularExpression) != nil
    }

    /// 账号校验：passport 接口给出昵称；接口不认识时只要有 sessionid 就先当作有效（取主页时再看效果）
    static func validate(cookie: String) async -> String? {
        guard isLoggedIn(cookie: cookie) else { return nil }
        let headers = [("User-Agent", VideoHTTP.uaChrome), ("Cookie", cookie), ("Referer", "https://www.douyin.com/")]
        if let r = try? await VideoHTTP.send(.get("https://www.douyin.com/passport/web/account/info/", headers: headers)),
           let json = r.json, json["message"].string == "success" {
            return json["data"].string("screen_name", "name").nilIfBlank ?? "抖音用户"
        }
        return "抖音用户"
    }

    /// 作品链接：图文走 /note/，其余走 /video/（两者都能被 VideoLinkParser 识别）
    static func workURL(id: String, note: Bool) -> String {
        "https://www.douyin.com/\(note ? "note" : "video")/\(id)"
    }

    /// aweme/post 的一页或多页（也接受钩子脚本汇总后的同形 JSON）→ 作品条目，按 aweme_id 去重、保持顺序
    static func userPosts(_ pages: [JSON]) -> UserPosts {
        var entries: [VideoEntry] = []
        var seen = Set<String>()
        var nickname = ""
        var hasMore = false
        for page in pages {
            for aweme in page["aweme_list"].array {
                let id = aweme["aweme_id"].string
                guard !id.isEmpty else { continue }
                if nickname.isEmpty { nickname = aweme["author"]["nickname"].string }
                guard seen.insert(id).inserted else { continue }
                entries.append(userEntry(aweme, id: id))
            }
            if page.has("has_more") { hasMore = page["has_more"].bool }
        }
        if nickname.isEmpty {
            nickname = pages.map { $0["nickname"].string }.first(where: { !$0.isEmpty }) ?? ""
        }
        return UserPosts(entries: entries, nickname: nickname.trimmed, hasMore: hasMore)
    }

    static func userEntry(_ aweme: JSON, id: String) -> VideoEntry {
        let note = isNote(aweme)
        let video = aweme["video"]
        var ms = aweme["duration"].double
        if ms <= 0 { ms = video["duration"].double }
        var cover = video["cover"]["url_list"][0].string
        if cover.isEmpty { cover = video["origin_cover"]["url_list"][0].string }
        if cover.isEmpty { cover = aweme["images"][0]["url_list"][0].string }
        let desc = aweme["desc"].string.trimmed
        let fallback = note ? "图文 \(id)" : "视频 \(id)"
        let title = desc.isEmpty ? fallback : desc
        let duration: Double? = (!note && ms > 0) ? ms / 1000 : nil
        return VideoEntry(title: title, url: workURL(id: id, note: note), duration: duration, cover: cover)
    }

    /// 图文：带 images（或 image_post_info.images），或 aweme_type 为图集类（2 / 68 / 150）
    static func isNote(_ aweme: JSON) -> Bool {
        if !aweme["images"].array.isEmpty { return true }
        if !aweme["image_post_info"]["images"].array.isEmpty { return true }
        let type = aweme["aweme_type"].int
        return type == 2 || type == 68 || type == 150
    }

    /// 网页标题「某某的抖音 - 抖音」→「某某」
    static func nickname(fromPageTitle title: String) -> String {
        var t = title.trimmed
        if let r = t.range(of: " - 抖音", options: .backwards) { t = String(t[..<r.lowerBound]) }
        if t.hasSuffix("的抖音") { t = String(t.dropLast(3)) }
        return t == "抖音" ? "" : t.trimmed
    }

    static let userCardSelector = #"[data-e2e="user-post-list"] li, a[href*="/video/"], a[href*="/note/"]"#

    /// 钩子处理函数体（见 ProfileCollectionJS.hookScript）：只留下列表需要的字段，形状与接口原文一致
    static let userPostHandlerJS = #"""
    var list = root.aweme_list;
    if (!list || typeof list.length !== 'number') return false;
    var first = function (n) { return (n && n.url_list && n.url_list.length) ? String(n.url_list[0] || '') : ''; };
    for (var i = 0; i < list.length; i++) {
      var a = list[i];
      if (!a || !a.aweme_id) continue;
      var id = String(a.aweme_id);
      if (!S.nickname && a.author && a.author.nickname) S.nickname = String(a.author.nickname);
      if (S.seen[id]) continue;
      S.seen[id] = 1;
      var v = a.video || {};
      var cover = first(v.cover) || first(v.origin_cover);
      var imgs = a.images || (a.image_post_info && a.image_post_info.images) || null;
      var img0 = '';
      if (imgs && imgs.length) img0 = first(imgs[0]) || first(imgs[0].display_image);
      S.list.push({
        aweme_id: id, desc: a.desc || '', aweme_type: a.aweme_type || 0, duration: a.duration || v.duration || 0,
        video: { cover: { url_list: cover ? [cover] : [] } },
        images: (imgs && imgs.length) ? [{ url_list: img0 ? [img0] : [] }] : [],
        author: { nickname: (a.author && a.author.nickname) || '' }
      });
    }
    S.hasMore = !(root.has_more === 0 || root.has_more === false);
    return true;
    """#

    static let userExtractJS = #"""
    (function () {
      try {
        var S = window.__cloudnProfile || { list: [], pages: 0, hasMore: true, nickname: '' };
        return JSON.stringify({ aweme_list: S.list, has_more: S.hasMore ? 1 : 0, pages: S.pages,
                                nickname: S.nickname, pageTitle: document.title || '' });
      } catch (e) { return JSON.stringify({ error: 'js: ' + e }); }
    })()
    """#
}

/// 应用层用的抖音登录态判断（解析器本身不公开）
public enum DouyinAccount {
    public static func looksLoggedIn(cookie: String) -> Bool { DouyinParser.isLoggedIn(cookie: cookie) }
}
