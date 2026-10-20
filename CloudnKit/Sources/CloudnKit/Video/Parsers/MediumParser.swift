// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 medium 解析。
import Foundation

/// Medium 文章：GraphQL（`medium.com/_/graphql`）按文章 ID 取正文段落，IMG 段落的 metadata.id 即原图
/// （`miro.medium.com/v2/{id}`）。只下载文章里的图片；会员专享文章只能拿到公开部分。
struct MediumParser: VideoParser {
    let platform = VideoPlatform.medium

    static let graphqlURL = "https://medium.com/_/graphql"
    /// 在参考实现的段落字段之外多取作者与发布时间；字段不被接受时退回 `minimalQuery`
    static let query = """
    query P($id: ID!) {
      post(id: $id) {
        title
        isLocked
        firstPublishedAt
        creator { name imageId }
        content { bodyModel { paragraphs { type text metadata { id originalWidth originalHeight } } } }
      }
    }
    """

    static let minimalQuery = """
    query P($id: ID!) {
      post(id: $id) {
        title
        isLocked
        content { bodyModel { paragraphs { type text metadata { id originalWidth originalHeight } } } }
      }
    }
    """

    struct Post {
        var title = ""
        var author = ""
        var avatar = ""
        var timestamp: Int64 = 0
        var isLocked = false
        var text = ""
        var images: [String] = []
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let id = link.id.isEmpty ? (Self.postID(from: link.url) ?? "") : link.id
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "不支持的 Medium 链接") }

        var json = try await request(id: id, query: Self.query)
        if Self.hasErrors(json) { json = try await request(id: id, query: Self.minimalQuery) }
        let post = try Self.parsePost(json)
        guard !post.images.isEmpty else {
            if post.isLocked {
                throw VideoParseError(.unsupported, "这是 Medium 会员专享文章，公开部分没有可下载的图片")
            }
            throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频")
        }

        let base = FileNames.base(post.title, fallback: "medium_\(id)")
        let mediaHeaders = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://medium.com/"]
        var medias: [VideoMedia] = []
        for (i, url) in post.images.enumerated() {
            let name = post.images.count == 1 ? base : "\(base)_\(i + 1)"
            medias.append(VideoMedia(url: url, kind: .image, fileName: "\(name).\(DomesticHTML.imageExtension(url))",
                                     headers: mediaHeaders, quality: "原图"))
        }
        let notice = post.isLocked ? "这是会员专享文章，只取到了公开部分的图片" : ""
        return VideoParseResult(platform: platform, title: post.title, author: post.author, avatar: post.avatar,
                                cover: post.images.first ?? "", text: post.text, timestamp: post.timestamp,
                                url: Self.canonicalURL(link.url), medias: medias, notice: notice)
    }

    private func request(id: String, query: String) async throws -> JSON {
        let variables: [String: Any] = ["id": id]
        let operation: [String: Any] = ["operationName": "P", "variables": variables, "query": query]
        let headers: [(String, String)] = [
            ("User-Agent", VideoHTTP.uaChrome), ("Accept", "application/json"), ("Origin", "https://medium.com"),
            ("Referer", "https://medium.com/")
        ]
        let r = try await OverseasHTTP.send(.postJSON(Self.graphqlURL, [operation], headers: headers), site: "Medium")
        switch r.status {
        case 200..<300: break
        case 403, 429: throw VideoParseError(.blocked, "Medium 拒绝了请求（HTTP \(r.status)），请稍后重试")
        default: throw VideoParseError(.unknown, "Medium 接口请求失败（HTTP \(r.status)）")
        }
        guard let json = r.json else { throw VideoParseError(.unknown, "Medium 接口返回的不是合法 JSON") }
        return json
    }

    // MARK: 纯逻辑

    static func hasErrors(_ json: JSON) -> Bool {
        let result = json.isArray ? json[0] : json
        return !result["errors"].array.isEmpty
    }

    /// 路径最后一段末尾的 8~12 位十六进制即文章 ID（`/@user/some-title-1a2b3c4d5e6f`、`/p/1a2b3c4d5e6f`）
    static func postID(from url: String) -> String? {
        let path = (URL(string: url)?.path ?? url.substringBefore("?")).trimmingTrailing("/")
        let last = path.substringAfterLast("/")
        return Rx(#"(?:^|-)([0-9a-f]{8,12})$"#).first(in: last)
    }

    static func canonicalURL(_ url: String) -> String {
        url.substringBefore("?").substringBefore("#")
    }

    /// GraphQL 响应（数组，取第一个）→ 文章
    static func parsePost(_ json: JSON) throws -> Post {
        let result = json.isArray ? json[0] : json
        if let message = result["errors"][0]["message"].string.nilIfBlank {
            throw VideoParseError(.unknown, "Medium 解析失败：\(message)")
        }
        let node = result["data"]["post"]
        guard node.isObject else { throw VideoParseError(.notFound, "Medium 内容不存在或已删除") }

        var post = Post()
        post.title = node["title"].string
        post.isLocked = node["isLocked"].bool
        post.author = node["creator"]["name"].string
        let avatarID = node["creator"]["imageId"].string
        if !avatarID.isEmpty { post.avatar = "https://miro.medium.com/v2/resize:fill:176:176/\(avatarID)" }
        post.timestamp = node["firstPublishedAt"].int64 / 1000

        var lines: [String] = []
        let paragraphs = node["content"]["bodyModel"]["paragraphs"].array
        for (index, p) in paragraphs.enumerated() {
            let type = p["type"].string
            let text = p["text"].string
            if type == "IMG" {
                let imageID = p["metadata"]["id"].string
                if !imageID.isEmpty {
                    let url = imageURL(imageID)
                    if !post.images.contains(url) { post.images.append(url) }
                }
                continue
            }
            // 开头与标题重复的 H2/H3/H4 不要
            if index == 0 && ["H2", "H3", "H4"].contains(type) && text.trimmed == post.title.trimmed { continue }
            if !text.trimmed.isEmpty { lines.append(text) }
        }
        post.text = lines.joined(separator: "\n\n")
        return post
    }

    static func imageURL(_ id: String) -> String {
        "https://miro.medium.com/v2/\(id)"
    }
}
