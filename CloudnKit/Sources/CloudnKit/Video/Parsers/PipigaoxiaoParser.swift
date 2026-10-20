// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 parse-video（MIT，wujunwei928/parse-video）的 pipigaoxiao 解析。
import Foundation

/// 皮皮搞笑：分享页 h5.pipigx.com/pp/post/{pid}；作品数据来自 POST `share.ippzone.com/ppapi/share/fetch_content`
/// （body `{"pid":…,"type":"post","mid":null}`）→ data.post。imgs 是作品里的每个图/视频位，
/// videos 以图片 id 为键给出视频地址；没有视频的图片位用 `file.ippzone.com/img/view/id/{id}` 取原图。
struct PipigaoxiaoParser: VideoParser {
    let platform = VideoPlatform.pipigaoxiao

    private static let apiUA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.169 Safari/537.36"
    private static let endpoints = ["https://share.ippzone.com/ppapi/share/fetch_content", "https://h5.pipigx.com/ppapi/share/fetch_content"]

    private var mediaHeaders: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://h5.pipigx.com/"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let pid = link.id
        guard !pid.isEmpty, Int64(pid) != nil else { throw VideoParseError(.unsupported, "无法识别皮皮搞笑链接") }
        let post = try await fetchPost(pid)
        let content = post["content"].string
        let base = FileNames.base(String(content.prefix(40)), fallback: "pipigx_\(pid)")
        let items = Self.mediaItems(post)
        guard !items.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        var medias: [VideoMedia] = []
        let videoCount = items.filter { $0.isVideo }.count
        let imageCount = items.count - videoCount
        var vi = 0
        var ii = 0
        for item in items {
            if item.isVideo {
                vi += 1
                let name = videoCount == 1 ? "\(base).mp4" : "\(base)_v\(vi).mp4"
                medias.append(VideoMedia(url: item.url, kind: .video, fileName: name, headers: mediaHeaders))
            } else {
                ii += 1
                let name = imageCount == 1 ? "\(base).jpg" : "\(base)_\(ii).jpg"
                medias.append(VideoMedia(url: item.url, kind: .image, fileName: name, headers: mediaHeaders, quality: "原图"))
            }
        }
        let firstImage = post["imgs"][0]["id"].string
        let cover = firstImage.isEmpty ? "" : Self.imageURL(firstImage)
        let member = post["member"]
        return VideoParseResult(platform: platform, title: String(content.prefix(60)), author: member["name"].string,
                                cover: cover, text: content, timestamp: post["ct"].int64,
                                url: "https://h5.pipigx.com/pp/post/\(pid)", medias: medias)
    }

    private func fetchPost(_ pid: String) async throws -> JSON {
        let body = Data("{\"pid\":\(pid),\"type\":\"post\",\"mid\":null}".utf8)
        var lastError: Error = VideoParseError(.notFound, "皮皮搞笑作品不存在或已删除")
        for endpoint in Self.endpoints {
            let headers: [(String, String)] = [("User-Agent", Self.apiUA), ("Referer", endpoint), ("Content-Type", "application/json")]
            do {
                let r = try await VideoHTTP.send(HTTPRequest(url: endpoint, method: "POST", headers: headers, body: body))
                try VideoHTTP.requireSuccess(r, "皮皮搞笑作品")
                guard let json = r.json else { throw VideoParseError(.unknown, "皮皮搞笑返回的不是合法 JSON") }
                return try Self.post(json)
            } catch let e as VideoParseError where e.kind == .notFound {
                throw e
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: 纯逻辑

    static func post(_ payload: JSON) throws -> JSON {
        let msg = payload["msg"].string
        if payload.has("msg") && !msg.isEmpty {
            throw VideoParseError(.notFound, "皮皮搞笑：\(msg)")
        }
        let post = payload["data"]["post"]
        guard post.isObject else { throw VideoParseError(.notFound, "皮皮搞笑作品不存在或已删除") }
        return post
    }

    static func imageURL(_ id: String) -> String { "https://file.ippzone.com/img/view/id/\(id)" }

    /// 按 imgs 顺序：有对应视频的出视频，否则出原图
    static func mediaItems(_ post: JSON) -> [(url: String, isVideo: Bool)] {
        var result: [(url: String, isVideo: Bool)] = []
        let videos = post["videos"]
        for img in post["imgs"].array {
            let id = img["id"].string
            guard !id.isEmpty else { continue }
            let video = videos[id]
            let url = video.string("url", "urlsrc", "urlext")
            if !url.isEmpty {
                result.append((url: url, isVideo: true))
            } else {
                result.append((url: imageURL(id), isVideo: false))
            }
        }
        return result
    }
}
