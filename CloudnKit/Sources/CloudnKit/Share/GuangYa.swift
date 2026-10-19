// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 光鸭云盘分享解析：提取码换分享访问令牌 → 游标翻页列目录 → get_share_download_url 取直链；
// 分享者关闭免登录下载时，已登录则转存到个人盘临时目录再取个人盘直链。转存到我的网盘走 restore_share。
// 协议细节参考 YunX（AGPL-3.0）的 GuangYaApi / GuangYaResolveRepository；我的网盘管理参考 YunX（AGPL-3.0）的 GuangYaCloudViewModel。
import Foundation

public final class GuangYaResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .guangya }
    public var supportsGuestDownload: Bool { true }

    static let webSite = "https://www.guangyapan.com"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let pageSize = 100

    static let taskDelay: UInt64 = 750_000_000

    private let credentials: CredentialStore
    private let client: HTTPClient
    private let apiBase: String
    /// 业务接口必需的 did 设备头：匿名访问用进程内固定的随机设备，登录后用登录设备
    private let deviceId = GuangYaResolver.randomHex(32)

    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared, apiBase: String = "https://api.guangyapan.com") {
        self.credentials = credentials
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
            guard let cred = try? await credential() else {
                throw CloudnError("分享者未开放免登录下载，请先到「我的」页登录光鸭云盘（会临时转存后下载）", code: 207)
            }
            return try await transferAndLink(session, file: file, cred: cred)
        }
        let url = data.string("signedURL", "signedUrl", "downloadUrl", "download_url", "url", "cdnUrl")
        guard !url.isEmpty else { throw CloudnError("光鸭未返回有效下载地址，请确认下载权限") }
        let size = data["size"].int64 > 0 ? data["size"].int64 : file.size
        return DownloadLink(fileName: file.name, url: url, size: size, headers: ["User-Agent": Self.ua, "Referer": Self.webSite + "/"])
    }

    public func cleanup(token: String) async {
        guard let cred = try? await credential() else { return }
        _ = try? await call("file/delete_file", .object([("fileIds", .array([.string(token)]))]), fallback: "删除失败", cred: cred)
    }

    // MARK: 受限分享：临时转存 → 个人盘取链

    private func transferAndLink(_ session: ShareSession, file: ShareFile, cred: GuangYaCredential) async throws -> DownloadLink {
        let folder = try await createDir(parent: "", name: "Cloudn临时转存_\(UUID().uuidString.prefix(8))", cred: cred)
        do {
            try await restore(session, ids: [file.fid], to: folder, cred: cred)
            let target = try await pollCopied(folder: folder, source: file, cred: cred)
            let data = try await call("get_res_download_url", .object([("fileId", .string(target.fid))]), fallback: "获取下载地址失败", cred: cred)
            return try Self.personalLink(data, file: file, cleanupToken: folder)
        } catch {
            await cleanup(token: folder)
            throw error
        }
    }

    /// 转存是异步的：轮询临时目录直到同名文件出现
    private func pollCopied(folder: String, source: ShareFile, cred: GuangYaCredential) async throws -> ShareFile {
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: Self.taskDelay)
            let files = (try? await personalList(folder, cred: cred)) ?? []
            let matches = files.filter { !$0.isDirectory && $0.name == source.name }
            if matches.count > 1 { throw CloudnError("光鸭临时目录出现同名文件，无法确定下载目标") }
            if let target = matches.first { return target }
        }
        throw CloudnError("光鸭转存已提交，目标文件暂不可见，请稍后重试")
    }

    private func createDir(parent: String, name: String, cred: GuangYaCredential) async throws -> String {
        let data = try await call("file/create_dir", .object([("parentId", .string(parent)), ("dirName", .string(name)), ("failIfNameExist", .bool(true))]),
                                  fallback: "新建文件夹失败", cred: cred)
        let id = data.string("fileId", "id")
        guard !id.isEmpty, data["resType"].string != "1" else { throw CloudnError("光鸭未创建文件夹，请检查是否存在同名文件") }
        return id
    }

    /// restore_share：body 的 accessToken 是分享访问令牌，Authorization 用账号令牌
    private func restore(_ session: ShareSession, ids: [String], to parent: String, cred: GuangYaCredential) async throws {
        let data = try await call("restore_share", .object([("accessToken", .string(session.stoken)), ("fileIds", .array(ids.map { .string($0) })),
                                                            ("parentId", .string(parent))]), fallback: "转存失败", cred: cred)
        let task = data["taskId"].string
        if !task.isEmpty { try await waitTask(task, cred: cred) }
    }

    /// 任务轮询：status 2 且 detail.code 0 为成功；status 3 或 detail.code 非 0 为失败
    private func waitTask(_ id: String, cred: GuangYaCredential) async throws {
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: Self.taskDelay)
            let data = try await call("get_task_status", .object([("taskId", .string(id))]), fallback: "任务状态查询失败", cred: cred)
            let status = data["status"].int
            let detail = data["detail"]["code"].int
            if status == 2 && detail == 0 { return }
            if status == 3 || (status == 2 && detail != 0) {
                throw CloudnError(data["detail"]["msg"].string.nilIfBlank ?? "光鸭操作失败")
            }
        }
        throw CloudnError("光鸭操作仍在处理中，请稍后刷新确认结果")
    }

    /// 个人盘列目录：page 从 0 开始翻页
    func personalList(_ parentId: String, cred: GuangYaCredential) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var seen = Set<String>()
        for page in 0..<1000 {
            let data = try await call("file/get_file_list", .object([
                ("parentId", .string(parentId)), ("pageSize", .int(Int64(Self.pageSize))), ("orderBy", .int(0)),
                ("sortType", .int(0)), ("page", .int(Int64(page)))
            ]), fallback: "获取文件列表失败", cred: cred)
            let list = Self.listArray(data).map { Self.parseFile($0) }
            var added = 0
            for f in list where seen.insert(f.fid).inserted { all.append(f); added += 1 }
            let total = data["total"].int64
            if list.isEmpty || added == 0 || (total > 0 && Int64(all.count) >= total) || (total <= 0 && list.count < Self.pageSize) { break }
        }
        return all
    }

    // MARK: 账号

    /// 已保存的登录凭据；令牌临近过期时先用 refresh_token 续期并回写
    func credential() async throws -> GuangYaCredential {
        guard let raw = await credentials.cookie(for: .guangya)?.nilIfBlank, let cred = GuangYaCredential.parse(raw) else {
            throw SharePlatform.guangya.loginRequired
        }
        let now = Int64(Date().timeIntervalSince1970)
        guard cred.expiresAt > 0, cred.expiresAt - 300 < now, let renewed = await GuangYaLogin.refresh(cred, client: client) else { return cred }
        await credentials.updateCookie(renewed.serialized, replacing: raw, for: .guangya)
        return renewed
    }

    // MARK: 请求

    /// `prefix` 为接口路径前缀：业务接口 /userres/v1/，容量接口 /assets/v1/
    private func call(_ name: String, _ body: OrderedJSON, fallback: String, cred: GuangYaCredential? = nil,
                      prefix: String = "/userres/v1/") async throws -> JSON {
        var headers: [(String, String)] = [
            ("Accept", "application/json, text/plain, */*"), ("Content-Type", "application/json"), ("User-Agent", Self.ua),
            ("Origin", Self.webSite), ("Referer", Self.webSite + "/"), ("dt", "4"), ("did", cred?.deviceId ?? deviceId),
            ("traceparent", "00-\(Self.randomHex(32))-\(Self.randomHex(16))-01")
        ]
        if let cred { headers.append(("Authorization", "Bearer " + cred.accessToken)) }
        let r = try await client.send(HTTPRequest(url: apiBase + prefix + name, method: "POST", headers: headers, body: Data(body.text.utf8)))
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

extension GuangYaResolver: ShareSaver {
    public var rootFolderId: String { "" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        try await personalList(parentId, cred: credential()).filter(\.isDirectory)
    }

    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        try await restore(session, ids: files.map(\.fid), to: folderId, cred: credential())
    }
}

