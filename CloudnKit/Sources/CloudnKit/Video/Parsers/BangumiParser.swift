// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 bangumi 解析。
import Foundation

/// Bangumi 番组计划：条目讨论 / 小组话题 / 日志，走 `next.bgm.tv/p1` 接口。
/// 正文是 BBCode：`[img]地址[/img]` 与 `[photo]相册路径[/photo]` 即图片；日志另有附带相册（/photos）。
struct BangumiParser: VideoParser {
    let platform = VideoPlatform.bangumi

    static let apiBase = "https://next.bgm.tv/p1"
    static let photoBase = "https://lain.bgm.tv/pic/photo/l/"

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome, "Accept": "application/json"] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "不支持的 Bangumi 链接") }

        var title = ""
        var author = ""
        var avatar = ""
        var timestamp: Int64 = 0
        var content = ""
        var images: [String] = []
        let pageURL: String

        switch link.kind {
        case "blog":
            let blog = try await getJSON("\(Self.apiBase)/blogs/\(id)")
            title = blog["title"].string
            content = blog["content"].string
            let user = blog["user"]
            author = user.string("nickname", "username")
            avatar = Self.avatar(user)
            timestamp = blog["createdAt"].int64
            images = Self.bbcodeImages(content)
            // 附带相册拿不到不致命
            if let photos = try? await getJSON("\(Self.apiBase)/blogs/\(id)/photos?limit=100") {
                images = Self.merge(images, Self.photoURLs(photos))
            }
            pageURL = "https://bgm.tv/blog/\(id)"
        case "subject", "group":
            let apiType = link.kind == "subject" ? "subjects" : "groups"
            let topic = try await getJSON("\(Self.apiBase)/\(apiType)/-/topics/\(id)")
            title = topic["title"].string
            content = topic["replies"][0]["content"].string
            let creator = topic["creator"].isObject ? topic["creator"] : topic["replies"][0]["creator"]
            author = creator.string("nickname", "username")
            avatar = Self.avatar(creator)
            timestamp = topic["createdAt"].int64
            images = Self.bbcodeImages(content)
            pageURL = "https://bgm.tv/\(link.kind)/topic/\(id)"
        default:
            throw VideoParseError(.unsupported, "暂不支持该类型的 Bangumi 链接（支持条目讨论、小组话题、日志）")
        }

        guard !images.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let base = FileNames.base(title, fallback: "bangumi_\(id)")
        let mediaHeaders = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://bgm.tv/"]
        var medias: [VideoMedia] = []
        for (i, url) in images.enumerated() {
            let name = images.count == 1 ? base : "\(base)_\(i + 1)"
            medias.append(VideoMedia(url: url, kind: .image, fileName: "\(name).\(DomesticHTML.imageExtension(url))",
                                     headers: mediaHeaders))
        }
        return VideoParseResult(platform: platform, title: title, author: author, avatar: avatar, cover: images.first ?? "",
                                text: Self.plainText(content), timestamp: timestamp, url: pageURL, medias: medias)
    }

    private func getJSON(_ url: String) async throws -> JSON {
        let r = try await OverseasHTTP.send(.get(url, headers: headers.sortedPairs), site: "Bangumi")
        let json = r.json ?? JSON(nil)
        if !r.isSuccess {
            let message = json["message"].string
            switch r.status {
            case 404: throw VideoParseError(.notFound, "Bangumi 内容不存在或已删除")
            case 401, 403:
                let reason = message.isEmpty ? "HTTP \(r.status)" : message
                throw VideoParseError(.unknown, "该 Bangumi 内容需要登录才能查看（\(reason)），暂不支持")
            default:
                let reason = message.isEmpty ? "HTTP \(r.status)" : message
                throw VideoParseError(.unknown, "Bangumi 解析失败：\(reason)")
            }
        }
        guard json.isObject else { throw VideoParseError(.unknown, "Bangumi 接口返回的不是合法 JSON") }
        return json
    }

    // MARK: 纯逻辑

    /// 正文 BBCode 里的图片，按出现顺序去重：[img]地址[/img]（可带 =宽,高）与 [photo]相册路径[/photo]
    static func bbcodeImages(_ content: String) -> [String] {
        let rx = Rx(#"\[(img|photo)(?:=[^\]]*)?\]\s*(.*?)\s*\[/\1\]"#, ignoreCase: true, dotAll: true)
        var result: [String] = []
        for m in rx.allMatches(in: content) {
            let body = m[2].trimmed
            guard !body.isEmpty else { continue }
            let url: String
            if m[1].lowercased() == "photo" {
                url = photoBase + trimLeadingSlashes(body)
            } else {
                url = DomesticHTML.absolute(body)
            }
            if !result.contains(url) { result.append(url) }
        }
        return result
    }

    /// 日志相册：data[].target 是相对路径
    static func photoURLs(_ photos: JSON) -> [String] {
        photos["data"].array.compactMap { (p: JSON) -> String? in
            let target = p["target"].string
            return target.isEmpty ? nil : photoBase + trimLeadingSlashes(target)
        }
    }

    static func merge(_ a: [String], _ b: [String]) -> [String] {
        var result = a
        for url in b where !result.contains(url) { result.append(url) }
        return result
    }

    static func trimLeadingSlashes(_ s: String) -> String {
        var t = Substring(s)
        while t.hasPrefix("/") { t = t.dropFirst() }
        return String(t)
    }

    static func avatar(_ user: JSON) -> String {
        let a = user["avatar"]
        if a.isObject { return a.string("large", "medium", "small") }
        return a.string
    }

    /// BBCode → 纯文本：去掉图片块与其余标签
    static func plainText(_ content: String) -> String {
        var s = content.replacingOccurrences(of: "\r\n", with: "\n")
        s = Rx(#"\[(img|photo)(?:=[^\]]*)?\].*?\[/\1\]"#, ignoreCase: true, dotAll: true).replacing(in: s, with: "")
        let tags = #"\[/?(?:img|url|b|i|s|u|mask|quote|code|user|size|color|align|left|right|center|photo)(?:=[^\]]*)?\]"#
        s = Rx(tags, ignoreCase: true).replacing(in: s, with: "")
        s = Rx(#"\n{3,}"#).replacing(in: s, with: "\n\n")
        return s.trimmed
    }
}
