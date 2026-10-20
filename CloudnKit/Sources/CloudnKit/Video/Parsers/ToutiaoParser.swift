// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 toutiao 解析。
import Foundation

/// 今日头条：移动端 info 接口（`m.toutiao.com/i{id}/info/v2/`）分三种形态：
/// - 微头条（data.thread）：thread_base.large_image_list 原图；
/// - 视频（play_auth_token_v2）：令牌 base64 解出 GetPlayInfoToken，向字节点播（vod.bytedanceapi.com）取播放列表，挑最高清；
/// - 文章：正文 HTML 里的 `<img src>` 与 `div.tt-video-box[data-token]` 视频。
/// 分享短链 `toutiao.com/is/xxx` 在解析器内自行展开（kind = "share"）。
struct ToutiaoParser: VideoParser {
    let platform = VideoPlatform.toutiao

    static let idRx = Rx(#"toutiao\.com/(?:(?:article|video|w|group|item)/|a|i)(\d+)"#, ignoreCase: true)

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome] }
    private var mediaHeaders: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.toutiao.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var id = link.id
        if link.kind == "share" {
            // 分享文案里链接后常紧跟中文：用捕获到的短码重建短链
            let start = link.id.isEmpty ? link.url : "https://m.toutiao.com/is/\(link.id)/"
            id = try await resolveShare(start)
        }
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法识别今日头条链接") }

        let info = try await VideoHTTP.getJSON("https://m.toutiao.com/i\(id)/info/v2/", headers: headers, what: "今日头条内容")
        let data = info["data"]
        guard data.isObject else { throw VideoParseError(.notFound, "今日头条内容不存在或已删除") }

        let author = data["media_user"]["screen_name"].string.nilIfBlank ?? data["source"].string
        let avatar = data["media_user"]["avatar_url"].string
        let pageURL = "https://www.toutiao.com/article/\(id)/"

        if data["thread"].isObject {
            let base = data["thread"]["thread_base"]
            let text = base["content"].string.trimmed
            let fileBase = FileNames.base(String(text.prefix(40)), fallback: "toutiao_\(id)")
            let images = Self.microPostImages(data["thread"])
            var medias: [VideoMedia] = []
            for (i, url) in images.enumerated() {
                medias.append(VideoMedia(url: url, kind: .image, fileName: "\(fileBase)_\(i + 1).\(DomesticHTML.imageExtension(url))",
                                         headers: mediaHeaders, quality: "原图"))
            }
            guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
            return VideoParseResult(platform: platform, title: String(text.prefix(40)), author: author, avatar: avatar,
                                    cover: images.first ?? "", text: text, url: "https://www.toutiao.com/w/\(id)/", medias: medias)
        }

        let title = data["title"].string
        let fileBase = FileNames.base(title, fallback: "toutiao_\(id)")
        let token = data["play_auth_token_v2"].string
        if data["biz_tag"].string != "图文" && !token.isEmpty {
            let video = try await fetchVideo(token: token)
            let media = VideoMedia(url: video.url, kind: .video, fileName: "\(fileBase).mp4", headers: mediaHeaders, quality: video.quality)
            return VideoParseResult(platform: platform, title: title, author: author, avatar: avatar,
                                    cover: data["poster_url"].string, url: "https://www.toutiao.com/video/\(id)/", medias: [media])
        }

        // 文章
        let content = data["content"].string
        var medias: [VideoMedia] = []
        let images = Self.articleImages(content)
        for (i, url) in images.enumerated() {
            medias.append(VideoMedia(url: url, kind: .image, fileName: "\(fileBase)_\(i + 1).\(DomesticHTML.imageExtension(url))",
                                     headers: mediaHeaders))
        }
        let tokens = Self.articleVideoTokens(content)
        for (i, t) in tokens.enumerated() {
            guard let video = try? await fetchVideo(token: t) else { continue }
            let name = tokens.count == 1 ? "\(fileBase).mp4" : "\(fileBase)_v\(i + 1).mp4"
            medias.append(VideoMedia(url: video.url, kind: .video, fileName: name, headers: mediaHeaders, quality: video.quality))
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        return VideoParseResult(platform: platform, title: title, author: author, avatar: avatar, cover: images.first ?? "",
                                text: DomesticHTML.text(content), url: pageURL, medias: medias)
    }

    /// 分享短链逐跳展开，直到落到带作品 id 的地址
    private func resolveShare(_ url: String) async throws -> String {
        var current = url
        for _ in 0..<5 {
            if let id = Self.idRx.first(in: current) { return id }
            guard let next = try await VideoHTTP.expandRedirect(current, headers: headers) else { break }
            current = next
        }
        if let id = Self.idRx.first(in: current) { return id }
        throw VideoParseError(.unsupported, "今日头条分享链接展开失败，请复制完整链接后重试")
    }

    private func fetchVideo(token: String) async throws -> (url: String, quality: String) {
        guard let query = Self.playInfoQuery(token: token) else {
            throw VideoParseError(.unknown, "今日头条视频令牌解析失败")
        }
        let payload = try await VideoHTTP.getJSON("https://vod.bytedanceapi.com/?\(query)", headers: headers, what: "今日头条视频")
        let error = payload["ResponseMetadata"]["Error"]
        if !error.isNull {
            let message = error.isObject ? error.string("Message", "message", "ErrorMessage") : error.string
            throw VideoParseError(.unknown, "今日头条视频地址获取失败：\(message.isEmpty ? "未知错误" : message)")
        }
        guard let best = Self.bestPlayInfo(payload["Result"]["Data"]["PlayInfoList"].array) else {
            throw VideoParseError(.unknown, "今日头条视频没有可用的播放地址")
        }
        return best
    }

    // MARK: 纯逻辑

    /// play_auth_token_v2 / data-token：base64url 编码的 JSON，取其中的 GetPlayInfoToken（已是完整查询串）
    static func playInfoQuery(token: String) -> String? {
        guard let data = Crypto.base64Decode(token), let json = JSON(data: data) else { return nil }
        let query = json["GetPlayInfoToken"].string
        return query.isEmpty ? nil : query
    }

    /// 按 (Height, Size) 取最大的一档
    static func bestPlayInfo(_ list: [JSON]) -> (url: String, quality: String)? {
        let usable = list.filter { !$0["MainPlayUrl"].string.isEmpty }
        let best = usable.max { a, b in
            let ha = a["Height"].int
            let hb = b["Height"].int
            if ha != hb { return ha < hb }
            return a["Size"].int64 < b["Size"].int64
        }
        guard let best else { return nil }
        let height = best["Height"].int
        let definition = best["Definition"].string
        let quality = height > 0 ? "\(height)p" : definition
        return (best["MainPlayUrl"].string, quality)
    }

    static func microPostImages(_ thread: JSON) -> [String] {
        thread["thread_base"]["large_image_list"].array.map { $0["url"].string }.filter { !$0.isEmpty }
    }

    static func articleImages(_ html: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in DomesticHTML.openTags("img", in: html) {
            guard let src = DomesticHTML.attribute("src", in: tag), !src.isEmpty else { continue }
            let url = DomesticHTML.absolute(src)
            if seen.insert(url).inserted { result.append(url) }
        }
        return result
    }

    static func articleVideoTokens(_ html: String) -> [String] {
        DomesticHTML.openTags("div", in: html)
            .filter { ($0.range(of: "tt-video-box") != nil) }
            .compactMap { DomesticHTML.attribute("data-token", in: $0) }
            .filter { !$0.isEmpty }
    }
}
