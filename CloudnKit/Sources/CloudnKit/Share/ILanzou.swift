// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 蓝奏云优享版（ilanzou.com）匿名分享解析：设备 uuid → /unproved/share/list 列目录 → /unproved/file/redirect 取直链。
// 登录后：取链的 downloadId 带上 userId；转存走 /proved/file/transfer。
// 协议细节参考 YunX（AGPL-3.0）的 ILanzouApi / ILanzouResolveRepository；我的网盘管理参考 YunX（AGPL-3.0）的 ILanzouCloudViewModel。
import Foundation

public final class ILanzouResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .ilanzou }
    public var supportsGuestDownload: Bool { true }

    static let apiBase = "https://apis.ilanzou.com"
    static let shareAPIBase = "https://apix.ilanzou.com"
    static let webSite = "https://www.ilanzou.com"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let aesKey = Array("lanZouY-disk-app".utf8)
    static let devType = "6"
    static let devVersion = "125"
    static let pageSize = 60
    static let folderPrefix = "d:"
    static let filePrefix = "f:"

    private let credentials: CredentialStore
    private let client: HTTPClient
    private let state = State()
    private let base: String
    private let shareBase: String

    private actor State {
        var uuid: String?
        func set(_ v: String) { uuid = v }
    }

    /// `apiBase` / `shareBase` 仅供测试替换为本地服务器
    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared,
                apiBase: String = "https://apis.ilanzou.com", shareBase: String = "https://apix.ilanzou.com") {
        self.credentials = credentials
        self.client = client
        self.base = apiBase
        self.shareBase = shareBase
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        // 优享版分享没有提取码环节：先列一次根目录，既校验分享有效，也能尽早暴露风控问题
        let session = ShareSession(platform: .ilanzou, shareId: share.shareId, stoken: share.shareId, title: "蓝奏云优享版分享", rootId: "")
        let root = try await list(session, dirId: "")
        if root.count == 1, let only = root.first, !only.isDirectory {
            return ShareSession(platform: .ilanzou, shareId: share.shareId, stoken: share.shareId, title: only.name, rootId: "")
        }
        return session
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let uuid = try await deviceId()
        let folderId = dirId.hasPrefix(Self.folderPrefix) ? String(dirId.dropFirst(Self.folderPrefix.count)) : dirId
        var all: [ShareFile] = []
        var seen = Set<String>()
        var page = 1
        while page <= 1000 {
            var params: [(String, String)] = []
            if !folderId.isEmpty && folderId != "0" { params.append(("folderId", folderId)) }
            params += [("offset", String(page)), ("limit", String(Self.pageSize))]
            let url = shareBase + "/unproved/share/list?" + Self.query(Self.commonParams(uuid: uuid, devModel: "Chrome") + [("extra", "2"), ("shareId", session.shareId)] + params)
            let r = try await client.send(.get(url, headers: Self.headers))
            guard let json = r.json, json.isObject else { throw CloudnError("蓝奏优享分享请求失败（HTTP \(r.status)）") }
            guard json["code"].int == 200 else {
                let msg = json["msg"].string
                throw CloudnError(msg.isEmpty ? "蓝奏优享分享请求失败（\(json["code"].int)）" : msg, code: json["code"].int)
            }
            let items = json["list"].array
            if items.isEmpty { break }
            var added = 0
            for item in items {
                guard let f = Self.parseItem(item, parent: dirId), seen.insert(f.fid).inserted else { continue }
                all.append(f)
                added += 1
            }
            if added == 0 { break }
            let totalPage = json["totalPage"].int
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && items.count < Self.pageSize { break }
            page += 1
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹无法直接下载") }
        let uuid = try await deviceId()
        let fileId = file.fid.hasPrefix(Self.filePrefix) ? String(file.fid.dropFirst(Self.filePrefix.count)) : file.fid
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        // downloadId = AES('<fileId>|<userId>')（游客 userId 为空串）；auth = AES('<fileId>|<毫秒时间戳>')
        let userId = await account()?.userId ?? ""
        let params: [(String, String)] = [
            ("downloadId", Self.aesHex("\(fileId)|\(userId)")), ("enable", "1"), ("devType", Self.devType), ("uuid", uuid),
            ("timestamp", Self.aesHex(ts)), ("auth", Self.aesHex("\(fileId)|\(ts)")), ("shareId", session.shareId)
        ]
        let url = shareBase + "/unproved/file/redirect?" + Self.query(params)
        let r = try await client.send(.get(url, headers: Self.headers, followRedirects: false))
        let dlHeaders = ["User-Agent": Self.ua, "Referer": Self.webSite + "/"]
        if (300..<400).contains(r.status), let location = r.header("Location"), !location.isEmpty {
            let resolved = URL(string: location, relativeTo: URL(string: shareBase))?.absoluteString ?? location
            return DownloadLink(fileName: file.name, url: resolved, size: -1, headers: dlHeaders)
        }
        guard let json = r.json, json.isObject else { throw CloudnError("蓝奏优享未返回下载地址") }
        let link = json["url"].string.nilIfBlank ?? json["data"]["url"].string
        guard !link.isEmpty else {
            throw CloudnError(json["msg"].string.nilIfBlank ?? "蓝奏优享未返回下载地址，请检查文件权限")
        }
        return DownloadLink(fileName: file.name, url: link, size: -1, headers: dlHeaders)
    }

    // MARK: 账号

    private func account() async -> ILanzouCredential? {
        guard let raw = await credentials.cookie(for: .ilanzou) else { return nil }
        return ILanzouCredential.parse(raw)
    }

    private func requireAccount() async throws -> ILanzouCredential {
        guard let cred = await account() else { throw SharePlatform.ilanzou.loginRequired }
        return cred
    }

    /// 已登录接口：公共参数 + appToken + extra=2 + 业务参数；code -1 / -2 为登录失效
    private func proved(_ path: String, _ cred: ILanzouCredential, params: [(String, String)] = [], body: OrderedJSON? = nil) async throws -> JSON {
        let url = base + path + "?" + Self.query(Self.commonParams(uuid: cred.uuid, devModel: "chrome") + [("appToken", cred.appToken), ("extra", "2")] + params)
        let request: HTTPRequest
        if let body {
            request = HTTPRequest(url: url, method: "POST", headers: Self.headers + [("Content-Type", "application/json; charset=utf-8")],
                                  body: Data(body.text.utf8))
        } else {
            request = .get(url, headers: Self.headers)
        }
        let r = try await client.send(request)
        if r.status == 401 || r.status == 403 { throw CloudnError("蓝奏优享登录已过期，请到「我的」页重新登录") }
        guard let json = r.json, json.isObject else {
            throw CloudnError(r.status == 409 ? "蓝奏优享触发了访问验证，请稍后重试" : "蓝奏优享请求失败（HTTP \(r.status)）")
        }
        let code = json["code"].int
        if code == -1 || code == -2 { throw CloudnError("蓝奏优享登录已过期，请到「我的」页重新登录") }
        guard code == 200 else { throw CloudnError(json["msg"].string.nilIfBlank ?? "蓝奏优享请求失败（\(code)）") }
        return json
    }

    /// 账号信息（userId / 昵称），登录与校验共用
    static func accountInfo(appToken: String, uuid: String, client: HTTPClient, apiBase: String = "https://apis.ilanzou.com") async -> (userId: String, nickname: String)? {
        let url = apiBase + "/proved/user/account/map?" + query(commonParams(uuid: uuid, devModel: "chrome") + [("appToken", appToken), ("extra", "2")])
        guard let r = try? await client.send(.get(url, headers: headers)), let json = r.json, json["code"].int == 200 else { return nil }
        let map = json["map"]
        let userId = map["userId"].string
        guard !userId.isEmpty, userId != "0" else { return nil }
        return (userId, map.string("nickName", "nickname", "account").nilIfBlank ?? "蓝奏优享用户")
    }

    /// 个人盘某目录下的条目（文件夹 id 带 d: 前缀）
    func personalList(_ folderId: String, cred: ILanzouCredential) async throws -> [ShareFile] {
        let raw = folderId.hasPrefix(Self.folderPrefix) ? String(folderId.dropFirst(Self.folderPrefix.count)) : folderId
        var all: [ShareFile] = []
        var seen = Set<String>()
        for page in 1...1000 {
            let json = try await proved("/proved/record/file/list", cred, params: [("offset", String(page)), ("limit", String(Self.pageSize)),
                                                                                  ("folderId", raw.nilIfBlank ?? "0"), ("type", "0")])
            let items = json["list"].array
            var added = 0
            for item in items {
                guard let f = Self.parseItem(item, parent: folderId), seen.insert(f.fid).inserted else { continue }
                all.append(f)
                added += 1
            }
            let totalPage = json["totalPage"].int
            if items.isEmpty || added == 0 || (totalPage > 0 && page >= totalPage) || (totalPage <= 0 && items.count < Self.pageSize) { break }
        }
        return all
    }

    /// 转存请求体：文件、文件夹 id 分别逗号拼接（去掉 f: / d: 前缀）
    static func transferBody(shareId: String, files: [ShareFile], to folderId: String) -> OrderedJSON {
        let fileIds = files.filter { !$0.isDirectory }.map { $0.fid.hasPrefix(filePrefix) ? String($0.fid.dropFirst(filePrefix.count)) : $0.fid }
        let folderIds = files.filter(\.isDirectory).map { $0.fid.hasPrefix(folderPrefix) ? String($0.fid.dropFirst(folderPrefix.count)) : $0.fid }
        let target = folderId.hasPrefix(folderPrefix) ? String(folderId.dropFirst(folderPrefix.count)) : folderId
        return .object([("targetFileId", .string(fileIds.joined(separator: ","))), ("targetFolderId", .string(folderIds.joined(separator: ","))),
                        ("folderId", .string(target.nilIfBlank ?? "0")), ("shareId", .string(shareId))])
    }

    // MARK: 设备标识

    private func deviceId() async throws -> String {
        if let cached = await state.uuid { return cached }
        let url = base + "/unproved/getUuid?" + Self.query(Self.commonParams(uuid: "", devModel: "chrome") + [("extra", "2")])
        let r = try await client.send(.get(url, headers: Self.headers))
        let uuid = r.json?["uuid"].string ?? ""
        guard Self.uuidRx.matches(uuid) else {
            if r.status == 409 { throw CloudnError("蓝奏优享触发了访问验证，请稍后重试") }
            throw CloudnError("蓝奏优享未返回有效设备标识")
        }
        await state.set(uuid)
        return uuid
    }

    static let uuidRx = Rx(#"^[A-Za-z0-9_-]{8,128}$"#)

    // MARK: 请求构造

    /// 该站 CDN / WAF 对「裸」HTTP 客户端返回空列表，需补全浏览器客户端提示头
    static let headers: [(String, String)] = [
        ("User-Agent", ua), ("Origin", webSite), ("Referer", webSite + "/"),
        ("Accept", "application/json, text/plain, */*"), ("Accept-Language", "zh-CN,zh;q=0.9"),
        ("sec-ch-ua", "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\""),
        ("sec-ch-ua-mobile", "?0"), ("sec-ch-ua-platform", "\"Windows\""),
        ("sec-fetch-dest", "empty"), ("sec-fetch-mode", "cors"), ("sec-fetch-site", "same-site")
    ]

    static func commonParams(uuid: String, devModel: String) -> [(String, String)] {
        [("uuid", uuid), ("devType", devType), ("devCode", uuid), ("devModel", devModel), ("devVersion", devVersion),
         ("appVersion", ""), ("timestamp", aesHex(String(Int64(Date().timeIntervalSince1970 * 1000))))]
    }

    /// 查询串编码：表单编码后把 %3A 还原为冒号（与网页端一致）
    static func query(_ params: [(String, String)]) -> String {
        params.map { "\($0.0)=\($0.1.formEncoded.replacingOccurrences(of: "%3A", with: ":"))" }.joined(separator: "&")
    }

    static func aesHex(_ plain: String) -> String {
        Crypto.hex(AES(key: aesKey)!.encrypt(Array(plain.utf8)))
    }

    /// 列表项：fileType == 2 为文件夹；文件大小单位是 KiB
    static func parseItem(_ item: JSON, parent: String) -> ShareFile? {
        let modified = item.string("updTime", "addTime")
        if item["fileType"].int == 2 {
            let id = item["folderId"].string
            guard !id.isEmpty, id != "0" else { return nil }
            return ShareFile(fid: folderPrefix + id, name: item["folderName"].string, size: 0, isDirectory: true, parentId: parent, modified: modified)
        }
        let id = item["fileId"].string
        guard !id.isEmpty, id != "0" else { return nil }
        return ShareFile(fid: filePrefix + id, name: item["fileName"].string, size: item["fileSize"].int64 * 1024,
                         isDirectory: false, parentId: parent, modified: modified)
    }
}

extension ILanzouResolver: ShareSaver {
    public var rootFolderId: String { "" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        try await personalList(parentId, cred: requireAccount()).filter(\.isDirectory)
    }

    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        let cred = try await requireAccount()
        let json = try await proved("/proved/file/transfer", cred, body: Self.transferBody(shareId: session.shareId, files: files, to: folderId))
        let key = json["data"]["transferKey"].string.nilIfBlank ?? json["map"]["transferKey"].string.nilIfBlank ?? json["transferKey"].string.nilIfBlank
            ?? (json["data"].raw as? String ?? "")
        guard !key.isEmpty else { return }
        // 异步转存：map.num == 1 表示完成
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let r = try? await proved("/proved/file/transfer/num", cred, params: [("transferKey", key)]), r["map"]["num"].int == 1 { return }
        }
        throw CloudnError("蓝奏优享仍在处理转存，请稍后在网盘里查看")
    }
}

