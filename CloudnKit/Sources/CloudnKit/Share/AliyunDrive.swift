// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 阿里云盘「我的网盘」：资源库 / 备份盘浏览、下载、新建、重命名、移动、删除（进回收站）、创建分享、容量、上传（秒传）与转存分享。
// 个人盘接口要求设备会话：设备 id = sha256(用户 id)，以它为 secp256k1 私钥对「appId:设备 id:用户 id:0」签名放进 X-Signature，
// 服务端提示设备会话无效时用公钥 create_session 后重试。协议细节参考 OpenList（AGPL-3.0）的 aliyundrive 驱动。
import Foundation

extension AliyunResolver {
    static let signAppId = "5dde4e1bdf9e4966b387ba58f4b3fdc3"
    static let driveCanary = "client=Android,app=adrive,version=v4.1.0"
    /// 上传分片大小；超过 10000 片时按文件大小放大
    static let partSize: Int64 = 10 << 20

    /// 当前账号的个人盘信息与设备签名
    struct DriveAccount: Equatable, Sendable {
        let userId: String
        /// 备份盘（default_drive_id）
        let backupDrive: String
        /// 资源库；老账号没有
        let resourceDrive: String
        let deviceId: String
        let signature: String
        let publicKey: String
        /// 相册；拿不到为空
        var albumDrive = ""

        /// 根目录顶部的系统文件夹（与阿里云盘 App「文件」页一致）：有资源库时备份盘作为「备份文件」，再加「相册」
        var systemFolders: [(id: String, name: String)] {
            var out: [(String, String)] = []
            if !resourceDrive.isEmpty, !backupDrive.isEmpty, backupDrive != resourceDrive { out.append((backupDrive, "备份文件")) }
            if !albumDrive.isEmpty, albumDrive != defaultDrive { out.append((albumDrive, "相册")) }
            return out
        }

        /// 转存、上传到「根目录」时落到哪个盘
        var defaultDrive: String { resourceDrive.nilIfBlank ?? backupDrive }
    }

    /// 设备签名：与 OpenList 相同，设备 id 与签名由用户 id 确定，不需要另外保存
    static func deviceSignature(userId: String) -> (deviceId: String, signature: String, publicKey: String)? {
        let deviceId = Crypto.hex(Crypto.sha256(Data(userId.utf8)))
        guard let priv = Crypto.bytes(hex: deviceId), let pub = Secp256k1.publicKey(priv) else { return nil }
        let message = "\(signAppId):\(deviceId):\(userId):0"
        guard let sig = Secp256k1.sign(hash: Crypto.sha256(Data(message.utf8)), priv: priv) else { return nil }
        return (deviceId, Crypto.hex(sig), Crypto.hex(pub))
    }

    // MARK: 复合 id：<盘 id>:<文件 id>

    /// 「我的网盘」里的 id 带上所在的盘；根目录为空串
    static func compose(drive: String, file: String) -> String { "\(drive):\(file)" }

    static func split(_ id: String) -> (drive: String, file: String)? {
        guard let i = id.firstIndex(of: ":") else { return nil }
        let drive = String(id[..<i]), file = String(id[id.index(after: i)...])
        return drive.isEmpty || file.isEmpty ? nil : (drive, file)
    }

    /// 目标文件夹：根目录（未选具体盘）落到资源库根目录
    func target(_ folderId: String, account: DriveAccount) -> (drive: String, file: String) {
        Self.split(folderId) ?? (account.defaultDrive, "root")
    }

    static func parseDriveFile(_ j: JSON, drive: String, parent: String) -> ShareFile {
        let driveId = j["drive_id"].string.nilIfBlank ?? drive
        return ShareFile(fid: compose(drive: driveId, file: j["file_id"].string), name: j["name"].string, size: j["size"].int64,
                         isDirectory: j["type"].string == "folder", parentId: parent, token: driveId,
                         modified: ISO8601DateFormatter.listText(j["updated_at"].string))
    }

    // MARK: 账号与请求

