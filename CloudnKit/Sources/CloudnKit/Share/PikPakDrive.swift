// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// PikPak 我的网盘 / 转存 / 上传 / 离线下载。
// 参考 OpenList（AGPL-3.0）drivers/pikpak（files 列目录与翻页、files/{id} 取直链、files:batchMove / batchTrash、PATCH 重命名、
// drive/v1/about 容量、UPLOAD_TYPE_RESUMABLE + 阿里云 OSS 直传、UPLOAD_TYPE_URL 离线下载、drive/v1/tasks 任务列表 / 删除）
// 与 internal/offline_download/pikpak；share/restore、POST drive/v1/share 参考 Quan666/PikPakAPI（MIT）。
import Foundation

// MARK: - 我的网盘

extension PikPakResolver: DriveManager {
    public var driveRootId: String { "" }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        try await driveFiles(Self.driveParent(folderId), foldersOnly: false)
    }

    /// files/{id}?usage=FETCH：web_content_link，没有时用媒体链接
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹不能直接下载") }
        let id = try await identity()
        let url = api + "/drive/v1/files/\(file.fid)?_magic=2021&usage=FETCH&thumbnail_size=SIZE_LARGE"
        let detail = try await call("GET", url, identity: id)
        guard let link = Self.fileLink(detail) else { throw CloudnError("PikPak 未返回下载链接") }
        let size = detail["size"].int64
        return DownloadLink(fileName: file.name, url: link, size: size > 0 ? size : file.size, headers: ["User-Agent": Self.downloadUA])
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        let id = try await identity()
        _ = try await call("POST", api + "/drive/v1/files", body: Self.createFolderBody(name: name, parent: Self.driveParent(parentId)), identity: id)
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        let id = try await identity()
        _ = try await call("PATCH", api + "/drive/v1/files/\(file.fid)", body: .object([("name", .string(name))]), identity: id)
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        let id = try await identity()
        _ = try await call("POST", api + "/drive/v1/files:batchMove", body: Self.moveBody(ids: files.map(\.fid), to: Self.driveParent(folderId)),
                           identity: id)
        // 批量操作在服务端异步执行，稍等再让调用方刷新
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    /// files:batchTrash：移入回收站
    public func delete(_ files: [ShareFile]) async throws {
        guard !files.isEmpty else { return }
        let id = try await identity()
        _ = try await call("POST", api + "/drive/v1/files:batchTrash", body: Self.idsBody(files.map(\.fid)), identity: id)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    /// POST /drive/v1/share（公开链接，不设提取码）；expiration_days -1 = 永久
    public func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink {
        guard !files.isEmpty else { throw CloudnError("请选择要分享的文件") }
        try expiry.require(in: shareExpiryOptions)
        let id = try await identity()
        let data = try await call("POST", api + "/drive/v1/share",
                                  body: Self.shareBody(ids: files.map(\.fid), days: expiry.isForever ? -1 : expiry.days), identity: id)
        guard let link = Self.parseShareLink(data) else { throw CloudnError("PikPak 创建分享失败") }
        return link
    }

    public func quota() async -> DriveQuota? {
        guard let id = try? await identity(), let data = try? await call("GET", api + "/drive/v1/about", identity: id) else { return nil }
        return Self.parseQuota(data)
    }

    // MARK: 列目录

    /// drive/v1/files（parent_id 为空 = 根目录），next_page_token 翻页
    func driveFiles(_ parent: String, foldersOnly: Bool) async throws -> [ShareFile] {
        let id = try await identity()
        var all: [ShareFile] = []
        var pageToken = ""
        for _ in 0..<200 {
            let data = try await call("GET", Self.driveFilesURL(api, parent: parent, pageToken: pageToken, foldersOnly: foldersOnly), identity: id)
            all += data["files"].array.map { Self.parseFile($0, parent: parent) }
            pageToken = data["next_page_token"].string
            if pageToken.isEmpty { break }
        }
        return foldersOnly ? all.filter(\.isDirectory) : all
    }

    // MARK: 请求体 / 解析

    static func driveParent(_ folderId: String) -> String { folderId == "0" ? "" : folderId }

    static func driveFilesURL(_ api: String, parent: String, pageToken: String, foldersOnly: Bool = false) -> String {
        let filters = foldersOnly
            ? #"{"kind":{"eq":"drive#folder"},"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#
            : #"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#
        return api + "/drive/v1/files?parent_id=\(parent.formEncoded)&thumbnail_size=SIZE_LARGE&with_audit=true&limit=100" +
            "&page_token=\(pageToken.formEncoded)&filters=\(filters.formEncoded)"
    }

    static func createFolderBody(name: String, parent: String) -> OrderedJSON {
        .object([("kind", .string("drive#folder")), ("parent_id", .string(parent)), ("name", .string(name))])
    }

    static func moveBody(ids: [String], to parent: String) -> OrderedJSON {
        .object([("ids", .array(ids.map { .string($0) })), ("to", .object([("parent_id", .string(parent))]))])
    }

    static func idsBody(_ ids: [String]) -> OrderedJSON {
        .object([("ids", .array(ids.map { .string($0) }))])
    }

    static func shareBody(ids: [String], days: Int) -> OrderedJSON {
        .object([("file_ids", .array(ids.map { .string($0) })), ("share_to", .string("publiclink")),
                 ("expiration_days", .int(Int64(days))), ("pass_code_option", .string("NOT_REQUIRED"))])
    }

    static func parseShareLink(_ data: JSON) -> DriveShareLink? {
        guard let url = data.string("share_url", "share_text").nilIfBlank else { return nil }
        return DriveShareLink(url: url, pwd: data["pass_code"].string)
    }

    static func parseQuota(_ data: JSON) -> DriveQuota? {
        let q = data["quota"]
        guard q.isObject else { return nil }
        let total = q["limit"].int64
        let used = q["usage"].int64
        guard total > 0 || used > 0 else { return nil }
        return DriveQuota(used: used, total: total)
    }
}

