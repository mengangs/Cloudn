// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 139 网盘（中国移动云盘）分享解析：getOutLinkInfoV6 匿名列目录 → 登录态 dlFromOutLinkV3 取直链。
// 分享接口的请求 / 响应都是 base64(IV ‖ AES-CBC(明文))，取链另需按明文 body 计算 mcloud-sign。
// 协议细节参考 YunX（AGPL-3.0）的 C139Api / C139Constants。
// 我的网盘管理参考 YunX（AGPL-3.0）的 C139Api / C139CloudViewModel：personal-kd-njs 的 /hcy/* 明文接口 + mcloud-sign。
import Foundation

public final class C139Resolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .c139 }
    public var supportsGuestDownload: Bool { false }

    public static let loginURL = "https://yun.139.com/m/#/login"
    public static let loginUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    /// 登录态 Cookie 分布在这两个域：fast login 的 Os_SSo_Sid / RMKEY 在 mail.10086.cn，authorization 在 yun.139.com
    public static let cookieDomains = ["mail.10086.cn", "yun.139.com", "139.com"]
    static let shareUA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"
    static let aesKey = Array("PVGDwmcvfs1uV3d1".utf8)

    private let credentials: CredentialStore
    private let client: HTTPClient
    private let shareBase: String
    private let personalBase: String

    public init(credentials: CredentialStore, client: HTTPClient = .shared, shareBase: String = "https://share-kd-njs.yun.139.com",
                personalBase: String = "https://personal-kd-njs.yun.139.com") {
        self.credentials = credentials
        self.client = client
        self.shareBase = shareBase
        self.personalBase = personalBase
    }

    private func url(_ name: String) -> String { "\(shareBase)/yun-share/richlifeApp/devapp/IOutLink/\(name)" }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        // getOutLinkGeneral 会明文回吐提取码（官方网页同样自动填），顺带拿标题
        let general = try? await post(url("getOutLinkGeneral"), .object([("getOutLinkGeneralReq", .object([
            ("linkID", .string(share.shareId)), ("isPasswd", .int(1)), ("account", .string(""))
        ]))]))
        let info = general.flatMap { Self.ok($0) ? $0["data"]["getOutLinkGeneralResp"]["outLinkGeneral"][0] : nil }
        let passwd = pwd?.nilIfBlank ?? share.pwd ?? info?["passwd"].string ?? ""
        let session = ShareSession(platform: .c139, shareId: share.shareId, stoken: passwd,
                                   title: info?["lkName"].string.nilIfBlank ?? "139 网盘分享", rootId: "root")
        // 先列一页根目录：提取码错误（9188）在这里暴露
        _ = try await listPage(session, dirId: "root", begin: 1, end: 50)
        return session
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let dir = dirId.isEmpty || dirId == "0" ? "root" : dirId
        var all: [ShareFile] = []
        var begin = 1
        while begin <= 20_000 {
            let batch = try await listPage(session, dirId: dir, begin: begin, end: begin + 199)
            all += batch
            if batch.count < 200 { break }
            begin += 200
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard let cookie = await credentials.cookie(for: .c139), Self.isValidCookie(cookie),
              let account = Self.account(in: cookie) else {
            throw CloudnError("139 网盘需要登录后才能下载，请到「我的」页登录 139 网盘")
        }
        let body = OrderedJSON.object([("dlFromOutLinkReqV3", .object([
            ("account", .string(account)), ("linkID", .string(session.shareId)),
            ("coIDLst", .object([("item", .array([.string(file.fid)]))])),
            ("commonAccountInfo", .object([("account", .string(account)), ("accountType", .int(1))]))
        ]))])
        let json = try await post(url("dlFromOutLinkV3"), body, authorization: Self.authorization(in: cookie), signed: true)
        guard Self.ok(json) else { throw CloudnError(Self.message(json, fallback: "获取下载链接失败")) }
        let link = json["data"]["redrUrl"].string
        guard !link.isEmpty else { throw CloudnError("139 网盘未返回下载链接") }
        return DownloadLink(fileName: file.name, url: link, size: file.size, headers: ["User-Agent": Self.shareUA])
    }

    // MARK: 列表

    private func listPage(_ session: ShareSession, dirId: String, begin: Int, end: Int) async throws -> [ShareFile] {
        // 列表端点必须匿名：account 为空串、不带鉴权头；字段缺一就报 9530
        let body = OrderedJSON.object([("getOutLinkInfoReq", .object([
            ("account", .string("")), ("linkID", .string(session.shareId)), ("passwd", .string(session.stoken)),
            ("caSrt", .int(1)), ("coSrt", .int(1)), ("srtDr", .int(0)), ("bNum", .int(Int64(begin))),
            ("pCaID", .string(dirId)), ("eNum", .int(Int64(end)))
        ]))])
        let json = try await post(url("getOutLinkInfoV6"), body)
        guard Self.ok(json) else {
            if json["resultCode"].string == "9188" { throw CloudnError("提取码错误，请检查后重新解析", code: 9188) }
            throw CloudnError(Self.message(json, fallback: "获取文件列表失败"))
        }
        return Self.parseList(json["data"], parent: dirId)
    }

    /// 子文件夹在 caLst，文件在 coLst（coType == 2 的 co 也是文件夹）
    static func parseList(_ data: JSON, parent: String) -> [ShareFile] {
        let folders = data["caLst"].array.map { item in
            ShareFile(fid: item["caID"].string, name: item["caName"].string, size: 0, isDirectory: true, parentId: parent,
                      modified: item.string("udTime", "ctTime"))
        }
        let files = data["coLst"].array.map { item in
            ShareFile(fid: item["coID"].string, name: item["coName"].string, size: item["coSize"].int64,
                      isDirectory: item.has("isdir") ? item["isdir"].bool : item["coType"].int == 2, parentId: parent,
                      modified: item.string("udTime", "ctTime"))
        }
        return folders + files
    }

    static func ok(_ json: JSON) -> Bool {
        let code = json["resultCode"].string
        if !code.isEmpty && code != "0" { return false }
        return !json.has("success") || json["success"].bool
    }

    static func message(_ json: JSON, fallback: String) -> String {
        json["desc"].string.nilIfBlank ?? "\(fallback)（\(json["resultCode"].string)）"
    }

    // MARK: 请求（AES-CBC 包装 + mcloud-sign）

    private func post(_ url: String, _ body: OrderedJSON, authorization: String? = nil, signed: Bool = false) async throws -> JSON {
        let plain = body.text
        var headers: [(String, String)] = [
            // 网关的解密开关，缺了业务层拿不到明文（9530）
            ("hcy-cool-flag", "1"),
            ("x-deviceinfo", "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||"),
            ("x-huawei-channelsrc", "10245500"), ("x-mm-source", "0002"),
            ("Content-Type", "application/json;charset=UTF-8"), ("User-Agent", Self.shareUA),
            ("Origin", "https://yun.139.com"), ("Referer", "https://yun.139.com/"), ("Accept", "application/json, text/plain, */*")
        ]
        if let authorization, !authorization.isEmpty { headers.append(("Authorization", authorization)) }
        if signed { headers.append(("mcloud-sign", Self.signHeader(plain))) }
        let r = try await client.send(HTTPRequest(url: url, method: "POST", headers: headers, body: Data(Self.encrypt(plain).utf8)))
        // 响应应为加密 base64；网关透传明文时兜底
        if let decrypted = Self.decrypt(r.text), let json = JSON(text: decrypted), json.isObject { return json }
        guard let json = r.json, json.isObject else { throw CloudnError("139 网盘响应解析失败（HTTP \(r.status)）") }
        return json
    }

    static func encrypt(_ plain: String, iv: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }) -> String {
        let cipher = AES(key: aesKey)!.encrypt(Array(plain.utf8), mode: .cbc(iv: iv))
        return Data(iv + cipher).base64EncodedString()
    }

    static func decrypt(_ text: String) -> String? {
        guard let raw = Crypto.base64Decode(text.trimmed), raw.count > 16 else { return nil }
        let bytes = [UInt8](raw)
        guard var plain = AES(key: aesKey)!.decrypt(Array(bytes[16...]), mode: .cbc(iv: Array(bytes[0..<16]))) else { return nil }
        if plain.count > 2, plain[0] == 0x1f, plain[1] == 0x8b {
            guard let unzipped = Gzip.decompress(plain) else { return nil }
            plain = unzipped
        }
        return String(decoding: plain, as: UTF8.self)
    }

    /// mcloud-sign = "<yyyy-MM-dd HH:mm:ss>,<16 位随机>,<sign>"
    static func signHeader(_ body: String, date: Date = Date(),
                           rand: String = String((0..<16).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = formatter.string(from: date)
        return "\(ts),\(rand),\(sign(body, ts: ts, rand: rand))"
    }

    /// encodeURIComponent(body) 逐字符升序 → base64 → md5，拼 md5("ts:rand") 再 md5，转大写
    static func sign(_ body: String, ts: String, rand: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        // 对齐 Java URLEncoder 后还原 ! ' ( ) *：保留这些字符，其余（含 "~"、空格）百分号编码
        allowed.insert(charactersIn: "-_.!*'()")
        let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
        let sorted = String(decoding: Array(encoded.utf8).sorted(), as: UTF8.self)
        let b64 = Data(sorted.utf8).base64EncodedString()
        return Crypto.md5Hex(Crypto.md5Hex(b64) + Crypto.md5Hex("\(ts):\(rand)")).uppercased()
    }

    // MARK: 登录态

    /// 有效登录态：网页版直接给的 authorization，或 fast login 的 Os_SSo_Sid + RMKEY
    public static func isValidCookie(_ cookie: String) -> Bool {
        if CookieUtil.value(of: "authorization", in: cookie)?.isEmpty == false { return true }
        return CookieUtil.value(of: "Os_SSo_Sid", in: cookie)?.isEmpty == false && CookieUtil.value(of: "RMKEY", in: cookie)?.isEmpty == false
    }

    static func authorization(in cookie: String) -> String? {
        CookieUtil.value(of: "authorization", in: cookie)?.removingPercentEncoding?.nilIfBlank
    }

    /// 完整手机号：ORCHES-I-ACCOUNT-ENCRYPT（base64）→ authorization（Basic base64(pc:账号:token)）→ Login_UserNumber
    static func account(in cookie: String) -> String? {
        if let v = CookieUtil.value(of: "ORCHES-I-ACCOUNT-ENCRYPT", in: cookie), let d = Crypto.base64Decode(v.removingPercentEncoding ?? v) {
            let s = String(decoding: d, as: UTF8.self).trimmed
            if !s.isEmpty { return s }
        }
        if let auth = authorization(in: cookie) {
            let b64 = auth.hasPrefix("Basic") ? String(auth.dropFirst(5)).trimmed : auth
            if let d = Crypto.base64Decode(b64) {
                let parts = String(decoding: d, as: UTF8.self).components(separatedBy: ":")
                if parts.count > 1, !parts[1].isEmpty { return parts[1] }
            }
        }
        return CookieUtil.value(of: "Login_UserNumber", in: cookie)?.nilIfBlank
    }

    /// 账号页展示用（优先脱敏手机号）
    public static func displayAccount(in cookie: String) -> String? {
        CookieUtil.value(of: "ORCHES-I-ACCOUNT-SIMPLIFY", in: cookie)?.removingPercentEncoding?.nilIfBlank ?? account(in: cookie)
    }
}

