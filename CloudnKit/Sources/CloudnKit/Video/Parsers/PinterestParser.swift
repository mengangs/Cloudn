// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 pinterest 解析。
import Foundation

/// Pinterest：PinResource 接口（field_set_key=unauth_react_main_pin，匿名可用）。
/// 视频取带音轨的 mp4（没有才用 HLS）；图片取 orig 原图；故事 Pin（多页）/ 轮播逐页取。
/// 接口失败时退回 Pin 页面内嵌的 __PWS_DATA__，再不行取 og:image 并换成 originals 原图。
/// pin.it 短链要经过 api.pinterest.com 跳板，在解析器里逐跳展开。
struct PinterestParser: VideoParser {
    let platform = VideoPlatform.pinterest

    static let pinRx = Rx(#"pinterest\.[a-z.]+/pin/(?:[\w\-]+--)?(\d+)"#, ignoreCase: true)
    static let referer = "https://www.pinterest.com/"

    struct Item: Equatable {
        let kind: MediaKind
        let url: String
        var isHLS = false
        var quality = ""
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var id = link.kind == "share" ? "" : link.id
        if id.isEmpty {
            let target = try await OverseasHTTP.expandShareLink(link.url, until: Self.pinRx, site: "Pinterest")
            id = Self.pinRx.first(in: target) ?? ""
        }
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 Pinterest Pin ID") }

        var pin = try await fetchAPI(id: id)
        var fallbackImages: [String] = []
        if pin == nil {
            let page = try await fetchPage(id: id)
            pin = page.pin
            fallbackImages = page.images
        }
        if let pin {
            if Self.isExternalEmbed(pin) {
                throw VideoParseError(.unsupported, "该 Pin 的视频来自外部网站（\(pin["domain"].string)），请到原站解析")
            }
            let items = Self.items(pin)
            if !items.isEmpty { return build(pin: pin, id: id, items: items) }
        }
        if !fallbackImages.isEmpty {
            let items = fallbackImages.map { Item(kind: .image, url: Self.originalImage($0), quality: "原图") }
            return build(pin: pin ?? JSON(nil), id: id, items: items)
        }
        if pin == nil { throw VideoParseError(.notFound, "Pin 不存在或不可见") }
        throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
    }

    /// PinResource 接口；拿不到数据返回 nil（交给网页兜底），明确 404 直接报错
    private func fetchAPI(id: String) async throws -> JSON? {
        let options = #"{"options":{"field_set_key":"unauth_react_main_pin","id":"\#(id)"}}"#
        let url = "https://www.pinterest.com/resource/PinResource/get/?data=" + options.urlQueryEncoded
        let headers: [(String, String)] = [
            ("Accept", "application/json, text/javascript, */*; q=0.01"), ("Referer", Self.referer),
            ("User-Agent", VideoHTTP.uaChrome), ("X-Pinterest-PWS-Handler", "www/[username].js"),
            ("X-Requested-With", "XMLHttpRequest")
        ]
        let r = try await OverseasHTTP.send(.get(url, headers: headers), site: "Pinterest")
        if r.status == 404 { throw VideoParseError(.notFound, "Pin 不存在或已删除（HTTP 404）") }
        guard r.isSuccess, let json = r.json else { return nil }
        let data = json["resource_response"]["data"]
        return data.isObject ? data : nil
    }

    private func fetchPage(id: String) async throws -> (pin: JSON?, images: [String]) {
        let url = "https://www.pinterest.com/pin/\(id)/"
        let headers: [(String, String)] = [("Accept-Language", "en-US,en;q=0.9"), ("User-Agent", VideoHTTP.uaChrome)]
        let r = try await OverseasHTTP.send(.get(url, headers: headers), site: "Pinterest")
        if r.status == 404 { throw VideoParseError(.notFound, "Pin 不存在或已删除（HTTP 404）") }
        guard r.isSuccess else { throw VideoParseError(.unknown, "Pinterest 页面请求失败（HTTP \(r.status)）") }
        let html = r.text
        return (Self.pinFromPage(html, id: id), OverseasHTTP.metaContent("og:image", in: html))
    }

    private func build(pin: JSON, id: String, items: [Item]) -> VideoParseResult {
        let headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer]
        var title = pin["title"].string.trimmed
        if title.isEmpty { title = pin["grid_title"].string.trimmed }
        var text = pin["description"].string.trimmed
        if text.isEmpty { text = pin["seo_description"].string.trimmed }
        if title.isEmpty { title = String(text.prefix(40)) }
        let base = FileNames.base(title, fallback: "pinterest_\(id)")
        let single = items.count == 1
        var medias: [VideoMedia] = []
        for (i, item) in items.enumerated() {
            let ext = item.kind == .video ? "mp4" : DomesticHTML.imageExtension(item.url)
            let name = single ? "\(base).\(ext)" : "\(base)_\(i + 1).\(ext)"
            medias.append(VideoMedia(url: item.url, kind: item.kind, fileName: name, isHLS: item.isHLS,
                                     headers: headers, quality: item.quality))
        }
        var author = pin["closeup_attribution"]["full_name"].string
        if author.isEmpty { author = pin["pinner"]["full_name"].string }
        if author.isEmpty { author = pin["pinner"]["username"].string }
        var cover = Self.bestImage(pin["images"])
        if cover.isEmpty { cover = items.first(where: { $0.kind == .image })?.url ?? "" }
        return VideoParseResult(platform: platform, title: title.isEmpty ? "Pinterest \(id)" : title, author: author,
                                avatar: pin["pinner"]["image_medium_url"].string, cover: cover, text: text,
                                timestamp: Self.parseTime(pin["created_at"].string),
                                url: "https://www.pinterest.com/pin/\(id)/", medias: medias)
    }

