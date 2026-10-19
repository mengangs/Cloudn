// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 123 云盘分享解析：/b/api/share/get 匿名列目录 → 登录态 + 签名头 /b/api/share/download/info 取直链。
// 协议细节（含 auth-key / auth-value 签名）参考 YunX（AGPL-3.0）的 Pan123Api / Pan123ResolveRepository。
// 我的网盘管理参考 YunX（AGPL-3.0）的 Pan123Api / Pan123CloudViewModel：/b/api/file/* + /api/file/download_info。
import Foundation

public final class Pan123Resolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .pan123 }
    public var supportsGuestDownload: Bool { false }

    public static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    static let dartUA = "Dart/3.12 (dart:io)"
    public static let loginURL = "https://yun.123pan.cn/"
    /// 网页登录后 SPA 把 Bearer JWT 写在 localStorage 的这个键里
    public static let tokenStorageKey = "authorToken"
    static let referer = "https://yun.123pan.cn/"
    static let signTable = Array("adefghlmyijnopkqrstubcvwsz")

    private let credentials: CredentialStore
    private let client: HTTPClient
    private let apiBase: String
    private let downloadBase: String
    private let state = State()

    /// 分享 key → mshare 子域的数字 id（S3KeyFlag 的前缀，转存接口要用；文件夹条目没有 S3KeyFlag，所以列目录时记下）
    private actor State {
        var mshare: [String: String] = [:]
        func set(_ key: String, _ id: String) { if mshare[key] == nil { mshare[key] = id } }
    }

    /// 设备标识：不参与签名，进程内固定即可
    private let loginUUID: String = (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()

    public init(credentials: CredentialStore, client: HTTPClient = .shared,
                apiBase: String = "https://yun.123pan.cn", downloadBase: String = "https://www.123865.com") {
        self.credentials = credentials
        self.client = client
        self.apiBase = apiBase
        self.downloadBase = downloadBase
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let sharePwd = pwd?.nilIfBlank ?? share.pwd ?? ""
        // 用根目录第一页校验提取码；标题取唯一的根条目名，否则用分享 key
        let (files, _) = try await sharePage(share.shareId, pwd: sharePwd, parent: "0", page: 1)
        let title = files.count == 1 ? files[0].name : "123 云盘分享"
        return ShareSession(platform: .pan123, shareId: share.shareId, stoken: sharePwd, title: title, rootId: "0")
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var page = 1
        while page < 50 {
            let (files, hasMore) = try await sharePage(session.shareId, pwd: session.stoken, parent: dirId.nilIfBlank ?? "0", page: page)
            all += files
            if files.isEmpty || !hasMore { break }
            page += 1
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard let token = await credentials.cookie(for: .pan123)?.nilIfBlank else {
            throw CloudnError("123 云盘需要登录后才能下载，请到「账号」页登录 123 云盘")
        }
        let parts = file.token.components(separatedBy: "|")
        let body: [String: Any] = [
            "ShareKey": session.shareId, "FileID": file.fid,
            "S3KeyFlag": parts.first ?? "", "Size": file.size, "Etag": parts.count > 1 ? parts[1] : ""
        ]
        let path = "/b/api/share/download/info"
        let json = try await callJSON(.postJSON(downloadBase + path, body,
                                                headers: authHeaders(path: path, token: token, platform: "android", appVersion: "39")))
        try Self.check(json, fallback: "获取下载链接失败")
        let raw = json["data"]["DownloadURL"].string
        guard !raw.isEmpty else { throw CloudnError("123 云盘未返回下载链接") }
        let real = await followRedirectURL(Self.decodeDownloadURL(raw) ?? raw)
        return DownloadLink(fileName: file.name, url: real, size: file.size, headers: ["User-Agent": Self.dartUA, "Referer": Self.referer])
    }

    // MARK: 账号

    /// 校验 token 并返回昵称；无效返回 nil
    public func fetchNickname(token: String) async -> String? {
        let path = "/b/api/user/info"
        guard let json = try? await callJSON(.get(apiBase + path, headers: authHeaders(path: path, token: token))),
              json["code"].int == 0 else { return nil }
        return json["data"]["Nickname"].string.nilIfBlank ?? "123 云盘用户"
    }

    /// 网页 localStorage 里的值可能带引号或 "Bearer " 前缀，统一成裸 JWT
    public static func normalizeToken(_ raw: String) -> String {
        var t = raw.trimmed
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)).trimmed }
        return t
    }

    // MARK: 列表

    /// 单页分享列表；返回 (文件, 是否还有下一页)。Next == "-1" 表示末页
    private func sharePage(_ key: String, pwd: String, parent: String, page: Int) async throws -> ([ShareFile], Bool) {
        // 无提取码时不能传空 SharePwd（服务端会 400）
        var url = apiBase + "/b/api/share/get?limit=100&next=0&orderBy=file_name&orderDirection=asc" +
            "&shareKey=\(key.urlQueryEncoded)&ParentFileId=\(parent.urlQueryEncoded)&Page=\(page)"
        if !pwd.isEmpty { url += "&SharePwd=\(pwd.urlQueryEncoded)" }
        let json = try await callJSON(.get(url, headers: [("User-Agent", Self.dartUA)]))
        try Self.check(json, fallback: "获取文件列表失败")
        let data = json["data"]
        if data["Expired"].bool { throw CloudnError("分享已失效") }
        let files = data["InfoList"].array.map { Self.parseItem($0) }
        if let id = files.lazy.compactMap({ Self.mshareId(fromToken: $0.token) }).first { await state.set(key, id) }
        return (files, data["Next"].string != "-1")
    }

    static func parseItem(_ item: JSON) -> ShareFile {
        ShareFile(
            fid: item["FileId"].string,
            name: item["FileName"].string,
            size: item["Size"].int64,
            isDirectory: item["Type"].int == 1,
            parentId: item["ParentFileId"].string,
            // 取链需要 S3KeyFlag + Etag，转存还要 StorageNode
            token: "\(item["S3KeyFlag"].string)|\(item["Etag"].string)|\(item["StorageNode"].string)",
            modified: item["UpdateAt"].string
        )
    }

    /// S3KeyFlag 形如 "1816216065-0"，前缀即 mshare 子域
    static func mshareId(fromToken token: String) -> String? {
        let flag = token.components(separatedBy: "|").first ?? ""
        let id = flag.components(separatedBy: "-").first ?? ""
        return id.isEmpty || !id.allSatisfy(\.isNumber) ? nil : id
    }

    /// copy/save 的 fileList 条目（大小写两套字段都要带，服务端各版本取的不一样）
    static func copySaveEntry(_ file: ShareFile, parent: Int64) -> [String: Any] {
        let parts = file.token.components(separatedBy: "|")
        let flag = parts.first ?? ""
        let fileId = Int64(file.fid) ?? 0
        return [
            "fileID": fileId, "fileId": fileId, "size": file.size, "etag": parts.count > 1 ? parts[1] : "",
            "type": file.isDirectory ? 1 : 0, "parentFileID": parent, "parentFileId": parent, "fileName": file.name,
            "driveID": 0, "driveId": 0, "s3keyFlag": flag, "S3KeyFlag": flag, "StorageNode": parts.count > 2 ? parts[2] : ""
        ]
    }

    // MARK: 直链解码

    /// 两种形态：整段 Base64，或 download-v2?params=<URL-safe Base64>
    static func decodeDownloadURL(_ url: String) -> String? {
        let trimmed = url.trimmed
        if !trimmed.contains("://") {
            guard let data = Crypto.base64Decode(trimmed) else { return nil }
            let s = String(decoding: data, as: UTF8.self)
            return s.lowercased().hasPrefix("http") ? s : nil
        }
        guard let range = trimmed.range(of: "params=") else { return nil }
        let param = String(trimmed[range.upperBound...]).substringBefore("&")
        guard let data = Crypto.base64Decode(param.removingPercentEncoding ?? param) else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.lowercased().hasPrefix("http") ? s : nil
    }

    /// 带 auto_redirect=0 的地址返回 `{"data":{"redirect_url":...}}` 小 JSON 而不是文件，可能多跳
    private func followRedirectURL(_ initial: String) async -> String {
        var url = initial
        for _ in 0..<5 {
            guard url.contains("auto_redirect=0") else { return url }
            // Range 只取 1 字节：万一已经是文件流，也不会把整个文件读进内存
            guard let r = try? await client.send(.get(url, headers: [("User-Agent", Self.dartUA), ("Referer", Self.referer), ("Range", "bytes=0-0")])),
                  r.body.count <= 8192, let next = r.json?["data"]["redirect_url"].string, !next.isEmpty else { return url }
            url = next
        }
        return url
    }

    // MARK: 签名

    /// auth-key = crc32(替换表映射后的 UTC「ts+16h」yyyyMMddHHmm)；
    /// auth-value = "<ts>-<random>-<crc32(ts|random|path|web|3|auth-key)>"（签名内固定 web / 3）
    static func sign(path: String, ts: Int64 = Int64(Date().timeIntervalSince1970), random: Int = Int.random(in: 0..<10_000_000)) -> (key: String, value: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts + 57600)))
        func pad(_ v: Int?, _ width: Int) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let stamp = pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + pad(c.hour, 2) + pad(c.minute, 2)
        let substituted = String(stamp.compactMap { $0.wholeNumberValue.map { signTable[$0] } })
        let authKey = Crypto.crc32Hex(substituted)
        let value = "\(ts)-\(random)-\(Crypto.crc32Hex("\(ts)|\(random)|\(path)|web|3|\(authKey)"))"
        return (authKey, value)
    }

    private func authHeaders(path: String, token: String, platform: String = "web", appVersion: String = "3") -> [(String, String)] {
        let s = Self.sign(path: path)
        return [("platform", platform), ("app-version", appVersion), ("authorization", "Bearer \(token)"),
                ("loginuuid", loginUUID), ("auth-key", s.key), ("auth-value", s.value),
                ("User-Agent", Self.webUA), ("Accept", "application/json, text/plain, */*")]
    }

    private func callJSON(_ req: HTTPRequest) async throws -> JSON {
        let r = try await client.send(req)
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        return json
    }

    static func check(_ json: JSON, fallback: String) throws {
        let code = json.has("code") ? json["code"].int : -1
        guard code != 0 else { return }
        if code == 401 { throw CloudnError("123 云盘登录已失效，请到「账号」页重新登录", code: code) }
        let msg = json["message"].string
        throw CloudnError(msg.isEmpty ? "\(fallback)（\(code)）" : msg, code: code)
    }
}

