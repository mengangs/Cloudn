// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 AcFunParser。
import Foundation

/// AcFun：作品页带 ajaxpipe=1 时内嵌 window.videoInfo，ksPlayJson 里是各清晰度 m3u8。
struct AcFunParser: VideoParser {
    let platform = VideoPlatform.acfun
    static let referer = "https://www.acfun.cn/"

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let html = try await VideoHTTP.getText("https://www.acfun.cn/v/ac\(link.id)?quickViewId=videoInfo_new&ajaxpipe=1",
                                               headers: headers, what: "AcFun 视频")
        guard let raw = VideoHTTP.extractInlineJSON(html, key: "window.videoInfo") else {
            throw VideoParseError(.notFound, "AcFun 页面里没有 videoInfo（可能已删除）")
        }
        guard let info = Self.decodeVideoInfo(raw) else { throw VideoParseError(.unknown, "AcFun 视频信息解析失败") }
        let variants = Self.variants(info)
        guard !variants.isEmpty else { throw VideoParseError(.unknown, "AcFun 未取到视频流地址") }
        let title = info["title"].string
        return VideoParseResult(
            platform: platform, title: title, author: info["user"]["name"].string, cover: info["coverUrl"].string,
            text: info["description"].string, url: link.url,
            medias: DomesticVariant.medias(variants, base: FileNames.base(title, fallback: "acfun_\(link.id)"), headers: headers))
    }

    /// ajaxpipe 返回的内嵌 JSON 被多转义了一层：先按原样解析，不行再还原引号
    static func decodeVideoInfo(_ raw: String) -> JSON? {
        if let j = JSON(text: raw), j.isObject { return j }
        let unescaped = raw.replacingOccurrences(of: "\\\\\"", with: "\\\"")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\/", with: "/")
        if let j = JSON(text: unescaped), j.isObject { return j }
        return nil
    }

    /// 取清晰度最高的一档（representation 按 4K → 360P 降序）
    static func pickM3U8(_ info: JSON) -> (url: String, quality: String)? {
        variants(info).first.map { (url: $0.url, quality: $0.label) }
    }

    /// 各档清晰度的 m3u8（每档一个子列表，按 representation 原顺序 4K → 360P），第一档为默认
    static func variants(_ info: JSON) -> [DomesticVariant] {
        let current = info["currentVideoInfo"]
        let ks = current["ksPlayJson"].isObject ? current["ksPlayJson"] : (JSON(text: current["ksPlayJson"].string) ?? JSON(nil))
        let reps = ks["adaptationSet"][0]["representation"].array.filter { !$0["url"].string.isEmpty }
        return DomesticVariant.normalized(reps.map {
            DomesticVariant(url: $0["url"].string, label: $0.string("qualityLabel", "qualityType"), isHLS: true)
        })
    }
}
