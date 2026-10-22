// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 天翼云盘「我的网盘」、转存与上传。
// 列目录 / 新建 / 重命名 / 批量任务（MOVE、DELETE、SHARE_SAVE）/ 直链 / 容量走 cloud.189.cn 网页接口
// （?sessionKey= + AppKey 签名），参考 wes-lin/cloud189-sdk、1307super/cloud189-auto-save 与 OpenList（AGPL-3.0）drivers/189pc；
// 创建分享参考 tickstep/cloudpan189-api（Apache-2.0）createShareLink。
// 上传参考 cloud189-sdk signatureUpload 与 OpenList 189pc：upload.cloud.189.cn initMultiUpload → checkTransSecond（秒传）→
// getMultiUploadUrls → PUT 分片 → commitMultiUploadFile；参数 AES 加密、RSA 交换密钥、HMAC-SHA1 签名。
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 我的网盘

extension Cloud189Resolver: DriveManager {
    public var driveRootId: String { "-11" }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        let dir = folderId.isEmpty ? driveRootId : folderId
        var files: [ShareFile] = []
        let pageSize = 200
        for page in 1...200 {
            let json = try await web("/api/open/file/listFiles.action", params: Self.listParams(dir, page: page, pageSize: pageSize))
            let (items, count) = Self.parseFileList(json, parent: dir)
            files += items
            if items.count < pageSize || files.count >= count { break }
        }
        return files
    }

    static func listParams(_ folderId: String, page: Int, pageSize: Int) -> [(String, String)] {
        [("pageSize", String(pageSize)), ("pageNum", String(page)), ("mediaType", "0"), ("folderId", folderId),
         ("iconOption", "5"), ("orderBy", "filename"), ("descending", "false")]
    }

    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹不能直接下载") }
        let json = try await web("/api/open/file/getFileDownloadUrl.action", params: [("fileId", file.fid)])
        return try await downloadLink(json, name: file.name, size: file.size)
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        _ = try await web("/api/open/file/createFolder.action", method: "POST",
                          params: [("parentFolderId", parentId.isEmpty ? driveRootId : parentId), ("folderName", name)])
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        if file.isDirectory {
            _ = try await web("/api/open/file/renameFolder.action", method: "POST", params: [("folderId", file.fid), ("destFolderName", name)])
        } else {
            _ = try await web("/api/open/file/renameFile.action", method: "POST", params: [("fileId", file.fid), ("destFileName", name)])
        }
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        try await batch("MOVE", files: files, target: folderId.isEmpty ? driveRootId : folderId)
    }

    public func delete(_ files: [ShareFile]) async throws {
        guard !files.isEmpty else { return }
        try await batch("DELETE", files: files, target: nil)
    }

    /// 网页分享只有 1 天 / 7 天 / 永久（永久传 2099）
    public var shareExpiryOptions: [ShareExpiry] { [.forever, ShareExpiry(days: 7), ShareExpiry(days: 1)] }

    /// createShareLink（shareType=3：私密分享，自带访问码）；一次只能分享一个文件 / 文件夹
    public func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink {
        try expiry.require(in: shareExpiryOptions)
        guard files.count == 1, let file = files.first else { throw CloudnError("天翼云盘一次只能分享一个文件或文件夹") }
        let json = try await web("/api/open/share/createShareLink.action",
                                 params: [("fileId", file.fid), ("expireTime", expiry.isForever ? "2099" : String(expiry.days)), ("shareType", "3")])
        guard let link = Self.parseShareLink(json) else { throw CloudnError("天翼云盘没有返回分享链接") }
        return link
    }

    static func parseShareLink(_ json: JSON) -> DriveShareLink? {
        let item = json["shareLinkList"][0].isObject ? json["shareLinkList"][0] : json
        var url = item.string("url", "accessUrl", "shortShareUrl")
        guard !url.isEmpty else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        return DriveShareLink(url: url, pwd: item["accessCode"].string)
    }

    /// portal/getUserSizeInfo：cloudCapacityInfo（个人云）
    public func quota() async -> DriveQuota? {
        guard let json = try? await web("/api/portal/getUserSizeInfo.action", params: []) else { return nil }
        return Self.parseQuota(json)
    }

    static func parseQuota(_ json: JSON) -> DriveQuota? {
        let info = json["cloudCapacityInfo"]
        let total = info["totalSize"].int64
        guard total > 0 else { return nil }
        return DriveQuota(used: info["usedSize"].int64, total: total)
    }

    // MARK: 批量任务

    /// taskInfos：[{"fileId","fileName","isFolder"}]（JSON 字符串）
    static func taskInfos(_ files: [ShareFile]) -> String {
        OrderedJSON.array(files.map {
            .object([("fileId", .string($0.fid)), ("fileName", .string($0.name)), ("isFolder", .int($0.isDirectory ? 1 : 0))])
        }).text
    }

    /// createBatchTask → 轮询 checkBatchTask 直到完成（taskStatus 4）
    func batch(_ type: String, files: [ShareFile], target: String?, extra: [(String, String)] = []) async throws {
        var params: [(String, String)] = [("type", type), ("taskInfos", Self.taskInfos(files))]
        if let target { params.append(("targetFolderId", target)) }
        params += extra
        let created = try await web("/api/open/batch/createBatchTask.action", method: "POST", params: params)
        guard let taskId = created["taskId"].string.nilIfBlank else { throw CloudnError("天翼云盘没有返回任务编号") }
        for attempt in 0..<240 {
            let state = try await web("/api/open/batch/checkBatchTask.action", method: "POST", params: [("type", type), ("taskId", taskId)])
            if try Self.batchFinished(state) { return }
            try await Task.sleep(nanoseconds: attempt < 10 ? 300_000_000 : 1_000_000_000)
        }
        throw CloudnError("天翼云盘任务处理超时，请稍后刷新查看")
    }

    /// 任务状态：4 完成 → true；1 / 3 处理中 → false；2 冲突、-1 失败 → 抛错
    static func batchFinished(_ json: JSON) throws -> Bool {
        switch json["taskStatus"].int {
        case 4:
            if json["failedCount"].int > 0 && json["successedCount"].int == 0 { throw CloudnError("天翼云盘任务执行失败") }
            return true
        case 2: throw CloudnError("目标文件夹已有同名文件")
        case -1: throw CloudnError("天翼云盘任务执行失败")
        default: return false
        }
    }
}

