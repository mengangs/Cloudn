// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 lvzhou 解析。
import Foundation

/// 绿洲：H5 分享页 `m.oasis.weibo.cn/v1/h5/share?sid={sid}` 是服务端渲染的 HTML：
/// 视频取 `<video src>`，标题 div.status-title，作者 div.nickname / a.avatar img，封面 div.video-cover 的背景图。
/// 没有视频时退而取页面里的新浪图床图片（换成 large 原图），头像除外。
struct LvzhouParser: VideoParser {
    let platform = VideoPlatform.lvzhou

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaIPhone, "Referer": "https://m.oasis.weibo.cn/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let sid = link.id
        guard !sid.isEmpty else { throw VideoParseError(.unsupported, "无法识别绿洲链接") }
        let pageURL = "https://m.oasis.weibo.cn/v1/h5/share?sid=\(sid)"
        let html = try await VideoHTTP.getText(pageURL, headers: headers, what: "绿洲分享页")
        let page = Self.page(html)
        let base = FileNames.base(page.title, fallback: "oasis_\(sid)")
        var medias: [VideoMedia] = []
        if !page.video.isEmpty {
            medias.append(VideoMedia(url: page.video, kind: .video, fileName: "\(base).mp4", headers: headers))
        } else {
            for (i, url) in page.images.enumerated() {
                medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1).\(DomesticHTML.imageExtension(url))",
                                         headers: headers, quality: "原图"))
            }
        }
        guard !medias.isEmpty else {
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频（绿洲作品可能已删除）")
        }
        let cover = page.cover.isEmpty ? (page.images.first ?? "") : page.cover
        return VideoParseResult(platform: platform, title: page.title, author: page.author, avatar: page.avatar, cover: cover,
                                text: page.title, url: pageURL, medias: medias)
    }

    // MARK: 纯逻辑

    struct Page {
        var title = ""
        var author = ""
        var avatar = ""
        var cover = ""
        var video = ""
        var images: [String] = []
    }

    static func page(_ html: String) -> Page {
        var p = Page()
        if let el = DomesticHTML.element(class: "status-title", in: html) { p.title = DomesticHTML.text(el) }
        if let el = DomesticHTML.element(class: "nickname", in: html) { p.author = DomesticHTML.text(el) }
        if let el = DomesticHTML.element(class: "avatar", in: html),
           let tag = DomesticHTML.openTags("img", in: el).first,
           let src = DomesticHTML.attribute("src", in: tag) {
            p.avatar = DomesticHTML.absolute(src)
        }
        for tag in DomesticHTML.openTags("video", in: html) + DomesticHTML.openTags("source", in: html) {
            if let src = DomesticHTML.attribute("src", in: tag), !src.isEmpty {
                p.video = DomesticHTML.absolute(src)
                break
            }
        }
        let coverRx = Rx(#"class\s*=\s*["'][^"']*\bvideo-cover\b[^"']*["'][^>]*?style\s*=\s*["'][^"']*background-image\s*:\s*url\(([^)]*)\)"#,
                         ignoreCase: true)
        if let u = coverRx.first(in: html) {
            p.cover = DomesticHTML.absolute(DomesticHTML.unescape(u).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
        }
        var seen = Set<String>()
        for tag in DomesticHTML.openTags("img", in: html) {
            guard let src = DomesticHTML.attribute("src", in: tag), src.contains("sinaimg.cn") else { continue }
            let url = largeImage(DomesticHTML.absolute(src))
            if url == largeImage(p.avatar) { continue }
            if seen.insert(url).inserted { p.images.append(url) }
        }
        return p
    }

    /// 新浪图床缩略图 → large 原图
    static func largeImage(_ url: String) -> String {
        Rx(#"(sinaimg\.cn/)(?:orj\d+|mw\d+|thumb\d+|thumbnail|bmiddle|small|square|crop[^/]*)/"#).replacing(in: url, with: "$1large/")
    }
}