// MARK: - 转存到我的网盘

extension PikPakResolver: ShareSaver {
    public var rootFolderId: String { "" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        try await driveFiles(Self.driveParent(parentId), foldersOnly: true)
    }

    /// share/restore：服务端异步转存，每次最多 100 项
    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        let id = try await identity()
        let passToken = await state.passTokens[session.shareId] ?? session.stoken
        for start in stride(from: 0, to: files.count, by: 100) {
            let ids = files[start..<min(start + 100, files.count)].map(\.fid)
            _ = try await call("POST", api + "/drive/v1/share/restore",
                               body: Self.restoreBody(shareId: session.shareId, passToken: passToken, ids: Array(ids),
                                                      to: Self.driveParent(folderId)), identity: id)
        }
    }

    /// 与迅雷同一套接口（Xbase）：parent_id + specify_parent_id 指定转存目录
    static func restoreBody(shareId: String, passToken: String, ids: [String], to parent: String) -> OrderedJSON {
        .object([("share_id", .string(shareId)), ("pass_code_token", .string(passToken)), ("file_ids", .array(ids.map { .string($0) })),
                 ("parent_id", .string(parent)), ("ancestor_ids", .array([])), ("specify_parent_id", .bool(true))])
    }
}

// MARK: - 离线下载

extension PikPakResolver: DriveOfflineDownloader {
    public var offlineSchemes: [String] { ["magnet:", "http", "ed2k:"] }
    public var offlineNote: String { "免费账号每天的离线次数与空间有限，超出需开通会员" }

    /// POST /drive/v1/files（upload_type UPLOAD_TYPE_URL）；存到根目录时交给服务端放进「My Pack」
    public func addOfflineTask(_ url: String, to folderId: String) async throws -> String? {
        let link = url.trimmed
        guard acceptsOffline(link) else { throw CloudnError("PikPak 只支持磁力链、http(s) 与 ed2k 链接") }
        let id = try await identity()
        let data = try await call("POST", api + "/drive/v1/files", body: Self.offlineBody(url: link, parent: Self.driveParent(folderId)), identity: id)
        return data["task"].string("name", "file_name").nilIfBlank ?? data["file"]["name"].string.nilIfBlank
    }

    public func offlineTasks() async throws -> [OfflineTask] {
        let id = try await identity()
        let data = try await call("GET", Self.offlineTasksURL(api), identity: id)
        return data["tasks"].array.compactMap(Self.parseOfflineTask)
    }

    /// DELETE /drive/v1/tasks?task_ids=a,b&delete_files=false（保留已下载的文件）
    public func removeOfflineTasks(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let id = try await identity()
        let url = api + "/drive/v1/tasks?task_ids=\(ids.joined(separator: ",").formEncoded)&delete_files=false"
        _ = try await call("DELETE", url, identity: id)
    }