// MARK: - 转存

extension Cloud189Resolver: ShareSaver {
    public var rootFolderId: String { "-11" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        try await listDrive(parentId).filter(\.isDirectory)
    }

    /// createBatchTask SHARE_SAVE（带 shareId）
    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        guard let meta = ShareMeta.decode(session.stoken) else { throw CloudnError("天翼云盘分享会话已失效，请重新解析") }
        for start in stride(from: 0, to: files.count, by: 100) {
            let chunk = Array(files[start..<min(start + 100, files.count)])
            try await batch("SHARE_SAVE", files: chunk, target: folderId.isEmpty ? rootFolderId : folderId, extra: [("shareId", meta.shareId)])
        }
    }
}

// MARK: - 上传

/// 上传签名用的 RSA 公钥（generateRsaKey）
struct Cloud189UploadKey: Equatable, Sendable {
    let pubKey: String
    let pkId: String
}

extension Cloud189Resolver: DriveUploader {
    /// 分片大小：10MB，超过 999 片用 20MB，再大按 1999 片取整到 10MB 的倍数（至少 50MB）
    static func partSize(_ size: Int64) -> Int64 {
        let base: Int64 = 10 << 20
        if size > base * 2 * 999 {
            let ratio = Int64((Double(size) / 1999 / Double(base)).rounded(.up))
            return max(ratio, 5) * base
        }
        if size > base * 999 { return base * 2 }
        return base
    }

    /// 整个文件 MD5 + 每片 MD5（大写十六进制）
    static func hashes(_ file: URL, partSize: Int64, progress: ((Int64) -> Void)?) throws -> (file: String, slices: [[UInt8]]) {
        var whole = MD5Hasher()
        var slice = MD5Hasher()
        var inSlice: Int64 = 0
        var slices: [[UInt8]] = []
        try FileChunks.scan(file, chunkSize: 4 << 20, progress: progress) { _, data in
            whole.update(data)
            var index = data.startIndex
            while index < data.endIndex {
                let take = Int(min(Int64(data.endIndex - index), partSize - inSlice))
                slice.update(data.subdata(in: index..<(index + take)))
                inSlice += Int64(take)
                index += take
                if inSlice == partSize {
                    slices.append(slice.finalize())
                    slice = MD5Hasher()
                    inSlice = 0
                }
            }
        }
        if inSlice > 0 || slices.isEmpty { slices.append(slice.finalize()) }
        return (Crypto.hex(whole.finalize()).uppercased(), slices)
    }

