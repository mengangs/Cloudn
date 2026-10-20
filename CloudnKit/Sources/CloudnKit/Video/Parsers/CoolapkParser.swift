// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 coolapk 解析。
import Foundation

/// 酷安动态 / 图文：直接抓网页版 HTML。
/// - 图文（有 .message-title）：正文 .feed-article-message 里的 img.message-image；
/// - 普通动态：.feed-message 文本 + .message-image-group 里的全部 img。
/// 分享链接里的 shareKey / s 参数必须保留，否则网页版常拿不到内容；网页版不加载实况照片。
struct CoolapkParser: VideoParser {
    let platform = VideoPlatform.coolapk

    static let imageAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"

    private var mediaHeaders: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Accept": Self.imageAccept] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let pageURL = Self.pageURL(link)
        let html = try await VideoHTTP.getText(pageURL, headers: ["User-Agent": VideoHTTP.uaChrome], what: "酷安动态")
        guard let page = Self.extract(html) else {
            let hasKey = Self.keptQuery(link.url) != nil
            throw VideoParseError(.unsupported, hasKey ? "获取酷安内容失败（动态可能已删除或仅登录可见）" : "获取酷安内容失败，分享时请保留 shareKey 或 s 参数")
        }
        let titleSeed = page.title.isEmpty ? String(page.text.prefix(40)) : page.title
        let base = FileNames.base(titleSeed, fallback: "coolapk_\(link.id)")
        var medias: [VideoMedia] = []
        for (i, url) in page.images.enumerated() {
            medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1).\(DomesticHTML.imageExtension(url))",
                                     headers: mediaHeaders, quality: "原图"))
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        return VideoParseResult(platform: platform, title: titleSeed, cover: page.images.first ?? "", text: page.text,
                                url: pageURL, medias: medias)
    }

    // MARK: 纯逻辑

    /// 统一到 www.coolapk.com，只保留 shareKey / s 参数
    static func pageURL(_ link: DetectedVideoLink) -> String {
        let path = link.kind == "picture" ? "picture" : "feed"
        let base = "https://www.coolapk.com/\(path)/\(link.id)"
        guard let query = keptQuery(link.url) else { return base }
        return base + "?" + query
    }

    static func keptQuery(_ url: String) -> String? {
        // 正则取值：分享文案里链接后常紧跟中文，URLComponents 会整体解析失败
        let pairs = Rx(#"[?&](shareKey|s)=([A-Za-z0-9_\-]+)"#).allMatches(in: url).map { "\($0[1])=\($0[2])" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "&")
    }

    struct Page: Equatable {
        let title: String
        let text: String
        let images: [String]
    }

    static func extract(_ html: String) -> Page? {
        if let titleHTML = DomesticHTML.element(class: "message-title", in: html) {
            let title = DomesticHTML.text(titleHTML)
            if !title.isEmpty {
                guard let content = DomesticHTML.element(class: "feed-article-message", in: html) else { return nil }
                let images = DomesticHTML.openTags("img", in: content)
                    .filter { Self.hasClass($0, "message-image") }
                    .compactMap { DomesticHTML.attribute("src", in: $0) }
                return Page(title: title, text: DomesticHTML.text(content), images: normalize(images))
            }
        }
        if let feed = DomesticHTML.element(class: "feed-message", in: html) {
            let text = DomesticHTML.text(feed)
            if !text.isEmpty {
                var images: [String] = []
                if let group = DomesticHTML.element(class: "message-image-group", in: html) {
                    images = DomesticHTML.openTags("img", in: group).compactMap { DomesticHTML.attribute("src", in: $0) }
                }
                return Page(title: "", text: text, images: normalize(images))
            }
        }
        return nil
    }

    static func hasClass(_ tag: String, _ cls: String) -> Bool {
        guard let value = DomesticHTML.attribute("class", in: tag) else { return false }
        return value.split(separator: " ").contains { $0 == cls }
    }

    /// 补 https，去掉缩略图后缀（`xxx.jpg.s.jpg` / `.m.jpg` / `.xs.jpg`）取原图，去重
    static func normalize(_ srcs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for src in srcs where !src.isEmpty {
            let url = originalImage(DomesticHTML.absolute(src))
            if seen.insert(url).inserted { result.append(url) }
        }
        return result
    }

    static func originalImage(_ url: String) -> String {
        guard let m = Rx(#"^(.*\.(?:jpe?g|png|gif|webp))\.(?:xs|s|m)\.jpg$"#, ignoreCase: true).firstMatch(in: url) else { return url }
        return m[1]
    }
}
