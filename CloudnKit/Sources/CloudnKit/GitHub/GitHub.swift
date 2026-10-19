// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// GitHub 链接解析、仓库浏览与 Release 下载，参考 YunX（AGPL-3.0）的 GitHubLinkParser / GitHubApi / UpdateChecker.mirrorUrl。
import Foundation

/// 识别出的 GitHub 链接
public enum GitHubLink: Hashable, Sendable {
    /// 文件直链（raw / releases/download / github.com/…/raw/…），直接下载
    case file(url: String, name: String)
    /// 仓库（可带 tree/blob/releases 等子路径）
    case repository(owner: String, repo: String, subPath: String?)
    /// 用户或组织主页
    case account(owner: String)

    static let rawRx = Rx(#"raw\.githubusercontent\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/[^/]+/(.+)"#, ignoreCase: true)
    static let releaseRx = Rx(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/[^/]+/(.+)"#, ignoreCase: true)
    static let githubRawRx = Rx(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/raw/[^/]+/(.+)"#, ignoreCase: true)
    static let repoRx = Rx(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:/([^\s]*))?"#, ignoreCase: true)
    static let accountRx = Rx(#"github\.com/([A-Za-z0-9_.-]+)/?(?:[?#]|$)"#, ignoreCase: true)
    /// github.com 自身的功能页，不是用户 / 组织
    static let specialPaths: Set<String> = [
        "features", "topics", "trending", "collections", "events", "sponsors", "about", "pricing", "login", "signup", "join",
        "marketplace", "explore", "notifications", "settings", "new", "orgs", "sites", "customer-stories", "team", "enterprise",
        "readme", "contact", "security", "resources", "search", "apps", "codespaces"
    ]

    /// 从一段文本里识别 GitHub 链接；优先级：文件直链 > 仓库 > 账号
    public static func parse(_ text: String) -> GitHubLink? {
        guard var url = ShareLinkParser.firstURL(in: text) else { return nil }
        while let last = url.last, "。，,；;)]}\"'".contains(last) { url.removeLast() }
        guard let host = URL(string: url)?.host?.lowercased(),
              host == "github.com" || host == "www.github.com" || host == "raw.githubusercontent.com" else { return nil }
        for rx in [rawRx, releaseRx, githubRawRx] {
            if let m = rx.firstMatch(in: url), m.count > 3, let name = fileName(m[3]) { return .file(url: url, name: name) }
        }
        if let m = repoRx.firstMatch(in: url), m.count > 2, !specialPaths.contains(m[1].lowercased()) {
            let repoName = m[2].hasSuffix(".git") ? String(m[2].dropLast(4)) : m[2]
            let sub = m.count > 3 ? m[3].components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? "" : ""
            return .repository(owner: m[1], repo: repoName, subPath: sub.isEmpty ? nil : sub)
        }
        if let owner = accountRx.first(in: url), !specialPaths.contains(owner.lowercased()) { return .account(owner: owner) }
        return nil
    }

    static func fileName(_ path: String) -> String? {
        let clean = path.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? path
        let name = (clean.split(separator: "/").last.map(String.init) ?? "").removingPercentEncoding ?? ""
        return name.isEmpty ? nil : name
    }
}

public struct GitHubRepo: Equatable, Sendable, Identifiable {
    public var id: String { fullName }
    public let owner: String
    public let name: String
    public let fullName: String
    public let description: String
    public let defaultBranch: String
    public let stars: Int
    public let updatedAt: String
}

/// 仓库目录项
public struct GitHubEntry: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    /// 文件的 raw 下载地址（目录为空）
    public let downloadURL: String
}

public struct GitHubAsset: Equatable, Sendable, Identifiable {
    public var id: String { url }
    public let name: String
    public let size: Int64
    public let url: String
    public let downloads: Int
}

public struct GitHubRelease: Equatable, Sendable, Identifiable {
    public var id: String { tag }
    public let tag: String
    public let name: String
    public let notes: String
    public let isPrerelease: Bool
    public let publishedAt: String
    public let assets: [GitHubAsset]
}

/// GitHub REST API（匿名 60 次 / 小时；配置 Token 后 5000 次 / 小时）。Token 只用于提高限额，不会写进日志
public struct GitHubClient: Sendable {
    public let token: String
    let client: HTTPClient
    let apiBase: String

    public init(token: String = "", client: HTTPClient = .shared, apiBase: String = "https://api.github.com") {
        self.token = token.trimmed
        self.client = client
        self.apiBase = apiBase
    }

    public func repository(_ owner: String, _ repo: String) async throws -> GitHubRepo {
        Self.parseRepo(try await get("/repos/\(owner)/\(repo)"))
    }

    /// 目录内容（path 为空表示仓库根目录）
    public func contents(_ owner: String, _ repo: String, path: String, ref: String) async throws -> [GitHubEntry] {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let json = try await get("/repos/\(owner)/\(repo)/contents/\(encoded)?ref=\(ref.formEncoded)")
        // 指向文件时返回单个对象
        let items = json.isArray ? json.array : [json]
        return items.map(Self.parseEntry).sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public func releases(_ owner: String, _ repo: String) async throws -> [GitHubRelease] {
        try await get("/repos/\(owner)/\(repo)/releases?per_page=50").array.filter { !$0["draft"].bool }.map(Self.parseRelease)
    }

    /// 用户或组织的公开仓库（按更新时间排序）
    public func repositories(of owner: String) async throws -> [GitHubRepo] {
        try await get("/users/\(owner)/repos?per_page=100&sort=updated").array.map(Self.parseRepo)
    }

    /// 校验 Token：返回登录名
    public func validate() async throws -> String {
        let login = try await get("/user")["login"].string
        guard !login.isEmpty else { throw CloudnError("Token 无效") }
        return login
    }

    func get(_ path: String) async throws -> JSON {
        var headers = [("Accept", "application/vnd.github+json"), ("User-Agent", "Cloudn-iOS"), ("X-GitHub-Api-Version", "2022-11-28")]
        if !token.isEmpty { headers.append(("Authorization", "Bearer " + token)) }
        let r = try await client.send(.get(apiBase + path, headers: headers))
        guard r.isSuccess, let json = r.json else { throw Self.error(r) }
        return json
    }

    static func error(_ r: HTTPResponse) -> CloudnError {
        let msg = r.json?["message"].string ?? ""
        switch r.status {
        case 401: return CloudnError("GitHub Token 无效或已过期")
        case 403 where msg.lowercased().contains("rate limit") || r.header("x-ratelimit-remaining") == "0":
            return CloudnError("GitHub 接口调用次数已达上限，请稍后再试，或在设置中填写 GitHub Token")
        case 404: return CloudnError("GitHub 上找不到该仓库或路径（私有仓库需要有权限的 Token）")
        default: return CloudnError(msg.isEmpty ? "GitHub 请求失败（HTTP \(r.status)）" : "GitHub：\(msg)")
        }
    }

    static func parseRepo(_ o: JSON) -> GitHubRepo {
        GitHubRepo(owner: o["owner"]["login"].string, name: o["name"].string, fullName: o["full_name"].string,
                   description: o["description"].string, defaultBranch: o["default_branch"].string.nilIfBlank ?? "main",
                   stars: o["stargazers_count"].int, updatedAt: o["pushed_at"].string.nilIfBlank ?? o["updated_at"].string)
    }

    static func parseEntry(_ o: JSON) -> GitHubEntry {
        GitHubEntry(name: o["name"].string, path: o["path"].string, isDirectory: o["type"].string == "dir",
                    size: o["size"].int64, downloadURL: o["download_url"].string)
    }

    static func parseRelease(_ o: JSON) -> GitHubRelease {
        GitHubRelease(tag: o["tag_name"].string, name: o["name"].string.nilIfBlank ?? o["tag_name"].string, notes: o["body"].string,
                      isPrerelease: o["prerelease"].bool, publishedAt: o["published_at"].string,
                      assets: o["assets"].array.map {
                          GitHubAsset(name: $0["name"].string, size: $0["size"].int64, url: $0["browser_download_url"].string,
                                      downloads: $0["download_count"].int)
                      })
    }
}

/// GitHub 下载镜像：给 github.com / raw.githubusercontent.com 的下载地址加前缀，改善国内下载速度
public enum GitHubMirror {
    public static let defaultPrefix = "https://cdn.gh-proxy.org/"

    /// prefix 为空串时原样返回；只处理 GitHub 自己的下载地址
    public static func apply(_ url: String, prefix: String) -> String {
        let p = prefix.trimmed
        guard !p.isEmpty, let host = URL(string: url)?.host?.lowercased(),
              host == "github.com" || host == "raw.githubusercontent.com" || host.hasSuffix(".githubusercontent.com") else { return url }
        return (p.hasSuffix("/") ? p : p + "/") + url
    }
}