// MARK: - 转存到我的网盘

extension C139Resolver: ShareSaver {
    public var rootFolderId: String { "/" }

    /// 个人网盘接口（明文 JSON）：需要网页版登录给的 authorization
    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        guard let cookie = await credentials.cookie(for: .c139), let authorization = Self.authorization(in: cookie) else {
            throw CloudnError("请先到「我的」页用网页登录 139 网盘（需要 authorization）")
        }
        var all: [ShareFile] = []
        var cursor: OrderedJSON = .null
        for _ in 0..<50 {
            let body = Self.folderListBody(parentId: parentId, cursor: cursor)
            let headers = Self.personalHeaders(authorization: authorization) + [("mcloud-sign", Self.signHeader(body.text))]
            let r = try await client.send(HTTPRequest(url: personalBase + "/hcy/file/list", method: "POST", headers: headers,
                                                      body: Data(body.text.utf8)))
            guard let json = r.json, json.isObject else { throw CloudnError("139 网盘响应解析失败（HTTP \(r.status)）") }
            let code = json["code"].string
            guard (!json.has("success") || json["success"].bool) && (code == "0000" || code == "0") else {
                throw CloudnError(json["message"].string.nilIfBlank ?? "获取文件夹失败（\(code)）")
            }
            all += json["data"]["items"].array.map {
                ShareFile(fid: $0["fileId"].string, name: $0["name"].string, size: 0, isDirectory: true, parentId: parentId,
                          modified: $0["updatedAt"].string)
            }
            let next = json["data"]["nextPageCursor"].string
            if next.isEmpty || next == "null" { break }
            cursor = .string(next)
        }
        return all
    }

    /// 转存：创建批量任务（分享接口的加密包装）→ 轮询任务进度
    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        guard let cookie = await credentials.cookie(for: .c139), Self.isValidCookie(cookie), let account = Self.account(in: cookie) else {
            throw SharePlatform.c139.loginRequired
        }
        let authorization = Self.authorization(in: cookie)
        let task = Self.transferTaskBody(account: account, linkID: session.shareId, files: files, target: folderId)
        let created = try await post("\(shareBase)/yun-share/richlifeApp/devapp/IBatchOprTask/createOuterLinkBatchOprTask", task,
                                     authorization: authorization, signed: true)
        guard Self.ok(created) else { throw CloudnError(Self.message(created, fallback: "创建转存任务失败")) }
        let taskID = created["data"]["taskID"].string
        guard !taskID.isEmpty else { throw CloudnError("139 网盘未返回转存任务") }
        let query = OrderedJSON.object([("queryBatchOprTaskDetailReq", .object([
            ("taskID", .string(taskID)), ("msisdn", .string(account)),
            ("commonAccountInfo", .object([("account", .string(account)), ("accountType", .int(1))]))
        ]))])
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 800_000_000)
            guard let json = try? await post("\(shareBase)/yun-share/richlifeApp/devapp/IBatchOprTask/queryBatchOprTaskDetail", query,
                                             authorization: authorization, signed: true) else { continue }
            guard Self.ok(json) else { throw CloudnError(Self.message(json, fallback: "查询转存结果失败")) }
            let progress = json["data"]["batchOprTask"]
            if progress["progress"].int >= 100 && progress["taskStatus"].int == 2 { return }
        }
        throw CloudnError("转存仍在进行，请稍后到 139 网盘里查看")
    }

    /// 文件放 contentInfoList（"/<coID>"），文件夹放 catalogInfoList；字段顺序参与签名，保持与官方一致
    static func transferTaskBody(account: String, linkID: String, files: [ShareFile], target: String) -> OrderedJSON {
        let contents = files.filter { !$0.isDirectory }.map { OrderedJSON.string("/" + $0.fid) }
        let catalogs = files.filter(\.isDirectory).map { OrderedJSON.string($0.fid) }
        return .object([
            ("createOuterLinkBatchOprTaskReq", .object([
                ("msisdn", .string(account)), ("ownerAccount", .string("")), ("taskType", .int(1)),
                ("taskInfo", .object([
                    ("contentInfoList", .array(contents)), ("catalogInfoList", .array(catalogs)), ("newCatalogID", .string(target)),
                    ("linkID", .string(linkID)), ("newCatalogName", .string("手机图片")), ("needPassword", .bool(true))
                ])),
                ("linkID", .string(linkID)), ("needPassword", .bool(true))
            ])),
            ("commonAccountInfo", .object([("account", .string(account)), ("accountType", .int(1))]))
        ])
    }

    static func folderListBody(parentId: String, cursor: OrderedJSON) -> OrderedJSON {
        .object([
            ("pageInfo", .object([("pageSize", .int(100)), ("pageCursor", cursor)])),
            ("orderBy", .string("updated_at")), ("orderDirection", .string("DESC")), ("parentFileId", .string(parentId)),
            ("imageThumbnailStyleList", .array([.string("Small"), .string("Large")])), ("type", .string("folder"))
        ])
    }

    /// 个人网盘网关必需的渠道 / 上下文头（缺任何一个都会 04000005 认证失败；值取自官方网页抓包）
    static func personalHeaders(authorization: String) -> [(String, String)] {
        let clientInfo = "||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||"
        return [
            ("Authorization", authorization),
            ("x-yun-channel-source", "10000034"), ("x-yun-app-channel", "10000034"), ("x-huawei-channelSrc", "10000034"),
            ("mcloud-version", "7.17.9"), ("mcloud-client", "10701"), ("mcloud-channel", "1000101"), ("mcloud-route", "001"),
            ("x-yun-module-type", "100"), ("x-yun-api-version", "v1"), ("x-yun-svc-type", "1"), ("x-SvcType", "1"),
            ("caller", "web"), ("x-inner-ntwk", "2"), ("CMS-DEVICE", "default"), ("x-m4c-src", "10002"), ("x-m4c-caller", "PC"),
            ("X-Deviceinfo", clientInfo), ("x-yun-client-info", clientInfo + "dW5kZWZpbmVk||"), ("INNER-HCY-ROUTER-HTTPS", "1"),
            ("Content-Type", "application/json;charset=UTF-8"),
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
            ("Origin", "https://yun.139.com"), ("Referer", "https://yun.139.com/"), ("Accept", "application/json, text/plain, */*")
        ]
    }
}