    // MARK: 纯逻辑

    /// 外站嵌入（YouTube / Vimeo 等）：Pinterest 自己没有文件
    static func isExternalEmbed(_ pin: JSON) -> Bool {
        let domain = pin["domain"].string.lowercased()
        return domain != "uploaded by user" && !pin["embed"]["src"].string.isEmpty && pin["videos"]["video_list"].isNull
    }

    /// Pin 数据 → 媒体：视频 → 故事 Pin 各页 → 轮播 → 主图
    static func items(_ pin: JSON) -> [Item] {
        if let video = bestVideo(pin["videos"]["video_list"]) { return [video] }

        var story: [Item] = []
        for page in pin["story_pin_data"]["pages"].array {
            for block in page["blocks"].array {
                if let video = bestVideo(block["video"]["video_list"]) {
                    story.append(video)
                    continue
                }
                let image = bestImage(block["image"]["images"])
                if !image.isEmpty { story.append(Item(kind: .image, url: image, quality: "原图")) }
            }
        }
        if !story.isEmpty { return dedupe(story) }

        var carousel: [Item] = []
        for slot in pin["carousel_data"]["carousel_slots"].array {
            let image = bestImage(slot["images"])
            if !image.isEmpty { carousel.append(Item(kind: .image, url: image, quality: "原图")) }
        }
        if !carousel.isEmpty { return dedupe(carousel) }

        let image = bestImage(pin["images"])
        return image.isEmpty ? [] : [Item(kind: .image, url: image, quality: "原图")]
    }

    /// video_list：优先面积最大的 mp4（带音轨），没有 mp4 才用 HLS
    static func bestVideo(_ list: JSON) -> Item? {
        guard list.isObject else { return nil }
        var mp4 = ""
        var mp4Area = -1
        var mp4Label = ""
        var hls = ""
        for key in list.keys.sorted() {
            let format = list[key]
            let url = format["url"].string
            guard !url.isEmpty else { continue }
            let isHLS = key.lowercased().contains("hls") || url.substringBefore("?").lowercased().hasSuffix(".m3u8")
            if isHLS {
                if hls.isEmpty { hls = url }
                continue
            }
            let width = format["width"].int
            let height = format["height"].int
            let area = width * height
            if area > mp4Area {
                mp4Area = area
                mp4 = url
                mp4Label = height > 0 ? "\(min(width, height))p" : ""
            }
        }
        if !mp4.isEmpty { return Item(kind: .video, url: mp4, quality: mp4Label) }
        if !hls.isEmpty { return Item(kind: .video, url: hls, isHLS: true, quality: "HLS") }
        return nil
    }

    /// images 字典：orig / originals 优先，否则取宽度最大的一档
    static func bestImage(_ images: JSON) -> String {
        guard images.isObject else { return "" }
        for key in ["orig", "originals"] {
            let url = images[key]["url"].string
            if !url.isEmpty { return url }
        }
        var best = ""
        var bestWidth = -1
        for key in images.keys.sorted() {
            let url = images[key]["url"].string
            let width = images[key]["width"].int
            if !url.isEmpty && width > bestWidth {
                bestWidth = width
                best = url
            }
        }
        return best
    }

    /// `i.pinimg.com/736x/ab/cd/x.jpg` → `i.pinimg.com/originals/ab/cd/x.jpg`
    static func originalImage(_ url: String) -> String {
        Rx(#"(pinimg\.com/)(?:\d+x\d*|\d+x)(?=/)"#).replacing(in: url, with: "$1originals")
    }

    /// Pin 页面内嵌的 __PWS_DATA__ / __PWS_INITIAL_PROPS__ 里的 Pin 数据
    static func pinFromPage(_ html: String, id: String) -> JSON? {
        let rx = Rx(#"<script[^>]*\bid="__PWS_(?:DATA|INITIAL_PROPS)__"[^>]*>(.*?)</script>"#, dotAll: true)
        for m in rx.allMatches(in: html) {
            guard let json = JSON(text: m[1]) else { continue }
            let candidates = [json["props"]["initialReduxState"]["pins"][id], json["initialReduxState"]["pins"][id]]
            for pin in candidates where pin.isObject { return pin }
        }
        return nil
    }

    static func dedupe(_ items: [Item]) -> [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for item in items where !seen.contains(item.url) {
            seen.insert(item.url)
            out.append(item)
        }
        return out
    }

    /// `Sat, 13 Jan 2024 05:42:11 +0000` → 秒
    static func parseTime(_ s: String) -> Int64 {
        guard !s.isEmpty else { return 0 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.date(from: s).map { Int64($0.timeIntervalSince1970) } ?? 0
    }
}
