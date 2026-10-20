// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 BilibiliParser；动态 / opus 部分参考 ParseHub（MIT，z-mio/ParseHub）的 bilibili 解析。
import Foundation

/// 哔哩哔哩：已登录优先取 DASH 高清（音视频分轨，下载后在 iOS 端用 AVFoundation 合轨），
/// 否则退回 `fnval=1` 的单文件 mp4 直链（清晰度较低）。
struct BilibiliParser: VideoParser {
    let platform = VideoPlatform.bilibili

    static let viewURL = "https://api.bilibili.com/x/web-interface/view"
    static let playURL = "https://api.bilibili.com/x/player/playurl"
    static let navURL = "https://api.bilibili.com/x/web-interface/nav"

    static func headers(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.bilibili.com/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    static func nickname(cookie: String) async -> String? {
        guard !cookie.isEmpty, let json = try? await VideoHTTP.getJSON(navURL, headers: headers(cookie), what: "B站登录态校验"),
              json["data"]["isLogin"].bool else { return nil }
        let name = json["data"]["uname"].string
        return name.isEmpty ? "B站用户" : name
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        if link.kind == "dynamic" { return try await parseDynamic(link, cookie: cookie) }
        return try await parseVideo(link, cookie: cookie)
    }

    private func parseVideo(_ link: DetectedVideoLink, cookie userCookie: String) async throws -> VideoParseResult {
        // 匿名访问（尤其海外 IP）不带 buvid3 时 view 接口会直接 412：补一份匿名指纹，用户自己的 Cookie 原样保留
        var cookie = userCookie
        if (CookieUtil.value(of: "buvid3", in: cookie) ?? "").isEmpty, let ids = await Self.buvid() {
            cookie = CookieUtil.setting("buvid3", ids.b3, in: cookie)
            if !ids.b4.isEmpty && (CookieUtil.value(of: "buvid4", in: cookie) ?? "").isEmpty {
                cookie = CookieUtil.setting("buvid4", ids.b4, in: cookie)
            }
        }
        let query = link.id.lowercased().hasPrefix("bv") ? "bvid=\(link.id)" : "aid=\(link.id.dropFirst(2))"
        let view = try await VideoHTTP.getJSON("\(Self.viewURL)?\(query)", headers: Self.headers(cookie), what: "B站视频信息")
        guard view["code"].int == 0 else {
            throw VideoParseError(.notFound, "B站视频信息接口返回 code=\(view["code"].int) \(view["message"].string)")
        }
        let data = view["data"]
        let bvid = data["bvid"].string
        // 多 P 视频：按链接里的 ?p= 取对应分 P
        let explicitPage = Rx(#"[?&]p=(\d+)"#).first(in: link.url)
        let pageIndex = max(0, (Int(explicitPage ?? "1") ?? 1) - 1)
        let pages = data["pages"].array
        let page = pageIndex < pages.count ? pages[pageIndex] : pages.first ?? JSON(nil)
        let cid = page["cid"].int64 > 0 ? page["cid"].int64 : data["cid"].int64
        guard !bvid.isEmpty, cid > 0 else { throw VideoParseError(.unknown, "B站视频信息缺少 bvid/cid") }

        var title = data["title"].string
        if pages.count > 1 { title += " P\(pageIndex + 1) \(page["part"].string)" }
        let base = FileNames.base(title, fallback: "bilibili_\(bvid)")

        // DASH 分轨：列出每档清晰度（最高档在前，作为默认），下载后合并；未登录时最高通常只有 480P / 720P
        var medias: [VideoMedia] = []
        if let choices = try? await dashChoices(bvid: bvid, cid: cid, cookie: cookie) {
            for (i, c) in choices.enumerated() {
                let label = Self.qualityLabel(c.quality) + (c.hevc ? " · HEVC" : "")
                let name = i == 0 ? "\(base).mp4" : "\(base)_\(FileNames.base(label, fallback: "\(c.quality)")).mp4"
                medias.append(VideoMedia(url: c.video, kind: .video, fileName: name, headers: Self.headers(cookie),
                                         quality: label, audioURL: c.audio, variantGroup: "video"))
            }
        }
        var media: VideoMedia?
        if medias.isEmpty {
            let play = try await VideoHTTP.getJSON(
                "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=80&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1",
                headers: Self.headers(cookie), what: "B站取直链")
            let first = play["data"]["durl"][0]
            let url = first["url"].string
            guard !url.isEmpty else {
                throw VideoParseError(.unsupported, "B站未返回可下载的视频流（可能是番剧/付费内容）")
            }
            media = VideoMedia(url: url, kind: .video, fileName: "\(base).mp4", size: first["size"].int64 > 0 ? first["size"].int64 : -1,
                               headers: Self.headers(cookie), quality: Self.qualityLabel(play["data"]["quality"].int))
        }
        let owner = data["owner"]
        let collection = Self.collection(data, explicitPage: explicitPage != nil)
        let subtitles = await subtitleTracks(bvid: bvid, cid: cid, cookie: cookie)
        return VideoParseResult(platform: platform, title: collection.title ?? title, author: owner["name"].string,
                                avatar: owner["face"].string, cover: data["pic"].string, text: data["desc"].string,
                                timestamp: data["pubdate"].int64, url: "https://www.bilibili.com/video/\(bvid)",
                                medias: medias.isEmpty ? (media.map { [$0] } ?? []) : medias, notice: collection.notice,
                                entries: collection.entries, subtitles: subtitles)
    }

    struct DashChoice: Equatable {
        let video: String
        let audio: String
        let quality: Int
        let hevc: Bool
    }

    /// fnval=4048 一次要齐 HDR / 4K / 杜比视界 / 8K / AV1 各档；qn=127 表示要最高档
    private func dashChoices(bvid: String, cid: Int64, cookie: String) async throws -> [DashChoice] {
        let json = try await VideoHTTP.getJSON("\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=127&fnval=4048&fnver=0&fourk=1",
                                               headers: Self.headers(cookie), what: "B站取 DASH 直链")
        return Self.dashChoices(json["data"]["dash"])
    }

    /// 每档清晰度一条：同档优先 H.264（codecid 7，兼容最好），没有才用 HEVC（codecid 12，4K / HDR 常常只有它）。
    /// AV1（codecid 13）不选：iOS 的合轨与播放只在新机型上支持。音轨取码率最高的 AAC
    static func dashChoices(_ dash: JSON) -> [DashChoice] {
        let audios = dash["audio"].array
        guard let audio = audios.max(by: { $0["bandwidth"].int < $1["bandwidth"].int }) else { return [] }
        let audioURL = audio.string("baseUrl", "base_url")
        guard !audioURL.isEmpty else { return [] }
        var best: [Int: (codec: Int, url: String, bandwidth: Int)] = [:]
        for v in dash["video"].array {
            let codec = v["codecid"].int
            guard codec == 7 || codec == 12 else { continue }
            let url = v.string("baseUrl", "base_url")
            guard !url.isEmpty else { continue }
            let id = v["id"].int
            let bandwidth = v["bandwidth"].int
            if let current = best[id] {
                // 同档：H.264 优先；同编码取码率高的
                let better = (codec == 7 && current.codec != 7) || (codec == current.codec && bandwidth > current.bandwidth)
                if !better { continue }
            }
            best[id] = (codec, url, bandwidth)
        }
        return best.keys.sorted(by: >).compactMap { id in
            guard let v = best[id] else { return nil }
            return DashChoice(video: v.url, audio: audioURL, quality: id, hevc: v.codec == 12)
        }
    }

    static func qualityLabel(_ qn: Int) -> String {
        switch qn {
        case 6, 7: return "240P"
        case 16: return "360P"
        case 32: return "480P"
        case 64: return "720P"
        case 74: return "720P60"
        case 80: return "1080P"
        case 112: return "1080P+"
        case 116: return "1080P60"
        case 120: return "4K"
        case 125: return "HDR"
        case 126: return "杜比视界"
        case 127: return "8K"
        default: return qn > 0 ? "画质 \(qn)" : ""
        }
    }
}

// MARK: 动态 / opus（t.bilibili.com、bilibili.com/opus、m.bilibili.com/dynamic）

/// 动态里的一张图；liveURL 非空表示实况照片（附带一段短视频）
struct BiliDynamicPic: Equatable, Sendable {
    let url: String
    let liveURL: String
}

enum BiliDynamicContent: Equatable, Sendable {
    /// 视频动态：交给视频解析
    case video(String)
    case pictures([BiliDynamicPic])
    case nothing
}

extension BilibiliParser {
    static let spiURL = "https://api.bilibili.com/x/frontend/finger/spi"
    static let dynamicURL = "https://api.bilibili.com/x/polymer/web-dynamic/v1/detail"

    /// 匿名指纹 buvid3 / buvid4：旧值失效会触发 -352 风控，每次现取
    static func buvid() async -> (b3: String, b4: String)? {
        guard let json = try? await VideoHTTP.getJSON(spiURL, headers: ["User-Agent": VideoHTTP.uaChrome], what: "B站指纹") else { return nil }
        let b3 = json["data"]["b_3"].string
        let b4 = json["data"]["b_4"].string
        guard !b3.isEmpty else { return nil }
        return (b3: b3, b4: b4)
    }

    func parseDynamic(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id.isEmpty ? (Rx(#"(\d{16,20})"#).first(in: link.url) ?? "") : link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "没有识别出B站动态 ID") }
        var requestCookie = cookie
        if let ids = await Self.buvid() {
            requestCookie = CookieUtil.setting("buvid3", ids.b3, in: requestCookie)
            if !ids.b4.isEmpty { requestCookie = CookieUtil.setting("buvid4", ids.b4, in: requestCookie) }
        }
        var headers = Self.headers(requestCookie)
        headers["Referer"] = "https://t.bilibili.com/\(id)"
        let json = try await VideoHTTP.getJSON("\(Self.dynamicURL)?timezone_offset=-480&id=\(id)&features=itemOpusStyle",
                                               headers: headers, what: "B站动态")
        let item = json["data"]["item"]
        guard json["code"].int == 0, item.isObject else {
            throw Self.dynamicError(code: json["code"].int, message: json["message"].string)
        }
        switch Self.dynamicContent(item) {
        case .video(let bvid):
            let videoLink = DetectedVideoLink(platform: .bilibili, kind: "video", id: bvid, url: "https://www.bilibili.com/video/\(bvid)")
            return try await parseVideo(videoLink, cookie: cookie)
        case .pictures(let pics):
            return try buildDynamic(item, id: id, pics: pics, cookie: cookie)
        case .nothing:
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
        }
    }

    private func buildDynamic(_ item: JSON, id: String, pics: [BiliDynamicPic], cookie: String) throws -> VideoParseResult {
        guard !pics.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let text = Self.dynamicText(item)
        let opusTitle = Self.dynamicTitle(item)
        let title = opusTitle.isEmpty ? String(text.prefix(40)) : opusTitle
        let base = FileNames.base(title, fallback: "bilibili_dynamic_\(id)")
        let headers = Self.headers(cookie)
        let medias = Self.dynamicMedias(pics, base: base, headers: headers)
        let author = item["modules"]["module_author"]
        return VideoParseResult(platform: .bilibili, title: title, author: author["name"].string, avatar: author["face"].string,
                                cover: pics[0].url, text: text, timestamp: author["pub_ts"].int64,
                                url: "https://t.bilibili.com/\(id)", medias: medias)
    }

    static func dynamicError(code: Int, message: String) -> VideoParseError {
        switch code {
        case -352: return VideoParseError(.blocked, "B站动态接口触发风控（-352），请稍后重试")
        case 4101152, 4101131, 4101105: return VideoParseError(.notFound, "B站动态不存在或不可见（\(code)）")
        case -101: return VideoParseError(.unsupported, "该动态需要登录后查看，请先到「我的」页登录哔哩哔哩")
        default: return VideoParseError(.unknown, "B站动态接口返回 code=\(code) \(message)")
        }
    }

    /// 动态 item → 内容：图文取 opus.pics（旧版 draw.items），视频取 archive.bvid，转发动态看 orig
    static func dynamicContent(_ item: JSON) -> BiliDynamicContent {
        let major = item["modules"]["module_dynamic"]["major"]
        guard major.isObject else {
            return item["orig"].isObject ? dynamicContent(item["orig"]) : .nothing
        }
        switch major["type"].string {
        case "MAJOR_TYPE_ARCHIVE":
            let archive = major["archive"]
            let bvid = archive["bvid"].string
            if !bvid.isEmpty { return .video(bvid) }
            let aid = archive["aid"].string
            return aid.isEmpty ? .nothing : .video("av\(aid)")
        case "MAJOR_TYPE_OPUS":
            let pics = major["opus"]["pics"].array.map { BiliDynamicPic(url: $0["url"].string, liveURL: $0["live_url"].string) }
            let valid = pics.filter { !$0.url.isEmpty }
            return valid.isEmpty ? .nothing : .pictures(valid)
        case "MAJOR_TYPE_DRAW":
            let pics = major["draw"]["items"].array.map { BiliDynamicPic(url: $0["src"].string, liveURL: "") }
            let valid = pics.filter { !$0.url.isEmpty }
            return valid.isEmpty ? .nothing : .pictures(valid)
        default:
            return .nothing
        }
    }

    static func dynamicTitle(_ item: JSON) -> String {
        let title = item["modules"]["module_dynamic"]["major"]["opus"]["title"].string
        if title.isEmpty && item["orig"].isObject { return dynamicTitle(item["orig"]) }
        return title
    }

    static func dynamicText(_ item: JSON) -> String {
        let dynamic = item["modules"]["module_dynamic"]
        let summary = dynamic["major"]["opus"]["summary"]["text"].string.trimmed
        if !summary.isEmpty { return summary }
        let desc = dynamic["desc"]["text"].string.trimmed
        if !desc.isEmpty { return desc }
        return item["orig"].isObject ? dynamicText(item["orig"]) : ""
    }

    /// 图片按序编号；实况照片紧跟一段同号的视频
    static func dynamicMedias(_ pics: [BiliDynamicPic], base: String, headers: [String: String]) -> [VideoMedia] {
        var medias: [VideoMedia] = []
        for (i, pic) in pics.enumerated() {
            let name = pics.count == 1 ? base : "\(base)_\(i + 1)"
            medias.append(VideoMedia(url: pic.url, kind: .image, fileName: "\(name).\(fileExt(pic.url, fallback: "jpg"))",
                                     headers: headers, quality: "原图"))
            if !pic.liveURL.isEmpty {
                medias.append(VideoMedia(url: pic.liveURL, kind: .video, fileName: "\(name)_live.\(fileExt(pic.liveURL, fallback: "mp4"))",
                                         headers: headers, quality: "实况"))
            }
        }
        return medias
    }

    static func fileExt(_ url: String, fallback: String) -> String {
        let last = url.substringBefore("?").substringAfterLast("/")
        let e = last.contains(".") ? last.substringAfterLast(".").lowercased() : ""
        return ["jpg", "jpeg", "png", "gif", "webp", "avif", "mp4", "mov"].contains(e) ? e : fallback
    }
}
