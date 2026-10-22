// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// PikPak：分享解析（drive/v1/share → share/detail 列目录 → share/file_info 取直链）、账号密码登录、令牌续期与人机验证令牌。
// 协议细节参考 OpenList（AGPL-3.0）的 drivers/pikpak、drivers/pikpak_share：
// client_id / client_secret / captcha_sign 盐表 / 自定义 UA（devicesign）、/v1/shield/captcha/init、/v1/auth/signin、/v1/auth/token，
// 错误码 16 / 4121 / 4122（令牌过期）、9（验证令牌过期）、4126（refresh_token 失效）；
// 分享转存 share/restore 与创建分享 POST drive/v1/share 参考 Quan666/PikPakAPI（MIT）。
// 我的网盘、转存、上传、离线下载见 PikPakDrive.swift。
import Foundation

// MARK: - 客户端参数

/// PikPak 官方客户端的标识与签名参数（OpenList drivers/pikpak/util.go）
struct PikPakClientInfo: Equatable, Sendable {
    let name: String
    let id: String
    let secret: String
    let version: String
    let packageName: String
    let sdkVersion: String
    let algorithms: [String]

    static let android = PikPakClientInfo(
        name: "android", id: "YNxT9w7GMdWvEOKa", secret: "dbw2OtmVEeuUvIptb1Coyg", version: "1.53.2",
        packageName: "com.pikcloud.pikpak", sdkVersion: "2.0.6.206003",
        algorithms: [
            "SOP04dGzk0TNO7t7t9ekDbAmx+eq0OI1ovEx", "nVBjhYiND4hZ2NCGyV5beamIr7k6ifAsAbl",
            "Ddjpt5B/Cit6EDq2a6cXgxY9lkEIOw4yC1GDF28KrA", "VVCogcmSNIVvgV6U+AochorydiSymi68YVNGiz",
            "u5ujk5sM62gpJOsB/1Gu/zsfgfZO", "dXYIiBOAHZgzSruaQ2Nhrqc2im", "z5jUTBSIpBN9g4qSJGlidNAutX6", "KJE2oveZ34du/g1tiimm",
        ])

    static let web = PikPakClientInfo(
        name: "web", id: "YUMx5nI8ZU8Ap8pm", secret: "dbw2OtmVEeuUvIptb1Coyg", version: "2.0.0",
        packageName: "mypikpak.com", sdkVersion: "8.0.3",
        algorithms: [
            "C9qPpZLN8ucRTaTiUMWYS9cQvWOE", "+r6CQVxjzJV6LCV", "F", "pFJRC", "9WXYIDGrwTCz2OiVlgZa90qpECPD6olt", "/750aCr4lm/Sly/c",
            "RB+DT/gZCrbV", "", "CyLsf7hdkIRxRm215hl", "7xHvLi2tOYP0Y92b", "ZGTXXxu8E/MIWaEDB+Sm/", "1UI3",
            "E7fP5Pfijd+7K+t6Tg/NhuLq0eEUVChpJSkrKxpO", "ihtqpG6FMt65+Xk+tWUH2", "NhXXU9rg4XXdzo7u5o",
        ])

    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36"

    static func named(_ name: String) -> PikPakClientInfo? {
        switch name {
        case "android": return .android
        case "web": return .web
        default: return nil
        }
    }

    /// captcha_sign = "1." + 依次 md5(上一轮 + 盐)，初值为 client_id + version + package + device_id + 毫秒时间戳
    func captchaSign(deviceId: String, timestamp: String) -> String {
        var s = id + version + packageName + deviceId + timestamp
        for salt in algorithms { s = Crypto.md5Hex(s + salt) }
        return "1." + s
    }

    /// devicesign = "div101." + device_id + md5(sha1(device_id + package + "1" + "appkey"))
    static func deviceSign(deviceId: String, packageName: String) -> String {
        "div101." + deviceId + Crypto.md5Hex(Crypto.sha1Hex(deviceId + packageName + "1appkey"))
    }

