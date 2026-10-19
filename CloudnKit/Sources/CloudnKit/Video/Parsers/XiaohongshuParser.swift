// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 XhsParser。
import Foundation

/// 小红书笔记：请求分享页，从内嵌的 `window.__INITIAL_STATE__` 取数据。
///
/// - 网页端笔记页对未登录会话一律拦截（302 到 `/login` 或 `/website-login/captcha`），所以需要登录 Cookie；
/// - 分享链接里的 `xsec_token` 必须原样带上，否则同样落到登录墙；
/// - explore 与 discovery 两种页面的 JSON 结构不同，先试 explore（桌面 UA），失败再试 discovery（iPhone UA）。
struct XiaohongshuParser: VideoParser {
    let platform = VideoPlatform.xiaohongshu

    static let home = "https://www.xiaohongshu.com"
    /// 原图 CDN：按图片 ID 取不带处理规格（无水印、不压 webp）的原图
    static let imageCDN = "https://sns-img-bd.xhscdn.com"
    static let accept = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"
    /// 最终地址命中这些片段 = 被登录墙 / 风控拦下（不是笔记被删）
    static let loginWallMarkers = ["/login", "website-login", "captcha"]
    /// h265 无水印优先
    static let streamOrder = [("h265", "H.265"), ("h264", "H.264"), ("av1", "AV1"), ("h266", "H.266")]

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            return try await parseExplore(link, cookie: cookie)
        } catch let e as VideoParseError where e.kind == .unsupported {
            // 登录墙对两条路径一样，换路径也过不去
            throw e
        } catch {
            return try await parseDiscovery(link, cookie: cookie)
        }
    }

    // MARK: 两种页面

    private func parseExplore(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let html = try await fetchPage("\(Self.home)/explore/\(link.id)\(Self.query(of: link.url))", headers: exploreHeaders(cookie))
        let state = try Self.initialState(html)
        let note = state["note"]["noteDetailMap"][link.id]["note"]
        guard note.isObject else { throw VideoParseError(.notFound, "小红书页面里没有该笔记数据") }
        return try await build(link, note: note, author: note["user"]["nickname"].string, coverCandidates: [], cookie: cookie)
    }

    private func parseDiscovery(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let html = try await fetchPage("\(Self.home)/discovery/item/\(link.id)\(Self.query(of: link.url))", headers: discoveryHeaders(cookie))
        let root = try Self.initialState(html)["noteData"]
        // discovery 比 explore 多嵌一层：noteData.data.noteData
        let note = root["data"]["noteData"]
        guard note.isObject else { throw VideoParseError(.notFound, "小红书分享链接失效或内容已删除") }
        let preload = root["normalNotePreloadData"]["imagesList"].array.map { $0.string("urlSizeLarge", "url") }.filter { !$0.isEmpty }
        // discovery 形态的昵称字段是大写 N 的 nickName
        return try await build(link, note: note, author: note["user"]["nickName"].string, coverCandidates: preload, cookie: cookie)
    }

    private func build(_ link: DetectedVideoLink, note: JSON, author: String, coverCandidates: [String], cookie: String) async throws -> VideoParseResult {
        let headers = mediaHeaders(cookie)
        let title = note["title"].string
        let base = FileNames.base(title, fallback: "xiaohongshu_\(link.id)")
        let rawImages = note["imageList"].array.map(Self.rawImageURL).filter { !$0.isEmpty }
        var medias: [VideoMedia] = []
        var cover = ""
        var notice = ""
        if let video = Self.pickVideo(note) {
            cover = Self.watermarkFree((coverCandidates.isEmpty ? rawImages : coverCandidates).first ?? "")
            medias.append(VideoMedia(url: video.url, kind: .video, fileName: "\(base).mp4", headers: headers, quality: video.quality))
        } else if note["video"].isObject {
            // 是视频笔记却没取到直链：明确报错，别把封面当成作品图返回
            throw VideoParseError(.unknown, "小红书视频笔记没有取到视频直链")
        } else {
            let resolved = await resolveImages(rawImages, headers: headers)
            for (i, url) in resolved.urls.enumerated() {
                medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1).jpg", headers: headers, quality: "原图"))
            }
            if resolved.fallbacks > 0 { notice = "\(resolved.fallbacks) 张图片没有可用的去水印原图，已改用平台地址（可能带水印）" }
            cover = resolved.urls.first ?? ""
        }
        guard !medias.isEmpty else { throw VideoParseError(.notFound, "小红书笔记里没有可下载的内容") }
        return VideoParseResult(platform: .xiaohongshu, title: title, author: author, avatar: note["user"]["avatar"].string,
                                cover: cover, text: note["desc"].string, timestamp: note["time"].int64 / 1000, url: link.url,
                                medias: medias, notice: notice)
    }

    // MARK: 请求

    /// 取页面，并先识别「被登录墙拦住」：此时页面里没有数据，不能报成「内容不存在」
    private func fetchPage(_ url: String, headers: [String: String]) async throws -> String {
        let r = try await VideoHTTP.send(.get(url, headers: headers.sortedPairs))
        if Self.isLoginWall(r.url) {
            throw VideoParseError(.unsupported, "小红书要求登录后才能查看笔记内容，请先到「我的」页登录小红书")
        }
        try VideoHTTP.requireSuccess(r, "小红书笔记")
        return r.text
    }

    static func isLoginWall(_ url: String) -> Bool { loginWallMarkers.contains { url.contains($0) } }

    private func exploreHeaders(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaChrome, "Accept": Self.accept, "Referer": Self.home + "/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func discoveryHeaders(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaIPhone, "Accept": Self.accept, "Referer": Self.home + "/", "Origin": Self.home,
                 "X-Requested-With": "XMLHttpRequest", "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func mediaHeaders(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.home + "/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    /// 校验登录态：带 Cookie 请求首页，未登录会被 302 到登录页（游客也会被种 web_session，不能只看 Cookie 名）
    static func validate(cookie: String) async -> String? {
        guard !cookie.isEmpty,
              let r = try? await HTTPClient.shared.send(.get(home + "/explore", headers: [("User-Agent", VideoHTTP.uaChrome), ("Cookie", cookie)])),
              r.isSuccess, !isLoginWall(r.url) else { return nil }
        return "小红书用户"
    }

    // MARK: 解析

    /// 原分享链接的查询串（含 xsec_token），重建地址时原样带上
    static func query(of url: String) -> String {
        guard let i = url.firstIndex(of: "?") else { return "" }
        let q = String(url[url.index(after: i)...]).substringBefore("#")
        return q.isEmpty ? "" : "?" + q
    }

    /// `window.__INITIAL_STATE__`；JSON 里混有裸的 `undefined`，先替换成 null
    static func initialState(_ html: String) throws -> JSON {
        guard let raw = VideoHTTP.extractInlineJSON(html, key: "window.__INITIAL_STATE__") else {
            throw VideoParseError(.unknown, "小红书页面里没有笔记数据（可能被风控拦截或页面改版）")
        }
        let fixed = Rx(#"(?<=[:\[,])\s*undefined\s*(?=[,\]}])"#).replacing(in: raw, with: "null")
        guard let json = JSON(text: fixed), json.isObject else { throw VideoParseError(.unknown, "小红书页面数据解析失败") }
        return json
    }

    static func pickVideo(_ note: JSON) -> (url: String, quality: String)? {
        let stream = note["video"]["media"]["stream"]
        for (key, label) in streamOrder {
            let first = stream[key][0]
            let url = first.string("masterUrl", "master_url")
            if !url.isEmpty { return (url, label) }
        }
        return nil
    }

    /// 图集里一张图的原始地址（explore 是 urlDefault，discovery 是 url），带水印，只作换算输入
    static func rawImageURL(_ item: JSON) -> String { item.string("urlDefault", "url") }

    /// 换算成去水印原图：丢掉 host 后前两段路径（时间桶 + 散列），再截掉 "!" 起的处理规格；取不到图片 ID 原样返回
    static func watermarkFree(_ raw: String) -> String {
        guard let schemeEnd = raw.range(of: "://") else { return raw }
        let afterHost = raw[schemeEnd.upperBound...].drop(while: { $0 != "/" }).dropFirst()
        let id = afterHost.split(separator: "/", omittingEmptySubsequences: false).dropFirst(2).joined(separator: "/").substringBefore("!")
        return id.isEmpty ? raw : "\(imageCDN)/\(id)"
    }

    /// 逐张换算成原图并并发 HEAD 探测：原图 404 / 410 时回退到原始地址（宁可带水印也要能下）
    private func resolveImages(_ raws: [String], headers: [String: String]) async -> (urls: [String], fallbacks: Int) {
        let results = await withTaskGroup(of: (Int, String, Bool).self) { group in
            for (i, raw) in raws.enumerated() {
                group.addTask {
                    let clean = Self.watermarkFree(raw)
                    guard clean != raw else { return (i, raw, false) }
                    let r = try? await HTTPClient.shared.send(HTTPRequest(url: clean, method: "HEAD", headers: headers.sortedPairs))
                    // 只认 404 / 410：超时、405 等都不代表图没了
                    if let status = r?.status, status == 404 || status == 410 { return (i, raw, true) }
                    return (i, clean, false)
                }
            }
            var out: [(Int, String, Bool)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }
        return (results.map(\.1), results.filter(\.2).count)
    }
}
