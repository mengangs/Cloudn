// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// Dropbox 分享解析：未登录时文件链接改 dl=1 直接下载、文件夹链接 dl=1 由 Dropbox 打包成 zip 下载；
// 登录后走 API v2：get_shared_link_metadata 打开分享，list_folder(shared_link) 列目录，get_shared_link_file 取文件（支持分享密码）。
// 「我的网盘」浏览 / 新建 / 重命名 / 移动 / 删除 / 容量 / 分享、分片上传、save_url 离线下载。
// 我的网盘接口参考 OpenList drivers/dropbox（AGPL-3.0），其余按 Dropbox API v2 官方文档。
import Foundation

public final class DropboxResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .dropbox }
    public var supportsGuestDownload: Bool { true }

    static let api = "https://api.dropboxapi.com/2"
    static let content = "https://content.dropboxapi.com/2"
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    /// 上传分片（Dropbox 要求单次不超过 150MB；不超过一片的文件直接 /files/upload）
    static let uploadChunk: Int64 = 8 << 20
    /// 只有一个条目的分享（单文件 / 未登录时打包的文件夹）根目录标记
    static let singleRoot = "#single"
    static let rootFileId = "#root"
    static let expired = CloudnError("Dropbox 登录已失效，请到「我的」页重新登录", code: 401)

    let credentials: CredentialStore
    let client: HTTPClient
    private let roots = RootCache()
    let jobs = OfflineJobs()

    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared) {
        self.credentials = credentials
        self.client = client
    }

    // MARK: 链接识别

    struct SharedLink: Equatable {
        /// 规范化后的分享链接（www.dropbox.com，只保留 rlkey / st 参数）
        let url: String
        let isFolder: Bool
        /// 文件链接路径里带的文件名
        let name: String?
    }

    private static let linkRx = Rx(#"^https?://(?:www\.|dl\.)?(?:dropbox\.com|dropboxusercontent\.com)/(s|sh|scl/fi|scl/fo)/([^?#\s]+)(?:\?([^#\s]*))?"#, ignoreCase: true)

    static func parseLink(_ url: String) -> SharedLink? {
        guard let m = linkRx.firstMatch(in: url.trimmed) else { return nil }
        let type = m[1].lowercased()
        let rest = m[2].trimmingTrailing("/")
        let segments = rest.split(separator: "/").map(String.init)
        guard let first = segments.first, !first.isEmpty else { return nil }
        let keep = m[3].split(separator: "&").filter { pair in
            let key = pair.split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            return key == "rlkey" || key == "st"
        }
        var canonical = "https://www.dropbox.com/\(type)/\(rest)"
        if !keep.isEmpty { canonical += "?" + keep.joined(separator: "&") }
        let isFolder = type == "sh" || type == "scl/fo"
        let name = !isFolder && segments.count >= 2 ? segments.last?.removingPercentEncoding?.nilIfBlank : nil
        return SharedLink(url: canonical, isFolder: isFolder, name: name)
    }

    /// 分享 id 用规范化后的完整链接（接口要整条链接）；Dropbox 链接里不带密码
    static func shareTarget(_ url: String) -> (id: String, pwd: String?)? {
        guard let link = parseLink(url) else { return nil }
        return (link.url, nil)
    }

    /// 免登录直接下载：dl=1（文件夹会被打包成 zip）
    static func directURL(_ link: String) -> String {
        link + (link.contains("?") ? "&" : "?") + "dl=1"
    }

    // MARK: 凭据

    /// 保存形态：OAuthCredential 的 JSON。粘贴的裸访问令牌（sl.… 短期令牌或旧式长期令牌）没有 refresh_token，过期后需重新粘贴
    static func normalizeCredential(_ raw: String) -> String {
        parseCredential(raw)?.serialized ?? raw.trimmed
    }

    static let tokenRx = Rx(#"^[A-Za-z0-9._~+/=-]{20,}$"#)

    static func parseCredential(_ raw: String) -> OAuthCredential? {
        let text = raw.trimmed
        if let cred = OAuthCredential.parse(text) { return cred }
        if let json = JSON(text: text), json.isObject {
            let access = json["access_token"].string
            guard !access.isEmpty else { return nil }
            var expires = json["expires_at"].int64
            if expires == 0, json["expires_in"].int64 > 0 { expires = Int64(Date().timeIntervalSince1970) + json["expires_in"].int64 }
            return OAuthCredential(refreshToken: json["refresh_token"].string, accessToken: access, expiresAt: expires, name: json["name"].string)
        }
        var token = text
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmed }
        guard tokenRx.matches(token) else { return nil }
        return OAuthCredential(refreshToken: "", accessToken: token, expiresAt: 0, name: "")
    }

    static func validate(cookie: String) async -> String? {
        guard var cred = parseCredential(cookie) else { return nil }
        if !cred.isFresh, !cred.refreshToken.isEmpty, let provider = OAuthProvider.dropbox,
           let renewed = try? await provider.refresh(cred) {
            cred = renewed
        }
        return await accountName(token: cred.accessToken, client: .shared)
    }

    static func accountName(token: String, client: HTTPClient) async -> String? {
        let request = HTTPRequest(url: api + "/users/get_current_account", method: "POST",
                                  headers: [("Authorization", "Bearer " + token), ("Content-Type", "application/json")], body: Data("null".utf8))
        guard let r = try? await client.send(request), r.isSuccess, let json = r.json else { return nil }
        return json["name"]["display_name"].string.nilIfBlank ?? json["email"].string.nilIfBlank ?? "Dropbox 用户"
    }

    /// 已保存账号的访问令牌；没登录返回 nil。有 refresh_token 且配置了 App Key 时自动续期，否则令牌被拒即提示重新登录
    func accessToken(rejecting rejected: String? = nil) async throws -> String? {
        guard let raw = await credentials.cookie(for: .dropbox)?.nilIfBlank, let cred = Self.parseCredential(raw) else { return nil }
        if !cred.refreshToken.isEmpty, let provider = OAuthProvider.dropbox {
            return try await OAuthCredential.accessToken(.dropbox, provider: provider, credentials: credentials, client: client, rejecting: rejected)
        }
        if let rejected, cred.accessToken == rejected { throw Self.expired }
        return cred.accessToken
    }

    // MARK: 请求

    /// RPC 接口：POST JSON；401 时续期重试一次
    @discardableResult
    func rpc(_ endpoint: String, _ body: [String: Any]? = nil) async throws -> JSON {
        let r = try await rpcResponse(endpoint, body)
        if r.isSuccess { return r.json ?? JSON([String: Any]()) }
        throw Self.apiError(r.status, r.json, text: r.text)
    }

    /// 原始响应（调用方自己处理 409 业务错误）
    func rpcResponse(_ endpoint: String, _ body: [String: Any]?) async throws -> HTTPResponse {
        guard var token = try await accessToken() else { throw SharePlatform.dropbox.loginRequired }
        let data = body.map { JSON.serialize($0) } ?? Data("null".utf8)
        for attempt in 0..<2 {
            let r = try await client.send(HTTPRequest(url: Self.api + "/" + endpoint, method: "POST",
                                                      headers: [("Authorization", "Bearer " + token), ("Content-Type", "application/json")], body: data))
            if r.status == 401, attempt == 0, let fresh = try await accessToken(rejecting: token), fresh != token {
                token = fresh
                continue
            }
            if r.status == 401 { throw Self.expired }
            return r
        }
        throw Self.expired
    }

    /// Dropbox-API-Arg 头里的 JSON：HTTP 头只能放 ASCII，非 ASCII 字符转成 \uXXXX
    static func apiArg(_ object: Any) -> String {
        let text = String(decoding: JSON.serialize(object), as: UTF8.self)
        var out = ""
        for unit in text.utf16 {
            if unit < 0x80 {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                let hex = String(unit, radix: 16)
                out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            }
        }
        return out
    }

    static func apiError(_ status: Int, _ json: JSON?, text: String = "") -> CloudnError {
        let summary = json?["error_summary"].string ?? ""
        func has(_ key: String) -> Bool { summary.contains(key) }
        if status == 401 { return expired }
        if status == 429 || has("too_many_requests") || has("too_many_write_operations") { return CloudnError("Dropbox 请求太频繁，请稍后再试") }
        if status >= 500 { return CloudnError("Dropbox 暂时不可用（HTTP \(status)），请稍后重试") }
        if has("missing_scope") { return CloudnError("Dropbox 授权缺少所需权限，请重新登录") }
        if has("shared_link_not_found") { return CloudnError("Dropbox 分享不存在或已失效") }
        if has("invalid_password") || has("password_required") { return CloudnError("Dropbox 分享密码错误") }
        if has("shared_link_access_denied") { return CloudnError("无法访问这个 Dropbox 分享：可能需要密码，或仅限指定的人访问") }
        if has("email_not_verified") { return CloudnError("请先验证 Dropbox 账号的邮箱") }
        if has("settings_error") || has("not_authorized") { return CloudnError("设置分享密码或有效期需要 Dropbox 付费账号") }
        if has("insufficient_space") { return CloudnError("Dropbox 空间不足") }
        if has("too_many_files") || has("too_large") { return CloudnError("文件夹太大或文件太多，Dropbox 无法打包下载") }
        if has("conflict") { return CloudnError("目标位置已有同名文件或文件夹") }
        if has("disallowed_name") { return CloudnError("Dropbox 不允许这个文件名") }
        if has("malformed_path") { return CloudnError("Dropbox 路径格式不对") }
        if has("not_found") { return CloudnError("文件不存在或已被删除") }
        if has("cant_move_folder_into_itself") || has("cant_nest_shared_folder") { return CloudnError("不能移动到这个位置") }
        if status == 403 { return CloudnError("Dropbox 拒绝了这个操作（没有权限）", code: 403) }
        if status == 400 {
            let detail = text.trimmed.prefix(100)
            return CloudnError(detail.isEmpty ? "Dropbox 请求有误（HTTP 400）" : "Dropbox 请求有误：\(detail)")
        }
        return CloudnError("Dropbox：\(summary.nilIfBlank ?? "请求失败（HTTP \(status)）")")
    }

    // MARK: 条目

    /// list_folder 的条目：fid 为路径（我的网盘是 path_display，分享里是相对分享根目录的路径），token 为 Dropbox 的 id
    static func parseEntry(_ j: JSON, parent: String) -> ShareFile? {
        let tag = j[".tag"].string
        guard tag == "file" || tag == "folder" else { return nil }
        let name = j["name"].string
        guard !name.isEmpty else { return nil }
        let path = j["path_display"].string.nilIfBlank ?? join(parent, name)
        return ShareFile(fid: path, name: name, size: tag == "file" ? j["size"].int64 : 0, isDirectory: tag == "folder", parentId: parent,
                         token: j["id"].string, modified: ISO8601DateFormatter.listText(j["server_modified"].string))
    }

    static func join(_ parent: String, _ name: String) -> String {
        (parent == "/" ? "" : parent.trimmingTrailing("/")) + "/" + name
    }

    /// 路径的上级目录（"/a/b" → "/a"，"/a" → ""）
    static func parentPath(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    /// list_folder + list_folder/continue 翻页取完
    func listFolder(_ body: [String: Any], parent: String) async throws -> [ShareFile] {
        var json = try await rpc("files/list_folder", body)
        var all = json["entries"].array.compactMap { Self.parseEntry($0, parent: parent) }
        var seen = Set<String>()
        while json["has_more"].bool {
            let cursor = json["cursor"].string
            guard !cursor.isEmpty, seen.insert(cursor).inserted, seen.count < 500 else { break }
            json = try await rpc("files/list_folder/continue", ["cursor": cursor])
            all += json["entries"].array.compactMap { Self.parseEntry($0, parent: parent) }
        }
        return all
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        guard let link = Self.parseLink(share.url) ?? Self.parseLink(share.shareId) else { throw CloudnError("无法识别的 Dropbox 链接") }
        let password = (pwd ?? share.pwd ?? "").trimmed
        if (try? await accessToken()) != nil {
            do {
                return try await openWithAPI(link, password: password)
            } catch let error as CloudnError where error.code == 401 && password.isEmpty {
                // 登录失效：公开链接仍可免登录下载
            }
        }
        guard password.isEmpty else { throw CloudnError("带密码的 Dropbox 分享需要先到「我的」页登录 Dropbox") }
        return try await openAnonymous(link)
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        if dirId == Self.singleRoot {
            if let file = await roots.get(session.shareId) { return [file] }
            let reopened = try await openSession(ParsedShare(shareId: session.shareId, pwd: session.stoken.nilIfBlank, platform: .dropbox,
                                                             url: session.shareId), pwd: session.stoken.nilIfBlank)
            guard reopened.rootId == Self.singleRoot, let file = await roots.get(session.shareId) else {
                return try await list(reopened, dirId: reopened.rootId)
            }
            return [file]
        }
        return try await listFolder(["path": dirId, "shared_link": Self.sharedLinkArg(session)], parent: dirId)
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        if file.token.hasPrefix("http") {
            return DownloadLink(fileName: file.name, url: file.token, size: file.size, headers: ["User-Agent": Self.ua])
        }
        guard !file.isDirectory else { throw CloudnError("文件夹无法直接下载") }
        guard let token = try await accessToken() else { throw SharePlatform.dropbox.loginRequired }
        // 下载类接口也支持 GET + Range；参数放 Dropbox-API-Arg 头
        return DownloadLink(fileName: file.name, url: Self.content + "/sharing/get_shared_link_file", size: file.size,
                            headers: ["Authorization": "Bearer " + token,
                                      "Dropbox-API-Arg": Self.apiArg(Self.sharedFileArg(session, path: file.fid == Self.rootFileId ? nil : file.fid)),
                                      "User-Agent": Self.ua])
    }

    static func sharedLinkArg(_ session: ShareSession) -> [String: Any] {
        var arg: [String: Any] = ["url": session.shareId]
        if !session.stoken.isEmpty { arg["password"] = session.stoken }
        return arg
    }

    static func sharedFileArg(_ session: ShareSession, path: String?) -> [String: Any] {
        var arg: [String: Any] = ["url": session.shareId]
        if let path { arg["path"] = path }
        if !session.stoken.isEmpty { arg["link_password"] = session.stoken }
        return arg
    }

    private func openWithAPI(_ link: SharedLink, password: String) async throws -> ShareSession {
        var body: [String: Any] = ["url": link.url]
        if !password.isEmpty { body["link_password"] = password }
        let meta = try await rpc("sharing/get_shared_link_metadata", body)
        let name = meta["name"].string.nilIfBlank ?? link.name ?? "Dropbox 分享"
        if meta[".tag"].string == "folder" {
            return ShareSession(platform: .dropbox, shareId: link.url, stoken: password, title: name, rootId: "")
        }
        let file = ShareFile(fid: Self.rootFileId, name: name, size: meta["size"].int64, isDirectory: false, parentId: Self.singleRoot,
                             token: "", modified: ISO8601DateFormatter.listText(meta["server_modified"].string))
        await roots.set(link.url, file)
        return ShareSession(platform: .dropbox, shareId: link.url, stoken: password, title: name, rootId: Self.singleRoot)
    }

    /// 未登录：文件探测第 1 个字节拿文件名和大小；文件夹整个打包成 zip（只发 HEAD，不触发打包传输）
    private func openAnonymous(_ link: SharedLink) async throws -> ShareSession {
        let direct = Self.directURL(link.url)
        let file: ShareFile
        if link.isFolder {
            var name = "Dropbox 分享.zip"
            if let r = try? await client.send(HTTPRequest(url: direct, method: "HEAD", headers: [("User-Agent", Self.ua)], timeout: 15)) {
                if r.status == 404 { throw CloudnError("Dropbox 分享不存在或已失效") }
                if let n = GoogleDriveResolver.fileName(fromDisposition: r.header("Content-Disposition") ?? "") { name = n }
            }
            file = ShareFile(fid: Self.rootFileId, name: name, size: 0, isDirectory: false, parentId: Self.singleRoot, token: direct)
        } else {
            let r = try await client.send(HTTPRequest(url: direct, headers: [("User-Agent", Self.ua), ("Range", "bytes=0-0")], timeout: 30))
            if let error = Self.anonymousError(r) { throw error }
            let name = GoogleDriveResolver.fileName(fromDisposition: r.header("Content-Disposition") ?? "") ?? link.name ?? "Dropbox 文件"
            let size = r.status == 416 ? 0 : GoogleDriveResolver.totalSize(r)
            file = ShareFile(fid: Self.rootFileId, name: name, size: size, isDirectory: false, parentId: Self.singleRoot, token: direct)
        }
        await roots.set(link.url, file)
        return ShareSession(platform: .dropbox, shareId: link.url, stoken: "", title: file.name, rootId: Self.singleRoot)
    }

    /// dl=1 没有拿到文件：网页（密码页 / 登录页 / 已删除）或 HTTP 错误
    static func anonymousError(_ r: HTTPResponse) -> CloudnError? {
        if r.status == 404 || r.status == 410 { return CloudnError("Dropbox 分享不存在或已失效") }
        if r.status == 429 || r.status == 460 { return CloudnError("这个 Dropbox 分享流量超限，暂时不能下载") }
        if r.status == 416 { return nil }
        let type = (r.header("Content-Type") ?? "").lowercased()
        if type.contains("text/html") || !(200..<300).contains(r.status) {
            if r.url.contains("/password") || r.text.contains("password") && r.text.contains("shared_link") {
                return CloudnError("这个 Dropbox 分享设置了密码，请先到「我的」页登录 Dropbox，再输入密码")
            }
            return CloudnError("Dropbox 没有返回文件：分享可能已失效、设置了密码或仅限指定的人访问（登录 Dropbox 后可再试）")
        }
        return nil
    }

    private actor RootCache {
        var map: [String: ShareFile] = [:]
        func get(_ k: String) -> ShareFile? { map[k] }
        func set(_ k: String, _ v: ShareFile) { map[k] = v }
    }
}

// MARK: - 我的网盘

extension DropboxResolver: DriveManager {
    public var driveRootId: String { "" }
    public var driveCapabilities: DriveCapabilities { .all }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        try await listFolder(["path": folderId, "limit": 2000, "include_non_downloadable_files": false], parent: folderId)
    }

    /// 文件：get_temporary_link（4 小时有效）；文件夹：download_zip 打包下载（20GB / 1 万个文件以内）
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        if file.isDirectory {
            guard let token = try await accessToken() else { throw SharePlatform.dropbox.loginRequired }
            return DownloadLink(fileName: file.name + ".zip", url: Self.content + "/files/download_zip", size: 0,
                                headers: ["Authorization": "Bearer " + token, "Dropbox-API-Arg": Self.apiArg(["path": file.fid]), "User-Agent": Self.ua])
        }
        let json = try await rpc("files/get_temporary_link", ["path": file.fid])
        let link = json["link"].string
        guard !link.isEmpty else { throw CloudnError("Dropbox 没有返回下载地址") }
        return DownloadLink(fileName: file.name, url: link, size: json["metadata"]["size"].int64 > 0 ? json["metadata"]["size"].int64 : file.size,
                            headers: ["User-Agent": Self.ua])
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        try await rpc("files/create_folder_v2", ["path": Self.join(parentId, name), "autorename": false])
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        try await rpc("files/move_v2", Self.moveBody(from: file.fid, to: Self.join(Self.parentPath(file.fid), name)))
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        for file in files {
            try await rpc("files/move_v2", Self.moveBody(from: file.fid, to: Self.join(folderId, file.name)))
        }
    }

    static func moveBody(from: String, to: String) -> [String: Any] {
        ["from_path": from, "to_path": to, "autorename": false, "allow_ownership_transfer": false]
    }

    /// 删除（30 天内可在 Dropbox 网页版恢复）
    public func delete(_ files: [ShareFile]) async throws {
        for file in files { try await rpc("files/delete_v2", ["path": file.fid]) }
    }

    public func quota() async -> DriveQuota? {
        guard let json = try? await rpc("users/get_space_usage") else { return nil }
        return Self.parseQuota(json)
    }

    static func parseQuota(_ json: JSON) -> DriveQuota? {
        let total = json["allocation"]["allocated"].int64
        guard total > 0 else { return nil }
        return DriveQuota(used: json["used"].int64, total: total)
    }

    // MARK: 分享

    public var shareExpiryOptions: [ShareExpiry] { ShareExpiry.standard }
    public var shareAudienceOptions: [ShareAudience] { [.anyone] }
    public var shareRoleOptions: [ShareRole] { [.view] }
    public var supportsSharePassword: Bool { true }
    public var shareOptionsNote: String {
        "Dropbox 免费账号只能创建永久的公开链接；设置密码和有效期需要 Plus / Essentials 等付费账号。同一个文件已有链接时会返回已有的链接。"
    }
    public var supportsShareManagement: Bool { true }

    public func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink {
        try await createShare(files, options: ShareOptions(expiry: expiry))
    }

    /// 每个文件一条链接（多个时一行一个）
    public func createShare(_ files: [ShareFile], options: ShareOptions) async throws -> DriveShareLink {
        guard !files.isEmpty else { throw CloudnError("请选择要分享的文件") }
        let settings = Self.shareSettings(options)
        let custom = options.expiry.days > 0 || !options.password.isEmpty
        var urls: [String] = []
        for file in files {
            let r = try await rpcResponse("sharing/create_shared_link_with_settings", ["path": file.fid, "settings": settings])
            if r.isSuccess {
                urls.append(r.json?["url"].string ?? "")
            } else if let existing = Self.existingLink(r.json) {
                var url = existing
                if url.isEmpty {
                    let links = try await rpc("sharing/list_shared_links", ["path": file.fid, "direct_only": true])
                    url = links["links"][0]["url"].string
                }
                guard !url.isEmpty else { throw CloudnError("Dropbox 没有返回分享链接") }
                if custom {
                    let modified = try await rpc("sharing/modify_shared_link_settings", ["url": url, "settings": settings])
                    url = modified["url"].string.nilIfBlank ?? url
                }
                urls.append(url)
            } else {
                throw Self.apiError(r.status, r.json, text: r.text)
            }
        }
        return DriveShareLink(url: urls.filter { !$0.isEmpty }.joined(separator: "\n"), pwd: options.password)
    }

    static func shareSettings(_ options: ShareOptions, now: Date = Date()) -> [String: Any] {
        var settings: [String: Any] = ["requested_visibility": options.password.isEmpty ? "public" : "password"]
        if !options.password.isEmpty { settings["link_password"] = options.password }
        if options.expiry.days > 0 {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            settings["expires"] = f.string(from: now.addingTimeInterval(TimeInterval(options.expiry.days) * 86400))
        }
        return settings
    }

    /// create_shared_link_with_settings 报 shared_link_already_exists：返回已有链接（错误里没带时为空串）；不是这个错误返回 nil
    static func existingLink(_ json: JSON?) -> String? {
        guard let json, json["error"][".tag"].string == "shared_link_already_exists" || json["error_summary"].string.hasPrefix("shared_link_already_exists") else {
            return nil
        }
        let info = json["error"]["shared_link_already_exists"]
        return info["metadata"]["url"].string.nilIfBlank ?? info["url"].string
    }

    public func existingShares(_ file: ShareFile) async throws -> [DriveShareInfo] {
        let json = try await rpc("sharing/list_shared_links", ["path": file.fid, "direct_only": true])
        return json["links"].array.compactMap(Self.parseShareInfo)
    }

    static func parseShareInfo(_ j: JSON) -> DriveShareInfo? {
        let url = j["url"].string
        guard !url.isEmpty else { return nil }
        let permissions = j["link_permissions"]
        let visibility = permissions["resolved_visibility"][".tag"].string.nilIfBlank ?? permissions["effective_audience"][".tag"].string
        let audience: String
        switch visibility {
        case "team_only", "team_and_password", "team": audience = "仅团队内的人"
        case "shared_folder_only", "no_one", "members": audience = "仅有权访问的人"
        default: audience = ShareAudience.anyone.label
        }
        let hasPassword = visibility == "password" || visibility == "team_and_password" || permissions["require_password"].bool
        let expires = j["expires"].string.isEmpty ? "" : ISO8601DateFormatter.listText(j["expires"].string)
        return DriveShareInfo(id: url, url: url, audience: audience, role: ShareRole.view.label, expires: expires, hasPassword: hasPassword)
    }

    public func revokeShare(_ file: ShareFile, id: String) async throws {
        try await rpc("sharing/revoke_shared_link", ["url": id])
    }
}