    /// 安卓客户端的自定义 UA（BuildCustomUserAgent）；网页客户端用桌面浏览器 UA
    func userAgent(deviceId: String, userId: String, now: Date = Date()) -> String {
        guard name == "android" else { return Self.webUA }
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let parts = [
            "ANDROID-\(packageName)/\(version)", "protocolVersion/200", "accesstype/", "clientid/\(id)", "clientversion/\(version)",
            "action_type/", "networktype/WIFI", "sessionid/", "deviceid/\(deviceId)", "providername/NONE",
            "devicesign/\(Self.deviceSign(deviceId: deviceId, packageName: packageName))", "refresh_token/", "sdkversion/\(sdkVersion)",
            "datetime/\(ms)", "usrno/\(userId)", "appname/android-\(packageName)", "session_origin/", "grant_type/", "appid/", "clientip/",
            "devicename/Xiaomi_M2004j7ac", "osversion/13", "platformversion/10", "accessmode/", "devicemodel/M2004J7AC",
        ]
        return parts.joined(separator: " ") + " "
    }
}

// MARK: - 凭据

/// PikPak 登录凭据，以 JSON 存在账号的 Cookie 槽位里；也接受手动粘贴的裸 refresh_token
public struct PikPakCredential: Equatable, Sendable {
    public var refreshToken: String
    public var accessToken: String
    /// access_token 过期时间（Unix 秒）；0 为未知
    public var expiresAt: Int64
    public var deviceId: String
    public var captchaToken: String
    public var userId: String
    public var username: String
    /// 令牌所属的客户端（android / web）；空 = 未知（裸 refresh_token），续期时依次尝试
    public var client: String

    public init(refreshToken: String, accessToken: String = "", expiresAt: Int64 = 0, deviceId: String = "", captchaToken: String = "",
                userId: String = "", username: String = "", client: String = "") {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.deviceId = deviceId
        self.captchaToken = captchaToken
        self.userId = userId
        self.username = username
        self.client = client
    }

    static let tokenRx = Rx(#"^[A-Za-z0-9._~+/=-]+$"#)

    public static func parse(_ raw: String) -> PikPakCredential? {
        var text = raw.trimmed
        if text.hasPrefix("\""), let unquoted = JSON(text: text)?.raw as? String { text = unquoted.trimmed }
        guard !text.isEmpty else { return nil }
        if !text.hasPrefix("{") {
            // 裸 refresh_token（形如 os.xxxx）
            guard (16...4096).contains(text.count), tokenRx.matches(text) else { return nil }
            return PikPakCredential(refreshToken: text)
        }
        guard let json = JSON(text: text), json.isObject else { return nil }
        let refresh = json.string("refresh_token", "refreshToken")
        guard !refresh.isEmpty, tokenRx.matches(refresh) else { return nil }
        // 网页 localStorage 里的 expires_at 是 ISO 时间串，取不到数字就留 0（再看 JWT 的 exp）
        var expires = json["expires_at"].int64
        if expires == 0 { expires = json["expiry"].int64 }
        let access = json.string("access_token", "accessToken")
        var client = PikPakClientInfo.named(json["client"].string)?.name ?? ""
        if client.isEmpty { client = clientName(fromAccessToken: access) }
        return PikPakCredential(refreshToken: refresh, accessToken: access, expiresAt: expires,
                                deviceId: json.string("device_id", "deviceId"), captchaToken: json.string("captcha_token", "captchaToken"),
                                userId: json.string("user_id", "sub"), username: json.string("username", "user_name"), client: client)
    }

    /// access_token（JWT）的 aud 是签发它的 client_id：从网页复制的凭据据此认出网页客户端
    static func clientName(fromAccessToken token: String) -> String {
        let aud = XunleiCredential.jwtClaim(token, "aud").string
        return [PikPakClientInfo.android, .web].first { $0.id == aud }?.name ?? ""
    }

    public var serialized: String {
        OrderedJSON.object([
            ("refresh_token", .string(refreshToken)), ("access_token", .string(accessToken)), ("expires_at", .int(expiresAt)),
            ("device_id", .string(deviceId)), ("captcha_token", .string(captchaToken)), ("user_id", .string(userId)),
            ("username", .string(username)), ("client", .string(client)),
        ]).text
    }

    /// access_token 的过期时间：没存就看 JWT 里的 exp
    var accessExpiry: Int64 {
        if expiresAt > 0 { return expiresAt }
        return XunleiCredential.jwtClaim(accessToken, "exp").int64
    }

    /// 需要先续期：没有 access_token、刚被服务端拒绝、或 5 分钟内过期
    func needsRefresh(rejecting rejected: String? = nil, now: Date = Date()) -> Bool {
        if accessToken.isEmpty || accessToken == rejected { return true }
        let exp = accessExpiry
        return exp > 0 && exp - 300 < Int64(now.timeIntervalSince1970)
    }

    var clientInfo: PikPakClientInfo { PikPakClientInfo.named(client) ?? .android }
}

// MARK: - 认证接口

enum PikPakAuth {
    static let userBase = "https://user.mypikpak.net"
    static let expiredCode = 4126
    static var expired: CloudnError { CloudnError("PikPak 登录已失效，请到「我的」页重新登录", code: expiredCode) }

