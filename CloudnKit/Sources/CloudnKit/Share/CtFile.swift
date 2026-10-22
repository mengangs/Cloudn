// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 城通网盘分享解析（免登录）：文件 getfile.php 取 file_chk → get_down_url.php 取直链；
// 文件夹 getdir.php 拿列表地址 → DataTables 分页接口（每行是 HTML 片段）列目录，子文件夹用 folder_id + fk 继续进入。
// 接口与解析做法参考 qaiu/netdisk-fast-download（MIT License，Copyright (c) 2023 qaiu）的 CtTool。
import Foundation

public final class CtFileResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .ctfile }
    public var supportsGuestDownload: Bool { true }

    static let apiBase = "https://webapi.ctfile.com"
    static let fileURLPrefix = "https://ctfile.com/file/"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let pageSize = 200
    /// 单文件分享的根目录标记
    static let singleRoot = "#file"

    private let credentials: CredentialStore
    private let client: HTTPClient

    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared) {
        self.credentials = credentials
        self.client = client
    }

    // MARK: 链接识别

    /// ctfile.com 及其各个用户子域名、备用域名；/f/ /file/ 为文件，/d/ 为文件夹；?p= 为提取码
    private static let linkRx = Rx(#"https?://(?:[A-Za-z0-9-]+\.)*(?:ctfile|545c|u062|089u|ghpym|474b)\.com/(f|file|d)/([0-9A-Za-z_-]+)"#, ignoreCase: true)
    private static let pwdRx = Rx(#"[?&#]p=(\w+)"#)

    static func shareTarget(_ url: String) -> (id: String, pwd: String?)? {
        guard let m = linkRx.firstMatch(in: url), m[2].contains("-") else { return nil }
        return (m[2], pwdRx.first(in: url))
    }

    /// 链接里的类型段：f / file / d
    static func pathKind(_ url: String) -> String {
        linkRx.firstMatch(in: url)?[1].lowercased() ?? "f"
    }

    /// 会话里存提取码 + 原始链接（接口要带上原链接作 url / Referer）
    static func encodeToken(pwd: String, url: String) -> String { pwd + "\n" + url }

    static func decodeToken(_ token: String) -> (pwd: String, url: String) {
        let parts = token.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let password = (pwd ?? share.pwd ?? Self.pwdRx.first(in: share.url) ?? "").trimmed
        let token = Self.encodeToken(pwd: password, url: share.url)
        if Self.pathKind(share.url) == "d" {
            let dir = try await getDir(shareKey: share.shareId, url: share.url, pwd: password, dirId: "")
            let title = dir.string("folder_name", "name", "title").nilIfBlank.map(GoogleDriveResolver.decodeEntities) ?? "城通网盘分享"
            return ShareSession(platform: .ctfile, shareId: share.shareId, stoken: token, title: title, rootId: "")
        }
        let file = try await getFile(shareKey: share.shareId, url: share.url, pwd: password)
        let title = file["file_name"].string.nilIfBlank ?? "城通网盘文件"
        return ShareSession(platform: .ctfile, shareId: share.shareId, stoken: token, title: title, rootId: Self.singleRoot)
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let (pwd, url) = Self.decodeToken(session.stoken)
        if dirId == Self.singleRoot {
            let file = try await getFile(shareKey: session.shareId, url: url, pwd: pwd)
            return [ShareFile(fid: session.shareId, name: file["file_name"].string.nilIfBlank ?? session.title,
                              size: ByteFormat.parseDisplay(file["file_size"].string), isDirectory: false, parentId: dirId, token: url,
                              modified: file["file_time"].string)]
        }
        let dir = try await getDir(shareKey: session.shareId, url: url, pwd: pwd, dirId: dirId)
        let listURL = dir["url"].string.trimmed
        guard !listURL.isEmpty else { throw CloudnError("城通网盘没有返回文件列表，分享可能已失效") }
        let base = listURL.hasPrefix("http") ? listURL : Self.apiBase + listURL
        var all: [ShareFile] = []
        var seen = Set<String>()
        var start = 0
        for _ in 0..<50 {
            let pageURL = base + (base.contains("?") ? "&" : "?") + Self.pageParams(start: start, length: Self.pageSize) + "&_=\(Self.millis())"
            let r = try await client.send(.get(pageURL, headers: Self.ajaxHeaders(url)))
            guard let json = r.json, json.isObject else { throw CloudnError("城通网盘列表请求失败（HTTP \(r.status)）") }
            let rows = json["aaData"].array
            for row in rows {
                guard let f = Self.parseRow(row, parent: dirId), seen.insert(f.fid).inserted else { continue }
                all.append(f)
            }
            let total = json["iTotalDisplayRecords"].isNull ? (json["iTotalRecords"].isNull ? -1 : json["iTotalRecords"].int) : json["iTotalDisplayRecords"].int
            start += rows.count
            if rows.isEmpty || (total >= 0 ? start >= total : rows.count < Self.pageSize) { break }
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹无法直接下载") }
        let (pwd, rootURL) = Self.decodeToken(session.stoken)
        let url = file.token.hasPrefix("http") ? file.token : (rootURL.nilIfBlank ?? Self.fileURLPrefix + file.fid)
        let info = try await getFile(shareKey: file.fid, url: url, pwd: pwd)
        let parts = file.fid.split(separator: "-").map(String.init)
        let uid = info["userid"].string.nilIfBlank ?? parts.first ?? ""
        let fid = info["file_id"].string.nilIfBlank ?? (parts.count > 1 ? parts[1] : "")
        let chk = info["file_chk"].string
        guard !uid.isEmpty, !fid.isEmpty, !chk.isEmpty else { throw CloudnError("城通网盘下载参数不完整，分享可能已失效或提取码不对") }
        let query = [("uid", uid), ("fid", fid), ("file_chk", chk), ("start_time", info["start_time"].string),
                     ("wait_seconds", info["wait_seconds"].string), ("rd", Self.random())]
        let r = try await client.send(.get(Self.apiBase + "/get_down_url.php?" + Self.query(query), headers: Self.ajaxHeaders(url)))
        guard let json = r.json, json.isObject else { throw CloudnError("城通网盘下载接口请求失败（HTTP \(r.status)）") }
        let link = json["downurl"].string
        guard !link.isEmpty else {
            throw CloudnError(json["message"].string.nilIfBlank.map { "城通网盘：\($0)" } ?? "城通网盘没有返回下载地址，分享可能已失效")
        }
        let size = file.size > 0 ? file.size : ByteFormat.parseDisplay(info["file_size"].string)
        return DownloadLink(fileName: file.name, url: link, size: size, headers: ["User-Agent": Self.ua, "Referer": url])
    }

    // MARK: 接口

    /// getfile.php → file 对象（含 file_chk / start_time / wait_seconds）
    private func getFile(shareKey: String, url: String, pwd: String) async throws -> JSON {
        let query = [("path", Self.pathKind(url)), ("f", shareKey), ("passcode", pwd), ("r", Self.random()), ("ref", ""), ("url", url)]
        let r = try await client.send(.get(Self.apiBase + "/getfile.php?" + Self.query(query), headers: Self.ajaxHeaders(url)))
        guard let json = r.json, json.isObject else { throw CloudnError("城通网盘请求失败（HTTP \(r.status)）") }
        let file = json["file"]
        guard file.isObject, !file["file_chk"].string.isEmpty || !file["file_name"].string.isEmpty else {
            throw Self.fileError(json)
        }
        return file
    }

    /// getdir.php → file 对象（url 为列表接口地址）；dirId 为「folder_id:fk」，空串时用链接里的参数
    private func getDir(shareKey: String, url: String, pwd: String, dirId: String) async throws -> JSON {
        let ctx = Self.directoryContext(url: url, dirId: dirId)
        let query = [("path", Self.pathKind(url)), ("d", shareKey), ("folder_id", ctx.folderId), ("fk", ctx.folderKey), ("passcode", pwd),
                     ("r", Self.random()), ("ref", ""), ("url", url)]
        let r = try await client.send(.get(Self.apiBase + "/getdir.php?" + Self.query(query), headers: Self.ajaxHeaders(url)))
        guard let json = r.json, json.isObject else { throw CloudnError("城通网盘请求失败（HTTP \(r.status)）") }
        let dir = json["file"]
        guard dir.isObject, !dir["url"].string.trimmed.isEmpty else { throw Self.fileError(json) }
        return dir
    }

    static func fileError(_ json: JSON) -> CloudnError {
        let code = json["code"].int
        let message = json["file"]["message"].string.nilIfBlank ?? json["message"].string
        if code == 423 || code == 401 || message.contains("密码") || message.contains("提取码") {
            return CloudnError("城通网盘提取码错误或缺失，请填写后重新解析", code: code)
        }
        if code == 404 || message.contains("不存在") || message.contains("删除") { return CloudnError("城通网盘分享不存在或已被删除", code: code) }
        return CloudnError(message.nilIfBlank.map { "城通网盘：\($0)" } ?? "城通网盘分享解析失败（\(code)），可能已失效", code: code)
    }

    struct DirectoryContext: Equatable {
        let folderId: String
        let folderKey: String
    }

    static func directoryContext(url: String, dirId: String) -> DirectoryContext {
        if !dirId.isEmpty {
            let parts = dirId.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return DirectoryContext(folderId: parts[0].nilIfBlank ?? "undefined", folderKey: parts.count > 1 ? parts[1] : "")
        }
        let folderId = queryValue(url, "folder_id") ?? queryValue(url, "d") ?? ""
        let fk = queryValue(url, "fk") ?? ""
        return DirectoryContext(folderId: folderId.nilIfBlank ?? "undefined", folderKey: fk)
    }

    static func queryValue(_ url: String, _ name: String) -> String? {
        URLComponents(string: url)?.queryItems?.first { $0.name == name }?.value?.nilIfBlank
    }

    // MARK: 列表行（DataTables：[勾选框 HTML, 名称 HTML, 大小, 日期]）

    private static let fileIdRx = Rx(#"value=["']f(\d+)["']"#)
    private static let folderIdRx = Rx(#"value=["']d(\d+)["']"#)
    private static let fileHrefRx = Rx(#"href=["']#/f/([^"']+)["']"#)
    private static let nameRx = Rx(#"<a\b[^>]*>([^<]+)</a>"#, ignoreCase: true)
    private static let iconRx = Rx(#"alt=["']([^"']+)["']"#)
    private static let subdirRx = Rx(#"load_subdir\s*\((\d+)\s*,\s*['"]([^'"]+)['"]\)"#)

    static func parseRow(_ row: JSON, parent: String) -> ShareFile? {
        let cells = row.array.map(\.string)
        guard cells.count >= 2 else { return nil }
        let checkbox = cells[0], nameCell = cells[1]
        let size = cells.count > 2 ? cells[2].trimmed : ""
        let date = cells.count > 3 ? cells[3].trimmed : ""
        guard let rawName = nameRx.first(in: nameCell)?.trimmed, !rawName.isEmpty else { return nil }
        let name = GoogleDriveResolver.decodeEntities(rawName)
        let icon = iconRx.first(in: nameCell) ?? ""
        if let m = subdirRx.firstMatch(in: nameCell) {
            return ShareFile(fid: "\(m[1]):\(m[2])", name: name, size: 0, isDirectory: true, parentId: parent, modified: date)
        }
        if icon.lowercased() == "folder" {
            guard let id = folderIdRx.first(in: checkbox) else { return nil }
            return ShareFile(fid: "\(id):", name: name, size: 0, isDirectory: true, parentId: parent, modified: date)
        }
        guard let key = fileHrefRx.first(in: nameCell)?.nilIfBlank else { return nil }
        return ShareFile(fid: key, name: name, size: ByteFormat.parseDisplay(size), isDirectory: false, parentId: parent,
                         token: fileURLPrefix + key, modified: date)
    }

    static func pageParams(start: Int, length: Int) -> String {
        var s = "sEcho=1&iColumns=4&sColumns=%2C%2C%2C&iDisplayStart=\(max(0, start))&iDisplayLength=\(max(1, length))"
        for i in 0..<4 {
            s += "&mDataProp_\(i)=\(i)&sSearch_\(i)=&bRegex_\(i)=false&bSearchable_\(i)=true&bSortable_\(i)=\(i == 0 ? "false" : "true")"
        }
        return s + "&sSearch=&bRegex=false&iSortCol_0=3&sSortDir_0=desc&iSortingCols=1"
    }

    // MARK: 请求构造

    static func ajaxHeaders(_ shareURL: String) -> [(String, String)] {
        var h: [(String, String)] = [("User-Agent", ua), ("Accept", "application/json, text/javascript, */*; q=0.01"),
                                     ("X-Requested-With", "XMLHttpRequest")]
        if !shareURL.isEmpty {
            h.append(("Referer", shareURL))
            if let u = URL(string: shareURL), let scheme = u.scheme, let host = u.host { h.append(("Origin", "\(scheme)://\(host)")) }
        }
        return h
    }

    static func query(_ params: [(String, String)]) -> String {
        params.map { "\($0.0)=\($0.1.urlQueryEncoded)" }.joined(separator: "&")
    }

    static func random() -> String { String(Double.random(in: 0..<1)) }
    static func millis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
