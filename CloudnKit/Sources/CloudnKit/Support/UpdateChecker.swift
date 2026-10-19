// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 新版本信息（来自 GitHub Releases）
public struct AppRelease: Equatable, Sendable, Identifiable {
    public var id: String { version }
    public let version: String
    public let name: String
    public let notes: String
    public let pageURL: String
    /// 未签名 IPA 的下载地址（没有附件为空）
    public let ipaURL: String
    public let publishedAt: String
    /// 预发布版（测试版）
    public let isPrerelease: Bool
}

/// 检查更新：读取 GitHub 仓库的最新正式版，与当前版本号比较
public enum UpdateChecker {
    public static let repository = "mengangs/Cloudn"

    /// 有更新返回新版本，已是最新返回 nil。includePrerelease 为 true 时预发布版也算
    public static func check(current: String, includePrerelease: Bool = false, client: HTTPClient = .shared,
                             apiBase: String = "https://api.github.com") async throws -> AppRelease? {
        let headers = [("Accept", "application/vnd.github+json"), ("User-Agent", "Cloudn-iOS")]
        // releases/latest 只返回最新正式版；要包含预发布版就取列表自己挑
        let path = includePrerelease ? "releases?per_page=20" : "releases/latest"
        let r = try await client.send(.get("\(apiBase)/repos/\(repository)/\(path)", headers: headers))
        if r.status == 404 { return nil }   // 还没有发布过正式版
        guard r.isSuccess, let json = r.json else { throw CloudnError("检查更新失败（HTTP \(r.status)）") }
        let release: AppRelease?
        if json.isArray {
            release = newest(json.array.filter { !$0["draft"].bool }.map(parse), includePrerelease: includePrerelease)
        } else if json.isObject {
            release = parse(json)
        } else {
            throw CloudnError("检查更新失败：响应格式异常")
        }
        guard let release, isNewer(release.version, than: current) else { return nil }
        return release
    }

    /// 版本号最大的一个（不含预发布版时先过滤掉）
    static func newest(_ releases: [AppRelease], includePrerelease: Bool) -> AppRelease? {
        releases.filter { includePrerelease || !$0.isPrerelease }
            .filter { !$0.version.isEmpty }
            .max { isNewer($1.version, than: $0.version) }
    }

    static func parse(_ json: JSON) -> AppRelease {
        let tag = json["tag_name"].string
        let ipa = json["assets"].array.first { $0["name"].string.lowercased().hasSuffix(".ipa") }?["browser_download_url"].string ?? ""
        return AppRelease(version: normalize(tag), name: json["name"].string.nilIfBlank ?? tag, notes: json["body"].string,
                          pageURL: json["html_url"].string, ipaURL: ipa, publishedAt: json["published_at"].string,
                          isPrerelease: json["prerelease"].bool)
    }

    /// 去掉 v 前缀与 -beta 之类的后缀
    static func normalize(_ tag: String) -> String {
        var s = tag.trimmed
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        return String(s.prefix { $0.isNumber || $0 == "." })
    }

    /// 按数字段逐段比较（1.10.0 > 1.9.3，缺的段按 0）
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalize(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalize(current).split(separator: ".").map { Int($0) ?? 0 }
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