    /// 本机固定的设备号（重复登录不被当成新设备）
    static var localDevice: String { DeviceFingerprint.hex("pikpak.device") }

    /// OpenList GetAction：METHOD:路径（不含域名与查询串）
    static func action(_ method: String, _ url: String) -> String {
        method + ":" + (Rx(#"://[^/]+((?:/[^/\s?#]+)*)"#).first(in: url) ?? "")
    }

    /// 登录前的 captcha meta：邮箱 / 手机号 / 用户名三选一
    static func loginMeta(_ username: String) -> [(String, OrderedJSON)] {
        if Rx(#"\w+([-+.]\w+)*@\w+([-.]\w+)*\.\w+([-.]\w+)*"#).matches(username) { return [("email", .string(username))] }
        if (11...18).contains(username.count) && username.allSatisfy({ $0.isNumber || $0 == "+" || $0 == " " }) {
            return [("phone_number", .string(username))]
        }
        return [("username", .string(username))]
    }

    static func captchaBody(action: String, captcha: String, client: PikPakClientInfo, deviceId: String,
                            meta: [(String, OrderedJSON)], timestamp: String) -> OrderedJSON {
        let sign: [(String, OrderedJSON)] = [("client_version", .string(client.version)), ("package_name", .string(client.packageName)),
                                             ("timestamp", .string(timestamp)),
                                             ("captcha_sign", .string(client.captchaSign(deviceId: deviceId, timestamp: timestamp)))]
        return .object([
            ("action", .string(action)), ("captcha_token", .string(captcha)), ("client_id", .string(client.id)),
            ("device_id", .string(deviceId)), ("meta", .object(meta + sign)),
            ("redirect_uri", .string("xlaccsdk01://xbase.cloud/callback?state=harbor")),
        ])
    }

    static func headers(_ client: PikPakClientInfo, deviceId: String, userId: String, access: String = "", captcha: String = "") -> [(String, String)] {
        var h: [(String, String)] = [("User-Agent", client.userAgent(deviceId: deviceId, userId: userId)), ("X-Device-ID", deviceId),
                                     ("X-Client-ID", client.id), ("Content-Type", "application/json; charset=utf-8"),
                                     ("Accept-Language", "zh-CN")]
        if !access.isEmpty { h.append(("Authorization", "Bearer " + access)) }
        if !captcha.isEmpty { h.append(("X-Captcha-Token", captcha)) }
        return h
    }

    /// /v1/shield/captcha/init：返回新的验证令牌；服务端要求人机验证（给了 url 且没给令牌）时报错
    static func initCaptcha(action: String, meta: [(String, OrderedJSON)], captcha: String, client: PikPakClientInfo, deviceId: String,
                            userId: String, access: String, http: HTTPClient, strict: Bool) async throws -> String {
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let body = captchaBody(action: action, captcha: captcha, client: client, deviceId: deviceId, meta: meta, timestamp: ts)
        let req = HTTPRequest(url: userBase + "/v1/shield/captcha/init?client_id=" + client.id, method: "POST",
                              headers: headers(client, deviceId: deviceId, userId: userId, access: access), body: Data(body.text.utf8))
        let r = try await http.send(req)
        guard let json = r.json, json.isObject else { throw CloudnError("PikPak 验证初始化失败（HTTP \(r.status)）") }
        if isError(json) { throw error(json, status: r.status) }
        let token = json["captcha_token"].string
        if !json["url"].string.isEmpty && (strict || token.isEmpty) {
            throw CloudnError("PikPak 要求完成人机验证，请稍后重试，或先在官方 App 登录一次")
        }
        guard !token.isEmpty else { throw CloudnError("PikPak 验证初始化失败，请稍后重试") }
        return token
    }

    /// 用 refresh_token 换新的 access_token（refresh_token 同时换新）。令牌所属客户端未知时依次尝试安卓与网页客户端
    static func refresh(_ cred: PikPakCredential, client http: HTTPClient) async throws -> PikPakCredential {
        let candidates = PikPakClientInfo.named(cred.client).map { [$0] } ?? [.android, .web]
        let device = cred.deviceId.nilIfBlank ?? localDevice
        var lastError: CloudnError = expired
        for info in candidates {
            let body = OrderedJSON.object([("client_id", .string(info.id)), ("client_secret", .string(info.secret)),
                                           ("grant_type", .string("refresh_token")), ("refresh_token", .string(cred.refreshToken))])
            let r = try await http.send(HTTPRequest(url: userBase + "/v1/auth/token?client_id=" + info.id, method: "POST",
                                                    headers: [("Content-Type", "application/json; charset=utf-8"), ("X-Device-ID", device),
                                                              ("Accept-Language", "zh-CN")],
                                                    body: Data(body.text.utf8)))
            // 限流 / 服务端故障不是登录失效
            if r.status == 429 || r.status >= 500 { throw CloudnError("PikPak 登录续期失败（HTTP \(r.status)），请稍后重试") }
            guard let json = r.json, json.isObject else { throw CloudnError("PikPak 登录续期失败（HTTP \(r.status)）") }
            if let renewed = applyToken(json, to: cred, client: info, deviceId: device) { return renewed }
            lastError = isAuthError(json) || json["error_code"].int == expiredCode || json["error"].string == "invalid_grant"
                ? expired : error(json, status: r.status)
        }
        throw lastError
    }

    /// 登录 / 续期响应 → 凭据；没拿到令牌返回 nil
    static func applyToken(_ json: JSON, to cred: PikPakCredential, client: PikPakClientInfo, deviceId: String,
                           now: Date = Date()) -> PikPakCredential? {
        let access = json["access_token"].string
        let refresh = json["refresh_token"].string
        guard !access.isEmpty, !isError(json) else { return nil }
        var out = cred
        out.accessToken = access
        out.refreshToken = refresh.nilIfBlank ?? cred.refreshToken
        let lifetime = json["expires_in"].int64 > 0 ? json["expires_in"].int64 : 7200
        out.expiresAt = Int64(now.timeIntervalSince1970) + lifetime
        out.userId = json["sub"].string.nilIfBlank ?? cred.userId
        out.deviceId = deviceId
        out.client = client.name
        return out
    }

    /// GET /v1/user/me 的昵称；令牌无效返回 nil
    static func nickname(_ cred: PikPakCredential, client http: HTTPClient) async -> String? {
        let info = cred.clientInfo
        let device = cred.deviceId.nilIfBlank ?? localDevice
        guard !cred.accessToken.isEmpty,
              let r = try? await http.send(.get(userBase + "/v1/user/me",
                                                headers: headers(info, deviceId: device, userId: cred.userId, access: cred.accessToken))),
              r.isSuccess, let json = r.json, !isError(json), !json["sub"].string.isEmpty || !json["name"].string.isEmpty else { return nil }
        return displayName(json, fallback: cred.username)
    }

    static func displayName(_ me: JSON, fallback: String) -> String {
        me.string("name", "email", "phone_number").nilIfBlank ?? fallback.nilIfBlank ?? "PikPak 用户"
    }

    // MARK: 错误

    static func isError(_ json: JSON) -> Bool {
        json["error_code"].int != 0 || !json["error"].string.isEmpty
    }

    /// access_token 过期 / 无效
    static func isAuthError(_ json: JSON) -> Bool {
        [16, 4121, 4122].contains(json["error_code"].int) || json["error"].string == "unauthenticated"
    }

    /// 验证令牌过期 / 无效
    static func isCaptchaError(_ json: JSON) -> Bool {
        json["error_code"].int == 9 || json["error"].string.lowercased().contains("captcha")
    }

    static func error(_ json: JSON, status: Int) -> CloudnError {
        let code = json["error_code"].int
        let err = json["error"].string
        let desc = json.string("error_description", "error_message", "message")
        switch err {
        case "invalid_account_or_password": return CloudnError("PikPak 账号或密码错误")
        case "invalid_grant": return expired
        case "unauthenticated": return CloudnError("PikPak 登录已失效，请到「我的」页重新登录", code: expiredCode)
        case "file_space_not_enough": return CloudnError("PikPak 网盘空间不足")
        case "file_not_found", "file_in_recycle_bin": return CloudnError("PikPak 文件不存在或已删除")
        case "permission_denied": return CloudnError("PikPak：没有权限执行该操作")
        case let e where e.hasPrefix("task_daily_create_limit") || e.hasPrefix("task_run_nums_limit"):
            return CloudnError("PikPak 今日离线次数已用完（免费账号有限额）")
        default: break
        }
        if isCaptchaError(json) { return CloudnError("PikPak 人机验证未通过，请稍后重试") }
        if code == 10 { return CloudnError(desc.nilIfBlank.map { "PikPak：\($0)" } ?? "PikPak 操作过于频繁，请稍后再试") }
        if [16, 4121, 4122].contains(code) { return CloudnError("PikPak 登录已失效，请到「我的」页重新登录", code: expiredCode) }
        return CloudnError("PikPak：" + (desc.nilIfBlank ?? err.nilIfBlank ?? "请求失败（HTTP \(status)）"))
    }
}

// MARK: - 解析器

public final class PikPakResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .pikpak }
    public var supportsGuestDownload: Bool { false }

    static let downloadUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    let credentials: CredentialStore
    let client: HTTPClient
    let api: String
    let state = State()

    actor State {
        /// 账号（用户 id + 设备号）→ 最近一次初始化出的验证令牌
        var captchas: [String: String] = [:]
        /// shareId → 提取码（pass_code_token 失效时重新换）
        var passCodes: [String: String] = [:]
        /// shareId → 最新的 pass_code_token
        var passTokens: [String: String] = [:]
        func captcha(_ key: String) -> String? { captchas[key] }
        func setCaptcha(_ key: String, _ v: String) { captchas[key] = v }
        func setPass(_ id: String, code: String, token: String) { passCodes[id] = code; passTokens[id] = token }
        func setPassToken(_ id: String, _ token: String) { passTokens[id] = token }
    }

    /// 一次请求的身份
    struct Identity: Sendable {
        let access: String
        let deviceId: String
        let userId: String
        let client: PikPakClientInfo
        var captcha: String
        var captchaKey: String { userId + "|" + deviceId }
    }

    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared, api: String = "https://api-drive.mypikpak.net") {
        self.credentials = credentials
        self.client = client
        self.api = api
    }

