// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 WeiboParser；weibo.com/ajax 兜底与实况/动图/混排媒体参考 ParseHub（MIT，z-mio/ParseHub）的 weibo 解析。
import Foundation

/// 微博里的一个媒体（换算成 VideoMedia 前的中间形态）
struct WeiboMediaRef: Equatable, Sendable {
    let url: String
    let kind: MediaKind
    let ext: String
    let quality: String
    /// 实况照片的视频部分：与前一张图同号
    var isLive: Bool = false
}

/// 微博：status（手机站 JSON，失败或无媒体时用 weibo.com/ajax 兜底）/ fid（视频组件接口）/ tv（mid → id 后按 status）
struct WeiboParser: VideoParser {
    let platform = VideoPlatform.weibo

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        switch link.kind {
        case "status": return try await parseStatusWithFallback(link, id: link.id, cookie: cookie)
        case "tv": return try await parseStatusWithFallback(link, id: Self.mid2id(link.id), cookie: cookie)
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
        let refs = Self.mobileMedias(data)
        if refs.isEmpty && allowRetweet && data["retweeted_status"].isObject {
            return build(link, data: data["retweeted_status"], cookie: cookie, allowRetweet: false)
        }
        let user = data["user"]
        let bid = data["bid"].string
        let uid = user["id"].string
        return VideoParseResult(platform: platform, title: title, author: user["screen_name"].string,
                                avatar: user["profile_image_url"].string, cover: pageInfo["page_pic"]["url"].string, text: text,
                                timestamp: Self.parseTime(data["created_at"].string),
                                url: (!uid.isEmpty && !bid.isEmpty) ? "https://weibo.com/\(uid)/\(bid)" : link.url,
                                medias: Self.medias(refs, base: base, headers: headers))
    }

    // MARK: weibo.com/ajax 兜底

    /// 访客 SUB（参考实现同款）：没有登录 Cookie 时 weibo.com/ajax 也能取到公开微博
    static let visitorSUB = "SUB=_2AkMR47Mlf8NxqwFRmfocxG_lbox2wg7EieKnv0L-JRMxHRl-yT9yqhFdtRB6OmOdyoia9pKPkqoHRRmSBA_WNPaHuybH"

    /// 先走手机站；失败或没有媒体时再试 weibo.com/ajax/statuses/show（字段更全：实况、动图、混排、最大尺寸）
    private func parseStatusWithFallback(_ link: DetectedVideoLink, id: String, cookie: String) async throws -> VideoParseResult {
        do {
            let result = try await parseStatus(link, id: id, cookie: cookie)
            if !result.medias.isEmpty { return result }
            if let alt = try? await parseAjax(link, id: id, cookie: cookie), !alt.medias.isEmpty { return alt }
            return result
        } catch {
            if let alt = try? await parseAjax(link, id: id, cookie: cookie), !alt.medias.isEmpty { return alt }
            throw error
        }
    }

    private func parseAjax(_ link: DetectedVideoLink, id: String, cookie: String) async throws -> VideoParseResult {
        let headers: [(String, String)] = [
            ("Accept", "application/json, text/plain, */*"), ("Referer", "https://weibo.com/"),
            ("User-Agent", VideoHTTP.uaChrome), ("Cookie", cookie.isEmpty ? Self.visitorSUB : cookie)
        ]
        let url = "https://weibo.com/ajax/statuses/show?id=\(id)&isGetLongText=true"
        let r = try await VideoHTTP.send(.get(url, headers: headers, followRedirects: false))
        try VideoHTTP.requireSuccess(r, "微博")
        guard let data = r.json, data.isObject, !data.string("idstr", "mblogid").isEmpty else {
            throw VideoParseError(.notFound, "微博内容不存在或已删除")
        }
        var refs = Self.ajaxMedias(data)
        if refs.isEmpty && data["retweeted_status"].isObject { refs = Self.ajaxMedias(data["retweeted_status"]) }
        let text = data["text_raw"].string.isEmpty ? Self.clean(data["text"].string) : data["text_raw"].string.trimmed
        let pageInfo = data["page_info"]
        let pageTitle = pageInfo["title"].string
        let title = pageTitle.isEmpty ? String(text.prefix(40)) : pageTitle
        let base = FileNames.base(title, fallback: "weibo_\(link.id)")
        let user = data["user"]
        let uid = user.string("idstr", "id")
        let bid = data["mblogid"].string
        let cover = pageInfo["page_pic"].isObject ? pageInfo["page_pic"]["url"].string : pageInfo["page_pic"].string
        return VideoParseResult(platform: platform, title: title, author: user["screen_name"].string,
                                avatar: user.string("avatar_large", "profile_image_url"), cover: Self.https(cover), text: text,
                                timestamp: Self.parseTime(data["created_at"].string),
                                url: (!uid.isEmpty && !bid.isEmpty) ? "https://weibo.com/\(uid)/\(bid)" : link.url,
                                medias: Self.medias(refs, base: base, headers: mediaHeaders(cookie)))
    }

    // MARK: 媒体映射（纯函数，便于测试）