    static func offlineBody(url: String, parent: String) -> OrderedJSON {
        .object([("kind", .string("drive#file")), ("name", .string("")), ("upload_type", .string("UPLOAD_TYPE_URL")),
                 ("url", .object([("url", .string(url))])), ("parent_id", .string(parent)),
                 ("folder_type", .string(parent.isEmpty ? "DOWNLOAD" : ""))])
    }

    static func offlineTasksURL(_ api: String) -> String {
        let filters = #"{"phase":{"in":"PHASE_TYPE_RUNNING,PHASE_TYPE_ERROR,PHASE_TYPE_COMPLETE,PHASE_TYPE_PENDING"}}"#
        return api + "/drive/v1/tasks?type=offline&thumbnail_size=SIZE_SMALL&limit=100&with=reference_resource" +
            "&filters=\(filters.formEncoded)"
    }

    static func parseOfflineTask(_ t: JSON) -> OfflineTask? {
        let taskId = t["id"].string
        guard !taskId.isEmpty else { return nil }
        let state: OfflineTaskState
        switch t["phase"].string {
        case "PHASE_TYPE_COMPLETE": state = .done
        case "PHASE_TYPE_RUNNING": state = .running
        case "PHASE_TYPE_ERROR": state = .failed(t["message"].string.nilIfBlank ?? "下载失败")
        default: state = .waiting
        }
        let progress = state == .done ? 1 : min(1, max(0, t["progress"].double / 100))
        let name = t.string("name", "file_name").nilIfBlank ?? t["reference_resource"]["name"].string.nilIfBlank ?? "离线任务"
        let size = t["file_size"].int64 > 0 ? t["file_size"].int64 : t["reference_resource"]["size"].int64
        return OfflineTask(id: taskId, name: name, progress: progress, size: size, state: state,
                           folderId: t["reference_resource"]["parent_id"].string.nilIfBlank)
    }
}

// MARK: - 上传到我的网盘

/// OpenList Put：算 GCID → POST drive/v1/files（UPLOAD_TYPE_RESUMABLE，同 GCID 已存在即秒传）→
/// 用 resumable.params 的 STS 临时凭证直传阿里云 OSS（≤10MB 单次 PUT，否则分片）
extension PikPakResolver: DriveUploader {
    static let ossUA = "aliyun-sdk-android/2.9.13(Linux/Android 14/M2004j7ac;UKQ1.231108.001)"
    static let singlePutLimit: Int64 = 10 << 20
    static let partSize: Int64 = 10 << 20

