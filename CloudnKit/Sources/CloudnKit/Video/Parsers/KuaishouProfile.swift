// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 kuaishou 解析（www.kuaishou.com/graphql 与网页游客 Cookie）。
import Foundation

/// 快手主页（www.kuaishou.com/profile/{principalId}）批量：
/// 1. 直连网页版 GraphQL visionProfilePhotoList，按 pcursor 翻页（游客 Cookie 即可，但常被要求验证）；
/// 2. 拿不到时隐藏浏览器打开主页，钩住页面自己发出的同名 GraphQL 响应并自动下滑翻页。
extension KuaishouParser {
    struct ProfilePosts {
        let entries: [VideoEntry]
        let author: String
        /// 最后一页仍有更多（被上限 / 超时 / 验证截断）
        let hasMore: Bool
    }

    struct ProfilePage {
        /// 接口正常返回了列表
        let ok: Bool
        let pcursor: String
        let feedCount: Int
        /// 需要验证（captcha）
        let needsVerify: Bool

        var hasMore: Bool { !pcursor.isEmpty && pcursor != "no_more" }
    }

    static let graphqlURL = "https://www.kuaishou.com/graphql"
    /// ParseHub 里网页版的游客设备标识部分（不含其中的登录态字段）
    static let guestCookie = "kpf=PC_WEB; clientid=3; kpn=KUAISHOU_VISION; did=web_bfbcdb2f5b3dc663a745deabafcf61e6"

    func parseProfile(_ userId: String, cookie: String) async throws -> VideoParseResult {
        let pageURL = Self.profileURL(userId)
        let httpPages = await fetchProfilePages(userId, cookie: cookie)
        var posts = Self.profilePosts(httpPages)
        if posts.entries.isEmpty, let extractor {
            let hook = ProfileCollectionJS.hookScript(urlMarker: "/graphql", handler: Self.profileHandlerJS,
                                                      cardSelector: Self.profileCardSelector)
            let raw = await extractor.extract(url: pageURL, userAgent: VideoHTTP.uaChrome, cookie: cookie,
                                              documentStartScripts: [hook], readyScript: ProfileCollectionJS.readyScript,
                                              extractScript: Self.profileExtractJS, timeout: ProfileCollectionJS.extractorTimeout)
            if let text = raw, let payload = JSON(text: text), payload["error"].string.isEmpty {
                posts = Self.profilePosts([payload])
            }
        }
        guard !posts.entries.isEmpty else {
            if extractor == nil {
                throw VideoParseError(.unsupported, "快手主页接口要求验证，当前环境没有可用的网页内核来加载作品列表")
            }
            throw VideoParseError(.blocked, "没有取到该快手用户的作品（主页可能不公开、没有作品，或快手要求验证），请稍后重试")
        }
        let title = posts.author.isEmpty ? "快手用户的作品" : "\(posts.author) 的作品"
        var notice = ""
        if posts.entries.count >= ProfileCollectionJS.maxItems {
            notice = "作品较多，只列出了前 \(posts.entries.count) 个"
        } else if posts.hasMore {
            notice = "只加载到前 \(posts.entries.count) 个作品（快手要求验证或加载超时），可稍后重试"
        }
        return VideoParseResult(platform: platform, title: title, author: posts.author, cover: posts.entries.first?.cover ?? "",
                                url: pageURL, notice: notice, entries: posts.entries)
    }

    /// 直连 GraphQL 逐页取，出错 / 要验证 / 到上限 / 超时即停，返回已拿到的各页原文
    private func fetchProfilePages(_ userId: String, cookie: String) async -> [JSON] {
        let headers: [(String, String)] = [
            ("User-Agent", VideoHTTP.uaChrome),
            ("Accept", "*/*"),
            ("Origin", "https://www.kuaishou.com"),
            ("Referer", Self.profileURL(userId)),
            ("Cookie", cookie.isEmpty ? Self.guestCookie : cookie)
        ]
        var pages: [JSON] = []
        var cursor = ""
        var count = 0
        let deadline = Date().addingTimeInterval(40)
        for _ in 0..<40 {
            let request = HTTPRequest.postJSON(Self.graphqlURL, Self.profileQueryBody(userId: userId, pcursor: cursor), headers: headers)
            guard let r = try? await VideoHTTP.send(request), r.isSuccess, let json = JSON(text: r.text) else { break }
            let page = Self.profilePage(json)
            guard page.ok else { break }
            pages.append(json)
            count += page.feedCount
            if !page.hasMore || page.feedCount == 0 || count >= ProfileCollectionJS.maxItems || Date() > deadline { break }
            cursor = page.pcursor
        }
        return pages
    }

    static func profileURL(_ userId: String) -> String { "https://www.kuaishou.com/profile/\(userId)" }

    static func photoURL(_ photoId: String) -> String { "https://www.kuaishou.com/short-video/\(photoId)" }

