// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 cctv 与 yt-dlp（Unlicense）的 cctv 解析。
import Foundation

/// 央视网：作品页 HTML 里取视频 GUID（`var guid = "…"` 等几种写法），
/// 再请求 `vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid={guid}`（status "001" 为成功）：
/// 取 hls_url 按 HLS 下载（manifest 里 h5e/enc 高码率流做了帧级加扰，不能用）；没有 hls_url 时退回 video.chapters 分段 mp4。
struct CctvParser: VideoParser {
    let platform = VideoPlatform.cctv

    private static let guidPatterns: [Rx] = [
        Rx(#"var\s+guid\s*=\s*["']([\da-fA-F]+)"#),
        Rx(#"videoCenterId(?:["']\s*,|:)\s*["']([\da-fA-F]+)"#),
        Rx(#"changePlayer\s*\(\s*["']([\da-fA-F]+)"#),
        Rx(#"load[Vv]ideo\s*\(\s*["']([\da-fA-F]+)"#),
        Rx(#"var\s+initMyAray\s*=\s*["']([\da-fA-F]+)"#),
        Rx(#"var\s+ids\s*=\s*\[["']([\da-fA-F]+)"#)
    ]

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://tv.cctv.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let html = try await VideoHTTP.getText(link.url, headers: headers, what: "央视网页面")
        var guid = Self.guid(fromHTML: html) ?? ""
        if guid.isEmpty, Rx(#"^[\da-fA-F]{32}$"#).matches(link.id) { guid = link.id }
        guard !guid.isEmpty else { throw VideoParseError(.unsupported, "这个央视网页面里没有找到视频") }

        let api = "https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid=\(guid)"
        let data = try await VideoHTTP.getJSON(api, headers: headers, what: "央视网视频")
        let status = data["status"].string
        guard status == "001" else {
            let msg = data["title"].string.nilIfBlank ?? status
            throw VideoParseError(.notFound, "央视网视频不可用（\(msg)）")
        }
        let title = data["title"].string
        let base = FileNames.base(title, fallback: "cctv_\(guid)")
        var medias: [VideoMedia] = []
        let hls = data["hls_url"].string
        if !hls.isEmpty {
            medias.append(VideoMedia(url: hls, kind: .video, fileName: "\(base).mp4", isHLS: true, headers: headers))
        } else {
            let parts = Self.chapterURLs(data["video"])
            for (i, url) in parts.enumerated() {
                let name = parts.count == 1 ? "\(base).mp4" : "\(base)_part\(i + 1).mp4"
                medias.append(VideoMedia(url: url, kind: .video, fileName: name, headers: headers))
            }
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let author = data["play_channel"].string.nilIfBlank ?? data["editer_name"].string
        return VideoParseResult(platform: platform, title: title, author: author, cover: data["image"].string,
                                url: link.url, medias: medias)
    }

    // MARK: 纯逻辑

    static func guid(fromHTML html: String) -> String? {
        for rx in guidPatterns {
            if let g = rx.first(in: html), !g.isEmpty { return g }
        }
        return nil
    }

    /// 无 hls_url 时的分段 mp4：取清晰度最高的一组 chapters（chapters4 > chapters3 > chapters2 > chapters > lowChapters）
    static func chapterURLs(_ video: JSON) -> [String] {
        for key in ["chapters4", "chapters3", "chapters2", "chapters", "lowChapters"] {
            let urls = video[key].array.map { $0["url"].string }.filter { !$0.isEmpty }
            if !urls.isEmpty { return urls }
        }
        return []
    }
}
