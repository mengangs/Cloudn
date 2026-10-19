// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 PixivParser。
import Foundation

/// Pixiv 插画 / 漫画：ajax/illust/{id} 取信息，ajax/illust/{id}/pages 取每页原图。
///
/// - 游客也能解析公开作品；R18 / 受限作品需要登录 Cookie（PHPSESSID）；
/// - 原图 CDN（i.pximg.net）有防盗链，下载必须带 Referer: https://www.pixiv.net/；
/// - 动图（ugoira，zip + 帧时长表）需要合成，暂不支持。
struct PixivParser: VideoParser {
    let platform = VideoPlatform.pixiv
    static let referer = "https://www.pixiv.net/"

    private func headers(_ cookie: String, json: Bool) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer]
        if json { h["Accept"] = "application/json" }
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let info = try await VideoHTTP.getJSON("https://www.pixiv.net/ajax/illust/\(link.id)", headers: headers(cookie, json: true), what: "Pixiv 作品信息")
        if info["error"].bool { throw Self.mapError(info["message"].string, hasCookie: !cookie.isEmpty) }
        let body = info["body"]
        guard body.isObject else { throw VideoParseError(.unknown, "Pixiv 作品信息缺少 body") }
        // illustType：0 插画 / 1 漫画 / 2 动图
        if body["illustType"].int == 2 { throw VideoParseError(.unsupported, "Pixiv 动图（ugoira）需要合成 GIF，暂不支持") }

        let pages = try await VideoHTTP.getJSON("https://www.pixiv.net/ajax/illust/\(link.id)/pages",
                                                headers: headers(cookie, json: true), what: "Pixiv 原图列表")["body"].array
        let title = body["title"].string
        let base = FileNames.base(title, fallback: "pixiv_\(link.id)")
        var originals = pages.map { $0["urls"]["original"].string }.filter { !$0.isEmpty }
        // pages 拿不到时至少用作品信息里的首图
        if originals.isEmpty, case let first = body["urls"]["original"].string, !first.isEmpty { originals = [first] }
        guard !originals.isEmpty else { throw VideoParseError(.notFound, "Pixiv 未返回任何可下载的原图") }

        let mediaHeaders = headers(cookie, json: false)
        let medias = originals.enumerated().map { i, url in
            let name = originals.count == 1 ? "\(base).\(Self.ext(url))" : "\(base)_\(i + 1).\(Self.ext(url))"
            return VideoMedia(url: url, kind: .image, fileName: name, headers: mediaHeaders, quality: "原图")
        }
        return VideoParseResult(platform: .pixiv, title: title, author: body["userName"].string, cover: medias[0].url,
                                text: Self.stripHTML(body["description"].string), timestamp: Self.timestamp(body["createDate"].string),
                                url: "https://www.pixiv.net/artworks/\(link.id)", medias: medias)
    }

    /// 服务端用同一个 error 表达「不存在」「登录失效」「受限作品」，按文案粗分给出可操作的提示
    static func mapError(_ message: String, hasCookie: Bool) -> VideoParseError {
        let lower = message.lowercased()
        if lower.contains("not found") || message.contains("削除") { return VideoParseError(.notFound, "Pixiv 作品不存在或已删除") }
        if lower.contains("login") || lower.contains("session") {
            return VideoParseError(.unsupported, "Pixiv 登录态已失效，请到「我的」页重新粘贴 Cookie")
        }
        if !hasCookie {
            return VideoParseError(.unsupported, "该作品需要登录后才能解析（多为 R18 或受限作品），请在「我的」页粘贴浏览器里的 Pixiv Cookie")
        }
        return VideoParseError(.blocked, "Pixiv 返回错误：\(message)")
    }

    /// 原图扩展名（jpg / png / gif）
    static func ext(_ url: String) -> String {
        let last = url.substringBefore("?").substringAfterLast("/")
        let e = last.contains(".") ? last.substringAfterLast(".").lowercased() : ""
        return !e.isEmpty && e.count <= 4 ? e : "jpg"
    }

    /// "2024-01-01T12:00:00+09:00" → 秒
    static func timestamp(_ text: String) -> Int64 {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text).map { Int64($0.timeIntervalSince1970) } ?? 0
    }

    static func stripHTML(_ html: String) -> String {
        let withBreaks = Rx(#"<br\s*/?>"#, ignoreCase: true).replacing(in: html, with: "\n")
        return Rx(#"<[^>]+>"#).replacing(in: withBreaks, with: "")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").trimmed
    }

    /// 登录态校验：未登录访问 /dashboard/works 会 302 回首页（带 return_to）。
    /// 游客打开首页就会被种 PHPSESSID，不能按 Cookie 名判断；探测本身失败时放行，解析时会有明确报错
    static func validate(cookie: String) async -> String? {
        guard cookie.contains("PHPSESSID=") else { return nil }
        guard let r = try? await HTTPClient.shared.send(.get("https://www.pixiv.net/dashboard/works",
                                                             headers: [("User-Agent", VideoHTTP.uaChrome), ("Cookie", cookie)],
                                                             followRedirects: false)) else { return "Pixiv 用户" }
        guard (300..<400).contains(r.status) else { return "Pixiv 用户" }
        let location = r.header("Location") ?? ""
        let wall = location.contains("return_to=") || location.contains("/login") || location.contains("accounts.pixiv.net")
        return wall ? nil : "Pixiv 用户"
    }
}

public enum PixivSession {
    /// 登录后的 PHPSESSID 形如「用户 ID_随机串」，游客的没有数字前缀。网页登录据此判断已经登录完成
    public static func isLoggedIn(cookie: String) -> Bool {
        cookie.range(of: #"(^|;\s*)PHPSESSID=\d+_"#, options: .regularExpression) != nil
    }
}