// MARK: - 上传

extension DropboxResolver: DriveUploader {
    /// 不超过一片的文件 /files/upload；更大的 upload_session start → append_v2 → finish
    public func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws {
        let size = FileChunks.size(of: file)
        let commit: [String: Any] = ["path": Self.join(folderId, name), "mode": "add", "autorename": true, "mute": false]
        let chunk = Self.uploadChunk
        func report(_ base: Int64) -> @Sendable (Int64) -> Void {
            { done in progress(.uploading, size > 0 ? Double(base + done) / Double(size) : 1) }
        }
        if size <= chunk {
            let r = try await contentUpload("files/upload", arg: commit, body: .file(file, offset: 0, length: size), progress: report(0))
            guard r.isSuccess else { throw Self.apiError(r.status, r.json, text: r.text) }
            progress(.finishing, 1)
            return
        }
        let start = try await contentUpload("upload_session/start", arg: ["close": false], body: .file(file, offset: 0, length: chunk), progress: report(0))
        guard start.isSuccess, let sessionId = start.json?["session_id"].string.nilIfBlank else {
            throw Self.apiError(start.status, start.json, text: start.text)
        }
        var offset = chunk
        var retries = 0
        while size - offset > chunk {
            let r = try await contentUpload("upload_session/append_v2", arg: ["cursor": ["session_id": sessionId, "offset": offset], "close": false],
                                            body: .file(file, offset: offset, length: chunk), progress: report(offset))
            if r.isSuccess {
                offset += chunk
                retries = 0
                continue
            }
            // 服务端实际收到的位置不同（上次请求超时但其实已收到）：从服务端给的位置接着传
            if let correct = Self.correctOffset(r.json), correct != offset, retries < 3 {
                offset = correct
                retries += 1
                continue
            }
            throw Self.apiError(r.status, r.json, text: r.text)
        }
        progress(.finishing, Double(offset) / Double(size))
        let finish = try await contentUpload("upload_session/finish", arg: ["cursor": ["session_id": sessionId, "offset": offset], "commit": commit],
                                             body: .file(file, offset: offset, length: size - offset), progress: report(offset))
        guard finish.isSuccess else { throw Self.apiError(finish.status, finish.json, text: finish.text) }
        progress(.finishing, 1)
    }

