// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 xinpianchang 与 parse-video（MIT，wujunwei928/parse-video）的 xinpianchang 解析。
import Foundation

/// 新片场：作品页 www.xinpianchang.com/a{id} 的 `__NEXT_DATA__` → props.pageProps.detail.video（vid + appKey），
/// 再请求 `mod-api.xinpianchang.com/mod/api/v2/media/{vid}?appKey=…` 取 resource：
/// progressive（整段 mp4，取最高清；不带 Range 头会 403）优先，其次 hls。
/// 接口失败时退回页面内嵌的 detail.video.content.progressive。
struct XinpianchangParser: VideoParser {
    let platform = VideoPlatform.xinpianchang

    private var pageHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.xinpianchang.com/", "Upgrade-Insecure-Requests": "1"]
    }
    private var mediaHeaders: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.xinpianchang.com/", "Range": "bytes=0-"]
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法识别新片场链接") }
        let pageURL = "https://www.xinpianchang.com/\(id)"
        let html = try await VideoHTTP.getText(pageURL, headers: pageHeaders, what: "新片场作品页")
        guard let detail = Self.detail(fromHTML: html) else {
            throw VideoParseError(.notFound, "新片场页面里没有作品数据（作品可能已删除或设为私密）")
        }
        let video = detail["video"]
        var resource = JSON(nil)
        var data = JSON(nil)
        let vid = video["vid"].string
        if !vid.isEmpty {
            let api = "https://mod-api.xinpianchang.com/mod/api/v2/media/\(vid)?appKey=\(video["appKey"].string.urlQueryEncoded)"
            if let payload = try? await VideoHTTP.getJSON(api, headers: pageHeaders, what: "新片场视频") {
                data = payload["data"]
                resource = data["resource"]
            }
        }
        var variants = Self.variants(resource)
        if variants.isEmpty { variants = Self.variants(video["content"]) }
        guard !variants.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }

        let title = detail["title"].string.nilIfBlank ?? data["title"].string
        let base = FileNames.base(title, fallback: "xinpianchang_\(id)")
        // m3u8 不能带 Range 头
        var hlsHeaders = mediaHeaders
        hlsHeaders.removeValue(forKey: "Range")
        let medias = DomesticVariant.medias(variants.map { v in
            var v = v
            if v.isHLS { v.headers = hlsHeaders }
            return v
        }, base: base, headers: mediaHeaders)
        let user = detail["author"]["userinfo"]
        let cover = detail["cover"].string.nilIfBlank ?? data["cover"].string
        let text = detail["content"].string.nilIfBlank ?? data["description"].string
        return VideoParseResult(platform: platform, title: title, author: user["username"].string, avatar: user["avatar"].string,
                                cover: cover, text: text, url: pageURL, medias: medias)
    }

    // MARK: 纯逻辑

    static func detail(fromHTML html: String) -> JSON? {
        let rx = Rx(#"<script[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>(.*?)</script>"#, ignoreCase: true, dotAll: true)
        guard let text = rx.first(in: html), let json = JSON(text: text.trimmed) else { return nil }
        let detail = json["props"]["pageProps"]["detail"]
        return detail.isObject ? detail : nil
    }

    /// 各档：默认档同 bestResource；整段 mp4 有多档时其余按高度、文件大小降序列出
    static func variants(_ resource: JSON) -> [DomesticVariant] {
        guard let best = bestResource(resource) else { return [] }
        if best.isHLS { return [DomesticVariant(url: best.url, label: best.quality, isHLS: true)] }
        func variant(_ p: JSON) -> DomesticVariant {
            DomesticVariant(url: p["url"].string, label: DomesticVariant.label(width: p["width"].int, height: p["height"].int, fallback: p["profile"].string),
                            size: p["filesize"].int64)
        }
        let list = resource["progressive"].array.filter { !$0["url"].string.isEmpty }
        let first = list.first(where: { $0["url"].string == best.url }).map(variant) ?? DomesticVariant(url: best.url, label: best.quality)
        let rest = list.sorted { a, b in
            let ha = a["height"].int
            let hb = b["height"].int
            return ha != hb ? ha > hb : a["filesize"].int64 > b["filesize"].int64
        }
        return DomesticVariant.normalized([first] + rest.map(variant))
    }

    /// progressive 取最高（高度、文件大小），没有则用 hls
    static func bestResource(_ resource: JSON) -> (url: String, isHLS: Bool, quality: String)? {
        var best: JSON?
        for p in resource["progressive"].array where !p["url"].string.isEmpty {
            if let b = best {
                let ph = p["height"].int
                let bh = b["height"].int
                if ph < bh { continue }
                if ph == bh && p["filesize"].int64 <= b["filesize"].int64 { continue }
            }
            best = p
        }
        if let b = best {
            let height = b["height"].int
            let quality = height > 0 ? "\(height)p" : b["profile"].string
            return (url: b["url"].string, isHLS: false, quality: quality)
        }
        let hls = resource["hls"]["url"].string
        if !hls.isEmpty { return (url: hls, isHLS: true, quality: "") }
        return nil
    }
}