// MARK: - 转存到我的网盘

extension Pan123Resolver: ShareSaver {
    public var rootFolderId: String { "0" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        guard let token = await credentials.cookie(for: .pan123)?.nilIfBlank else { throw SharePlatform.pan123.loginRequired }
        var all: [ShareFile] = []
        var next = "0"
        for page in 1...50 {
            let path = "/b/api/file/list/new"
            let url = apiBase + path + "?driveId=0&limit=100&next=\(next.urlQueryEncoded)&orderBy=file_name&orderDirection=asc" +
                "&parentFileId=\(parentId.urlQueryEncoded)&trashed=false&SearchData=&Page=\(page)&OnlyLookAbnormalFile=0" +
                "&event=homeListFile&operateType=1&inDirectSpace=false"
            let json = try await callJSON(.get(url, headers: authHeaders(path: path, token: token)))
            try Self.check(json, fallback: "获取文件夹失败")
            let data = json["data"]
            all += data["InfoList"].array.map { Self.parseItem($0) }.filter(\.isDirectory)
            let cursor = data["Next"].string
            if cursor == "-1" || data["InfoList"].array.isEmpty { break }
            next = cursor.isEmpty ? "0" : cursor
        }
        return all
    }

    /// copy/save 走 mshare 子域：不需要签名，只带 Bearer + LoginUuid；异步任务轮询 copy/save/get
    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        guard let token = await credentials.cookie(for: .pan123)?.nilIfBlank else { throw SharePlatform.pan123.loginRequired }
        let cached = await state.mshare[session.shareId]
        guard let mshare = cached ?? files.lazy.compactMap({ Self.mshareId(fromToken: $0.token) }).first else {
            throw CloudnError("无法识别 123 分享的转存标识，请重新解析后再试")
        }
        let base = "https://\(mshare).mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save"
        let headers: [(String, String)] = [("Authorization", "Bearer \(token)"), ("LoginUuid", loginUUID), ("platform", "web"),
                                           ("User-Agent", Self.dartUA)]
        let parent = Int64(folderId) ?? 0
        for start in stride(from: 0, to: files.count, by: 100) {
            let batch = files[start..<min(start + 100, files.count)]
            let body: [String: Any] = ["fileList": batch.map { Self.copySaveEntry($0, parent: parent) }, "shareKey": session.shareId,
                                       "sharePwd": session.stoken, "currentLevel": 1, "superAdmin": NSNull()]
            let json = try await callJSON(.postJSON(base, body, headers: headers))
            try Self.check(json, fallback: "转存失败")
            let taskId = json["data"]["taskID"].string
            guard !taskId.isEmpty else { throw CloudnError("123 云盘未返回转存任务") }
            try await waitCopySave(base + "/get?taskID=\(taskId.urlQueryEncoded)", headers: headers)
        }
    }

    private func waitCopySave(_ url: String, headers: [(String, String)]) async throws {
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let json = try? await callJSON(.get(url, headers: headers)) else { continue }
            if json["code"].int != 0 {
                let msg = json["message"].string
                if !msg.isEmpty { throw CloudnError("转存失败：\(msg)") }
                continue
            }
            let data = json["data"]
            let state = data["state"].string.lowercased()
            let status = data["status"].int
            if data["finished"].bool || status == 2 || status == 3 || state == "success" || state == "done" || state == "2" ||
                data.has("fileId") || data.has("FileId") || data.has("newFileId") {
                return
            }
        }
        throw CloudnError("转存仍在进行，请稍后到 123 云盘里查看")
    }
}

