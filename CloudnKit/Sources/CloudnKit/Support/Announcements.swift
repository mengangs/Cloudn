// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 一条应用内公告。公告源是本仓库根目录的 announcements.json（不依赖额外的服务器），格式：
///
///     { "announcements": [ { "id": "2026-10-bt", "title": "…", "summary": "…", "content": "Markdown 正文",
///       "pinned": false, "popup": true, "publishedAt": "2026-10-20T08:00:00Z", "expiresAt": null,
///       "cover": "https://…", "images": ["https://…"], "minVersion": "1.2.0", "maxVersion": null } ] }
///
/// 只有 id 与 title 必填；publishedAt 在未来的公告到时间才显示，expiresAt 之后不再显示。
public struct Announcement: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let content: String
    public let pinned: Bool
    /// 是否在启动时弹出（默认是）
    public let popup: Bool
    public let publishedAt: Date?
    public let expiresAt: Date?
    public let cover: String
    public let images: [String]
    /// 只对这个版本区间的应用显示（含端点；为空不限）
    public let minVersion: String
    public let maxVersion: String

    public init(id: String, title: String, summary: String = "", content: String = "", pinned: Bool = false, popup: Bool = true,
                publishedAt: Date? = nil, expiresAt: Date? = nil, cover: String = "", images: [String] = [],
                minVersion: String = "", maxVersion: String = "") {
        self.id = id
        self.title = title
        self.summary = summary
        self.content = content
        self.pinned = pinned
        self.popup = popup
        self.publishedAt = publishedAt
        self.expiresAt = expiresAt
        self.cover = cover
        self.images = images
        self.minVersion = minVersion
        self.maxVersion = maxVersion
    }

    /// 列表与弹窗里用的一句话摘要
    public var preview: String {
        if !summary.isEmpty { return summary }
        let plain = content.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[#>*_`\-]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(plain.prefix(120))
    }

    /// 封面 + 正文图片（去重），详情页的图集
    public var gallery: [String] {
        var seen = Set<String>()
        return ([cover] + images).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public enum Announcements {
    public static let path = "announcements.json"

    /// 公告源地址（可套 GitHub 镜像）
    public static func sourceURL(mirror: String = "") -> String {
        GitHubMirror.apply("https://raw.githubusercontent.com/\(UpdateChecker.repository)/main/\(path)", prefix: mirror)
    }

    /// 拉取并筛出当前应显示的公告：置顶在前，其余按发布时间新到旧。文件不存在（还没发过公告）返回空
    public static func fetch(mirror: String = "", currentVersion: String, now: Date = Date(), client: HTTPClient = .shared) async throws -> [Announcement] {
        var request = HTTPRequest.get(sourceURL(mirror: mirror), headers: [("User-Agent", "Cloudn-iOS"), ("Cache-Control", "no-cache")])
        request.timeout = 15
        let r = try await client.send(request)
        if r.status == 404 { return [] }
        guard r.isSuccess else { throw CloudnError("公告加载失败（HTTP \(r.status)）") }
        return try visible(parse(r.body), currentVersion: currentVersion, now: now)
    }

    public static func parse(_ data: Data) throws -> [Announcement] {
        guard let json = JSON(data: data) else { throw CloudnError("公告格式无效") }
        let list = json.isArray ? json.array : json["announcements"].array
        return list.compactMap { a in
            let id = a["id"].string.trimmed, title = a["title"].string.trimmed
            guard !id.isEmpty, !title.isEmpty else { return nil }
            return Announcement(id: id, title: title, summary: a["summary"].string.trimmed, content: a["content"].string,
                                pinned: a["pinned"].bool, popup: a["popup"].isNull ? true : a["popup"].bool,
                                publishedAt: date(a["publishedAt"].string), expiresAt: date(a["expiresAt"].string),
                                cover: a["cover"].string.trimmed, images: a["images"].array.map(\.string).filter { !$0.isEmpty },
                                minVersion: a["minVersion"].string.trimmed, maxVersion: a["maxVersion"].string.trimmed)
        }
    }

    public static func visible(_ list: [Announcement], currentVersion: String, now: Date) -> [Announcement] {
        list.filter { a in
            if let p = a.publishedAt, p > now { return false }
            if let e = a.expiresAt, e <= now { return false }
            if !a.minVersion.isEmpty, UpdateChecker.isNewer(a.minVersion, than: currentVersion) { return false }
            if !a.maxVersion.isEmpty, UpdateChecker.isNewer(currentVersion, than: a.maxVersion) { return false }
            return true
        }
        .sorted { x, y in
            if x.pinned != y.pinned { return x.pinned }
            return (x.publishedAt ?? .distantPast) > (y.publishedAt ?? .distantPast)
        }
    }

    /// 启动弹窗：有未读置顶弹置顶，否则弹最新一条未读；关掉弹窗不想再弹的（popup = false）不弹
    public static func popupCandidate(_ list: [Announcement], read: Set<String>) -> Announcement? {
        let unread = list.filter { $0.popup && !read.contains($0.id) }
        if let pinned = unread.first(where: \.pinned) { return pinned }
        return unread.max { ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast) }
    }

    static func date(_ s: String) -> Date? {
        let t = s.trimmed
        guard !t.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withFullDate]
        return f.date(from: t)
    }
}