    func driveAccount() async throws -> DriveAccount {
        guard let access = try await accessToken() else { throw SharePlatform.aliyun.loginRequired }
        if let cached = await driveCache.get(access) { return cached }
        let json = try await userInfo(access: access)
        let userId = json["user_id"].string
        guard !userId.isEmpty, let sig = await driveCache.signature(userId) else { throw CloudnError("阿里云盘账号信息获取失败") }
        var account = DriveAccount(userId: userId, backupDrive: json.string("backup_drive_id", "default_drive_id"),
                                   resourceDrive: json["resource_drive_id"].string, deviceId: sig.deviceId,
                                   signature: sig.signature, publicKey: sig.publicKey)
        if let album = try? await rawDriveCall("/adrive/v1/user/albums_info", [String: Any](), access: access, account: account) {
            account.albumDrive = album["data"].string("driveId", "drive_id")
        }
        Log.info("阿里云盘：资源库 \(account.resourceDrive.isEmpty ? "无" : account.resourceDrive)，备份盘 \(account.backupDrive)，相册 \(account.albumDrive.isEmpty ? "无" : account.albumDrive)")
        await driveCache.set(access, account)
        return account
    }

    /// 用户信息：资源库 / 备份盘的 id 只在用户服务（user.alipan.com）的返回里有，api 域名下的老接口只给 default_drive_id
    private func userInfo(access: String) async throws -> JSON {
        var fallback: JSON?
        for host in ["https://user.alipan.com", "https://user.aliyundrive.com", Self.api] {
            guard let json = try? await rawDriveCall("/v2/user/get", [String: Any](), access: access, account: nil, host: host),
                  !json["user_id"].string.isEmpty else { continue }
            if !json["resource_drive_id"].string.isEmpty { return json }
            if fallback == nil { fallback = json }
        }
        guard let fallback else { throw CloudnError("阿里云盘账号信息获取失败，请到「我的」页重新登录") }
        return fallback
    }

    /// 个人盘接口：设备会话失效时建会话重试一次，访问令牌失效时续期重试一次
    func driveCall(_ path: String, _ body: [String: Any], host: String = AliyunResolver.api, shareToken: String? = nil) async throws -> JSON {
        let account = try await driveAccount()
        guard let access = try await accessToken() else { throw SharePlatform.aliyun.loginRequired }
        do {
            return try await rawDriveCall(path, body, access: access, account: account, host: host, shareToken: shareToken)
        } catch let e as CloudnError where e.code == Self.deviceSessionInvalid {
            try await createSession(account, access: access)
            return try await rawDriveCall(path, body, access: access, account: account, host: host, shareToken: shareToken)
        } catch let e as CloudnError where e.code == Self.accessExpired {
            guard let fresh = try await accessToken(rejecting: access) else { throw SharePlatform.aliyun.loginRequired }
            return try await rawDriveCall(path, body, access: fresh, account: account, host: host, shareToken: shareToken)
        }
    }

    static let deviceSessionInvalid = 4013

    private func createSession(_ account: DriveAccount, access: String) async throws {
        guard let raw = await credentials.cookie(for: .aliyun), let cred = AliyunCredential.parse(raw) else { throw SharePlatform.aliyun.loginRequired }
        let body: [String: Any] = ["deviceName": "Cloudn", "modelName": "iPhone", "nonce": 0, "pubKey": account.publicKey,
                                   "refreshToken": cred.refreshToken]
        let json = try await rawDriveCall("/users/v1/users/device/create_session", body, access: access, account: account)
        if json.has("success"), !json["success"].bool {
            throw CloudnError("阿里云盘设备会话创建失败：\(json["errorMessage"].string.nilIfBlank ?? json["message"].string)")
        }
    }

    private func rawDriveCall(_ path: String, _ body: [String: Any], access: String, account: DriveAccount?,
                              host: String = AliyunResolver.api, shareToken: String? = nil) async throws -> JSON {
        var headers: [(String, String)] = [("User-Agent", Self.ua), ("Authorization", "Bearer " + access), ("Origin", Self.webSite),
                                           ("Referer", Self.webSite + "/"), ("X-Canary", Self.driveCanary),
                                           ("x-request-id", UUID().uuidString.lowercased())]
        if let account { headers += [("X-Device-Id", account.deviceId), ("X-Signature", account.signature)] }
        if let shareToken { headers.append(("x-share-token", shareToken)) }
        let r = try await client.send(.postJSON(host + path, body, headers: headers))
        // 删除 / 改名等成功时可能是 204 空响应
        if r.isSuccess && r.body.isEmpty { return JSON([String: Any]()) }
        guard let json = r.json else { throw CloudnError("阿里云盘响应解析失败（HTTP \(r.status)）") }
        let code = json["code"].string
        if r.isSuccess && code.isEmpty { return json }
        if ["DeviceSessionSignatureInvalid", "UserDeviceOffline", "UserDeviceIllegality"].contains(code) {
            throw CloudnError("阿里云盘设备会话已失效", code: Self.deviceSessionInvalid)
        }
        if code == "PreHashMatched" { return json }
        throw Self.error(json, status: r.status, fallback: "请求失败")
    }
}