// MARK: 我的网盘管理

extension GuangYaResolver: DriveManager {
    public var driveRootId: String { "" }
    public var driveCapabilities: DriveCapabilities { .all }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        try await personalList(folderId, cred: credential())
    }

    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹无法直接下载") }
        let cred = try await credential()
        let data = try await call("get_res_download_url", .object([("fileId", .string(file.fid))]), fallback: "获取下载地址失败", cred: cred)
        return try Self.personalLink(data, file: file)
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        _ = try await createDir(parent: parentId, name: name, cred: credential())
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        try await runTask("file/rename", .object([("fileId", .string(file.fid)), ("newName", .string(name))]), fallback: "重命名失败")
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        try await runTask("file/move_file", .object([("fileIds", Self.idArray(files)), ("parentId", .string(folderId))]), fallback: "移动失败")
    }

    public func delete(_ files: [ShareFile]) async throws {
        guard !files.isEmpty else { return }
        try await runTask("file/delete_file", .object([("fileIds", Self.idArray(files))]), fallback: "删除失败")
    }

    /// 永久有效、无提取码的分享
    public func createShare(_ files: [ShareFile]) async throws -> DriveShareLink {
        guard !files.isEmpty else { throw CloudnError("请选择要分享的文件") }
        let cred = try await credential()
        let data = try await call("share_file", Self.shareBody(files, code: ""), fallback: "创建分享失败", cred: cred)
        guard let link = Self.parseShare(data, code: "") else { throw CloudnError("创建分享失败") }
        return link
    }

    public func quota() async -> DriveQuota? {
        guard let cred = try? await credential(),
              let data = try? await call("get_assets", .object([]), fallback: "获取容量信息失败", cred: cred, prefix: "/assets/v1/") else { return nil }
        return Self.parseQuota(data)
    }

    /// 改名 / 移动 / 删除：返回 taskId 时轮询到完成
    private func runTask(_ name: String, _ body: OrderedJSON, fallback: String) async throws {
        let cred = try await credential()
        let data = try await call(name, body, fallback: fallback, cred: cred)
        let task = data["taskId"].string
        if !task.isEmpty { try await waitTask(task, cred: cred) }
    }

    // MARK: 纯函数（便于单测）

    static func idArray(_ files: [ShareFile]) -> OrderedJSON {
        .array(files.map { .string($0.fid) })
    }

    /// share_file 请求体（字段顺序与网页端一致）；code 为空即无提取码
    static func shareBody(_ files: [ShareFile], code: String, days: Int = 0) -> OrderedJSON {
        let title = files.count == 1 ? files[0].name : "分享 \(files.count) 个文件"
        return .object([
            ("fileIds", idArray(files)), ("title", .string(title)), ("validateDuration", .int(Int64(days))),
            ("shareType", .int(code.trimmed.isEmpty ? 0 : 1)), ("code", .string(code)), ("autoFillCode", .bool(false)),
            ("trafficLimit", .string("0")), ("maxRestoreCount", .int(0)), ("downloadType", .int(1))
        ])
    }

    /// shareUrl 缺省时用 shareId 拼分享页地址
    static func parseShare(_ data: JSON, code: String) -> DriveShareLink? {
        let shareId = data.string("shareId", "id")
        var url = data["shareUrl"].string.trimmed
        if url.isEmpty {
            guard !shareId.isEmpty else { return nil }
            url = webSite + "/s/" + shareId
        }
        return DriveShareLink(url: url, pwd: data["code"].string.nilIfBlank ?? code)
    }

    /// get_assets：totalSpaceSize / usedSpaceSize（字节，可能是字符串）
    static func parseQuota(_ data: JSON) -> DriveQuota? {
        guard data.has("totalSpaceSize") else { return nil }
        let total = data["totalSpaceSize"].int64
        guard total > 0 else { return nil }
        return DriveQuota(used: max(0, data["usedSpaceSize"].int64), total: total)
    }

    static func personalLink(_ data: JSON, file: ShareFile, cleanupToken: String? = nil) throws -> DownloadLink {
        let url = data.string("signedURL", "signedUrl", "downloadUrl", "download_url", "url", "cdnUrl")
        guard !url.isEmpty else { throw CloudnError("光鸭未返回有效下载地址，请确认下载权限") }
        let size = data["size"].int64 > 0 ? data["size"].int64 : file.size
        return DownloadLink(fileName: file.name, url: url, size: size, headers: ["User-Agent": ua, "Referer": webSite + "/"],
                            cleanupToken: cleanupToken)
    }
}