    // MARK: 链接识别

    static let linkRx = Rx(#"(?:^|[/.])mypikpak\.(?:com|net)/s/([A-Za-z0-9_-]{6,})(?:/([A-Za-z0-9_-]{6,}))?"#, ignoreCase: true)
    static let pwdRx = Rx(#"[?&#](?:pwd|pass_code|passcode|password)=([A-Za-z0-9]+)"#, ignoreCase: true)

    /// mypikpak.com/s/<分享 id>[/<子文件夹 id>][?pwd=提取码]
    static func shareTarget(_ url: String) -> (id: String, pwd: String?)? {
        guard let m = linkRx.firstMatch(in: url), !m[1].isEmpty else { return nil }
        return (m[1], pwdRx.first(in: url))
    }

    /// 链接里直接指向分享内的某个文件夹
    static func folderId(in url: String) -> String? {
        linkRx.firstMatch(in: url).flatMap { $0[2].nilIfBlank }
    }

    // MARK: 账号

    /// 凭据统一成保存的形态（JSON）；裸 refresh_token 补上本机设备号
    static func normalizeCredential(_ raw: String) -> String {
        guard var cred = PikPakCredential.parse(raw) else { return raw.trimmed }
        if cred.deviceId.isEmpty { cred.deviceId = PikPakAuth.localDevice }
        return cred.serialized
    }

    /// 校验凭据，返回昵称；access_token 过期时续期一次（新凭据记入 CredentialRenewal，解析器读到旧凭据时换上）
    static func validate(cookie: String) async -> String? {
        guard var cred = PikPakCredential.parse(cookie) else { return nil }
        if cred.deviceId.isEmpty { cred.deviceId = PikPakAuth.localDevice }
        if !cred.needsRefresh(), let name = await PikPakAuth.nickname(cred, client: .shared) { return name }
        guard let renewed = try? await PikPakAuth.refresh(cred, client: .shared) else { return nil }
        await CredentialRenewal.shared.recordValidated(.pikpak, consumedRefreshToken: cred.refreshToken, renewed: renewed.serialized)
        return await PikPakAuth.nickname(renewed, client: .shared) ?? renewed.username.nilIfBlank ?? "PikPak 用户"
    }

    /// 登录态检测：走续期流程（续期换来的新 refresh_token 会回写）
    public func checkLogin() async -> Bool {
        guard let id = try? await identity() else { return false }
        return (try? await call("GET", api + "/drive/v1/about", identity: id)) != nil
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let id = try await identity()
        let code = pwd?.nilIfBlank ?? share.pwd ?? ""
        let data = try await sharePage(share.shareId, passCode: code, identity: id)
        let token = data["pass_code_token"].string
        await state.setPass(share.shareId, code: code, token: token)
        return ShareSession(platform: .pikpak, shareId: share.shareId, stoken: token, title: Self.shareTitle(data),
                            rootId: Self.folderId(in: share.url) ?? "")
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let id = try await identity()
        let parent = dirId == "0" ? "" : dirId
        var files: [ShareFile] = []
        var pageToken = ""
        var retriedPass = false
        for _ in 0..<200 {
            let passToken = await state.passTokens[session.shareId] ?? session.stoken
            let url = Self.shareDetailURL(api, shareId: session.shareId, parent: parent, passToken: passToken, pageToken: pageToken)
            let data = try await call("GET", url, identity: id)
            let status = data["share_status"].string
            if status == "PASS_CODE_EMPTY" || status == "PASS_CODE_ERROR", !retriedPass {
                // pass_code_token 过期：用记下的提取码重新换一个
                retriedPass = true
                try await renewPassToken(session.shareId, identity: id)
                continue
            }
            try Self.checkShareStatus(data)
            files += data["files"].array.map { Self.parseFile($0, parent: parent) }
            pageToken = data["next_page_token"].string
            if pageToken.isEmpty { break }
        }
        return files
    }

    /// share/file_info：web_content_link，没有时用转码后的媒体链接
    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹不能直接下载") }
        let id = try await identity()
        let passToken = await state.passTokens[session.shareId] ?? session.stoken
        let url = api + "/drive/v1/share/file_info?share_id=\(session.shareId.formEncoded)&file_id=\(file.fid.formEncoded)" +
            "&pass_code_token=\(passToken.formEncoded)"
        let data = try await call("GET", url, identity: id)
        try Self.checkShareStatus(data)
        let info = data["file_info"]
        guard let link = Self.fileLink(info) else { throw CloudnError("PikPak 未返回下载链接，可先转存到自己的网盘再下载") }
        let size = info["size"].int64
        return DownloadLink(fileName: file.name, url: link, size: size > 0 ? size : file.size, headers: ["User-Agent": Self.downloadUA])
    }

    // MARK: 分享

    private func sharePage(_ shareId: String, passCode: String, identity: Identity) async throws -> JSON {
        let url = api + "/drive/v1/share?share_id=\(shareId.formEncoded)&pass_code=\(passCode.formEncoded)&limit=100" +
            "&thumbnail_size=SIZE_LARGE"
        let data = try await call("GET", url, identity: identity)
        try Self.checkShareStatus(data)
        return data
    }

    private func renewPassToken(_ shareId: String, identity: Identity) async throws {
        let code = await state.passCodes[shareId] ?? ""
        let data = try await sharePage(shareId, passCode: code, identity: identity)
        await state.setPassToken(shareId, data["pass_code_token"].string)
    }

    static func shareDetailURL(_ api: String, shareId: String, parent: String, passToken: String, pageToken: String) -> String {
        let filters = #"{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}"#
        return api + "/drive/v1/share/detail?share_id=\(shareId.formEncoded)&parent_id=\(parent.formEncoded)" +
            "&pass_code_token=\(passToken.formEncoded)&limit=100&page_token=\(pageToken.formEncoded)&thumbnail_size=SIZE_LARGE" +
            "&with_audit=true&filters=\(filters.formEncoded)"
    }

    /// share_status 不是 OK 时的提示（HTTP 200 也可能是提取码错误 / 分享失效）
    static func checkShareStatus(_ data: JSON) throws {
        let status = data["share_status"].string
        switch status {
        case "", "OK": return
        case "PASS_CODE_EMPTY": throw CloudnError("该 PikPak 分享需要提取码，请填写后重新解析")
        case "PASS_CODE_ERROR": throw CloudnError("PikPak 提取码错误，请检查后重新解析")
        case "EXPIRED": throw CloudnError("PikPak 分享已过期")
        case "DELETED", "NOT_FOUND": throw CloudnError("PikPak 分享已取消或不存在")
        case let s where s.hasPrefix("SENSITIVE"): throw CloudnError("PikPak 分享因违规无法访问")
        default: throw CloudnError("PikPak 分享无法访问：" + (data["share_status_text"].string.nilIfBlank ?? status))
        }
    }

    static func shareTitle(_ data: JSON) -> String {
        if let t = data.string("title").nilIfBlank ?? data["share_info"]["title"].string.nilIfBlank { return t }
        let files = data["files"].array
        if files.count == 1, let name = files[0]["name"].string.nilIfBlank { return name }
        return "PikPak 分享"
    }

    static func parseFile(_ item: JSON, parent: String) -> ShareFile {
        ShareFile(fid: item["id"].string, name: item["name"].string, size: item["size"].int64,
                  isDirectory: item["kind"].string == "drive#folder", parentId: item["parent_id"].string.nilIfBlank ?? parent,
                  modified: ISO8601DateFormatter.listText(item["modified_time"].string))
    }

    /// web_content_link 优先，其次第一个媒体链接
    static func fileLink(_ info: JSON) -> String? {
        if let link = info["web_content_link"].string.nilIfBlank { return link }
        return info["medias"].array.lazy.compactMap { $0["link"]["url"].string.nilIfBlank }.first
    }

    // MARK: 身份

    /// 当前账号的身份；未登录抛 loginRequired。access_token 快过期（或 rejected 刚被拒绝）时续期并回写。
    /// refresh_token 每次续期都会换新：并发续期合并成一次（CredentialRenewal）
    func identity(rejecting rejected: String? = nil) async throws -> Identity {
        guard var raw = await credentials.cookie(for: .pikpak)?.nilIfBlank, var cred = PikPakCredential.parse(raw) else {
            throw SharePlatform.pikpak.loginRequired
        }
        // 登录校验时已续期过（保存的 refresh_token 已作废）：换成那次拿到的新凭据
        if let newer = await CredentialRenewal.shared.validatedRenewal(.pikpak, refreshToken: cred.refreshToken),
           let parsed = PikPakCredential.parse(newer), parsed != cred {
            await credentials.updateCookie(newer, replacing: raw, for: .pikpak)
            raw = newer
            cred = parsed
        }
        if cred.deviceId.isEmpty { cred.deviceId = PikPakAuth.localDevice }
        if cred.needsRefresh(rejecting: rejected) {
            let (stored, current, http, store) = (raw, cred, client, credentials)
            let renewed = try await CredentialRenewal.shared.renew(.pikpak, raw: stored) {
                let renewed = try await PikPakAuth.refresh(current, client: http)
                await store.updateCookie(renewed.serialized, replacing: stored, for: .pikpak)
                return renewed.serialized
            }
            guard let parsed = PikPakCredential.parse(renewed) else { throw PikPakAuth.expired }
            cred = parsed
        }
        let key = cred.userId + "|" + cred.deviceId
        let captcha = await state.captcha(key) ?? cred.captchaToken
        return Identity(access: cred.accessToken, deviceId: cred.deviceId, userId: cred.userId, client: cred.clientInfo, captcha: captcha)
    }

    // MARK: 请求

    /// 带登录态的请求：令牌过期续期后重试一次；验证令牌过期按本次 action 重新初始化后重试（OpenList request）
    func call(_ method: String, _ url: String, body: OrderedJSON? = nil, identity: Identity) async throws -> JSON {
        var id = identity
        let action = PikPakAuth.action(method, url)
        var renewed = false
        // 还没有验证令牌：先申请一个（失败也照常请求，服务端报验证错误时再按下面的流程处理）
        if id.captcha.isEmpty { try? await refreshCaptcha(action, identity: &id) }
        for attempt in 0..<4 {
            var req = HTTPRequest(url: url, method: method,
                                  headers: PikPakAuth.headers(id.client, deviceId: id.deviceId, userId: id.userId, access: id.access, captcha: id.captcha))
            if let body { req.body = Data(body.text.utf8) }
            let r = try await client.send(req)
            let json: JSON
            if r.body.isEmpty || r.text.trimmed.isEmpty {
                guard r.isSuccess else { throw CloudnError("PikPak 请求失败（HTTP \(r.status)）") }
                return JSON([String: Any]())
            } else if let parsed = r.json, parsed.isObject {
                json = parsed
            } else {
                throw CloudnError("PikPak 响应解析失败（HTTP \(r.status)）")
            }
            if !PikPakAuth.isError(json) && r.isSuccess { return json }
            if (PikPakAuth.isAuthError(json) || r.status == 401) && !renewed {
                renewed = true
                let fresh = try await self.identity(rejecting: id.access)
                id = Identity(access: fresh.access, deviceId: fresh.deviceId, userId: fresh.userId, client: fresh.client, captcha: id.captcha)
                continue
            }
            if PikPakAuth.isCaptchaError(json) && attempt < 3 {
                Log.error("PikPak \(action) 需要刷新验证：error=\(json["error"].string) code=\(json["error_code"].int)")
                try await refreshCaptcha(action, identity: &id)
                continue
            }
            if !PikPakAuth.isError(json) { throw CloudnError("PikPak 请求失败（HTTP \(r.status)）") }
            throw PikPakAuth.error(json, status: r.status)
        }
        throw CloudnError("PikPak 验证刷新后仍失败，请稍后重试")
    }

    /// 登录后的验证令牌（meta 带 user_id）；成功后本进程内同账号共用
    private func refreshCaptcha(_ action: String, identity id: inout Identity) async throws {
        let token = try await PikPakAuth.initCaptcha(action: action, meta: [("user_id", .string(id.userId))], captcha: id.captcha,
                                                     client: id.client, deviceId: id.deviceId, userId: id.userId, access: id.access,
                                                     http: client, strict: false)
        id.captcha = token
        await state.setCaptcha(id.captchaKey, token)
    }
}

// MARK: - 登录

/// PikPak 账号密码登录：captcha/init（action POST:/v1/auth/signin）→ /v1/auth/signin → 再申请一次登录后的验证令牌
struct PikPakLogin: PasswordLogin {
    let client: HTTPClient
    var accountHint: String { "邮箱 / 手机号（带区号，如 +86）" }