// MARK: - 我的网盘管理

extension Pan123Resolver: DriveManager {
    public var driveRootId: String { "0" }

    /// 个人盘列表：GET /b/api/file/list/new，Next 游标翻页（"-1" 为末页）
    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        let token = try await driveToken()
        let parent = folderId.nilIfBlank ?? "0"
        var all: [ShareFile] = []
        var seen = Set<String>()
        var next = "0"
        for _ in 0..<200 {
            let path = "/b/api/file/list/new"
            let url = apiBase + path + "?driveId=0&limit=100&next=\(next.urlQueryEncoded)&orderBy=update_time&orderDirection=desc" +
                "&parentFileId=\(parent.urlQueryEncoded)&trashed=false&SearchData=&Page=1&OnlyLookAbnormalFile=0" +
                "&event=homeListFile&operateType=1&inDirectSpace=false"
            let json = try await callJSON(.get(url, headers: authHeaders(path: path, token: token)))
            try Self.check(json, fallback: "获取文件列表失败")
            let data = json["data"]
            // 游标异常回吐同一页时按 fid 去重，没有新条目即停
            let page = data["InfoList"].array.map { Self.parseItem($0) }.filter { seen.insert($0.fid).inserted }
            all += page
            let cursor = data["Next"].string
            if cursor == "-1" || page.isEmpty { break }
            next = cursor
        }
        return all
    }

    /// 个人盘直链：POST /api/file/download_info（注意没有 /b/），解 download-v2 包装并跟随 redirect_url
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        let token = try await driveToken()
        let path = "/api/file/download_info"
        let json = try await callJSON(.postJSON(apiBase + path, Self.driveDownloadBody(file), headers: jsonAuthHeaders(path: path, token: token)))
        try Self.check(json, fallback: "获取下载链接失败")
        let raw = json["data"].string("DownloadUrl", "DownloadURL")
        guard !raw.isEmpty else { throw CloudnError("123 云盘未返回下载链接") }
        let real = await followRedirectURL(Self.decodeDownloadURL(raw) ?? raw)
        return DownloadLink(fileName: file.name, url: real, size: file.size, headers: ["User-Agent": Self.webUA, "Referer": Self.referer])
    }

    /// 123 没有独立建目录端点：上传预创建 /b/api/file/upload_request 的 type=1
    public func createFolder(_ name: String, in parentId: String) async throws {
        try await drivePost("/b/api/file/upload_request", Self.createFolderBody(name: name, parentId: parentId), fallback: "新建文件夹失败")
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        try await drivePost("/b/api/file/rename", Self.renameBody(fileId: file.fid, name: name), fallback: "重命名失败")
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        try await drivePost("/b/api/file/mod_pid", Self.moveBody(fileIds: files.map(\.fid), to: folderId), fallback: "移动失败")
    }

    /// 删除 = 移入回收站
    public func delete(_ files: [ShareFile]) async throws {
        guard !files.isEmpty else { return }
        try await drivePost("/b/api/file/trash", Self.trashBody(files), fallback: "删除失败")
    }

    /// 永久有效、随机 4 位提取码
    public func createShare(_ files: [ShareFile]) async throws -> DriveShareLink {
        guard !files.isEmpty else { throw CloudnError("请选择要分享的文件") }
        let token = try await driveToken()
        let pwd = String((0..<4).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
        let name = files.count == 1 ? files[0].name : "分享 \(files.count) 个文件"
        let path = "/b/api/share/create"
        let body = Self.shareCreateBody(fileIds: files.map(\.fid), name: name, pwd: pwd)
        let json = try await callJSON(.postJSON(apiBase + path, body, headers: jsonAuthHeaders(path: path, token: token)))
        try Self.check(json, fallback: "创建分享失败")
        guard let url = Self.shareURL(from: json["data"]) else { throw CloudnError("创建分享失败：未返回 ShareKey") }
        return DriveShareLink(url: url, pwd: pwd)
    }

    /// GET /b/api/user/info：SpaceUsed / SpacePermanent + SpaceTemp
    public func quota() async -> DriveQuota? {
        guard let token = await credentials.cookie(for: .pan123)?.nilIfBlank else { return nil }
        let path = "/b/api/user/info"
        guard let json = try? await callJSON(.get(apiBase + path, headers: authHeaders(path: path, token: token))),
              json["code"].int == 0 else { return nil }
        return Self.parseQuota(json["data"])
    }

    // MARK: 内部

    private func driveToken() async throws -> String {
        guard let token = await credentials.cookie(for: .pan123)?.nilIfBlank else { throw SharePlatform.pan123.loginRequired }
        return token
    }

    private func jsonAuthHeaders(path: String, token: String) -> [(String, String)] {
        authHeaders(path: path, token: token) + [("Content-Type", "application/json;charset=UTF-8")]
    }

    /// 签名 path 必须与请求 path 逐字一致
    private func drivePost(_ path: String, _ body: [String: Any], fallback: String) async throws {
        let token = try await driveToken()
        let json = try await callJSON(.postJSON(apiBase + path, body, headers: jsonAuthHeaders(path: path, token: token)))
        try Self.check(json, fallback: fallback)
    }

    static func driveDownloadBody(_ file: ShareFile) -> [String: Any] {
        let parts = file.token.components(separatedBy: "|")
        return ["driveId": 0, "etag": parts.count > 1 ? parts[1] : "", "fileId": Int64(file.fid) ?? 0,
                "s3keyFlag": parts.first ?? "", "type": 0, "fileName": file.name, "size": file.size]
    }

    static func createFolderBody(name: String, parentId: String) -> [String: Any] {
        ["driveId": 0, "parentFileId": Int64(parentId) ?? 0, "fileName": name, "size": 0, "type": 1, "etag": "",
         "duplicate": 1, "NotReuse": true, "RequestSource": NSNull()]
    }

    static func renameBody(fileId: String, name: String) -> [String: Any] {
        ["driveId": 0, "fileId": Int64(fileId) ?? 0, "fileName": name, "duplicate": 1, "event": "fileRename",
         "operatePlace": "right", "RequestSource": NSNull()]
    }

    static func moveBody(fileIds: [String], to folderId: String) -> [String: Any] {
        ["fileIdList": fileIds.map { ["FileId": Int64($0) ?? 0] as [String: Any] }, "parentFileId": Int64(folderId) ?? 0,
         "event": "fileMove", "operatePlace": 1, "RequestSource": NSNull()]
    }

    static func trashBody(_ files: [ShareFile]) -> [String: Any] {
        let list: [[String: Any]] = files.map { f in
            let parts = f.token.components(separatedBy: "|")
            return ["FileId": Int64(f.fid) ?? 0, "FileName": f.name, "Type": f.isDirectory ? 1 : 0, "Size": f.size,
                    "S3KeyFlag": parts.first ?? "", "Etag": parts.count > 1 ? parts[1] : ""]
        }
        return ["driveId": 0, "fileTrashInfoList": list, "operation": true, "event": "intoRecycle", "operatePlace": 1, "safeBox": false]
    }

    /// 永久分享过期时间固定 2099-12-12T08:00:00+08:00；单文件 fileIdList 为标量，多文件为数组
    static func shareCreateBody(fileIds: [String], name: String, pwd: String,
                                expiration: String = "2099-12-12T08:00:00+08:00") -> [String: Any] {
        let ids = fileIds.map { Int64($0) ?? 0 }
        var body: [String: Any] = [
            "driveId": 0, "expiration": expiration, "shareName": name, "event": "shareCreate", "fileNum": ids.count,
            "shareModality": 4, "trafficLimitSwitch": 1, "trafficLimit": 0, "trafficSwitch": 1, "fillPwdSwitch": 0
        ]
        if ids.count == 1 { body["fileIdList"] = ids[0] } else { body["fileIdList"] = ids }
        if !pwd.isEmpty { body["sharePwd"] = pwd }
        return body
    }

    /// shareLinkList.list[0] → shareLinkList.standBy → https://www.123pan.com/s/<ShareKey>
    static func shareURL(from data: JSON) -> String? {
        let key = data["ShareKey"].string
        guard !key.isEmpty else { return nil }
        let links = data["shareLinkList"]
        return links["list"][0].string.nilIfBlank ?? links["standBy"].string.nilIfBlank ?? "https://www.123pan.com/s/\(key)"
    }

    static func parseQuota(_ data: JSON) -> DriveQuota? {
        guard data.isObject else { return nil }
        return DriveQuota(used: data["SpaceUsed"].int64, total: data["SpacePermanent"].int64 + data["SpaceTemp"].int64)
    }
}
