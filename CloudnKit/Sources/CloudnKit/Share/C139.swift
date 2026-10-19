// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 139 网盘（中国移动云盘）分享解析：getOutLinkInfoV6 匿名列目录 → 登录态 dlFromOutLinkV3 取直链。
// 分享接口的请求 / 响应都是 base64(IV ‖ AES-CBC(明文))，取链另需按明文 body 计算 mcloud-sign。
// 协议细节参考 YunX（AGPL-3.0）的 C139Api / C139Constants。
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

    public init(credentials: CredentialStore, client: HTTPClient = .shared, shareBase: String = "https://share-kd-njs.yun.139.com") {
        self.credentials = credentials
        self.client = client
        self.shareBase = shareBase
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
            throw CloudnError("139 网盘需要登录后才能下载，请到「账号」页登录 139 网盘")
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