    public func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws {
        let id = try await identity()
        let size = FileChunks.size(of: file)
        var gcid = XunleiResolver.GCIDHasher(size: size)
        try FileChunks.scan(file, progress: progress.hashing(total: size)) { _, d in gcid.update(d) }
        let hash = Crypto.hex(gcid.finalize()).uppercased()

        let created = try await call("POST", api + "/drive/v1/files",
                                     body: Self.uploadBody(name: name, parent: Self.driveParent(folderId), size: size, gcid: hash), identity: id)
        // 没有 resumable：服务端已有同 GCID 的文件，秒传完成
        guard created["resumable"].isObject else { progress(.finishing, 1); return }
        guard let ticket = Self.parseUploadTicket(created) else { throw CloudnError("PikPak 未返回上传凭证，请稍后重试") }
        try await putObject(file, size: size, ticket: ticket, progress: progress)
        progress(.finishing, 1)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    static func uploadBody(name: String, parent: String, size: Int64, gcid: String) -> OrderedJSON {
        .object([("kind", .string("drive#file")), ("name", .string(name)), ("size", .int(size)), ("hash", .string(gcid)),
                 ("upload_type", .string("UPLOAD_TYPE_RESUMABLE")), ("objProvider", .object([("provider", .string("UPLOAD_TYPE_UNKNOWN"))])),
                 ("parent_id", .string(parent)), ("folder_type", .string("NORMAL"))])
    }

    struct UploadTicket: Equatable {
        let bucket: String
        /// 对象存储域名（不含 bucket 前缀）
        let endpoint: String
        let key: String
        let accessKeyId: String
        let accessKeySecret: String
        let securityToken: String

        var objectURL: String { "https://" + bucket + "." + endpoint + "/" + UploadUtil.encodePath(key) }
    }

    /// 安卓端返回的 endpoint 形如 vip-lixian-07.mypikpak.net，OpenList 统一改成 mypikpak.net（虚拟主机风格再拼 bucket）
    static func parseUploadTicket(_ json: JSON) -> UploadTicket? {
        let p = json["resumable"]["params"]
        let bucket = p["bucket"].string.trimmed
        var endpoint = XunleiResolver.objectEndpoint(p["endpoint"].string, bucket: bucket)
        if endpoint.hasSuffix("mypikpak.net") { endpoint = "mypikpak.net" }
        let ticket = UploadTicket(bucket: bucket, endpoint: endpoint, key: p["key"].string, accessKeyId: p["access_key_id"].string,
                                  accessKeySecret: p["access_key_secret"].string, securityToken: p["security_token"].string)
        guard !ticket.bucket.isEmpty, !ticket.endpoint.isEmpty, !ticket.key.isEmpty, !ticket.accessKeyId.isEmpty,
              !ticket.accessKeySecret.isEmpty else { return nil }
        return ticket
    }

    private func putObject(_ file: URL, size: Int64, ticket: UploadTicket, progress: UploadProgress) async throws {
        let signer = OSSSigner(accessKeyId: ticket.accessKeyId, accessKeySecret: ticket.accessKeySecret, securityToken: ticket.securityToken)
        let octet = "application/octet-stream"
        let total = Double(max(1, size))
        if size <= Self.singlePutLimit {
            _ = try await ossRequest(ticket, signer: signer, method: "PUT", query: [], contentType: octet, body: .file(file, offset: 0, length: size)) { done in
                progress(.uploading, Double(done) / total)
            }
            return
        }
        let initiated = try await ossRequest(ticket, signer: signer, method: "POST", query: [("uploads", "")], contentType: octet, body: .data(Data()))
        guard let uploadId = UploadUtil.xmlValue("UploadId", in: initiated.text)?.nilIfBlank else {
            throw CloudnError("PikPak 对象存储未返回分片上传 ID")
        }
        var etags: [String] = []
        var sent: Int64 = 0
        for (i, part) in UploadUtil.parts(size: size, partSize: Self.partSize).enumerated() {
            let base = sent
            let query: [(String, String)] = [("partNumber", String(i + 1)), ("uploadId", uploadId)]
            let r = try await ossRequest(ticket, signer: signer, method: "PUT", query: query, contentType: octet,
                                         body: .file(file, offset: part.offset, length: part.length)) { done in
                progress(.uploading, Double(base + done) / total)
            }
            guard let etag = r.header("ETag")?.nilIfBlank else { throw CloudnError("PikPak 分片上传未返回 ETag") }
            etags.append(etag)
            sent += part.length
        }
        progress(.finishing, 0)
        // 合并接口返回的可能是 JSON（OpenList 注释），只看 HTTP 状态
        let xml = UploadUtil.completeXML(etags)
        _ = try await ossRequest(ticket, signer: signer, method: "POST", query: [("uploadId", uploadId)], contentType: "application/xml",
                                 body: .data(Data(xml.utf8)))
    }

    /// OSS V1 签名请求；非 2xx 时重新签名重试，共 3 次
    private func ossRequest(_ ticket: UploadTicket, signer: OSSSigner, method: String, query: [(String, String)], contentType: String,
                            body: UploadBody, onSent: (@Sendable (Int64) -> Void)? = nil) async throws -> HTTPResponse {
        let q = XunleiResolver.objectQuery(query, oss: true)
        let url = ticket.objectURL + (q.isEmpty ? "" : "?" + q)
        var last: HTTPResponse?
        for _ in 0..<3 {
            var headers = signer.headers(method: method, bucket: ticket.bucket, key: ticket.key, query: query, contentType: contentType)
            headers.append(("User-Agent", Self.ossUA))
            let r = try await client.upload(HTTPRequest(url: url, method: method, headers: headers), body: body, progress: onSent)
            if r.isSuccess { return r }
            last = r
        }
        let code = last.flatMap { UploadUtil.xmlValue("Code", in: $0.text) } ?? ""
        throw CloudnError("PikPak 上传失败（HTTP \(last?.status ?? 0)\(code.isEmpty ? "" : " " + code)）")
    }
}