// MARK: - 我的网盘管理

extension C139Resolver: DriveManager {
    public var driveRootId: String { "/" }

    static let outLinkURL = "https://yun.139.com/orchestration/personalCloud-rebuild/outlink/v1.0/getOutLink"
    static let quotaURL = "https://user-njs.yun.139.com/user/disk/quota/detail"
    static let pcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// POST /hcy/file/list：nextPageCursor 为 null 即末页；按 updated_at 翻页可能回吐边界项，按 fid 去重
    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        let authorization = try await driveAuth().authorization
        let parent = folderId.isEmpty || folderId == "0" ? "/" : folderId
        var all: [ShareFile] = []
        var seen = Set<String>()
        var cursor: OrderedJSON = .null
        var last = ""
        for _ in 0..<200 {
            let json = try await personalPost(personalBase + "/hcy/file/list", Self.driveListBody(parentId: parent, cursor: cursor),
                                              authorization: authorization, fallback: "获取文件列表失败")
            all += Self.parseDriveList(json["data"], parent: parent).filter { !$0.fid.isEmpty && seen.insert($0.fid).inserted }
            let next = json["data"]["nextPageCursor"].string
            if next.isEmpty || next == "null" || next == last { break }
            last = next
            cursor = .string(next)
        }
        return all
    }

    /// POST /hcy/file/getDownloadUrl：OBS 预签名直链（900 秒有效），响应不带文件名，用列表里的
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        let authorization = try await driveAuth().authorization
        let json = try await personalPost(personalBase + "/hcy/file/getDownloadUrl", .object([("fileId", .string(file.fid))]),
                                          authorization: authorization, fallback: "获取下载链接失败")
        let link = json["data"]["url"].string
        guard !link.isEmpty else { throw CloudnError("139 网盘未返回下载链接") }
        let size = file.size > 0 ? file.size : json["data"]["size"].int64
        return DownloadLink(fileName: file.name.nilIfBlank ?? json["data"]["name"].string, url: link, size: size,
                            headers: ["User-Agent": Self.pcUA, "Referer": "https://yun.139.com/"])
    }

    /// POST /hcy/file/create（type=folder，重名由服务端自动改名）
    public func createFolder(_ name: String, in parentId: String) async throws {
        let authorization = try await driveAuth().authorization
        _ = try await personalPost(personalBase + "/hcy/file/create", Self.createFolderBody(name: name, parentId: parentId.nilIfBlank ?? "/"),
                                   authorization: authorization, fallback: "新建文件夹失败")
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        let authorization = try await driveAuth().authorization
        let body = OrderedJSON.object([("fileId", .string(file.fid)), ("name", .string(name)), ("description", .string(""))])
        _ = try await personalPost(personalBase + "/hcy/file/update", body, authorization: authorization, fallback: "重命名失败")
    }

    /// POST /hcy/file/batchMove → 异步任务轮询
    public func move(_ files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        let authorization = try await driveAuth().authorization
        let body = OrderedJSON.object([("fileIds", .array(files.map { OrderedJSON.string($0.fid) })), ("toParentFileId", .string(folderId.nilIfBlank ?? "/"))])
        let json = try await personalPost(personalBase + "/hcy/file/batchMove", body, authorization: authorization, fallback: "移动失败")
        try await waitTask(json["data"]["taskId"].string, authorization: authorization)
    }

    /// POST /hcy/recyclebin/batchTrash（移入回收站）→ 异步任务轮询
    public func delete(_ files: [ShareFile]) async throws {
        guard !files.isEmpty else { return }
        let authorization = try await driveAuth().authorization
        let body = OrderedJSON.object([("fileIds", .array(files.map { OrderedJSON.string($0.fid) }))])
        let json = try await personalPost(personalBase + "/hcy/recyclebin/batchTrash", body, authorization: authorization, fallback: "删除失败")
        try await waitTask(json["data"]["taskId"].string, authorization: authorization)
    }

    /// orchestration getOutLink：需 Cookie + mcloud-skey；永久有效，提取码由服务端生成
    public func createShare(_ files: [ShareFile]) async throws -> DriveShareLink {
        guard !files.isEmpty else { throw CloudnError("请选择要分享的文件") }
        let (cookie, authorization) = try await driveAuth()
        guard let account = Self.account(in: cookie) else { throw SharePlatform.c139.loginRequired }
        let name = files.count == 1 ? files[0].name : "分享 \(files.count) 个文件"
        let body = Self.outLinkBody(account: account, files: files, name: name)
        let json = try await personalPost(Self.outLinkURL, body, authorization: authorization, cookie: cookie, skey: true, fallback: "创建分享失败")
        guard let link = Self.parseOutLink(json["data"]) else { throw CloudnError("创建分享失败：未返回链接") }
        return link
    }

    /// user/disk/quota/detail：diskSize / quotaList[0].usedSize（单位 MB）
    public func quota() async -> DriveQuota? {
        guard let cookie = await credentials.cookie(for: .c139), let authorization = Self.authorization(in: cookie),
              let account = Self.account(in: cookie) else { return nil }
        let body = OrderedJSON.object([
            ("userDomainId", .string("")),
            ("commonAccountInfo", .object([("account", .string(account)), ("accountType", .int(1))]))
        ])
        guard let json = try? await personalPost(Self.quotaURL, body, authorization: authorization, cookie: cookie, skey: true,
                                                 fallback: "获取空间详情失败") else { return nil }
        return Self.parseQuota(json["data"])
    }

    // MARK: 内部

    private func driveAuth() async throws -> (cookie: String, authorization: String) {
        guard let cookie = await credentials.cookie(for: .c139), let authorization = Self.authorization(in: cookie) else {
            throw SharePlatform.c139.loginRequired
        }
        return (cookie, authorization)
    }

    /// 个人网盘明文 POST：渠道头 + mcloud-sign（按明文 body）；分享 / 容量另带 Cookie + mcloud-skey；成功判定 success 且 code ∈ {"0000","0"}
    private func personalPost(_ url: String, _ body: OrderedJSON, authorization: String, cookie: String? = nil, skey: Bool = false,
                              fallback: String) async throws -> JSON {
        let plain = body.text
        var headers = Self.personalHeaders(authorization: authorization) + [
            ("mcloud-sign", Self.signHeader(plain)),
            ("Sec-Fetch-Site", "same-site"), ("Sec-Fetch-Mode", "cors"), ("Sec-Fetch-Dest", "empty")
        ]
        if let cookie, !cookie.isEmpty {
            headers.append(("Cookie", cookie))
            if skey, let value = CookieUtil.value(of: "skey", in: cookie)?.nilIfBlank { headers.append(("mcloud-skey", value)) }
        }
        let r = try await client.send(HTTPRequest(url: url, method: "POST", headers: headers, body: Data(plain.utf8)))
        guard let json = r.json, json.isObject else { throw CloudnError("139 网盘响应解析失败（HTTP \(r.status)）") }
        try Self.checkPersonal(json, fallback: fallback)
        return json
    }

    /// POST /hcy/task/get：status == "Succeed" 或 progress >= 100 即完成；batchFileResults 有非 0000 errCode 视为失败
    private func waitTask(_ taskId: String, authorization: String) async throws {
        guard !taskId.isEmpty else { return }
        try await Task.sleep(nanoseconds: 500_000_000)
        for _ in 0..<30 {
            let json = try await personalPost(personalBase + "/hcy/task/get", .object([("taskId", .string(taskId))]),
                                              authorization: authorization, fallback: "查询任务失败")
            if try Self.taskFinished(json["data"]) { return }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        throw CloudnError("139 网盘任务超时，请稍后刷新查看")
    }

    static func checkPersonal(_ json: JSON, fallback: String) throws {
        let code = json["code"].string
        if (!json.has("success") || json["success"].bool) && (code == "0000" || code == "0") { return }
        throw CloudnError(json["message"].string.nilIfBlank ?? "\(fallback)（\(code)）")
    }

    /// 任务完成返回 true，未完成 false，失败抛错
    static func taskFinished(_ data: JSON) throws -> Bool {
        let info = data["taskInfo"]
        if info["status"].string == "Succeed" || info["progress"].int >= 100 { return true }
        if let failed = data["batchFileResults"].array.first(where: { !$0["errCode"].string.isEmpty && $0["errCode"].string != "0000" }) {
            throw CloudnError("139 网盘任务失败（\(failed["errCode"].string)）")
        }
        return false
    }

    /// 与 folderListBody 相同但不限定 type（文件 + 文件夹）；pageCursor 首页必须是真正的 JSON null
    static func driveListBody(parentId: String, cursor: OrderedJSON) -> OrderedJSON {
        .object([
            ("pageInfo", .object([("pageSize", .int(100)), ("pageCursor", cursor)])),
            ("orderBy", .string("updated_at")), ("orderDirection", .string("DESC")), ("parentFileId", .string(parentId)),
            ("imageThumbnailStyleList", .array([.string("Small"), .string("Large")]))
        ])
    }

    /// data.items[]：type == "folder" 为文件夹；token 存 fileId（取链只要 fileId）
    static func parseDriveList(_ data: JSON, parent: String) -> [ShareFile] {
        data["items"].array.map {
            ShareFile(fid: $0["fileId"].string, name: $0["name"].string, size: $0["size"].int64, isDirectory: $0["type"].string == "folder",
                      parentId: parent, token: $0["fileId"].string, modified: $0["updatedAt"].string)
        }
    }

    static func createFolderBody(name: String, parentId: String) -> OrderedJSON {
        .object([("parentFileId", .string(parentId)), ("name", .string(name)), ("description", .string("")),
                 ("type", .string("folder")), ("fileRenameMode", .string("force_rename"))])
    }

    /// 文件进 coIDLst、文件夹进 caIDLst；不传 period = 永久
    static func outLinkBody(account: String, files: [ShareFile], name: String) -> OrderedJSON {
        .object([("getOutLinkReq", .object([
            ("subLinkType", .int(0)), ("encrypt", .int(1)),
            ("coIDLst", .array(files.filter { !$0.isDirectory }.map { OrderedJSON.string($0.fid) })),
            ("caIDLst", .array(files.filter(\.isDirectory).map { OrderedJSON.string($0.fid) })),
            ("pubType", .int(1)), ("dedicatedName", .string(name)), ("periodUnit", .int(1)), ("viewerLst", .array([])),
            ("extInfo", .object([("isWatermark", .int(0)), ("shareChannel", .string("3001"))])),
            ("commonAccountInfo", .object([("account", .string(account)), ("accountType", .int(1))]))
        ]))])
    }

    /// data.getOutLinkRes.getOutLinkResSet[0] → linkUrl / passwd
    static func parseOutLink(_ data: JSON) -> DriveShareLink? {
        let set = data["getOutLinkRes"]["getOutLinkResSet"][0]
        let url = set["linkUrl"].string
        return url.isEmpty ? nil : DriveShareLink(url: url, pwd: set["passwd"].string)
    }

    /// 已用优先取 quotaList[0].usedSize（个人云），否则 diskSize - freeDiskSize
    static func parseQuota(_ data: JSON) -> DriveQuota? {
        guard data.isObject else { return nil }
        let mb: Int64 = 1024 * 1024
        let total = data["diskSize"].int64 * mb
        let first = data["quotaList"][0]
        let used = first.isObject ? first["usedSize"].int64 * mb : total - data["freeDiskSize"].int64 * mb
        return DriveQuota(used: used, total: total)
    }
}
