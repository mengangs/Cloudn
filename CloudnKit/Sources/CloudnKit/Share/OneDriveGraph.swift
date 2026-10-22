// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// OneDrive「我的网盘」：微软账号 OAuth 登录后走 Microsoft Graph（/me/drive）。
// 浏览、下载、新建、重命名、移动、删除、容量、上传（小文件直传，大文件分片会话），
// 分享可选谁能访问（任何人 / 组织内）、查看或编辑、有效期、密码，并能列出 / 取消已有链接。
import Foundation

extension OneDriveResolver {
    static let graph = "https://graph.microsoft.com/v1.0"
    static let graphFields = "id,name,size,folder,file,lastModifiedDateTime,parentReference,@microsoft.graph.downloadUrl"
    /// 小于这个大小直接 PUT 内容，否则走上传会话
    static let simpleUploadLimit: Int64 = 4 << 20
    /// 上传会话的分片：必须是 320 KiB 的整数倍
    static let uploadChunk: Int64 = 320 * 1024 * 32

    /// 当前账号的盘信息（按访问令牌缓存，切换账号自然失效）
    actor GraphState {
        private var token = ""
        private var info: DriveInfo?
        func get(_ access: String) -> DriveInfo? { access == token ? info : nil }
        func set(_ access: String, _ value: DriveInfo) { token = access; info = value }
    }

    struct DriveInfo: Sendable, Equatable {
        let driveId: String
        let rootId: String
        /// personal / business / documentLibrary
        let driveType: String
        var isPersonal: Bool { driveType == "personal" }
    }

    // MARK: 登录态

    /// 当前账号的访问令牌；没登录返回 nil。快过期时续期并回写
    func graphToken(forceRefresh: Bool = false) async throws -> String? {
        guard let raw = await credentials.cookie(for: .onedrive)?.nilIfBlank, let cred = OAuthCredential.parse(raw) else { return nil }
        if !forceRefresh, cred.isFresh { return cred.accessToken }
        let renewed = try await OAuthProvider.microsoft.refresh(cred, client: client)
        await credentials.updateCookie(renewed.serialized, replacing: raw, for: .onedrive)
        return renewed.accessToken
    }

    /// 登录态检测：走续期流程（新令牌会回写）
    public func checkLogin() async -> Bool {
        guard let token = try? await graphToken() else { return false }
        return (try? await graphRequest("GET", "/me?$select=id", token: token)) != nil
    }

    /// 账号显示名（校验登录时用）
    public static func accountName(_ cred: OAuthCredential, client: HTTPClient = .shared) async -> String? {
        var token = cred.accessToken
        if !cred.isFresh {
            guard let renewed = try? await OAuthProvider.microsoft.refresh(cred, client: client) else { return nil }
            token = renewed.accessToken
        }
        guard let r = try? await client.send(.get(graph + "/me?$select=displayName,userPrincipalName,mail",
                                                  headers: [("Authorization", "Bearer " + token)])),
              r.isSuccess, let json = r.json else { return nil }
        return json.string("displayName", "userPrincipalName", "mail").nilIfBlank ?? "OneDrive 用户"
    }

    /// 分享在匿名方式下打不开时，用自己的账号访问
    func graphShareContext() async throws -> Context {
        guard let token = try await graphToken() else { throw SharePlatform.onedrive.loginRequired }
        var context = Context(api: Self.graph, auth: [("Authorization", "Bearer " + token), ("Prefer", "redeemSharingLinkIfNecessary")],
                              expiresAt: Date().addingTimeInterval(45 * 60), root: nil)
        context.fields = Self.graphFields
        context.isGraph = true
        return context
    }

    // MARK: 请求

    @discardableResult
    func graphRequest(_ method: String, _ path: String, body: Any? = nil, token: String? = nil) async throws -> JSON {
        var access: String
        if let token { access = token } else {
            guard let t = try await graphToken() else { throw SharePlatform.onedrive.loginRequired }
            access = t
        }
        for attempt in 0..<2 {
            var headers: [(String, String)] = [("Authorization", "Bearer " + access), ("Accept", "application/json")]
            var data: Data?
            if let body {
                headers.append(("Content-Type", "application/json"))
                data = JSON.serialize(body)
            }
            let r = try await client.send(HTTPRequest(url: path.hasPrefix("http") ? path : Self.graph + path, method: method,
                                                      headers: headers, body: data))
            if r.status == 401, attempt == 0, let fresh = try await graphToken(forceRefresh: true) {
                access = fresh
                continue
            }
            if r.isSuccess { return r.body.isEmpty ? JSON([String: Any]()) : (r.json ?? JSON([String: Any]())) }
            throw Self.graphError(r)
        }
        throw SharePlatform.onedrive.loginRequired
    }