    func login(account: String, password: String) async throws -> String {
        let username = account.trimmed
        guard !username.isEmpty, !password.isEmpty else { throw CloudnError("请输入账号和密码") }
        let info = PikPakClientInfo.android
        let device = PikPakAuth.localDevice
        let url = PikPakAuth.userBase + "/v1/auth/signin"
        let captcha = try await PikPakAuth.initCaptcha(action: PikPakAuth.action("POST", url), meta: PikPakAuth.loginMeta(username),
                                                       captcha: "", client: info, deviceId: device, userId: "", access: "",
                                                       http: client, strict: true)
        let body = Self.signinBody(username: username, password: password, captcha: captcha, client: info)
        let r = try await client.send(HTTPRequest(url: url + "?client_id=" + info.id, method: "POST",
                                                  headers: PikPakAuth.headers(info, deviceId: device, userId: "", captcha: captcha),
                                                  body: Data(body.text.utf8)))
        guard let json = r.json, json.isObject else { throw CloudnError("PikPak 登录失败（HTTP \(r.status)）") }
        guard var cred = PikPakAuth.applyToken(json, to: PikPakCredential(refreshToken: ""), client: info, deviceId: device),
              !cred.refreshToken.isEmpty else {
            throw PikPakAuth.isError(json) ? PikPakAuth.error(json, status: r.status) : CloudnError("PikPak 登录失败，请稍后重试")
        }
        cred.username = username
        // 登录后的验证令牌（OpenList Init 里的 RefreshCaptchaTokenAtLogin）；拿不到不影响登录，请求时再申请
        cred.captchaToken = (try? await PikPakAuth.initCaptcha(
            action: PikPakAuth.action("GET", "https://api-drive.mypikpak.net/drive/v1/files"), meta: [("user_id", .string(cred.userId))],
            captcha: captcha, client: info, deviceId: device, userId: cred.userId, access: cred.accessToken, http: client, strict: false)) ?? ""
        return cred.serialized
    }

    static func signinBody(username: String, password: String, captcha: String, client: PikPakClientInfo) -> OrderedJSON {
        .object([("captcha_token", .string(captcha)), ("client_id", .string(client.id)), ("client_secret", .string(client.secret)),
                 ("username", .string(username)), ("password", .string(password))])
    }
}
