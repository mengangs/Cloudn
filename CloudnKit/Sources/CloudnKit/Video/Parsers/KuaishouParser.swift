// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 KuaishouParser。
import Foundation

/// 快手：移动端作品页 SSR 的 window.INIT_STATE（作品 id → 作品数据），视频 + 图集。
/// UA 必须是 iPhone + Referer v.kuaishou.com，桌面 UA 拿到的是没有 INIT_STATE 的 SPA 页。
struct KuaishouParser: VideoParser {
    let platform = VideoPlatform.kuaishou
    /// 主页批量的回退路线（GraphQL 直连被要求验证时用页面自己的请求）；单作品解析用不到
    let extractor: WebPageExtractor?

    init(extractor: WebPageExtractor? = nil) {
        self.extractor = extractor
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        if link.kind == "profile" { return try await parseProfile(link.id, cookie: cookie) }
        var headers = ["User-Agent": VideoHTTP.uaIPhone, "Referer": "https://v.kuaishou.com/"]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        // 入口页（短链 / short-video / f/码）先跟随一次重定向到真正的作品页
        let first = (try? await VideoHTTP.expandRedirect(link.url, headers: headers)) ?? nil
        let pageURL = (first ?? link.url).replacingOccurrences(of: "/fw/long-video/", with: "/fw/photo/")
        // 分享的是主页（短链展开后落到 /fw/user/ 或 /profile/）
        if let profileID = Self.profileID(in: pageURL) { return try await parseProfile(profileID, cookie: cookie) }
        let html = try await VideoHTTP.getText(pageURL, headers: headers, what: "快手作品页")
        guard let initText = VideoHTTP.extractInlineJSON(html, key: "window.INIT_STATE"), let state = JSON(text: initText) else {
            throw VideoParseError(.unknown, "快手页面里没有作品数据（作品可能已删除或页面改版）")
        }
        guard let photo = Self.findPhoto(state) else { throw VideoParseError(.unknown, "快手页面里没有作品数据") }

        let id = link.id.isEmpty ? (Rx(#"/photo/([A-Za-z\d]+)"#).first(in: pageURL) ?? "") : link.id
        let title = photo["caption"].string
        let base = FileNames.base(title, fallback: "kuaishou_\(id)")
        var medias: [VideoMedia] = []
        if let video = Self.firstURL(photo["mainMvUrls"].array) {
            medias.append(VideoMedia(url: video, kind: .video, fileName: "\(base).mp4", headers: headers))
        }
        for (i, url) in Self.atlasImages(photo["ext_params"]["atlas"]).enumerated() {
            medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1).jpg", headers: headers))
        }
        return VideoParseResult(
            platform: platform, title: title,
            author: photo["userName"].string.replacingOccurrences(of: "\u{3164}", with: "").trimmed,
            avatar: photo["headUrl"].string, cover: Self.firstURL(photo["coverUrls"].array) ?? "",
            timestamp: photo["timestamp"].int64 / 1000, url: link.url, medias: medias)
    }

    /// 取第一个含 photo 的 value（JSON 对象无序，优先挑带视频/图集的那条）
    static func findPhoto(_ state: JSON) -> JSON? {
        let photos = state.keys.sorted().map { state[$0]["photo"] }.filter { $0.isObject }
        return photos.first(where: { !$0["mainMvUrls"].array.isEmpty || $0["ext_params"]["atlas"].isObject }) ?? photos.first
    }

    static func firstURL(_ nodes: [JSON]) -> String? {
        nodes.map { $0["url"].string }.first(where: { !$0.isEmpty })
    }

    static func atlasImages(_ atlas: JSON) -> [String] {
        let cdn = atlas["cdnList"][0]["cdn"].string
        guard !cdn.isEmpty else { return [] }
        return atlas["list"].array.map { $0.string }.filter { !$0.isEmpty }.map { "https://\(cdn)/\($0)" }
    }
}
