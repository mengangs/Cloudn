// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 huoshan 解析。
import Foundation

/// 抖音火山版：`share.huoshan.com/api/item/info?item_id={id}` → data.item_info.url / cover。
/// 分享短链 share.huoshan.com/hotsoon/s/xxx 在解析器内逐跳展开（kind = "share"），从落地页取 item_id；
/// 新版分享链可能直接落到抖音分享页，此时按抖音分享页（_ROUTER_DATA）解析。
struct HuoshanParser: VideoParser {
    let platform = VideoPlatform.huoshan

    static let itemRx = Rx(#"[?&]item_id=(\d+)"#, ignoreCase: true)
    static let douyinRx = Rx(#"(?:iesdouyin|douyin)\.com/(?:share/)?video/(\d{10,})"#, ignoreCase: true)

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaIPhone, "Referer": "https://share.huoshan.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var itemID = link.kind == "item" ? link.id : ""
        if link.kind == "share" {
            let start = link.id.isEmpty ? link.url : "https://share.huoshan.com/hotsoon/s/\(link.id)/"
            let landing = try await resolveShare(start)
            if let id = Self.itemRx.first(in: landing) {
                itemID = id
            } else if let awemeID = Self.douyinRx.first(in: landing) {
                return try await parseDouyin(awemeID, url: landing)
            }
        }
        guard !itemID.isEmpty else { throw VideoParseError(.unsupported, "抖音火山版分享链接展开失败，请复制完整链接后重试") }

        let payload = try await VideoHTTP.getJSON("https://share.huoshan.com/api/item/info?item_id=\(itemID)", headers: headers,
                                                  what: "抖音火山版作品")
        guard let info = Self.itemInfo(payload) else {
            throw VideoParseError(.notFound, "抖音火山版作品不存在或已删除")
        }
        let media = VideoMedia(url: info.url, kind: .video, fileName: "huoshan_\(itemID).mp4", headers: headers)
        return VideoParseResult(platform: platform, title: "火山视频 \(itemID)", cover: info.cover,
                                url: "https://share.huoshan.com/pages/item/index.html?item_id=\(itemID)", medias: [media])
    }

    private func resolveShare(_ url: String) async throws -> String {
        var current = url
        for _ in 0..<5 {
            if Self.itemRx.matches(current) || Self.douyinRx.matches(current) { return current }
            guard let next = try await VideoHTTP.expandRedirect(current, headers: headers) else { break }
            current = next
        }
        return current
    }

    /// 已迁到抖音的作品：走抖音分享页（不需要浏览器内核的那条回退路线），结果仍记在火山名下
    private func parseDouyin(_ awemeID: String, url: String) async throws -> VideoParseResult {
        let link = DetectedVideoLink(platform: .douyin, kind: "video", id: awemeID, url: "https://www.iesdouyin.com/share/video/\(awemeID)/")
        let r = try await DouyinParser(extractor: nil).parse(link, cookie: "")
        return VideoParseResult(platform: platform, title: r.title, author: r.author, avatar: r.avatar, cover: r.cover, text: r.text,
                                timestamp: r.timestamp, url: url, medias: r.medias, notice: r.notice)
    }

    // MARK: 纯逻辑

    static func itemInfo(_ payload: JSON) -> (url: String, cover: String)? {
        let info = payload["data"]["item_info"]
        let url = info["url"].string
        guard !url.isEmpty else { return nil }
        return (url: url, cover: info["cover"].string)
    }
}