    /// 主页链接（含短链展开后的移动端 /fw/user/）里的用户 id
    static func profileID(in url: String) -> String? {
        Rx(#"^https?://[^/?#\s]+/(?:profile|fw/user)/([A-Za-z\d_\-]+)"#, ignoreCase: true).first(in: url)
    }

    static func profileQueryBody(userId: String, pcursor: String) -> [String: Any] {
        [
            "operationName": "visionProfilePhotoList",
            "variables": ["userId": userId, "pcursor": pcursor, "page": "profile"] as [String: Any],
            "query": profileQuery
        ]
    }

    static func profilePage(_ root: JSON) -> ProfilePage {
        let messages = root["errors"].array.map { $0["message"].string }
        let verify = messages.contains(where: { $0.lowercased().contains("captcha") })
        let list = root["data"]["visionProfilePhotoList"]
        let feeds = list["feeds"].array
        let ok = messages.isEmpty && list.isObject && (list["result"].int == 1 || !feeds.isEmpty)
        return ProfilePage(ok: ok, pcursor: list["pcursor"].string, feedCount: feeds.count, needsVerify: verify)
    }

    /// visionProfilePhotoList 的一页或多页（也接受钩子脚本汇总后的同形 JSON）→ 作品条目，按 photo.id 去重、保持顺序
    static func profilePosts(_ pages: [JSON]) -> ProfilePosts {
        var entries: [VideoEntry] = []
        var seen = Set<String>()
        var author = ""
        var hasMore = false
        for page in pages {
            let list = page["data"]["visionProfilePhotoList"]
            for feed in list["feeds"].array {
                let photo = feed["photo"]
                let id = photo["id"].string
                guard !id.isEmpty else { continue }
                if author.isEmpty { author = feed["author"]["name"].string }
                guard seen.insert(id).inserted else { continue }
                entries.append(profileEntry(photo, id: id))
            }
            if list.isObject {
                let cursor = list["pcursor"].string
                hasMore = !cursor.isEmpty && cursor != "no_more"
            }
        }
        let cleaned = author.replacingOccurrences(of: "\u{3164}", with: "").trimmed
        return ProfilePosts(entries: entries, author: cleaned, hasMore: hasMore)
    }

    static func profileEntry(_ photo: JSON, id: String) -> VideoEntry {
        let caption = photo["caption"].string.trimmed
        let title = caption.isEmpty ? "作品 \(id)" : caption
        let ms = photo["duration"].double
        let duration: Double? = ms > 0 ? ms / 1000 : nil
        return VideoEntry(title: title, url: photoURL(id), duration: duration, cover: photo["coverUrl"].string)
    }

    /// 只取列表需要的字段（字段名对齐 ParseHub 的 visionVideoDetail 查询里同一个 photo / author 类型）
    static let profileQuery = """
    query visionProfilePhotoList($pcursor: String, $userId: String, $page: String, $webPageArea: String) {
      visionProfilePhotoList(pcursor: $pcursor, userId: $userId, page: $page, webPageArea: $webPageArea) {
        result
        llsid
        webPageArea
        feeds {
          type
          author {
            id
            name
            following
            headerUrl
            __typename
          }
          photo {
            id
            duration
            caption
            likeCount
            realLikeCount
            coverUrl
            photoUrl
            timestamp
            expTag
            viewCount
            videoRatio
            __typename
          }
          __typename
        }
        hostName
        pcursor
        __typename
      }
    }
    """

    static let profileCardSelector = #".video-card, [class*="video-card"], .card-link"#

    /// 钩子处理函数体（见 ProfileCollectionJS.hookScript）：只认 visionProfilePhotoList，形状与接口原文一致
    static let profileHandlerJS = #"""
    var d = root.data && root.data.visionProfilePhotoList;
    if (!d || !d.feeds || typeof d.feeds.length !== 'number') return false;
    for (var i = 0; i < d.feeds.length; i++) {
      var f = d.feeds[i];
      var p = f && f.photo;
      if (!p || !p.id) continue;
      var id = String(p.id);
      if (!S.nickname && f.author && f.author.name) S.nickname = String(f.author.name);
      if (S.seen[id]) continue;
      S.seen[id] = 1;
      S.list.push({ photo: { id: id, caption: p.caption || '', duration: p.duration || 0, coverUrl: p.coverUrl || '' },
                    author: { name: (f.author && f.author.name) || '' } });
    }
    S.hasMore = !!(d.pcursor && d.pcursor !== 'no_more');
    return true;
    """#

    static let profileExtractJS = #"""
    (function () {
      try {
        var S = window.__cloudnProfile || { list: [], pages: 0, hasMore: true, nickname: '' };
        return JSON.stringify({ data: { visionProfilePhotoList: { result: 1, feeds: S.list, pcursor: S.hasMore ? 'more' : 'no_more' } },
                                pages: S.pages, nickname: S.nickname, pageTitle: document.title || '' });
      } catch (e) { return JSON.stringify({ error: 'js: ' + e }); }
    })()
    """#
}