    static func graphError(_ r: HTTPResponse) -> CloudnError {
        let error = r.json?["error"] ?? JSON(nil)
        let code = error["code"].string
        let message = error["message"].string
        switch (r.status, code) {
        case (401, _): return CloudnError("OneDrive 登录已失效，请到「我的」页重新登录", code: 401)
        case (_, "nameAlreadyExists"): return CloudnError("已有同名的文件或文件夹")
        case (_, "itemNotFound"): return CloudnError("文件不存在或已被删除")
        case (_, "quotaLimitReached"): return CloudnError("OneDrive 空间不足")
        case (_, "accessDenied"): return CloudnError("OneDrive 拒绝了这个操作：\(message.nilIfBlank ?? "没有权限")")
        default: return CloudnError("OneDrive：\(message.nilIfBlank ?? "请求失败（HTTP \(r.status)）")")
        }
    }

    func driveInfo() async throws -> DriveInfo {
        guard let token = try await graphToken() else { throw SharePlatform.onedrive.loginRequired }
        if let cached = await graphState.get(token) { return cached }
        let drive = try await graphRequest("GET", "/me/drive?$select=id,driveType", token: token)
        let root = try await graphRequest("GET", "/me/drive/root?$select=id", token: token)
        let info = DriveInfo(driveId: drive["id"].string, rootId: root["id"].string, driveType: drive["driveType"].string)
        await graphState.set(token, info)
        return info
    }

    /// 某个文件夹的接口路径（空串为根目录）
    static func itemPath(_ id: String) -> String { id.isEmpty ? "/me/drive/root" : "/me/drive/items/\(id)" }

    static func parseGraphItem(_ j: JSON, parent: String) -> ShareFile {
        ShareFile(fid: j["id"].string, name: j["name"].string, size: j["size"].int64, isDirectory: j.has("folder"), parentId: parent,
                  token: j["parentReference"]["driveId"].string, modified: ISO8601DateFormatter.listText(j["lastModifiedDateTime"].string))
    }
}

// MARK: - 我的网盘