// MARK: - 转存到我的网盘

extension AliyunResolver: ShareSaver {
    public var rootFolderId: String { "" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        try await listDrive(parentId).filter(\.isDirectory)
    }

    /// 分享里的文件逐个 /file/copy 到目标文件夹（批量接口一次最多 100 个）
    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        let account = try await driveAccount()
        let (drive, parent) = target(folderId, account: account)
        let shareToken = await tokens.share(session.shareId) ?? session.stoken
        for chunk in stride(from: 0, to: files.count, by: 100).map({ Array(files[$0..<min($0 + 100, files.count)]) }) {
            let requests: [[String: Any]] = chunk.enumerated().map { i, f in
                ["body": ["file_id": f.fid, "share_id": session.shareId, "auto_rename": true, "to_parent_file_id": parent, "to_drive_id": drive],
                 "headers": ["Content-Type": "application/json"], "id": "\(i)", "method": "POST", "url": "/file/copy"]
            }
            let json = try await driveCall("/adrive/v4/batch", ["requests": requests, "resource": "file"], shareToken: shareToken)
            try Self.checkBatch(json, action: "转存")
        }
    }

    /// 批量接口：每项各自有 status，任何一项 ≥ 400 都算失败
    static func checkBatch(_ json: JSON, action: String) throws {
        let failed = json["responses"].array.filter { $0["status"].int >= 400 || $0["status"].int == 0 }
        guard let first = failed.first else { return }
        let message = first["body"]["message"].string.nilIfBlank ?? first["body"]["code"].string
        throw CloudnError("阿里云盘\(action)失败\(failed.count > 1 ? "（\(failed.count) 项）" : "")\(message.isEmpty ? "" : "：\(message)")")
    }
}

// MARK: - 我的网盘

