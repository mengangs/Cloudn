// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的 tieba 解析。
import Foundation

/// 百度贴吧：先取游客 tbs，再按 PC 客户端协议（表单 + MD5 签名）请求 `c/f/pb/page_pc` 拿主楼。
/// 主楼有图取 origin_thread_info.media[].big_pic，否则取 thread.video_info 视频。
struct TiebaParser: VideoParser {
    let platform = VideoPlatform.tieba

    static let salt = "36770b1f34c9bbf2e7d1a99d2b82fa9e"

    private var headers: [String: String] { ["User-Agent": VideoHTTP.uaChrome] }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let kz = link.id
        let tbsJSON = try await VideoHTTP.getJSON("https://tieba.baidu.com/dc/common/tbs", headers: headers, what: "贴吧 tbs")
        let tbs = tbsJSON["tbs"].string
        guard !tbs.isEmpty else { throw VideoParseError(.blocked, "获取贴吧 tbs 失败，请稍后重试") }

        let form = Self.signedForm(kz: kz, tbs: tbs)
        let r = try await VideoHTTP.send(.postForm("https://tieba.baidu.com/c/f/pb/page_pc", form, headers: headers.sortedPairs))
        try VideoHTTP.requireSuccess(r, "贴吧帖子")
        guard let json = r.json else { throw VideoParseError(.unknown, "贴吧帖子返回的不是合法 JSON") }
        if json["error_code"].int != 0 {
            let msg = json["error_msg"].string
            throw VideoParseError(.notFound, msg.isEmpty ? "获取帖子内容失败" : "贴吧：\(msg)")
        }
        return try build(json, kz: kz)
    }

    private func build(_ json: JSON, kz: String) throws -> VideoParseResult {
        let thread = json["thread"]
        let origin = thread["origin_thread_info"]
        let title = origin["title"].string
        let text = Self.contentText(origin["content"])
        let base = FileNames.base(title, fallback: "tieba_\(kz)")
        var medias: [VideoMedia] = []
        var cover = ""
        let photos = Self.photos(origin)
        if !photos.isEmpty {
            for (i, url) in photos.enumerated() {
                medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(i + 1).\(DomesticHTML.imageExtension(url))",
                                         headers: headers, quality: "原图"))
            }
            cover = photos[0]
        } else if let video = Self.video(thread) {
            medias.append(VideoMedia(url: video.url, kind: .video, fileName: "\(base).mp4", headers: headers))
            cover = video.cover
        }
        guard !medias.isEmpty else { throw VideoParseError(.unsupported, "这条内容没有可下载的图片或视频") }
        let author = thread["author"].string("name_show", "name")
        return VideoParseResult(platform: platform, title: title, author: author, cover: cover, text: text,
                                url: "https://tieba.baidu.com/p/\(kz)", medias: medias)
    }

    // MARK: 纯逻辑

    /// 键按字节序排序后拼 `k=v`（无分隔符）+ 盐，取小写 MD5
    static func sign(_ params: [(String, String)]) -> String {
        let sorted = params.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        let base = sorted.map { "\($0.0)=\($0.1)" }.joined()
        return Crypto.md5Hex(base + salt)
    }

    static func signedForm(kz: String, tbs: String) -> [(String, String)] {
        var form: [(String, String)] = [
            ("pn", "1"), ("lz", "0"), ("r", "2"), ("mark_type", "0"), ("back", "0"), ("fr", "personalize_page"),
            ("kz", kz), ("session_request_times", "1"), ("tbs", tbs), ("subapp_type", "pc"), ("_client_type", "20")
        ]
        form.append(("sign", sign(form)))
        return form
    }

    /// content 里 type == 0 的文本段，换行拼接
    static func contentText(_ content: JSON) -> String {
        content.array.filter { $0["type"].int == 0 }.map { $0["text"].string }.joined(separator: "\n")
    }

    static func photos(_ origin: JSON) -> [String] {
        origin["media"].array.map { $0.string("big_pic", "small_pic") }.filter { !$0.isEmpty }
    }

    static func video(_ thread: JSON) -> (url: String, cover: String)? {
        let info = thread["video_info"]
        let url = info["video_url"].string
        guard !url.isEmpty else { return nil }
        return (url, info["thumbnail_url"].string)
    }
}