    /// 手机站 status：page_info 视频 + pics（实况：原图 + mov；动图：videoSrc 的 mp4）+ 混排
    static func mobileMedias(_ data: JSON) -> [WeiboMediaRef] {
        var refs: [WeiboMediaRef] = []
        let pageInfo = data["page_info"]
        let urls = pageInfo["urls"]
        let candidates = [urls["mp4_1080p_mp4"], urls["mp4_720p_mp4"], urls["mp4_hd_mp4"], urls["mp4_ld_mp4"]].map { $0.string }
        let video = candidates.first(where: { !$0.isEmpty }) ?? pageInfo["media_info"]["stream_url_hd"].string
        if !video.isEmpty {
            refs.append(WeiboMediaRef(url: https(video), kind: .video, ext: "mp4", quality: ""))
        }
        for pic in data["pics"].array {
            let still = https(pic["large"]["url"].string.isEmpty ? pic["url"].string : pic["large"]["url"].string)
            let type = pic["type"].string.lowercased()
            let videoSrc = https(pic["videoSrc"].string)
            if type.contains("gif") && !videoSrc.isEmpty {
                refs.append(WeiboMediaRef(url: videoSrc, kind: .video, ext: "mp4", quality: "动图"))
                continue
            }
            guard !still.isEmpty else { continue }
            refs.append(WeiboMediaRef(url: still, kind: .image, ext: imageExt(still), quality: "原图"))
            if type == "livephoto" && !videoSrc.isEmpty {
                refs.append(WeiboMediaRef(url: videoSrc, kind: .video, ext: "mov", quality: "实况", isLive: true))
            }
        }
        if data["pics"].array.isEmpty { refs += mixMedias(data["mix_media_info"]) }
        return refs
    }

    /// weibo.com/ajax status：pic_infos（按 pic_ids 排序）→ 混排 mix_media_info → page_info 视频
    static func ajaxMedias(_ data: JSON) -> [WeiboMediaRef] {
        let infos = data["pic_infos"]
        var ids = data["pic_ids"].array.map { $0.string }.filter { infos[$0].isObject }
        if ids.isEmpty { ids = infos.keys.sorted() }
        var refs: [WeiboMediaRef] = []
        for id in ids { refs += picMedias(infos[id]) }
        if refs.isEmpty { refs = mixMedias(data["mix_media_info"]) }
        if refs.isEmpty && data["page_info"]["object_type"].string == "video" {
            let video = pageVideoURL(data["page_info"])
            if !video.isEmpty { refs.append(WeiboMediaRef(url: video, kind: .video, ext: "mp4", quality: "")) }
        }
        return refs
    }

    static func mixMedias(_ mix: JSON) -> [WeiboMediaRef] {
        var refs: [WeiboMediaRef] = []
        for item in mix["items"].array {
            switch item["type"].string {
            case "pic":
                refs += picMedias(item["data"])
            case "video":
                let video = pageVideoURL(item["data"])
                if !video.isEmpty { refs.append(WeiboMediaRef(url: video, kind: .video, ext: "mp4", quality: "")) }
            default:
                continue
            }
        }
        return refs
    }

    /// pic_infos 里的一项：pic 取最大尺寸；livephoto 取原图 + mov；gif 取视频（没有则原 gif）
    static func picMedias(_ info: JSON) -> [WeiboMediaRef] {
        let still = largestURL(info)
        let video = https(info["video"].string)
        switch info["type"].string {
        case "gif":
            if !video.isEmpty { return [WeiboMediaRef(url: video, kind: .video, ext: "mp4", quality: "动图")] }
            return still.isEmpty ? [] : [WeiboMediaRef(url: still, kind: .image, ext: imageExt(still), quality: "动图")]
        case "livephoto":
            var refs: [WeiboMediaRef] = []
            if !still.isEmpty { refs.append(WeiboMediaRef(url: still, kind: .image, ext: imageExt(still), quality: "原图")) }
            if !video.isEmpty { refs.append(WeiboMediaRef(url: video, kind: .video, ext: "mov", quality: "实况", isLive: !still.isEmpty)) }
            return refs
        default:
            return still.isEmpty ? [] : [WeiboMediaRef(url: still, kind: .image, ext: imageExt(still), quality: "原图")]
        }
    }

    static func largestURL(_ info: JSON) -> String {
        for key in ["largest", "original", "mw2000", "large", "bmiddle"] {
            let url = info[key]["url"].string
            if !url.isEmpty { return https(url) }
        }
        return ""
    }

    /// 视频 page_info：playback_list 里分辨率最高的一档，退回 mp4_* 直链
    static func pageVideoURL(_ pageInfo: JSON) -> String {
        let mediaInfo = pageInfo["media_info"]
        var bestURL = ""
        var bestPixels = -1
        for playback in mediaInfo["playback_list"].array {
            let info = playback["play_info"]
            let url = info["url"].string
            guard !url.isEmpty else { continue }
            let pixels = info["width"].int * info["height"].int
            if pixels > bestPixels {
                bestPixels = pixels
                bestURL = url
            }
        }
        if bestURL.isEmpty {
            bestURL = mediaInfo.string("mp4_720p_mp4", "mp4_hd_url", "mp4_sd_url", "stream_url_hd", "stream_url")
        }
        return https(bestURL)
    }

    /// 中间形态 → VideoMedia：只有一个媒体时不编号；实况视频与前一张图同号（_live 后缀）
    static func medias(_ refs: [WeiboMediaRef], base: String, headers: [String: String]) -> [VideoMedia] {
        var out: [VideoMedia] = []
        var index = 0
        for ref in refs {
            let name: String
            if refs.count == 1 {
                name = "\(base).\(ref.ext)"
            } else if ref.isLive && index > 0 {
                name = "\(base)_\(index)_live.\(ref.ext)"
            } else {
                index += 1
                name = "\(base)_\(index).\(ref.ext)"
            }
            out.append(VideoMedia(url: ref.url, kind: ref.kind, fileName: name, headers: headers, quality: ref.quality))
        }
        return out
    }

    static func imageExt(_ url: String) -> String {
        let last = url.substringBefore("?").substringAfterLast("/")
        let e = last.contains(".") ? last.substringAfterLast(".").lowercased() : ""
        return ["jpg", "jpeg", "png", "gif", "webp"].contains(e) ? e : "jpg"
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