extension AliyunResolver: DriveManager {
    public var driveRootId: String { "" }
    public var driveCapabilities: DriveCapabilities { .all }
    public var shareExpiryOptions: [ShareExpiry] { ShareExpiry.standard }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        let account = try await driveAccount()
        guard let (drive, file) = Self.split(folderId) else {
            // 根目录：资源库（老账号为备份盘）的内容，顶部放「备份文件」「相册」两个系统文件夹
            let system = account.systemFolders.map {
                ShareFile(fid: Self.compose(drive: $0.id, file: "root"), name: $0.name, size: 0, isDirectory: true, token: $0.id)
            }
            return system + (try await list(drive: account.defaultDrive, file: "root", parent: ""))
        }
        return try await list(drive: drive, file: file, parent: folderId)
    }

    private func list(drive: String, file: String, parent folderId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var marker = ""
        for _ in 0..<500 {
            let body: [String: Any] = ["drive_id": drive, "parent_file_id": file, "limit": 200, "marker": marker, "fields": "*",
                                       "order_by": "name", "order_direction": "ASC"]
            let json = try await driveCall("/adrive/v3/file/list", body)
            all += json["items"].array.map { Self.parseDriveFile($0, drive: drive, parent: folderId) }
            marker = json["next_marker"].string
            if marker.isEmpty { break }
        }
        return all
    }

    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory, let (drive, id) = Self.split(file.fid) else { throw CloudnError("文件夹无法直接下载") }
        let json = try await driveCall("/v2/file/get_download_url", ["drive_id": drive, "file_id": id, "expire_sec": 14400])
        let url = json.string("url", "download_url")
        guard !url.isEmpty else { throw CloudnError("阿里云盘未返回下载地址") }
        let size = json["size"].int64 > 0 ? json["size"].int64 : file.size
        return DownloadLink(fileName: file.name, url: url, size: size, headers: ["User-Agent": Self.ua, "Referer": Self.webSite + "/"])
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        let account = try await driveAccount()
        let (drive, parent) = target(parentId, account: account)
        _ = try await driveCall("/adrive/v2/file/createWithFolders",
                                ["check_name_mode": "refuse", "drive_id": drive, "name": name, "parent_file_id": parent, "type": "folder"])
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        guard let (drive, id) = Self.split(file.fid), id != "root" else { throw CloudnError("资源库和备份盘不能重命名") }
        _ = try await driveCall("/v3/file/update", ["check_name_mode": "refuse", "drive_id": drive, "file_id": id, "name": name])
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        let account = try await driveAccount()
        let (drive, parent) = target(folderId, account: account)
        try await batch(files, url: "/file/move", action: "移动") { id, fromDrive in
            ["drive_id": fromDrive, "file_id": id, "to_drive_id": drive, "to_parent_file_id": parent]
        }
    }

    /// 移到回收站（与网页版一致，可在阿里云盘里恢复）
    public func delete(_ files: [ShareFile]) async throws {
        try await batch(files, url: "/recyclebin/trash", action: "删除") { id, drive in ["drive_id": drive, "file_id": id] }
    }

    private func batch(_ files: [ShareFile], url: String, action: String, body: (String, String) -> [String: Any]) async throws {
        let items = files.compactMap { Self.split($0.fid) }
        guard !items.contains(where: { $0.file == "root" }) else { throw CloudnError("资源库和备份盘本身不能\(action)") }
        guard !items.isEmpty else { return }
        for start in stride(from: 0, to: items.count, by: 100) {
            let chunk = items[start..<min(start + 100, items.count)]
            let requests: [[String: Any]] = chunk.enumerated().map { i, item in
                ["body": body(item.file, item.drive), "headers": ["Content-Type": "application/json"], "id": "\(i)", "method": "POST", "url": url]
            }
            let json = try await driveCall("/v3/batch", ["requests": requests, "resource": "file"])
            try Self.checkBatch(json, action: action)
        }
    }

    /// 不带提取码的分享；有效期为 UTC 时间点，空串为永久。同一个分享只能包含同一个盘里的文件
    public func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink {
        let items = files.compactMap { Self.split($0.fid) }
        guard let drive = items.first?.drive else { throw CloudnError("请选择要分享的文件") }
        guard items.allSatisfy({ $0.drive == drive }) else { throw CloudnError("资源库和备份盘里的文件不能放在同一个分享里") }
        try expiry.require(in: shareExpiryOptions)
        let body: [String: Any] = ["drive_id": drive, "file_id_list": items.map(\.file), "share_pwd": "",
                                   "expiration": Self.expiration(expiry, now: Date()), "sync_to_homepage": false]
        let json = try await driveCall("/adrive/v2/share_link/create", body)
        let url = json.string("share_url", "full_share_url")
        guard !url.isEmpty else { throw CloudnError("阿里云盘创建分享失败") }
        return DriveShareLink(url: url, pwd: json["share_pwd"].string)
    }

    static func expiration(_ expiry: ShareExpiry, now: Date) -> String {
        guard !expiry.isForever else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: now.addingTimeInterval(TimeInterval(expiry.days) * 86400))
    }

    public func quota() async -> DriveQuota? {
        guard let json = try? await driveCall("/adrive/v1/user/driveCapacityDetails", [String: Any]()) else { return nil }
        let total = json["drive_total_size"].int64
        guard total > 0 else { return nil }
        return DriveQuota(used: json["drive_used_size"].int64, total: total)
    }
}

// MARK: - 上传

