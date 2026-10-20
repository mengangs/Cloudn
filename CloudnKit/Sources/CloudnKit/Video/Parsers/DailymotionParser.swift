// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 dailymotion 解析。
import Foundation

/// Dailymotion：播放器元数据接口 `www.dailymotion.com/player/metadata/video/{xid}`，
/// qualities 里取 HLS 主播放列表（application/x-mpegURL），交给 HLS 引擎挑最高码率。
/// 分享短链 `dai.ly/{xid}` 直接就是视频 ID，不用展开。
struct DailymotionParser: VideoParser {
    let platform = VideoPlatform.dailymotion

    private var headers: [String: String] {
        ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.dailymotion.com/", "Origin": "https://www.dailymotion.com",
         "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let xid = link.id.isEmpty ? (Self.videoID(from: link.url) ?? "") : link.id
        guard !xid.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 Dailymotion 视频 ID") }

        let url = "https://www.dailymotion.com/player/metadata/video/\(xid)?app=com.dailymotion.neon"
        let r = try await OverseasHTTP.send(.get(url, headers: headers.sortedPairs), site: "Dailymotion")
        guard let metadata = r.json, metadata.isObject else {
            switch r.status {
            case 404, 410: throw VideoParseError(.notFound, "Dailymotion 视频不存在或已删除")
            case 403, 429: throw VideoParseError(.blocked, "Dailymotion 拒绝了请求（HTTP \(r.status)），请稍后重试")
            default: throw VideoParseError(.unknown, "Dailymotion 元数据获取失败（HTTP \(r.status)）")
            }
        }
        try Self.checkError(metadata)
        guard let stream = Self.bestStream(metadata) else {
            throw VideoParseError(.unsupported, "这个 Dailymotion 视频没有可下载的播放地址")
        }

        let title = metadata["title"].string
        let base = FileNames.base(title, fallback: "dailymotion_\(xid)")
        // 参考实现：Dailymotion 的 m3u8 会按请求头指纹 403，带几条随机无意义的头可绕过
        var mediaHeaders = headers
        for (k, v) in Self.randomHeaders() { mediaHeaders[k] = v }
        let media = VideoMedia(url: stream.url, kind: .video, fileName: "\(base).mp4", isHLS: stream.isHLS,
                               headers: mediaHeaders, quality: stream.quality)
        let owner = metadata["owner"]
        return VideoParseResult(platform: platform, title: title, author: owner.string("screenname", "username"),
                                avatar: owner.string("avatar_url", "avatar_190_url"), cover: Self.poster(metadata),
                                timestamp: metadata["created_time"].int64, url: "https://www.dailymotion.com/video/\(xid)",
                                medias: [media])
    }

    // MARK: 纯逻辑

    static func videoID(from url: String) -> String? {
        if let id = Rx(#"dai\.ly/([A-Za-z0-9]+)"#, ignoreCase: true).first(in: url) { return id }
        if let id = Rx(#"dailymotion\.[a-z]{2,3}/(?:(?:embed|crawler|swf)/)?video/([A-Za-z0-9]+)"#, ignoreCase: true).first(in: url) {
            return id
        }
        return Rx(#"dailymotion\.[a-z]{2,3}/player[^\s?]*\?[^\s]*?\bvideo=([A-Za-z0-9]+)"#, ignoreCase: true).first(in: url)
    }

    /// 接口在 error 里给出访问限制（DM007 地区限制、私有、已删除等）
    static func checkError(_ metadata: JSON) throws {
        let error = metadata["error"]
        guard error.isObject else { return }
        let title = error.string("title", "raw_message", "message")
        let code = error["code"].string
        if code == "DM007" {
            throw VideoParseError(.unsupported, "Dailymotion：该视频在当前地区不可观看（\(title)）")
        }
        let detail = title.isEmpty ? "视频不可用（\(code)）" : title
        throw VideoParseError(.unknown, "Dailymotion：\(detail)")
    }

    /// qualities：优先 HLS 主播放列表；没有 HLS 时取分辨率最高的直链 mp4
    static func bestStream(_ metadata: JSON) -> (url: String, isHLS: Bool, quality: String)? {
        let qualities = metadata["qualities"]
        var hls = ""
        var bestMP4 = ""
        var bestHeight = -1
        for key in qualities.keys.sorted() {
            for item in qualities[key].array {
                let url = item["url"].string.substringBefore("#")
                let type = item["type"].string
                if url.isEmpty || type == "application/vnd.lumberjack.manifest" { continue }
                if type == "application/x-mpegURL" || url.contains(".m3u8") {
                    if hls.isEmpty || key == "auto" { hls = url }
                    continue
                }
                let height = Int(Rx(#"/H264-\d+x(\d+)"#).first(in: url) ?? "") ?? (Int(key) ?? 0)
                if height > bestHeight {
                    bestHeight = height
                    bestMP4 = url
                }
            }
        }
        if !hls.isEmpty { return (hls, true, "HLS") }
        if !bestMP4.isEmpty { return (bestMP4, false, bestHeight > 0 ? "\(bestHeight)p" : "") }
        return nil
    }

    /// posters / thumbnails 是「高度 → 地址」，取最大的一张
    static func poster(_ metadata: JSON) -> String {
        for field in ["posters", "thumbnails"] {
            let dict = metadata[field]
            var bestKey = -1
            var bestURL = ""
            for key in dict.keys {
                let url = dict[key].string
                let size = Int(key) ?? 0
                if !url.isEmpty && size > bestKey {
                    bestKey = size
                    bestURL = url
                }
            }
            if !bestURL.isEmpty { return bestURL }
        }
        return ""
    }

    /// 参考实现的 blockbuster headers：2~8 条随机辅音字母组成的头（不会撞上真实头名）
    static func randomHeaders() -> [String: String] {
        let letters = Array("bcdfghjklmnpqrstvwxz")
        func word(_ minLength: Int, _ maxLength: Int) -> String {
            let count = Int.random(in: minLength...maxLength)
            return String((0..<count).map { _ in letters[Int.random(in: 0..<letters.count)] })
        }
        var result: [String: String] = [:]
        for _ in 0..<Int.random(in: 2...8) { result[word(8, 24)] = word(16, 32) }
        return result
    }
}
