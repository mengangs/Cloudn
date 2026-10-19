// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 光鸭云盘分享解析（匿名）：提取码换分享访问令牌 → 游标翻页列目录 → get_share_download_url 取直链。
// 协议细节参考 YunX（AGPL-3.0）的 GuangYaApi / GuangYaResolveRepository。
import Foundation

public final class GuangYaResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .guangya }
    public var supportsGuestDownload: Bool { true }

    static let webSite = "https://www.guangyapan.com"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let pageSize = 100

    private let client: HTTPClient
    private let apiBase: String
    /// 业务接口必需的 did 设备头：匿名访问用进程内固定的随机设备
    private let deviceId = GuangYaResolver.randomHex(32)

    public init(client: HTTPClient = .shared, apiBase: String = "https://api.guangyapan.com") {
        self.client = client
        self.apiBase = apiBase
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let code = pwd?.nilIfBlank ?? share.pwd ?? ""
        let data = try await call("get_share_access_token", .object([("shareId", .string(share.shareId)), ("code", .string(code))]),
                                  fallback: "获取分享访问令牌失败")
        let token = data.string("accessToken", "access_token")
        guard !token.isEmpty else { throw CloudnError("光鸭分享链接无效") }
        let summary = try? await call("get_share_summary", .object([("shareId", .string(share.shareId))]), fallback: "获取分享信息失败")
        let title = summary?.string("title", "shareName") ?? ""
        return ShareSession(platform: .guangya, shareId: share.shareId, stoken: token,
                            title: title.isEmpty ? "光鸭云盘分享" : title, rootId: "")
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var seen = Set<String>()
        var cursor: String?
        for _ in 0..<1000 {
            var fields: [(String, OrderedJSON)] = [
                ("parentId", .string(dirId)), ("pageSize", .int(Int64(Self.pageSize))), ("orderBy", .int(0)),
                ("sortType", .int(0)), ("accessToken", .string(session.stoken))
            ]
            if let cursor { fields.append(("cursor", .string(cursor))) }
            let data = try await call("get_share_page_files_list", .object(fields), fallback: "获取分享文件列表失败")
            for f in Self.listArray(data).map({ Self.parseFile($0) }) where seen.insert(f.fid).inserted { all.append(f) }
            let next = data["cursor"].string
            guard data["hasMore"].bool, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let data: JSON
        do {
            data = try await call("get_share_download_url", .object([("fileId", .string(file.fid)), ("accessToken", .string(session.stoken))]),
                                  fallback: "获取下载地址失败")
        } catch let e as CloudnError where e.code == 207 {
            throw CloudnError("分享者未开放免登录下载，暂时只能在光鸭云盘官方客户端转存后下载", code: 207)
        }
        let url = data.string("signedURL", "signedUrl", "downloadUrl", "download_url", "url", "cdnUrl")
        guard !url.isEmpty else { throw CloudnError("光鸭未返回有效下载地址，请确认下载权限") }
        let size = data["size"].int64 > 0 ? data["size"].int64 : file.size
        return DownloadLink(fileName: file.name, url: url, size: size, headers: ["User-Agent": Self.ua, "Referer": Self.webSite + "/"])
    }

    // MARK: 请求

    private func call(_ name: String, _ body: OrderedJSON, fallback: String) async throws -> JSON {
        let headers: [(String, String)] = [
            ("Accept", "application/json, text/plain, */*"), ("Content-Type", "application/json"), ("User-Agent", Self.ua),
            ("Origin", Self.webSite), ("Referer", Self.webSite + "/"), ("dt", "4"), ("did", deviceId),
            ("traceparent", "00-\(Self.randomHex(32))-\(Self.randomHex(16))-01")
        ]
        let r = try await client.send(HTTPRequest(url: "\(apiBase)/userres/v1/\(name)", method: "POST", headers: headers, body: Data(body.text.utf8)))
        guard let json = r.json, json.isObject else { throw CloudnError("光鸭响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: fallback)
        return json["data"]
    }

    static func check(_ json: JSON, fallback: String) throws {
        let code = json["code"].string
        let failed = (json.has("success") && !json["success"].bool) || !json["error"].string.isEmpty || !(code.isEmpty || code == "0")
        guard failed else { return }
        let mapped: String?
        switch code {
        case "209": mapped = "光鸭分享提取码错误或缺失"
        case "200", "201", "202": mapped = "光鸭分享已取消、过期或不可访问"
        case "205", "206", "504": mapped = "光鸭分享下载受限，请在官网确认该分享的下载权限"
        case "207": mapped = "该光鸭分享需要登录并转存后才能下载"
        default: mapped = nil
        }
        let server = json.string("msg", "message", "error_description")
        throw CloudnError(mapped ?? (server.isEmpty ? "\(fallback)（code=\(code)）" : server), code: Int(code) ?? -1)
    }

    /// 不同接口版本的列表字段名不一致
    static func listArray(_ data: JSON) -> [JSON] {
        data.arrayValue("list", "items", "files", "records", "content")
    }

    static func parseFile(_ item: JSON) -> ShareFile {
        let name = item.string("fileName", "name", "filename", "dirName", "title")
        let isDir: Bool
        switch item["resType"].string {
        case "2": isDir = true
        case "1": isDir = false
        default:
            let types: Set<String> = ["folder", "dir", "directory", "0"]
            isDir = item["isDir"].bool || item["isdir"].bool || item["dir"].bool || item["isFolder"].bool || item["folder"].bool ||
                !item["dirName"].string.isEmpty || types.contains(item["type"].string.lowercased()) ||
                types.contains(item["fileType"].string.lowercased()) || (!name.contains(".") && item["dirType"].string == "1")
        }
        return ShareFile(
            fid: item.string("fileId", "file_id", "id", "resId", "resourceId"),
            name: name,
            size: Int64(item.string("fileSize", "size", "file_size")) ?? 0,
            isDirectory: isDir,
            parentId: item.string("parentId", "parentFileId", "parent_id"),
            modified: item.string("updatedAt", "updateAt", "updated_at", "updateTime", "mtime", "utime", "createdAt", "createTime", "ctime")
        )
    }

    static func randomHex(_ n: Int) -> String {
        String((0..<n).map { _ in "0123456789abcdef".randomElement()! })
    }
}