    /// 上传类接口：参数放 Dropbox-API-Arg 头，文件内容作请求体；401 时续期重试一次
    private func contentUpload(_ endpoint: String, arg: [String: Any], body: UploadBody, progress: @escaping @Sendable (Int64) -> Void) async throws -> HTTPResponse {
        guard var token = try await accessToken() else { throw SharePlatform.dropbox.loginRequired }
        let path = endpoint.hasPrefix("upload_session") ? "files/" + endpoint : endpoint
        for attempt in 0..<2 {
            let request = HTTPRequest(url: Self.content + "/" + path, method: "POST",
                                      headers: [("Authorization", "Bearer " + token), ("Dropbox-API-Arg", Self.apiArg(arg)),
                                                ("Content-Type", "application/octet-stream")])
            let r = try await client.upload(request, body: body, progress: progress)
            if r.status == 401, attempt == 0, let fresh = try await accessToken(rejecting: token), fresh != token {
                token = fresh
                continue
            }
            return r
        }
        throw Self.expired
    }

    /// append / finish 的 incorrect_offset 错误里带的正确偏移
    static func correctOffset(_ json: JSON?) -> Int64? {
        guard let json else { return nil }
        let candidates = [json["error"]["correct_offset"], json["error"]["lookup_failed"]["correct_offset"]]
        return candidates.first { !$0.isNull }.map(\.int64)
    }
}

