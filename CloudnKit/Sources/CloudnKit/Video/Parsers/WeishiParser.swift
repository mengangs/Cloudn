// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 weishi 解析。
import Foundation

/// 微视：H5 播放页接口 `h5.weishi.qq.com/webapp/json/weishi/WSH5GetPlayPage?feedid={id}` → data.feeds[0].video_url。
/// 分享页 isee.weishi.qq.com/...?id={feedid} 直接取 id；video.weishi.qq.com 短链走统一的短链展开。
struct WeishiParser: VideoParser {
    let platform = VideoPlatform.weishi

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaIPhone, "Referer": "https://isee.weishi.qq.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法识别微视链接") }
        let payload = try await VideoHTTP.getJSON("https://h5.weishi.qq.com/webapp/json/weishi/WSH5GetPlayPage?feedid=\(id)",
                                                  headers: headers, what: "微视作品")
        let feed = try Self.feed(payload)
        let title = feed["feed_desc_withat"].string.nilIfBlank ?? feed["feed_desc"].string
        let base = FileNames.base(title, fallback: "weishi_\(id)")
        let videoURL = feed["video_url"].string
        guard !videoURL.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let media = VideoMedia(url: videoURL, kind: .video, fileName: "\(base).mp4", headers: headers)
        let poster = feed["poster"]
        return VideoParseResult(platform: platform, title: title, author: poster["nick"].string, avatar: poster["avatar"].string,
                                cover: feed["images"][0]["url"].string, timestamp: feed["createtime"].int64,
                                url: "https://isee.weishi.qq.com/ws/app-pages/share/index.html?id=\(id)", medias: [media])
    }

    // MARK: 纯逻辑

    static func feed(_ payload: JSON) throws -> JSON {
        if payload["ret"].int != 0 {
            let msg = payload["msg"].string
            throw VideoParseError(.unknown, "微视返回错误：\(msg.isEmpty ? "未知错误" : msg)")
        }
        let errmsg = payload["data"]["errmsg"].string
        if !errmsg.isEmpty { throw VideoParseError(.notFound, "微视：\(errmsg)") }
        let feed = payload["data"]["feeds"][0]
        guard feed.isObject else { throw VideoParseError(.notFound, "微视作品不存在或已删除") }
        return feed
    }
}
