// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 pipix 解析。
import Foundation

/// 皮皮虾：作品页的 `<script id="RENDER_DATA">`（URL 编码的 JSON）→ ppxItemDetail.item。
/// item_type 1 图文取 cover.download_list；2 视频优先 origin_video_download（无水印原片），退回 video.video_download。
/// 分享短链 h5.pipix.com/s/xxx 直接请求（跟随重定向）即落到作品页，无需单独展开。
struct PipixParser: VideoParser {
    let platform = VideoPlatform.pipix

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let url = link.kind == "share" ? "https://h5.pipix.com/s/\(link.id)/" : link.url
        let r = try await VideoHTTP.send(.get(url, headers: headers.sortedPairs))
        try VideoHTTP.requireSuccess(r, "皮皮虾作品页")
        guard let item = Self.item(fromHTML: r.text) else {
            throw VideoParseError(.notFound, "皮皮虾页面里没有作品数据（作品可能已删除）")
        }
        let content = item["content"].string
        let itemID = item["item_id_str"].string.nilIfBlank ?? item["item_id"].string.nilIfBlank ?? link.id
        let base = FileNames.base(content, fallback: "pipix_\(itemID)")
        var medias: [VideoMedia] = []
        var cover = ""
        if let video = Self.video(item) {
            medias.append(VideoMedia(url: video.url, kind: .video, fileName: "\(base).mp4", headers: headers))
            cover = video.cover
        } else {
            let images = Self.images(item)
            for (i, img) in images.enumerated() {
                medias.append(VideoMedia(url: img, kind: .image, fileName: "\(base)_\(i + 1).\(DomesticHTML.imageExtension(img))",
                                         headers: headers))
            }
            cover = images.first ?? ""
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let author = item["author"]
        return VideoParseResult(platform: platform, title: content, author: author["name"].string,
                                avatar: author["avatar"]["download_list"][0]["url"].string, cover: cover, text: content,
                                timestamp: item["create_time"].int64, url: r.url, medias: medias)
    }

    // MARK: 纯逻辑

    static func item(fromHTML html: String) -> JSON? {
        guard let raw = Rx(#"<script[^>]*\bid\s*=\s*["']RENDER_DATA["'][^>]*>(.*?)</script>"#, ignoreCase: true, dotAll: true).first(in: html) else {
            return nil
        }
        let decoded = raw.trimmed.removingPercentEncoding ?? raw
        guard let json = JSON(text: decoded) else { return nil }
        let item = json["ppxItemDetail"]["item"]
        return item.isObject ? item : nil
    }

    static func video(_ item: JSON) -> (url: String, cover: String)? {
        guard item["item_type"].int == 2 else { return nil }
        let download = item["video"]["video_download"]
        let origin = item["origin_video_download"]["url_list"][0]["url"].string
        let fallback = download["url_list"][0]["url"].string
        let url = origin.isEmpty ? fallback : origin
        guard !url.isEmpty else { return nil }
        return (url, download["cover_image"]["download_list"][0]["url"].string)
    }

    static func images(_ item: JSON) -> [String] {
        item["cover"]["download_list"].array.map { $0["url"].string }.filter { !$0.isEmpty }
    }
}