    /// 多片时 sliceMd5 = md5(各片大写 md5 用换行连接)；单片时等于文件 md5
    static func sliceMd5(fileMd5: String, slices: [[UInt8]]) -> String {
        guard slices.count > 1 else { return fileMd5 }
        return Crypto.md5Hex(slices.map { Crypto.hex($0).uppercased() }.joined(separator: "\n")).uppercased()
    }

    public func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws {
        let size = FileChunks.size(of: file)
        let part = Self.partSize(size)
        let (fileMd5, slices) = try Self.hashes(file, partSize: part, progress: progress.hashing(total: size))
        let sliceMd5 = Self.sliceMd5(fileMd5: fileMd5, slices: slices)
        let multi = slices.count > 1
        let parent = folderId.isEmpty ? driveRootId : folderId

        var initParams: [(String, String)] = [("parentFolderId", parent), ("fileName", Self.encodeURIComponent(name)),
                                              ("fileSize", String(size)), ("sliceSize", String(part))]
        initParams += multi ? [("lazyCheck", "1")] : [("fileMd5", fileMd5), ("sliceMd5", sliceMd5)]
        let created = try await uploadAPI("/person/initMultiUpload", initParams)
        guard let uploadId = created["data"]["uploadFileId"].string.nilIfBlank else { throw CloudnError("天翼云盘没有返回上传编号") }
        var exists = created["data"]["fileDataExists"].int == 1
        if multi && !exists {
            let check = try await uploadAPI("/person/checkTransSecond", [("fileMd5", fileMd5), ("sliceMd5", sliceMd5), ("uploadFileId", uploadId)])
            exists = check["data"]["fileDataExists"].int == 1
        }

        if !exists {
            progress(.uploading, 0)
            var done: Int64 = 0
            for (i, md5) in slices.enumerated() {
                let number = i + 1
                let partInfo = "\(number)-\(Data(md5).base64EncodedString())"
                let urls = try await uploadAPI("/person/getMultiUploadUrls", [("partInfo", partInfo), ("uploadFileId", uploadId)])
                let item = urls["uploadUrls"]["partNumber_\(number)"]
                guard let requestURL = item["requestURL"].string.nilIfBlank else { throw CloudnError("天翼云盘没有返回上传地址") }
                let offset = Int64(i) * part
                let length = min(part, size - offset)
                let base = done
                let req = HTTPRequest(url: requestURL, method: "PUT", headers: Self.parseHeaders(item["requestHeader"].string))
                let r = try await client.upload(req, body: .file(file, offset: offset, length: length)) { sent in
                    progress(.uploading, size > 0 ? Double(base + sent) / Double(size) : 1)
                }
                guard r.isSuccess else { throw CloudnError("天翼云盘分片上传失败（HTTP \(r.status)）") }
                done += length
            }
        }
        progress(.finishing, 0)
        var commit: [(String, String)] = [("uploadFileId", uploadId), ("fileMd5", fileMd5), ("sliceMd5", sliceMd5)]
        if multi { commit.append(("lazyCheck", "1")) }
        _ = try await uploadAPI("/person/commitMultiUploadFile", commit)
        progress(.finishing, 1)
    }