// MARK: - 离线下载（save_url）

extension DropboxResolver: DriveOfflineDownloader {
    public var offlineSchemes: [String] { ["http"] }
    public var offlineNote: String {
        "Dropbox 只能离线下载 http(s) 直链（不支持磁力链接），单个文件最大 20GB；Dropbox 分享链接也可以直接粘贴。Dropbox 没有任务列表接口，这里只显示本次打开应用后添加的任务。"
    }

    public func addOfflineTask(_ url: String, to folderId: String) async throws -> String? {
        var source = url.trimmed
        guard source.lowercased().hasPrefix("http") else { throw CloudnError("Dropbox 只支持 http(s) 链接") }
        var name = Self.offlineName(source)
        if let link = Self.parseLink(source) {
            source = Self.directURL(link.url)
            name = link.isFolder ? "Dropbox 分享 \(Self.offlineName(link.url).prefix(8)).zip" : link.name.map(FileNames.sanitize) ?? Self.offlineName(link.url)
        }
        let json = try await rpc("files/save_url", ["path": Self.join(folderId, name), "url": source])
        let state: OfflineTaskState = json[".tag"].string == "complete" ? .done : .running
        let id = json["async_job_id"].string.nilIfBlank ?? "done-" + UUID().uuidString
        await jobs.add(OfflineTask(id: id, name: name, progress: nil, size: json["size"].int64, state: state, folderId: folderId))
        return name
    }

