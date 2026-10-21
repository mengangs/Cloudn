// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 wxchannels 解析。
import Foundation

/// 微信视频号：借腾讯元宝（yuanbao.tencent.com）的「解析视频号链接」能力。
///
/// 1. 带元宝登录 Cookie POST `/api/weixin/get_parse_result`，拿到 `playable_url`
///    （channels.weixin.qq.com/finder-preview 的网页播放地址，查询串里带 `token` 与 `eid`）；
/// 2. 用 token / eid 调 finder-preview 的 `get_feed_info`（不需要 Cookie），取 feedInfo 里的视频直链；
/// 3. 视频优先 H.264，其次 videoUrl、H.265。图片动态（picInfo）按图集返回（ParseHub 只取视频，这里补上）。
///
/// 这条链路给的是网页可直接播放的明文流，不带 decodeKey，无需解密（见 WxChannelsCrypto）。
struct WxChannelsParser: VideoParser {
    let platform = VideoPlatform.wxchannels

    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36"
    static let loginURL = "https://yuanbao.tencent.com/"
    static let yuanbaoAPI = "https://yuanbao.tencent.com/api/weixin/get_parse_result"
    static let feedAPI = "https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info"
    static let feedPage = "https://channels.weixin.qq.com/finder-preview/pages/feed"
    static let needLogin = "解析视频号需要登录腾讯元宝：请先到「我的」页登录腾讯元宝"
    static let expired = "腾讯元宝登录已失效：请到「我的」页重新登录腾讯元宝"

    // MARK: 入口

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        guard !cookie.trimmed.isEmpty else { throw VideoParseError(.unsupported, Self.needLogin) }
        let fromLink: String? = link.id.nilIfBlank
        guard let shareID = fromLink ?? Self.shareID(in: link.url) else {
            throw VideoParseError(.unsupported, "不支持的微信视频号链接")
        }

        // 1. 元宝解析分享链接
        let yr = try await VideoHTTP.send(.postJSON(Self.yuanbaoAPI, Self.yuanbaoBody(shareID: shareID),
                                                     headers: Self.yuanbaoHeaders(cookie: cookie)))
        let data = try Self.yuanbaoData(status: yr.status, json: yr.json)
        let playable = data["playable_url"].string
        guard !data["wx_export_id"].string.isEmpty, !playable.isEmpty else {
            throw VideoParseError(.notFound, "微信视频号视频不存在或已删除")
        }
        guard let params = Self.playableParams(playable) else {
            throw VideoParseError(.unknown, "无法获取视频号视频信息")
        }