// MARK: 我的网盘管理（优享版没有创建分享接口）

extension ILanzouResolver: DriveManager {
    public var driveRootId: String { "" }
    public var driveCapabilities: DriveCapabilities { [.createFolder, .rename, .move, .delete] }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        try await personalList(folderId, cred: requireAccount())
    }

    /// 个人盘取链：apis 主机的 /unproved/file/redirect，带 appToken、不带 extra，timestamp 与 auth 共用同一毫秒时间戳
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹无法直接下载") }
        let cred = try await requireAccount()
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let params = Self.personalRedirectParams(fileId: Self.rawId(file.fid), userId: cred.userId, uuid: cred.uuid, appToken: cred.appToken, ts: ts)
        let r = try await client.send(.get(base + "/unproved/file/redirect?" + Self.query(params), headers: Self.headers, followRedirects: false))
        let dlHeaders = ["User-Agent": Self.ua, "Referer": Self.webSite + "/", "Origin": Self.webSite]
        if (300..<400).contains(r.status), let location = r.header("Location"), !location.isEmpty {
            let resolved = URL(string: location, relativeTo: URL(string: base))?.absoluteString ?? location
            return DownloadLink(fileName: file.name, url: resolved, size: file.size > 0 ? file.size : -1, headers: dlHeaders)
        }
        if r.status == 401 || r.status == 403 { throw CloudnError("蓝奏优享登录已过期，请到「我的」页重新登录") }
        guard let json = r.json, json.isObject else { throw CloudnError("蓝奏优享未返回下载地址") }
        let code = json["code"].int
        if code == -1 || code == -2 { throw CloudnError("蓝奏优享登录已过期，请到「我的」页重新登录") }
        let link = json["url"].string.nilIfBlank ?? json["data"]["url"].string
        guard !link.isEmpty else {
            throw CloudnError(json["msg"].string.nilIfBlank ?? "蓝奏优享未返回下载地址，请检查文件权限")
        }
        return DownloadLink(fileName: file.name, url: link, size: file.size > 0 ? file.size : -1, headers: dlHeaders)
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        _ = try await proved("/proved/file/folder/save", requireAccount(), body: Self.folderBody(id: parentId, name: name, root: true))
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        let cred = try await requireAccount()
        if file.isDirectory {
            _ = try await proved("/proved/file/folder/edit", cred, body: Self.folderBody(id: file.fid, name: name, root: false))
        } else {
            _ = try await proved("/proved/file/edit", cred, body: .object([("fileDesc", .string("")), ("fileId", .string(Self.rawId(file.fid))),
                                                                            ("fileName", .string(name))]))
        }
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        let target = Self.rawId(folderId)
        let ids = Self.splitIds(files)
        _ = try await proved("/proved/file/folder/move", requireAccount(), body: .object([
            ("folderIds", .string(ids.folders)), ("fileIds", .string(ids.files)), ("targetId", .string(target.nilIfBlank ?? "0"))
        ]))
    }

    public func delete(_ files: [ShareFile]) async throws {
        guard !files.isEmpty else { return }
        let ids = Self.splitIds(files)
        _ = try await proved("/proved/file/delete", requireAccount(), body: .object([
            ("folderIds", .string(ids.folders)), ("fileIds", .string(ids.files)), ("status", .int(0))
        ]))
    }

    public func quota() async -> DriveQuota? {
        guard let cred = await account(), let json = try? await proved("/proved/user/account/map", cred) else { return nil }
        return Self.parseQuota(json["map"])
    }

    // MARK: 纯函数（便于单测）

    /// 去掉 d: / f: 前缀
    static func rawId(_ id: String) -> String {
        if id.hasPrefix(folderPrefix) { return String(id.dropFirst(folderPrefix.count)) }
        if id.hasPrefix(filePrefix) { return String(id.dropFirst(filePrefix.count)) }
        return id
    }

    /// 文件夹 / 文件 id 分别逗号拼接
    static func splitIds(_ files: [ShareFile]) -> (folders: String, files: String) {
        (files.filter(\.isDirectory).map { rawId($0.fid) }.joined(separator: ","),
         files.filter { !$0.isDirectory }.map { rawId($0.fid) }.joined(separator: ","))
    }

    /// 新建（root: 父目录为空时用 "0"）/ 重命名文件夹的请求体
    static func folderBody(id: String, name: String, root: Bool) -> OrderedJSON {
        let raw = rawId(id)
        return .object([("folderDesc", .string("")), ("folderId", .string(root ? (raw.nilIfBlank ?? "0") : raw)), ("folderName", .string(name))])
    }

    static func personalRedirectParams(fileId: String, userId: String, uuid: String, appToken: String, ts: String) -> [(String, String)] {
        let encTs = aesHex(ts)
        return [("uuid", uuid), ("devType", devType), ("devCode", uuid), ("devModel", "chrome"), ("devVersion", devVersion),
                ("appVersion", ""), ("timestamp", encTs), ("appToken", appToken),
                ("enable", "1"), ("downloadId", aesHex("\(fileId)|\(userId)")), ("auth", aesHex("\(fileId)|\(ts)")), ("timestamp", encTs)]
    }

    /// account/map：大小单位 KiB；总量 = totalSize + vipSize + rewardSize
    static func parseQuota(_ map: JSON) -> DriveQuota? {
        guard map.isObject else { return nil }
        let total = (map["totalSize"].int64 + map["vipSize"].int64 + map["rewardSize"].int64) * 1024
        guard total > 0 else { return nil }
        return DriveQuota(used: map["usedSize"].int64 * 1024, total: total)
    }
}