    public func offlineTasks() async throws -> [OfflineTask] {
        for task in await jobs.all() where !task.state.isFinished && !task.id.hasPrefix("done-") {
            guard let json = try? await rpc("files/save_url/check_job_status", ["async_job_id": task.id]) else { continue }
            let (state, size) = Self.jobState(json)
            await jobs.update(OfflineTask(id: task.id, name: task.name, progress: state == .done ? 1 : nil, size: size > 0 ? size : task.size,
                                          state: state, folderId: task.folderId))
        }
        return await jobs.all()
    }

    public func removeOfflineTasks(_ ids: [String]) async throws {
        await jobs.remove(ids)
    }

    /// check_job_status 的结果 → 任务状态与大小
    static func jobState(_ json: JSON) -> (OfflineTaskState, Int64) {
        switch json[".tag"].string {
        case "complete": return (.done, json["size"].int64)
        case "failed":
            let reason: String
            switch json["failed"][".tag"].string {
            case "download_failed": reason = "下载失败（源站无法访问）"
            case "invalid_url": reason = "链接无效"
            case "not_found": reason = "文件不存在"
            case "path": reason = "保存位置有误或已有同名文件"
            case "insufficient_space": reason = "Dropbox 空间不足"
            default: reason = json["failed"][".tag"].string.nilIfBlank ?? "失败"
            }
            return (.failed(reason), 0)
        default: return (.running, 0)
        }
    }

