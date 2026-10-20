// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 zuiyou 解析。
import Foundation

/// 最右：`POST share.xiaochuankeji.cn/planck/share/post/detail_h5 {"pid": n}` → data.post。
/// imgs[] 每项的 urls 是「规格 → {urls:[...]}」，取最后一个规格的最后一个地址（与参考实现一致，依赖键顺序，
/// 所以用保序的 JSLiteral 解析）；img.video 为真时视频在 post.videos[img.id].url。
struct ZuiyouParser: VideoParser {
    let platform = VideoPlatform.zuiyou

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        guard let pid = Int(link.id) else { throw VideoParseError(.unsupported, "无法从链接里取到最右帖子 pid") }
        let r = try await VideoHTTP.send(.postJSON("https://share.xiaochuankeji.cn/planck/share/post/detail_h5", ["pid": pid],
                                                   headers: headers.sortedPairs))
        try VideoHTTP.requireSuccess(r, "最右帖子")
        guard let root = JSLiteral.parse(r.text), let post = root["data"]?["post"], case .object = post else {
            let msg = r.json?["msg"].string ?? ""
            throw VideoParseError(.notFound, msg.isEmpty ? "最右帖子不存在或已删除" : "最右：\(msg)")
        }
        let content = post["content"]?.stringValue ?? ""
        let base = FileNames.base(String(content.prefix(40)), fallback: "zuiyou_\(link.id)")
        var medias: [VideoMedia] = []
        var imageIndex = 0
        var videoIndex = 0
        var cover = ""
        for m in Self.medias(post) {
            if cover.isEmpty { cover = m.thumb }
            if m.isVideo {
                videoIndex += 1
                medias.append(VideoMedia(url: m.url, kind: .video, fileName: "\(base)_v\(videoIndex).mp4", headers: headers))
            } else {
                imageIndex += 1
                medias.append(VideoMedia(url: m.url, kind: .image, fileName: "\(base)_\(imageIndex).\(DomesticHTML.imageExtension(m.url))",
                                         headers: headers))
            }
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let member = post["member"]?.json ?? JSON(nil)
        return VideoParseResult(platform: platform, title: String(content.prefix(40)), author: member["name"].string,
                                cover: cover, text: content, timestamp: post["ct"]?.json.int64 ?? 0,
                                url: "https://share.xiaochuankeji.cn/hybrid/share/post?pid=\(link.id)", medias: medias)
    }

    // MARK: 纯逻辑

    struct Item: Equatable {
        let url: String
        let thumb: String
        let isVideo: Bool
    }

    static func medias(_ post: JSLiteral) -> [Item] {
        let videos = post["videos"]
        var result: [Item] = []
        for img in post["imgs"]?.items ?? [] {
            let lastSpec = img["urls"]?.orderedValues.last
            let imgURL = lastSpec?["urls"]?.items.last?.stringValue ?? ""
            let id = img["id"]?.stringValue ?? ""
            let isVideo = img["video"]?.json.bool ?? false
            if isVideo {
                let videoURL = videos?[id]?["url"]?.stringValue ?? ""
                if !videoURL.isEmpty { result.append(Item(url: videoURL, thumb: imgURL, isVideo: true)) }
                continue
            }
            if !imgURL.isEmpty { result.append(Item(url: imgURL, thumb: imgURL, isVideo: false)) }
        }
        return result
    }
}
