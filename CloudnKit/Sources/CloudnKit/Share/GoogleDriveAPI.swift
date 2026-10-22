// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// Google 云端硬盘「我的网盘」：Google 账号 OAuth 登录后走 Drive API v3。
// 浏览、下载（Google 文档导出为 Office）、新建、重命名、移动、删除（进回收站）、容量、断点续传式上传；
// 分享可设「知道链接的任何人」查看 / 评论 / 编辑，并能列出 / 移除已有的访问权限；公开分享里的文件可以复制到自己的盘。
import Foundation

extension GoogleDriveResolver {
    static let api = "https://www.googleapis.com/drive/v3"
    static let uploadAPI = "https://www.googleapis.com/upload/drive/v3/files"
    static let folderMime = "application/vnd.google-apps.folder"
    static let fileFields = "id,name,mimeType,size,modifiedTime,parents,webViewLink"
    /// 续传上传的分片：必须是 256 KiB 的整数倍
    static let uploadChunk: Int64 = 256 * 1024 * 40

    // MARK: 登录态

    func driveToken(forceRefresh: Bool = false) async throws -> String? {
        guard let raw = await credentials.cookie(for: .gdrive)?.nilIfBlank, let cred = OAuthCredential.parse(raw) else { return nil }
        if !forceRefresh, cred.isFresh { return cred.accessToken }
        let renewed = try await OAuthProvider.google.refresh(cred, client: client)
        await credentials.updateCookie(renewed.serialized, replacing: raw, for: .gdrive)
        return renewed.accessToken
    }

    public func checkLogin() async -> Bool {
        (try? await apiRequest("GET", "/about?fields=user(emailAddress)")) != nil
    }

    /// 账号显示名（校验登录时用）
    public static func accountName(_ cred: OAuthCredential, client: HTTPClient = .shared) async -> String? {
        var token = cred.accessToken
        if !cred.isFresh {
            guard let renewed = try? await OAuthProvider.google.refresh(cred, client: client) else { return nil }
            token = renewed.accessToken
        }
        guard let r = try? await client.send(.get(api + "/about?fields=user(displayName,emailAddress)",
                                                  headers: [("Authorization", "Bearer " + token)])),
              r.isSuccess, let json = r.json else { return nil }
        return json["user"].string("displayName", "emailAddress").nilIfBlank ?? "Google 用户"
    }

    // MARK: 请求

    @discardableResult
    func apiRequest(_ method: String, _ path: String, body: Any? = nil, headers extra: [(String, String)] = []) async throws -> JSON {
        guard var access = try await driveToken() else { throw SharePlatform.gdrive.loginRequired }
        for attempt in 0..<2 {
            var headers: [(String, String)] = [("Authorization", "Bearer " + access), ("Accept", "application/json")] + extra
            var data: Data?
            if let body {
                headers.append(("Content-Type", "application/json"))
                data = JSON.serialize(body)
            }
            let r = try await client.send(HTTPRequest(url: path.hasPrefix("http") ? path : Self.api + path, method: method, headers: headers, body: data))
            if r.status == 401, attempt == 0, let fresh = try await driveToken(forceRefresh: true) {
                access = fresh
                continue
            }
            if r.isSuccess { return r.body.isEmpty ? JSON([String: Any]()) : (r.json ?? JSON([String: Any]())) }
            throw Self.apiError(r)
        }
        throw SharePlatform.gdrive.loginRequired
    }

    static func apiError(_ r: HTTPResponse) -> CloudnError {
        let error = r.json?["error"] ?? JSON(nil)
        let reason = error["errors"][0]["reason"].string
        let message = error["message"].string
        switch (r.status, reason) {
        case (401, _): return CloudnError("Google 云端硬盘登录已失效，请到「我的」页重新登录", code: 401)
        case (_, "storageQuotaExceeded"): return CloudnError("Google 云端硬盘空间不足")
        case (404, _): return CloudnError("文件不存在或没有权限访问")
        case (_, "exportSizeLimitExceeded"): return CloudnError("这个 Google 文档太大，无法导出（上限 10MB），请到网页版下载")
        case (_, "rateLimitExceeded"), (_, "userRateLimitExceeded"): return CloudnError("Google 请求太频繁，请稍后再试")
        default: return CloudnError("Google 云端硬盘：\(message.nilIfBlank ?? "请求失败（HTTP \(r.status)）")")
        }
    }

    static func folderRef(_ id: String) -> String { id.isEmpty ? "root" : id }

    /// 文件 → ShareFile：token 存 mimeType（文件夹 / Google 文档要区别处理）
    static func parseAPIFile(_ j: JSON, parent: String) -> ShareFile {
        let mime = j["mimeType"].string
        var name = j["name"].string
        if let kind = docKind(mime: mime) { name = exportName(name, kind: kind) }
        return ShareFile(fid: j["id"].string, name: name, size: j["size"].int64, isDirectory: mime == folderMime, parentId: parent,
                         token: mime, modified: ISO8601DateFormatter.listText(j["modifiedTime"].string))
    }