        // 2. finder-preview 取视频详情
        let feedURL = Self.feedURL(rid: Self.makeRid())
        let body: [String: Any] = ["baseReq": ["generalToken": params.token], "exportId": params.exportID]
        let headers: [(String, String)] = [
            ("User-Agent", Self.ua),
            ("Origin", "https://channels.weixin.qq.com"),
            ("Referer", playable)
        ]
        let fr = try await VideoHTTP.send(.postJSON(feedURL, body, headers: headers))
        try VideoHTTP.requireSuccess(fr, "视频号详情")
        guard let feedJSON = fr.json else { throw VideoParseError(.unknown, "视频号详情返回的不是合法 JSON") }
        let feed = try Self.feedData(feedJSON)
        return try Self.buildResult(feed: feed, yuanbao: data, shareID: shareID)
    }

    // MARK: 请求

    static func yuanbaoBody(shareID: String) -> [String: Any] {
        ["type": "video_channel_url", "url": shareURL(shareID), "scene": 1]
    }

    static func yuanbaoHeaders(cookie: String) -> [(String, String)] {
        [
            ("User-Agent", ua),
            ("Origin", "https://yuanbao.tencent.com"),
            ("Referer", "https://yuanbao.tencent.com/"),
            ("Cookie", cookie)
        ]
    }

    static func shareURL(_ id: String) -> String { "https://weixin.qq.com/sph/\(id)" }

    static func feedURL(rid: String) -> String {
        "\(feedAPI)?_rid=\(rid)&_pageUrl=\(feedPage.urlQueryEncoded)"
    }

    /// `_rid`：秒级时间戳十六进制 + "-" + 8 位随机十六进制
    static func makeRid(now: Date = Date()) -> String {
        let ts = String(Int(now.timeIntervalSince1970), radix: 16)
        let digits = Array("0123456789abcdef")
        var tail = ""
        for _ in 0..<8 { tail.append(digits[Int.random(in: 0..<16)]) }
        return "\(ts)-\(tail)"
    }

    // MARK: 链接

    /// 分享链接里的视频号 id：`weixin.qq.com/sph/<id>` 或 `channels.weixin.qq.com/finder-preview/pages/sph?...id=<id>`
    static func shareID(in url: String) -> String? {
        if let id = Rx(#"weixin\.qq\.com/sph/([A-Za-z0-9_]+)"#, ignoreCase: true).first(in: url), !id.isEmpty { return id }
        let rx = Rx(#"channels\.weixin\.qq\.com/finder-preview/pages/sph\?[^#\s]*?\bid=([A-Za-z0-9_]+)"#, ignoreCase: true)
        if let id = rx.first(in: url), !id.isEmpty { return id }
        return nil
    }

    /// playable_url 查询串里的 token / eid
    static func playableParams(_ playable: String) -> (token: String, exportID: String)? {
        guard let items = URLComponents(string: playable)?.queryItems else { return nil }
        let token = items.first(where: { $0.name == "token" })?.value ?? ""
        let eid = items.first(where: { $0.name == "eid" })?.value ?? ""
        guard !token.isEmpty, !eid.isEmpty else { return nil }
        return (token, eid)
    }

    // MARK: 响应

    /// 元宝接口：401 / error.code 20000 为登录失效；其余 error 或 code ≠ 0 均为失败
    static func yuanbaoData(status: Int, json: JSON?) throws -> JSON {
        if status == 401 { throw VideoParseError(.unsupported, expired) }
        guard let json, json.isObject else {
            if !(200..<300).contains(status) { throw VideoParseError(.unknown, "腾讯元宝解析请求失败（HTTP \(status)）") }
            throw VideoParseError(.unknown, "腾讯元宝返回的不是合法 JSON")
        }
        let error = json["error"]
        // 与 Python 的真值判断一致：null / 空对象 / 空串都当没有错误
        let hasError = (error.isObject && !error.keys.isEmpty) || !error.string.isEmpty
        if hasError {
            if error["code"].string == "20000" { throw VideoParseError(.unsupported, expired) }
            let message = error["message"].string
            let detail = message.isEmpty ? error.string : message
            throw VideoParseError(.unknown, "腾讯元宝解析失败：\(detail.isEmpty ? "未知错误" : detail)")
        }
        if !(200..<300).contains(status) { throw VideoParseError(.unknown, "腾讯元宝解析请求失败（HTTP \(status)）") }
        if !json.has("code") || json["code"].int != 0 {
            let message = json.string("message", "msg")
            throw VideoParseError(.unknown, message.isEmpty ? "微信视频号解析失败" : "微信视频号解析失败：\(message)")
        }
        return json["data"]
    }

    /// finder-preview 接口：errCode ≠ 0 或 data.errMsg 有标题/内容都算失败
    static func feedData(_ json: JSON) throws -> JSON {
        let data = json["data"]
        let errObj = data["errMsg"]
        let parts = [stripHTML(errObj["title"].string), stripHTML(errObj["content"].string)]
        let errorText = parts.joined(separator: " ").trimmed
        if !json.has("errCode") || json["errCode"].int != 0 {
            let message = json["errMsg"].string
            throw VideoParseError(.unknown, message.isEmpty ? "微信视频号解析失败" : "微信视频号解析失败：\(stripHTML(message))")
        }
        if !errorText.isEmpty { throw VideoParseError(.unknown, "微信视频号：\(errorText)") }
        return data
    }

    static func stripHTML(_ s: String) -> String {
        DomesticHTML.unescape(Rx(#"<[^>]*>"#).replacing(in: s, with: "")).trimmed
    }

    /// 视频直链：H.264 → videoUrl → H.265
    static func videoURL(_ feedInfo: JSON) -> (url: String, quality: String)? {
        let h264 = feedInfo["h264VideoInfo"]["videoUrl"].string
        if !h264.isEmpty { return (h264, "H.264") }
        let plain = feedInfo["videoUrl"].string
        if !plain.isEmpty { return (plain, "") }
        let h265 = feedInfo["h265VideoInfo"]["videoUrl"].string
        if !h265.isEmpty { return (h265, "H.265") }
        return nil
    }

    /// 视频的各档：默认档同 videoURL（H.264 优先），同时给了 H.265 时作为另一档（同画质、体积更小）
    static func videoVariants(_ feedInfo: JSON) -> [DomesticVariant] {
        guard let picked = videoURL(feedInfo) else { return [] }
        func size(_ info: JSON) -> Int64 {
            let n = info["fileSize"].int64
            return n > 0 ? n : info["file_size"].int64
        }
        let h264 = feedInfo["h264VideoInfo"]
        let h265 = feedInfo["h265VideoInfo"]
        let first: DomesticVariant
        switch picked.quality {
        case "H.264": first = DomesticVariant(url: picked.url, label: picked.quality, size: size(h264))
        case "H.265": first = DomesticVariant(url: picked.url, label: picked.quality, size: size(h265))
        default: first = DomesticVariant(url: picked.url, label: picked.quality)
        }
        var list = [first]
        let alt = h265["videoUrl"].string
        if picked.quality != "H.265" && !alt.isEmpty && alt != picked.url {
            if list[0].label.isEmpty { list[0].label = "默认" }
            list.append(DomesticVariant(url: alt, label: "H.265", size: size(h265)))
        }
        return DomesticVariant.normalized(list)
    }

    /// 图片动态的原图（picInfo[].url）
    static func imageURLs(_ feedInfo: JSON) -> [String] {
        feedInfo["picInfo"].array.map { $0["url"].string.trimmed }.filter { !$0.isEmpty }
    }

    /// 防御：若接口哪天带上 decodeKey，说明直链是加密流（需 WxChannelsCrypto 解密）
    static func decodeKey(_ feedInfo: JSON) -> String {
        let holders = [feedInfo, feedInfo["h264VideoInfo"], feedInfo["h265VideoInfo"]]
        for h in holders {
            let k = h.string("decodeKey", "decode_key")
            if !k.isEmpty { return k }
        }
        return ""
    }

    static func buildResult(feed: JSON, yuanbao: JSON, shareID: String) throws -> VideoParseResult {
        let info = feed["feedInfo"]
        let authorInfo = feed["authorInfo"]
        let desc = info["description"].string
        let title = desc.isEmpty ? yuanbao["desc"].string : desc
        let nickname = authorInfo["nickname"].string
        let author = nickname.isEmpty ? yuanbao["author"].string : nickname
        let headImg = authorInfo["headImgUrl"].string
        let avatar = headImg.isEmpty ? yuanbao["author_icon"].string : headImg
        let coverURL = info["coverUrl"].string
        let cover = coverURL.isEmpty ? yuanbao["cover_url"].string : coverURL
        let base = FileNames.base(title, fallback: "wxchannels_\(shareID)")
        let headers = ["User-Agent": ua]

        var medias: [VideoMedia] = []
        var notice = ""
        let variants = videoVariants(info)
        if !variants.isEmpty {
            medias += DomesticVariant.medias(variants, base: base, headers: headers)
            if !decodeKey(info).isEmpty {
                notice = "这条视频号视频返回了加密密钥，下载的文件可能需要解密后才能播放"
            }
        } else {
            let images = imageURLs(info)
            for (i, u) in images.enumerated() {
                let ext = DomesticHTML.imageExtension(u)
                let name = images.count == 1 ? "\(base).\(ext)" : "\(base)_\(i + 1).\(ext)"
                medias.append(VideoMedia(url: u, kind: .image, fileName: name, headers: headers))
            }
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "暂不支持该类型的视频号内容（没有可下载的图片或视频）") }

        return VideoParseResult(platform: .wxchannels, title: title.isEmpty ? "微信视频号_\(shareID)" : title, author: author,
                                avatar: avatar, cover: cover, text: desc, timestamp: info["createtime"].int64,
                                url: shareURL(shareID), medias: medias, notice: notice)
    }

    // MARK: 登录态

    /// 元宝登录 Cookie 名：hy_user（用户 ID）+ hy_token（登录令牌），都在 .tencent.com / yuanbao.tencent.com 域下
    static let loginCookieNames = ["hy_user", "hy_token"]

    /// 只看 Cookie 是否齐全（WebView 登录完成判定用）
    static func looksLoggedIn(cookie: String) -> Bool {
        for name in loginCookieNames {
            guard let v = CookieUtil.value(of: name, in: cookie), !v.isEmpty else { return false }
        }
        return true
    }

    /// 展示名：「腾讯元宝用户 · hy_user 末四位」（区分多个账号）
    static func displayName(cookie: String) -> String {
        let user = CookieUtil.value(of: "hy_user", in: cookie) ?? ""
        return user.count >= 4 ? "腾讯元宝用户 · \(user.suffix(4))" : "腾讯元宝用户"
    }

    /// 登录态校验。元宝没有已知的公开轻量用户信息接口：先要求 hy_user / hy_token 齐全，
    /// 再用一个空链接探测解析接口——只有明确的 401 / error.code 20000（ParseHub 认定的登录失效）才判无效，
    /// 探测本身失败或返回其它业务错误时放行（解析时会有明确报错）
    static func validate(cookie: String) async -> String? {
        guard looksLoggedIn(cookie: cookie) else { return nil }
        let body: [String: Any] = ["type": "video_channel_url", "url": "", "scene": 1]
        let request = HTTPRequest.postJSON(yuanbaoAPI, body, headers: yuanbaoHeaders(cookie: cookie))
        guard let r = try? await HTTPClient.shared.send(request) else { return displayName(cookie: cookie) }
        return isLoginExpired(status: r.status, json: r.json) ? nil : displayName(cookie: cookie)
    }

    static func isLoginExpired(status: Int, json: JSON?) -> Bool {
        if status == 401 { return true }
        guard let json else { return false }
        return json["error"]["code"].string == "20000"
    }
}

/// 腾讯元宝账号（解析视频号用）：供应用层登录页使用
public enum YuanbaoAccount {
    public static var loginURL: String { WxChannelsParser.loginURL }

    public static func looksLoggedIn(cookie: String) -> Bool {
        WxChannelsParser.looksLoggedIn(cookie: cookie)
    }
}