extension AliyunResolver: DriveUploader {
    /// 先用前 1KB 的 SHA1 试探；命中（PreHashMatched）再算整文件 SHA1 与 proof_code 走秒传；否则按 upload_url 逐片 PUT，最后 complete
    public func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws {
        let account = try await driveAccount()
        let (drive, parent) = target(folderId, account: account)
        let size = FileChunks.size(of: file)
        let partSize = Self.uploadPartSize(size)
        let parts = Self.partNumbers(size: size, partSize: partSize)
        var body: [String: Any] = ["check_name_mode": "auto_rename", "drive_id": drive, "name": name, "parent_file_id": parent,
                                   "part_info_list": parts.map { ["part_number": $0] }, "size": size, "type": "file"]
        let head = try FileChunks.read(file, offset: 0, length: Int(min(1024, size)))
        body["pre_hash"] = Crypto.hex(SHA1Hasher.digest(head))
        var created = try await driveCall("/adrive/v2/file/createWithFolders", body)

        if created["code"].string == "PreHashMatched" {
            var sha1 = SHA1Hasher()
            try FileChunks.scan(file, progress: progress.hashing(total: size)) { _, d in sha1.update(d) }
            guard let access = try await accessToken() else { throw SharePlatform.aliyun.loginRequired }
            body["pre_hash"] = nil
            body["content_hash"] = Crypto.hex(sha1.finalize())
            body["content_hash_name"] = "sha1"
            body["proof_version"] = "v1"
            body["proof_code"] = try Self.proofCode(file, size: size, accessToken: access)
            created = try await driveCall("/adrive/v2/file/createWithFolders", body)
            if created["rapid_upload"].bool {
                progress(.finishing, 1)
                return
            }
        }
        let fileId = created["file_id"].string, uploadId = created["upload_id"].string
        guard !fileId.isEmpty else { throw CloudnError("阿里云盘创建上传任务失败") }
        if created["rapid_upload"].bool || created["exist"].bool { progress(.finishing, 1); return }
        var urls: [Int: String] = [:]
        for p in created["part_info_list"].array { urls[p["part_number"].int] = p["upload_url"].string }

        var sent: Int64 = 0
        for number in parts {
            let offset = Int64(number - 1) * partSize
            let length = min(partSize, size - offset)
            var attempt = 0
            while true {
                if urls[number]?.isEmpty ?? true {
                    urls[number] = try await refreshUploadURL(drive: drive, fileId: fileId, uploadId: uploadId, part: number)
                }
                let base = sent
                // 签名里 Content-Type 为空：显式给空值，不让系统补默认类型
                let r = try await client.upload(HTTPRequest(url: urls[number] ?? "", method: "PUT", headers: [("Content-Type", "")]),
                                                body: .file(file, offset: offset, length: length)) { done in
                    progress(.uploading, size > 0 ? Double(base + done) / Double(size) : 1)
                }
                if r.isSuccess || r.text.contains("PartAlreadyExist") { break }
                attempt += 1
                // 上传地址约 1 小时过期：换新地址再传这一片
                guard attempt < 3, r.status == 403 || r.status == 400 else {
                    throw CloudnError("阿里云盘上传分片失败（HTTP \(r.status)）\(Self.ossError(r.text))")
                }
                urls[number] = ""
            }
            sent += length
        }
        progress(.finishing, 0)
        _ = try await driveCall("/v2/file/complete", ["drive_id": drive, "file_id": fileId, "upload_id": uploadId])
        progress(.finishing, 1)
    }

    private func refreshUploadURL(drive: String, fileId: String, uploadId: String, part: Int) async throws -> String {
        let json = try await driveCall("/v2/file/get_upload_url",
                                       ["drive_id": drive, "file_id": fileId, "upload_id": uploadId, "part_info_list": [["part_number": part]]])
        let url = json["part_info_list"][0]["upload_url"].string
        guard !url.isEmpty else { throw CloudnError("阿里云盘上传地址获取失败") }
        return url
    }

    static func uploadPartSize(_ size: Int64) -> Int64 {
        guard size > partSize * 10000 else { return partSize }
        let mb: Int64 = 1 << 20
        return (size / 10000 / mb + 1) * mb
    }

    static func partNumbers(size: Int64, partSize: Int64) -> [Int] {
        Array(1...max(1, Int((size + partSize - 1) / partSize)))
    }

    /// 秒传证明：md5(access_token) 的前 16 位十六进制当数，对文件大小取模得偏移，取该处 8 字节的 base64
    static func proofCode(_ file: URL, size: Int64, accessToken: String) throws -> String {
        guard size > 0 else { return "" }
        let offset = proofOffset(accessToken: accessToken, size: size)
        let data = try FileChunks.read(file, offset: offset, length: Int(min(8, size - offset)))
        return data.base64EncodedString()
    }

    static func proofOffset(accessToken: String, size: Int64) -> Int64 {
        let md5 = Crypto.hex(MD5Hasher.digest(Data(accessToken.utf8)))
        guard size > 0, let r = UInt64(md5.prefix(16), radix: 16) else { return 0 }
        return Int64(r % UInt64(size))
    }

    static func ossError(_ xml: String) -> String {
        guard let code = Rx(#"<Code>([^<]+)</Code>"#).first(in: xml) else { return "" }
        return "：\(code)"
    }
}