    /// Google 原生文档的 mimeType → 导出用的种类
    static func docKind(mime: String) -> String? {
        switch mime {
        case "application/vnd.google-apps.document": return "document"
        case "application/vnd.google-apps.spreadsheet": return "spreadsheets"
        case "application/vnd.google-apps.presentation": return "presentation"
        case "application/vnd.google-apps.drawing": return "drawings"
        default: return nil
        }
    }

    /// 导出成的 Office / 图片格式
    static func exportMime(_ kind: String) -> String? {
        switch kind {
        case "document": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "spreadsheets": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "presentation": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "drawings": return "image/png"
        default: return nil
        }
    }

    static func listQuery(_ folderId: String) -> String {
        "'\(folderRef(folderId))' in parents and trashed = false"
    }
}

// MARK: - 我的网盘

extension GoogleDriveResolver: DriveManager {
    public var driveRootId: String { "" }
    public var driveCapabilities: DriveCapabilities { .all }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var pageToken = ""
        for _ in 0..<200 {
            var components = URLComponents(string: Self.api + "/files")!
            components.queryItems = [URLQueryItem(name: "q", value: Self.listQuery(folderId)),
                                     URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fileFields))"),
                                     URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "orderBy", value: "folder,name"),
                                     URLQueryItem(name: "pageToken", value: pageToken.nilIfBlank)].filter { $0.value != nil }
            let json = try await apiRequest("GET", components.url!.absoluteString)
            all += json["files"].array.map { Self.parseAPIFile($0, parent: folderId) }
            pageToken = json["nextPageToken"].string
            if pageToken.isEmpty { break }
        }
        return all
    }

    /// 带 Authorization 头下载（访问令牌约 1 小时有效，超长下载中断后重试会重新取链）
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹无法直接下载") }
        guard let token = try await driveToken() else { throw SharePlatform.gdrive.loginRequired }
        let headers = ["Authorization": "Bearer " + token, "User-Agent": Self.ua]
        if let kind = Self.docKind(mime: file.token) {
            guard let mime = Self.exportMime(kind)?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                throw CloudnError("这种 Google 文档不能导出")
            }
            return DownloadLink(fileName: file.name, url: Self.api + "/files/\(file.fid)/export?mimeType=\(mime)", size: 0, headers: headers)
        }
        if file.token.hasPrefix("application/vnd.google-apps.") { throw CloudnError("这种 Google 文件（表单、站点等）不能下载") }
        return DownloadLink(fileName: file.name, url: Self.api + "/files/\(file.fid)?alt=media&acknowledgeAbuse=true", size: file.size, headers: headers)
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        try await apiRequest("POST", "/files?fields=id", body: ["name": name, "mimeType": Self.folderMime, "parents": [Self.folderRef(parentId)]])
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        try await apiRequest("PATCH", "/files/\(file.fid)?fields=id", body: ["name": name])
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        for file in files {
            let current = try await apiRequest("GET", "/files/\(file.fid)?fields=parents")
            let old = current["parents"].array.map(\.string).joined(separator: ",")
            var path = "/files/\(file.fid)?fields=id&addParents=\(Self.folderRef(folderId))"
            if !old.isEmpty { path += "&removeParents=\(old)" }
            try await apiRequest("PATCH", path, body: [String: Any]())
        }
    }

    /// 移到 Google 云端硬盘回收站
    public func delete(_ files: [ShareFile]) async throws {
        for file in files { try await apiRequest("PATCH", "/files/\(file.fid)?fields=id", body: ["trashed": true]) }
    }

    public func quota() async -> DriveQuota? {
        guard let json = try? await apiRequest("GET", "/about?fields=storageQuota") else { return nil }
        let q = json["storageQuota"]
        let total = q["limit"].int64
        guard total > 0 else { return nil }   // 没有上限（企业无限空间）时不显示
        return DriveQuota(used: q["usage"].int64, total: total)
    }

    // MARK: 分享

    public var shareExpiryOptions: [ShareExpiry] { [.forever] }
    public var shareAudienceOptions: [ShareAudience] { [.anyone] }
    public var shareRoleOptions: [ShareRole] { ShareRole.allCases }
    public var shareOptionsNote: String {
        "Google 的「知道链接的任何人」不能设密码和有效期。不想公开时，在下面的「已有的分享」里移除「知道链接的任何人」即可恢复为仅自己和被添加的人可见。"
    }
    public var supportsShareManagement: Bool { true }

    public func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink {
        try await createShare(files, options: ShareOptions(expiry: expiry))
    }

    /// 给每个文件加「知道链接的任何人」权限，返回各自的网页链接（多个时一行一个）
    public func createShare(_ files: [ShareFile], options: ShareOptions) async throws -> DriveShareLink {
        guard !files.isEmpty else { throw CloudnError("请选择要分享的文件") }
        var urls: [String] = []
        for file in files {
            try await apiRequest("POST", "/files/\(file.fid)/permissions?fields=id",
                                 body: ["type": "anyone", "role": options.role == .edit ? "writer" : "reader", "allowFileDiscovery": false])
            let info = try await apiRequest("GET", "/files/\(file.fid)?fields=webViewLink")
            urls.append(info["webViewLink"].string.nilIfBlank ?? "https://drive.google.com/open?id=\(file.fid)")
        }
        return DriveShareLink(url: urls.joined(separator: "\n"))
    }

    public func existingShares(_ file: ShareFile) async throws -> [DriveShareInfo] {
        let perms = try await apiRequest("GET", "/files/\(file.fid)/permissions?fields=permissions(id,type,role,emailAddress,domain,displayName,expirationTime)")
        let info = try await apiRequest("GET", "/files/\(file.fid)?fields=webViewLink")
        let url = info["webViewLink"].string
        return perms["permissions"].array.compactMap { Self.parseShareInfo($0, url: url) }
    }

    /// 文件所有者那一条不列出（不能移除）
    static func parseShareInfo(_ p: JSON, url: String) -> DriveShareInfo? {
        let role = p["role"].string
        guard role != "owner", !p["id"].string.isEmpty else { return nil }
        let audience: String
        switch p["type"].string {
        case "anyone": audience = ShareAudience.anyone.label
        case "domain": audience = "\(p["domain"].string) 内的人"
        default: audience = p["emailAddress"].string.nilIfBlank ?? p["displayName"].string.nilIfBlank ?? "指定的人"
        }
        let roleText: String
        switch role {
        case "writer", "fileOrganizer", "organizer": roleText = ShareRole.edit.label
        case "commenter": roleText = "可评论"
        default: roleText = ShareRole.view.label
        }
        let expires = p["expirationTime"].string.isEmpty ? "" : ISO8601DateFormatter.listText(p["expirationTime"].string)
        return DriveShareInfo(id: p["id"].string, url: url, audience: audience, role: roleText, expires: expires, hasPassword: false)
    }

    public func revokeShare(_ file: ShareFile, id: String) async throws {
        try await apiRequest("DELETE", "/files/\(file.fid)/permissions/\(id)")
    }
}

