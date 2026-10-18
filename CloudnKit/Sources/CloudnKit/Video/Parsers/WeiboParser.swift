// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 WeiboParser。
import Foundation

/// 微博：status（手机站 JSON）/ fid（视频组件接口）/ tv（mid → id 后按 status）
struct WeiboParser: VideoParser {
    let platform = VideoPlatform.weibo

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        switch link.kind {
        case "status": return try await parseStatus(link, id: link.id, cookie: cookie)
        case "tv": return try await parseStatus(link, id: Self.mid2id(link.id), cookie: cookie)
        case "fid": return try await parseFid(link, cookie: cookie)
        default: throw VideoParseError(.unsupported, "不支持的微博链接形态")
        }
    }

    private func mediaHeaders(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://weibo.com/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func parseStatus(_ link: DetectedVideoLink, id: String, cookie: String) async throws -> VideoParseResult {
        var headers: [(String, String)] = [
            ("Accept", "application/json, text/plain, */*"), ("Referer", "https://m.weibo.cn/detail/\(id)"),
            ("Origin", "https://m.weibo.cn"), ("X-Requested-With", "XMLHttpRequest"), ("MWeibo-Pwa", "1"),
            ("User-Agent", VideoHTTP.uaChrome)
        ]
        if !cookie.isEmpty { headers.append(("Cookie", cookie)) }
        // 不跟随重定向：跟随会被 302 到登录/验证页
        let url = "https://m.weibo.cn/statuses/show?id=\(id)&_=\(Int(Date().timeIntervalSince1970 * 1000))"
        let r = try await VideoHTTP.send(.get(url, headers: headers, followRedirects: false))
        guard r.status == 200 else {
            switch r.status {
            case 403, 418, 429: throw VideoParseError(.blocked, "微博被风控拦截（HTTP \(r.status)）")
            case 404, 410: throw VideoParseError(.notFound, "微博内容不存在或已删除")
            default: throw VideoParseError(.blocked, "微博数据获取失败（HTTP \(r.status)），请稍后重试")
            }
        }
        guard (r.header("Content-Type") ?? "").contains("json"), let json = r.json else {
            throw VideoParseError(.blocked, "微博接口返回的不是 JSON，多半被风控拦截")
        }
        let data = json["data"]
        guard data.isObject else { throw VideoParseError(.notFound, "微博内容不存在或已删除") }
        return build(link, data: data, cookie: cookie, allowRetweet: true)
    }

    private func build(_ link: DetectedVideoLink, data: JSON, cookie: String, allowRetweet: Bool) -> VideoParseResult {
        let headers = mediaHeaders(cookie)
        let pageInfo = data["page_info"]
        let text = Self.clean(data["text"].string.replacingOccurrences(of: "<br />", with: "\n"))
        let title = pageInfo["title"].string.isEmpty ? String(text.prefix(40)) : pageInfo["title"].string
        let base = FileNames.base(title, fallback: "weibo_\(link.id)")
        var medias: [VideoMedia] = []
        let urls = pageInfo["urls"]
        let video = [urls["mp4_1080p_mp4"], urls["mp4_720p_mp4"], urls["mp4_hd_mp4"], urls["mp4_ld_mp4"]]
            .map { $0.string }.first(where: { !$0.isEmpty }) ?? pageInfo["media_info"]["stream_url_hd"].string
        if !video.isEmpty {
            medias.append(VideoMedia(url: Self.https(video), kind: .video, fileName: "\(base).mp4", headers: headers))
        }
        var index = 0
        for pic in data["pics"].array {
            // 实况照片（livephoto）同时给 videoSrc，这里只取原图
            let url = pic["large"]["url"].string
            guard !url.isEmpty else { continue }
            index += 1
            medias.append(VideoMedia(url: Self.https(url), kind: .image, fileName: "\(base)_\(index).jpg", headers: headers, quality: "原图"))
        }
        if medias.isEmpty && allowRetweet && data["retweeted_status"].isObject {
            return build(link, data: data["retweeted_status"], cookie: cookie, allowRetweet: false)
        }
        let user = data["user"]
        let bid = data["bid"].string
        let uid = user["id"].string
        return VideoParseResult(platform: platform, title: title, author: user["screen_name"].string,
                                avatar: user["profile_image_url"].string, cover: pageInfo["page_pic"]["url"].string, text: text,
                                timestamp: Self.parseTime(data["created_at"].string),
                                url: (!uid.isEmpty && !bid.isEmpty) ? "https://weibo.com/\(uid)/\(bid)" : link.url, medias: medias)
    }

    private func parseFid(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var headers: [(String, String)] = [("Referer", "https://h5.video.weibo.com/show/\(link.id)"), ("User-Agent", VideoHTTP.uaChrome)]
        if !cookie.isEmpty { headers.append(("Cookie", cookie)) }
        let form = [("data", #"{"Component_Play_Playinfo":{"oid":"\#(link.id)"}}"#)]
        let r = try await VideoHTTP.send(.postForm("https://h5.video.weibo.com/api/component?page=/show/\(link.id)", form, headers: headers))
        try VideoHTTP.requireSuccess(r, "微博视频")
        let data = r.json?["data"]["Component_Play_Playinfo"] ?? JSON(nil)
        guard data.isObject else { throw VideoParseError(.notFound, "微博视频数据为空（作品可能已删除）") }
        let title = data["title"].string
        let base = FileNames.base(title, fallback: "weibo_\(link.id)")
        let urls = data["urls"]
        // urls 是「清晰度 → 直链」，取数字最大的一档
        let best = urls.keys.max(by: { Self.resolutionRank($0) < Self.resolutionRank($1) }).map { urls[$0].string } ?? ""
        let videoURL = best.isEmpty ? data["stream_url"].string : best
        var medias: [VideoMedia] = []
        if !videoURL.isEmpty {
            medias.append(VideoMedia(url: Self.https(videoURL), kind: .video, fileName: "\(base).mp4", headers: mediaHeaders(cookie)))
        }
        return VideoParseResult(platform: platform, title: title, author: data["reward"]["user"]["name"].string, avatar: data["reward"]["user"]["profile_image_url"].string,
                                cover: Self.https(data["cover_image"].string), text: Self.clean(data["text"].string),
                                url: link.url, medias: medias)
    }

    static func resolutionRank(_ key: String) -> Int {
        Int(Rx(#"(\d{3,4})"#).first(in: key) ?? "") ?? 0
    }

    static func clean(_ html: String) -> String {
        Rx("<[^>]*>").replacing(in: html, with: "").trimmed
    }

    static func https(_ v: String) -> String {
        if v.isEmpty || v.hasPrefix("http") { return v }
        return v.hasPrefix("//") ? "https:" + v : "https://" + v
    }

    /// `Thu Oct 02 14:39:33 +0800 2025` → 秒
    static func parseTime(_ s: String) -> Int64 {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f.date(from: s).map { Int64($0.timeIntervalSince1970) } ?? 0
    }

    /// 微博 mid → id：反转后每 7 位一段、段内再反转，按 base62 编码（非尾段补足 4 位），段序反转后拼接
    static func mid2id(_ mid: String) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        func base62(_ n: Int64) -> String {
            if n == 0 { return "0" }
            var v = n
            var s = ""
            while v > 0 { s = String(alphabet[Int(v % 62)]) + s; v /= 62 }
            return s
        }
        let reversed = Array(mid.reversed())
        guard !reversed.isEmpty else { return "" }
        let size = (reversed.count + 6) / 7
        var chunks: [String] = []
        for i in 0..<size {
            let piece = String(reversed[(i * 7)..<min((i + 1) * 7, reversed.count)].reversed())
            var enc = base62(Int64(piece) ?? 0)
            if i < size - 1 && enc.count < 4 { enc = String(repeating: "0", count: 4 - enc.count) + enc }
            chunks.append(enc)
        }
        return chunks.reversed().joined()
    }
}