    /// 链接 → 保存的文件名（取路径最后一段）
    static func offlineName(_ url: String) -> String {
        let path = URL(string: url)?.path ?? ""
        let last = (path as NSString).lastPathComponent
        let decoded = (last == "/" ? "" : last).removingPercentEncoding ?? last
        let name = FileNames.sanitize(decoded)
        return name.isEmpty ? "download-\(Int(Date().timeIntervalSince1970))" : name
    }

    /// Dropbox 没有离线任务列表接口：只记住本次运行添加的任务
    actor OfflineJobs {
        private var tasks: [OfflineTask] = []
        func add(_ task: OfflineTask) { tasks.insert(task, at: 0) }
        func all() -> [OfflineTask] { tasks }
        func update(_ task: OfflineTask) {
            if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = task }
        }
        func remove(_ ids: [String]) { tasks.removeAll { ids.contains($0.id) } }
    }
}

public extension OAuthProvider {
    /// Dropbox 的 App Key（在 dropbox.com/developers 注册应用后填入）；为空时不提供授权登录。
    /// 应用需开启下面 scopes 里的权限，并把 redirectURI 加到应用的 Redirect URIs
    static let dropboxAppKey = "rasxxsb6j9q0s2y"

    static var dropbox: OAuthProvider? {
        guard !dropboxAppKey.isEmpty else { return nil }
        return OAuthProvider(name: "Dropbox", clientId: dropboxAppKey,
                             authorizeEndpoint: "https://www.dropbox.com/oauth2/authorize",
                             tokenEndpoint: "https://api.dropboxapi.com/oauth2/token",
                             redirectURI: "db-\(dropboxAppKey)://2/token",
                             scopes: ["account_info.read", "files.metadata.read", "files.metadata.write", "files.content.read",
                                      "files.content.write", "sharing.read", "sharing.write"],
                             extraAuthorizeParams: [("token_access_type", "offline")])
    }
}