extension OneDriveResolver: DriveManager {
    public var driveRootId: String { "" }
    public var driveCapabilities: DriveCapabilities { .all }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var next: String? = Self.itemPath(folderId) + "/children?$top=200&$select=" + Self.graphFields
        var pages = 0
        while let url = next, pages < 200 {
            pages += 1
            let json = try await graphRequest("GET", url)
            all += json["value"].array.map { Self.parseGraphItem($0, parent: folderId) }
            next = json["@odata.nextLink"].string.nilIfBlank
        }
        return all
    }

    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹无法直接下载") }
        let json = try await graphRequest("GET", Self.itemPath(file.fid) + "?$select=id,size,@microsoft.graph.downloadUrl")
        let url = json["@microsoft.graph.downloadUrl"].string
        guard !url.isEmpty else { throw CloudnError("OneDrive 没有返回下载地址") }
        let size = json["size"].int64 > 0 ? json["size"].int64 : file.size
        return DownloadLink(fileName: file.name, url: url, size: size, headers: ["User-Agent": Self.ua])
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        try await graphRequest("POST", Self.itemPath(parentId) + "/children",
                               body: ["name": name, "folder": [String: Any](), "@microsoft.graph.conflictBehavior": "fail"])
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        try await graphRequest("PATCH", Self.itemPath(file.fid), body: ["name": name])
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        let target = folderId.isEmpty ? try await driveInfo().rootId : folderId
        for file in files {
            try await graphRequest("PATCH", Self.itemPath(file.fid), body: ["parentReference": ["id": target]])
        }
    }

    /// 删除进 OneDrive 回收站
    public func delete(_ files: [ShareFile]) async throws {
        for file in files { try await graphRequest("DELETE", Self.itemPath(file.fid)) }
    }

    public func quota() async -> DriveQuota? {
        guard let json = try? await graphRequest("GET", "/me/drive?$select=quota") else { return nil }
        let total = json["quota"]["total"].int64
        guard total > 0 else { return nil }
        return DriveQuota(used: json["quota"]["used"].int64, total: total)
    }

    // MARK: 分享

    public var shareExpiryOptions: [ShareExpiry] { ShareExpiry.standard }
    public var shareAudienceOptions: [ShareAudience] { ShareAudience.allCases }
    public var shareRoleOptions: [ShareRole] { ShareRole.allCases }
    public var supportsSharePassword: Bool { true }
    public var shareOptionsNote: String {
        "「仅组织内的人」只适用于工作或学校账号。个人版设有效期、密码需要 Microsoft 365 订阅，没有订阅时 OneDrive 会拒绝。"
    }
    public var supportsShareManagement: Bool { true }

    public func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink {
        try await createShare(files, options: ShareOptions(expiry: expiry))
    }

    /// 每个文件各建一个链接；多个文件时一行一个
    public func createShare(_ files: [ShareFile], options: ShareOptions) async throws -> DriveShareLink {
        guard !files.isEmpty else { throw CloudnError("请选择要分享的文件") }
        let info = try await driveInfo()
        if options.audience == .organization, info.isPersonal { throw CloudnError("个人版 OneDrive 没有「组织」，请选择「知道链接的任何人」") }
        var urls: [String] = []
        for file in files {
            let json = try await graphRequest("POST", Self.itemPath(file.fid) + "/createLink", body: Self.linkBody(options, now: Date()))
            let url = json["link"]["webUrl"].string
            guard !url.isEmpty else { throw CloudnError("OneDrive 创建分享失败") }
            urls.append(url)
        }
        return DriveShareLink(url: urls.joined(separator: "\n"), pwd: options.password)
    }

    static func linkBody(_ options: ShareOptions, now: Date) -> [String: Any] {
        var body: [String: Any] = ["type": options.role == .edit ? "edit" : "view",
                                   "scope": options.audience == .organization ? "organization" : "anonymous"]
        if !options.password.isEmpty { body["password"] = options.password }
        if !options.expiry.isForever {
            let f = ISO8601DateFormatter()
            body["expirationDateTime"] = f.string(from: now.addingTimeInterval(TimeInterval(options.expiry.days) * 86400))
        }
        return body
    }

    public func existingShares(_ file: ShareFile) async throws -> [DriveShareInfo] {
        let json = try await graphRequest("GET", Self.itemPath(file.fid) + "/permissions")
        return json["value"].array.compactMap(Self.parseShareInfo)
    }

    static func parseShareInfo(_ p: JSON) -> DriveShareInfo? {
        let link = p["link"]
        let url = link["webUrl"].string
        guard !url.isEmpty, !p["id"].string.isEmpty else { return nil }
        let audience: String
        switch link["scope"].string {
        case "anonymous": audience = ShareAudience.anyone.label
        case "organization": audience = ShareAudience.organization.label
        default: audience = "指定的人"
        }
        let role = link["type"].string == "edit" || p["roles"].array.contains { $0.string == "write" } ? ShareRole.edit.label : ShareRole.view.label
        let expires = p["expirationDateTime"].string.isEmpty ? "" : ISO8601DateFormatter.listText(p["expirationDateTime"].string)
        return DriveShareInfo(id: p["id"].string, url: url, audience: audience, role: role, expires: expires, hasPassword: p["hasPassword"].bool)
    }

    public func revokeShare(_ file: ShareFile, id: String) async throws {
        try await graphRequest("DELETE", Self.itemPath(file.fid) + "/permissions/\(id)")
    }
}

// MARK: - 上传

extension OneDriveResolver: DriveUploader {
    public var uploadSizeLimit: Int64? { 250 << 30 }

    public func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws {
        let size = FileChunks.size(of: file)
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? name
        let base = Self.itemPath(folderId) + ":/\(encoded):"
        guard let token = try await graphToken() else { throw SharePlatform.onedrive.loginRequired }
        if size <= Self.simpleUploadLimit {
            let r = try await client.upload(HTTPRequest(url: Self.graph + base + "/content?@microsoft.graph.conflictBehavior=rename", method: "PUT",
                                                        headers: [("Authorization", "Bearer " + token)]),
                                            body: .file(file, offset: 0, length: size)) { done in
                progress(.uploading, size > 0 ? Double(done) / Double(size) : 1)
            }
            guard r.isSuccess else { throw Self.graphError(r) }
            progress(.finishing, 1)
            return
        }
        let session = try await graphRequest("POST", base + "/createUploadSession",
                                             body: ["item": ["@microsoft.graph.conflictBehavior": "rename"]], token: token)
        let uploadURL = session["uploadUrl"].string
        guard !uploadURL.isEmpty else { throw CloudnError("OneDrive 创建上传会话失败") }
        var offset: Int64 = 0
        while offset < size {
            let length = min(Self.uploadChunk, size - offset)
            // 上传会话地址自带授权，不能再带 Authorization
            let r = try await client.upload(HTTPRequest(url: uploadURL, method: "PUT",
                                                        headers: [("Content-Range", "bytes \(offset)-\(offset + length - 1)/\(size)")]),
                                            body: .file(file, offset: offset, length: length)) { [offset] done in
                progress(.uploading, Double(offset + done) / Double(size))
            }
            guard r.isSuccess else {
                _ = try? await client.send(HTTPRequest(url: uploadURL, method: "DELETE"))
                throw Self.graphError(r)
            }
            offset += length
        }
        progress(.finishing, 1)
    }
}