// MARK: - 转存公开分享里的文件

extension GoogleDriveResolver: ShareSaver {
    public var rootFolderId: String { "" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        var components = URLComponents(string: Self.api + "/files")!
        components.queryItems = [URLQueryItem(name: "q", value: Self.listQuery(parentId) + " and mimeType = '\(Self.folderMime)'"),
                                 URLQueryItem(name: "fields", value: "files(\(Self.fileFields))"), URLQueryItem(name: "pageSize", value: "1000"),
                                 URLQueryItem(name: "orderBy", value: "name")]
        let json = try await apiRequest("GET", components.url!.absoluteString)
        return json["files"].array.map { Self.parseAPIFile($0, parent: parentId) }
    }

    /// Drive API 不能复制文件夹：只复制选中的文件（文件夹请进去后选择文件）
    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        let targets = files.filter { !$0.isDirectory }
        guard !targets.isEmpty else { throw CloudnError("Google 云端硬盘不能复制文件夹，请进入文件夹后选择文件转存") }
        var headers: [(String, String)] = []
        for file in targets {
            if !session.stoken.isEmpty { headers = [("X-Goog-Drive-Resource-Keys", "\(file.fid)/\(session.stoken)")] }
            try await apiRequest("POST", "/files/\(file.fid)/copy?fields=id",
                                 body: ["parents": [Self.folderRef(folderId)], "name": file.name], headers: headers)
        }
    }
}

// MARK: - 上传

extension GoogleDriveResolver: DriveUploader {
    /// 续传上传：先建会话拿上传地址，再按 10MB 分片 PUT（中间片返回 308）
    public func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws {
        let size = FileChunks.size(of: file)
        guard let token = try await driveToken() else { throw SharePlatform.gdrive.loginRequired }
        let start = try await client.send(.postJSON(Self.uploadAPI + "?uploadType=resumable&fields=id",
                                                    ["name": name, "parents": [Self.folderRef(folderId)]],
                                                    headers: [("Authorization", "Bearer " + token), ("X-Upload-Content-Length", "\(size)")]))
        guard start.isSuccess, let session = start.header("Location"), !session.isEmpty else { throw Self.apiError(start) }
        var offset: Int64 = 0
        repeat {
            let length = min(Self.uploadChunk, size - offset)
            let range = length > 0 ? "bytes \(offset)-\(offset + length - 1)/\(size)" : "bytes */\(size)"
            let r = try await client.upload(HTTPRequest(url: session, method: "PUT", headers: [("Content-Range", range)]),
                                            body: .file(file, offset: offset, length: length)) { [offset] done in
                progress(.uploading, size > 0 ? Double(offset + done) / Double(size) : 1)
            }
            guard r.isSuccess || r.status == 308 else { throw Self.apiError(r) }
            offset += length
        } while offset < size
        progress(.finishing, 1)
    }
}