    /// requestHeader：「键=值&键=值」，值里可能还有 =
    static func parseHeaders(_ text: String) -> [(String, String)] {
        text.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    /// upload.cloud.189.cn 的请求（cloud189-sdk signatureUpload）：
    /// 随机 uuid 的前 16 位作 AES 密钥加密参数，uuid 用 RSA 公钥加密放 EncryptionText，HMAC-SHA1(uuid) 签名
    static func uploadRequest(_ route: String, params: [(String, String)], sessionKey: String, key: Cloud189UploadKey,
                              uuid: String, requestId: String, timestamp: String) -> HTTPRequest? {
        guard uuid.utf8.count >= 16, let aes = AES(key: Array(uuid.utf8.prefix(16))),
              let rsa = Cloud189RSA.parse(key.pubKey), let encrypted = Cloud189RSA.encrypt(Array(uuid.utf8), key: rsa) else { return nil }
        let plain = params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let enc = Crypto.hex(aes.encrypt(Array(plain.utf8)))
        let source = "SessionKey=\(sessionKey)&Operate=GET&RequestURI=\(route)&Date=\(timestamp)&params=\(enc)"
        let signature = Crypto.hex(Crypto.hmac(SHA1Hasher.self, key: Array(uuid.utf8), message: Data(source.utf8)))
        return HTTPRequest(url: uploadURL + route + "?params=" + enc, headers: [
            ("Accept", "application/json;charset=UTF-8"), ("User-Agent", userAgent),
            ("X-Request-Date", timestamp), ("X-Request-ID", requestId), ("SessionKey", sessionKey),
            ("EncryptionText", Data(encrypted).base64EncodedString()), ("PkId", key.pkId), ("Signature", signature),
        ])
    }

    /// 16~31 位随机十六进制
    static func randomUUIDKey() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(Int.random(in: 16...31)))
    }

    private func uploadKey(_ auth: Auth) async throws -> Cloud189UploadKey {
        if let k = await state.rsaKey(auth.sessionKey) { return k }
        let r = try await client.send(Self.webRequest("/api/security/generateRsaKey.action", params: [], sessionKey: auth.sessionKey, cookie: auth.cred.cookie))
        guard let json = r.json, let pub = json["pubKey"].string.nilIfBlank, let pkId = json["pkId"].string.nilIfBlank else {
            if Self.isSessionError(r.text) { throw Self.expired }
            throw CloudnError("天翼云盘上传准备失败（HTTP \(r.status)）")
        }
        let key = Cloud189UploadKey(pubKey: pub, pkId: pkId)
        // expire 为毫秒时间戳；拿不到就缓存 5 分钟
        let expire = json["expire"].int64
        let until = expire > 0 ? Date(timeIntervalSince1970: Double(expire) / 1000 - 60) : Date().addingTimeInterval(300)
        await state.setRSAKey(auth.sessionKey, key, until: until)
        return key
    }

    /// 上传接口：code 为 SUCCESS 才算成功；sessionKey 失效续一次
    func uploadAPI(_ route: String, _ params: [(String, String)]) async throws -> JSON {
        var auth = try await session()
        for attempt in 0..<2 {
            let key: Cloud189UploadKey
            do {
                key = try await uploadKey(auth)
            } catch let e as CloudnError where e == Self.expired && attempt == 0 {
                auth = try await renewSession(auth)
                continue
            }
            guard let req = Self.uploadRequest(route, params: params, sessionKey: auth.sessionKey, key: key, uuid: Self.randomUUIDKey(),
                                               requestId: UUID().uuidString.lowercased(),
                                               timestamp: String(Int64(Date().timeIntervalSince1970 * 1000))) else {
                throw CloudnError("天翼云盘上传签名失败")
            }
            let r = try await client.send(req)
            if attempt == 0, Self.isSessionError(r.text) {
                auth = try await renewSession(auth)
                continue
            }
            guard let json = r.json, json.isObject else { throw CloudnError("天翼云盘上传失败（HTTP \(r.status)）") }
            if let err = Self.uploadError(json, status: r.status) { throw err }
            return json
        }
        throw Self.expired
    }

    static func uploadError(_ json: JSON, status: Int) -> CloudnError? {
        let code = json["code"].string
        if code.isEmpty || code == "SUCCESS" { return apiError(json, status: status) }
        switch code {
        case "UserDayFlowOverLimited": return CloudnError("天翼云盘今日上传流量已用完")
        case "InsufficientStorageSpace": return CloudnError("天翼云盘空间不足")
        case "InfoSecurityErrorCode": return CloudnError("文件未通过天翼云盘安全检查")
        default:
            let msg = json.string("msg", "message", "errorMsg")
            return CloudnError(msg.isEmpty ? "天翼云盘上传失败（\(code)）" : "天翼云盘上传失败：\(msg)")
        }
    }
}
