// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 应用内账号密码 / 短信验证码登录。协议细节参考 YunX（AGPL-3.0）的
// Pan123Api.passwordLogin、GuangYaApi、XunleiApi（v3/login、sendsms、smslogin、signin/token）、ILanzouApi.login、LanzouApi.login。
import Foundation

/// 短信验证码挑战：发码时返回，提交验证码时原样带回（附带平台需要的中间状态）
public struct SMSChallenge: Sendable {
    public let phone: String
    public let state: [String: String]
    public let message: String

    public init(phone: String, state: [String: String], message: String = "验证码已发送") {
        self.phone = phone
        self.state = state
        self.message = message
    }
}

/// 应用内登录：成功时返回要存进账号的凭据串（Cookie / 令牌 / 凭据 JSON）
public protocol PasswordLogin: Sendable {
    var supportsPassword: Bool { get }
    var supportsSMS: Bool { get }
    /// 账号输入框的提示（手机号 / 邮箱 / 用户名）
    var accountHint: String { get }
    func login(account: String, password: String) async throws -> String
    func sendSMS(phone: String) async throws -> SMSChallenge
    func loginSMS(_ challenge: SMSChallenge, code: String) async throws -> String
}

public extension PasswordLogin {
    var supportsPassword: Bool { true }
    var supportsSMS: Bool { false }
    var accountHint: String { "手机号 / 邮箱 / 用户名" }
    func sendSMS(phone: String) async throws -> SMSChallenge { throw CloudnError("该平台不支持短信验证码登录") }
    func loginSMS(_ challenge: SMSChallenge, code: String) async throws -> String { throw CloudnError("该平台不支持短信验证码登录") }
}

public enum PasswordLogins {
    public static func provider(for kind: AccountKind, client: HTTPClient = .shared) -> PasswordLogin? {
        switch kind {
        case .pan123: return Pan123Login(client: client)
        case .guangya: return GuangYaLogin(client: client)
        case .xunlei: return XunleiLogin(client: client)
        case .ilanzou: return ILanzouLogin(client: client)
        case .lanzou: return LanzouLogin(client: client)
        default: return nil
        }
    }

    static func randomHex(_ n: Int) -> String {
        String((0..<n).map { _ in "0123456789abcdef".randomElement()! })
    }
}

// MARK: - 123 云盘

/// user.123pan.cn/api/user/sign_in → data.token（与网页 localStorage 的 authorToken 同源同形）
struct Pan123Login: PasswordLogin {
    let client: HTTPClient

    func login(account: String, password: String) async throws -> String {
        let passport = account.trimmed
        guard !passport.isEmpty, !password.isEmpty else { throw CloudnError("请输入账号和密码") }
        let r = try await client.send(.postJSON("https://user.123pan.cn/api/user/sign_in",
                                                ["passport": passport, "password": password, "remember": false] as [String: Any],
                                                headers: [("platform", "web"), ("app-version", "132"), ("loginuuid", PasswordLogins.randomHex(32)),
                                                          ("Origin", "https://user.123pan.cn"), ("Referer", "https://user.123pan.cn/"),
                                                          ("User-Agent", Pan123Resolver.webUA)]))
        guard let json = r.json, json.isObject else { throw CloudnError("123 云盘登录失败（HTTP \(r.status)）") }
        // 登录接口成功码是 200（其它接口是 0）
        guard json["code"].int == 200, case let token = json["data"]["token"].string, !token.isEmpty else {
            let msg = json["message"].string
            throw CloudnError(msg.contains("密码") || msg.contains("账号") ? msg : "123 云盘登录失败，请检查账号和密码")
        }
        return token
    }
}

// MARK: - 光鸭云盘

/// 光鸭登录凭据（JSON 存储）：令牌对 + 设备签名（账号接口与业务接口都要用同一台设备）
public struct GuangYaCredential: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var deviceId: String
    public var deviceSign: String
    /// 访问令牌过期时间（秒级时间戳，0 表示未知）
    public var expiresAt: Int64

    public static func parse(_ raw: String) -> GuangYaCredential? {
        guard let json = JSON(text: raw.trimmed), json.isObject else {
            // 手动粘贴裸 access_token
            let token = raw.trimmed
            guard token.count >= 16, !token.contains(" ") else { return nil }
            let device = PasswordLogins.randomHex(32)
            return GuangYaCredential(accessToken: token, refreshToken: "", deviceId: device,
                                     deviceSign: "wdi10." + device + PasswordLogins.randomHex(32), expiresAt: 0)
        }
        let access = json.string("access_token", "accessToken")
        guard !access.isEmpty else { return nil }
        let device = json["device_id"].string.nilIfBlank ?? PasswordLogins.randomHex(32)
        return GuangYaCredential(accessToken: access, refreshToken: json.string("refresh_token", "refreshToken"), deviceId: device,
                                 deviceSign: json["device_sign"].string.nilIfBlank ?? "wdi10." + device + PasswordLogins.randomHex(32),
                                 expiresAt: json["expires_at"].int64)
    }

    public var serialized: String {
        OrderedJSON.object([("access_token", .string(accessToken)), ("refresh_token", .string(refreshToken)),
                            ("device_id", .string(deviceId)), ("device_sign", .string(deviceSign)), ("expires_at", .int(expiresAt))]).text
    }
}

struct GuangYaLogin: PasswordLogin {
    let client: HTTPClient
    static let clientId = "aMe-8VSlkrbQXpUR"
    static let accountBase = "https://account.guangyapan.com"

    var supportsSMS: Bool { true }

    func login(account: String, password: String) async throws -> String {
        let device = Self.newDevice()
        let username = Self.normalize(account)
        guard !username.isEmpty, !password.isEmpty else { throw CloudnError("请输入账号和密码") }
        let meta = Self.meta(for: username)
        for _ in 0..<3 {
            let captcha = try await initCaptcha(device: device, meta: meta, action: "POST:/v1/auth/signin")
            var headers = Self.accountHeaders(device)
            if let captcha = captcha.token { headers.append(("X-Captcha-Token", captcha)) }
            let r = try await client.send(.postJSON(Self.accountBase + "/v1/auth/signin",
                                                    ["client_id": Self.clientId, "username": username, "password": password], headers: headers))
            let json = r.json ?? JSON(nil)
            let code = json.string("code", "error")
            if code == "captcha_required" || code == "captcha_invalid" { continue }
            guard Self.isSuccess(json) else { throw CloudnError(Self.signinError(json)) }
            return try Self.credential(json, device: device).serialized
        }
        throw CloudnError("光鸭安全验证未通过，请稍后重试或改用短信登录")
    }

    func sendSMS(phone: String) async throws -> SMSChallenge {
        let device = Self.newDevice()
        let number = Self.normalize(phone)
        let meta: [String: Any] = ["phone_number": number]
        for _ in 0..<3 {
            let captcha = try await initCaptcha(device: device, meta: meta, action: "POST:/v1/auth/verification")
            if captcha.needsWeb { throw CloudnError("光鸭需要网页人机验证，请稍后重试或改用账号密码登录") }
            // 始终带 X-Captcha-Token（即使为空串）：服务端以这个头是否存在判断流程
            let headers = Self.accountHeaders(device) + [("X-Captcha-Token", captcha.token ?? "")]
            let r = try await client.send(.postJSON(Self.accountBase + "/v1/auth/verification",
                                                    ["client_id": Self.clientId, "phone_number": number, "target": "ANY"], headers: headers))
            let json = r.json ?? JSON(nil)
            let code = json.string("code", "error")
            if code == "captcha_required" || code == "captcha_invalid" { continue }
            try Self.ensure(json, fallback: "发送验证码失败")
            let node = json["data"].isObject ? json["data"] : json
            let id = node["verification_id"].string
            guard !id.isEmpty else { throw CloudnError("验证码请求过于频繁，请稍后重试") }
            return SMSChallenge(phone: number, state: ["verification_id": id, "is_user": node["is_user"].bool ? "1" : "0",
                                                       "device_id": device.id, "device_sign": device.sign])
        }
        throw CloudnError("光鸭安全验证未通过，请稍后重试")
    }

    func loginSMS(_ challenge: SMSChallenge, code: String) async throws -> String {
        guard Rx(#"^[0-9]{4,8}$"#).matches(code) else { throw CloudnError("短信验证码错误或已过期，请重新获取") }
        let device = (id: challenge.state["device_id"] ?? "", sign: challenge.state["device_sign"] ?? "")
        let verify = try await client.send(.postJSON(Self.accountBase + "/v1/auth/verification/verify", [
            "client_id": Self.clientId, "verification_id": challenge.state["verification_id"] ?? "", "verification_code": code
        ], headers: Self.accountHeaders(device)))
        let vjson = verify.json ?? JSON(nil)
        try Self.ensure(vjson, fallback: "短信验证码错误或已过期，请重新获取")
        let token = (vjson["data"].isObject ? vjson["data"] : vjson)["verification_token"].string
        guard !token.isEmpty else { throw CloudnError("短信验证码错误或已过期，请重新获取") }
        let phone = challenge.phone
        let isUser = challenge.state["is_user"] == "1"
        let body: [String: Any]
        let path: String
        if isUser {
            path = "/v1/auth/signin"
            body = ["client_id": Self.clientId, "username": phone, "verification_code": code, "verification_token": token]
        } else {
            // 新用户短信注册：昵称取前 3 位 + **** + 后 4 位
            let digits = phone.filter(\.isNumber)
            let local = digits.count > 11 ? String(digits.suffix(11)) : digits
            let name = local.count >= 7 ? String(local.prefix(3)) + "****" + String(local.suffix(4)) : local
            path = "/v1/auth/signup"
            body = ["client_id": Self.clientId, "phone_number": phone, "name": name, "verification_code": code, "verification_token": token]
        }
        let r = try await client.send(.postJSON(Self.accountBase + path, body, headers: Self.accountHeaders(device)))
        let json = r.json ?? JSON(nil)
        try Self.ensure(json, fallback: "短信验证码错误或已过期，请重新获取")
        return try Self.credential(json, device: device).serialized
    }

    /// 用 refresh_token 续期（GuangYaResolver 调用）
    static func refresh(_ cred: GuangYaCredential, client: HTTPClient) async -> GuangYaCredential? {
        guard !cred.refreshToken.isEmpty else { return nil }
        let device = (id: cred.deviceId, sign: cred.deviceSign)
        guard let r = try? await client.send(.postJSON(accountBase + "/v1/auth/token", [
            "client_id": clientId, "grant_type": "refresh_token", "refresh_token": cred.refreshToken
        ], headers: accountHeaders(device) + [("X-Action", "401")])), let json = r.json, isSuccess(json),
              let renewed = try? credential(json, device: device) else { return nil }
        return renewed
    }

    /// 账号信息：GET /v1/user/me，返回昵称（令牌无效返回 nil）
    static func nickname(_ cred: GuangYaCredential, client: HTTPClient) async -> String? {
        let device = (id: cred.deviceId, sign: cred.deviceSign)
        guard let r = try? await client.send(.get(accountBase + "/v1/user/me", headers: accountHeaders(device) + [("Authorization", "Bearer " + cred.accessToken)])),
              r.isSuccess, let json = r.json, isSuccess(json) else { return nil }
        let node = json["data"].isObject ? json["data"] : json
        guard !node.string("sub", "user_id", "userId").isEmpty else { return nil }
        return node.string("nickname", "nick_name", "name", "username").nilIfBlank ?? "光鸭云盘用户"
    }

    // MARK: 内部

    struct Captcha {
        let token: String?
        let needsWeb: Bool
    }

    private func initCaptcha(device: (id: String, sign: String), meta: [String: Any], action: String) async throws -> Captcha {
        let r = try await client.send(.postJSON(Self.accountBase + "/v1/shield/captcha/init", [
            "client_id": Self.clientId, "action": action, "device_id": device.id, "captcha_token": "", "meta": meta
        ] as [String: Any], headers: Self.accountHeaders(device)))
        let json = r.json ?? JSON(nil)
        return Captcha(token: json["captcha_token"].string.nilIfBlank, needsWeb: !json["url"].string.isEmpty)
    }

    /// 本机固定的光鸭设备（设备号 + 签名都持久化）
    static func newDevice() -> (id: String, sign: String) {
        let id = DeviceFingerprint.hex("guangya.device")
        return (id, "wdi10." + id + DeviceFingerprint.hex("guangya.sign"))
    }

    /// 账号接口要求的一整套 X-Device-* 头（X-Device-Id 取签名里 "." 之后的 32 位）
    static func accountHeaders(_ device: (id: String, sign: String)) -> [(String, String)] {
        let afterDot = device.sign.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""
        let headerId = afterDot.count >= 32 ? String(afterDot.prefix(32)) : device.id
        return [
            ("X-Client-Id", clientId), ("X-Client-Version", "0.0.1"), ("X-Device-Id", headerId.formEncoded),
            ("X-Device-Model", "chrome%2F131.0.0.0"), ("X-Device-Name", "PC-Chrome"), ("X-Device-Sign", device.sign.formEncoded),
            ("X-Os-Version", "Win32"), ("X-Platform-Version", "1"), ("X-Protocol-Version", "301"), ("X-Sdk-Version", "9.1.3"),
            ("Accept", "application/json, text/plain, */*"), ("User-Agent", GuangYaResolver.ua)
        ]
    }

    /// 11 位手机号 → "+86 1xxxxxxxxxx"；带 +86 前缀的去掉多余空格
    static func normalize(_ raw: String) -> String {
        let s = raw.trimmed
        let digits = s.filter(\.isNumber)
        if s.hasPrefix("+86") { return "+86 " + (digits.hasPrefix("86") ? String(digits.dropFirst(2)) : digits) }
        if s.count == 11 && s.allSatisfy(\.isNumber) { return "+86 " + s }
        return s
    }

    static func meta(for account: String) -> [String: Any] {
        if account.hasPrefix("+") { return ["phone_number": account] }
        if account.contains("@") { return ["email": account] }
        return ["username": account]
    }

    static func isSuccess(_ json: JSON) -> Bool {
        if json.has("success") && !json["success"].bool { return false }
        if !json["error"].string.isEmpty { return false }
        let code = json["code"].string
        return code.isEmpty || code == "0"
    }

    static func ensure(_ json: JSON, fallback: String) throws {
        guard !isSuccess(json) else { return }
        let code = json.string("code", "error")
        let msg = json.string("msg", "message", "error_description")
        if (msg + code).lowercased().contains("captcha") { throw CloudnError("光鸭安全验证未通过，请重试") }
        if code.lowercased().contains("frequent") || code == "429" || msg.contains("频繁") { throw CloudnError("验证码请求过于频繁，请稍后重试") }
        throw CloudnError(msg.isEmpty ? fallback : msg)
    }

    static func signinError(_ json: JSON) -> String {
        switch json.string("code", "error") {
        case "too_many_requests": return "光鸭登录尝试过于频繁，请稍后重试"
        case "invalid_password", "invalid_account_or_password", "invalid_credentials", "unauthenticated", "user_not_found":
            return "光鸭账号或密码不正确，请检查后重试"
        case "password_required", "password_not_set": return "该光鸭账号尚未设置密码，请改用短信验证码登录"
        case "verification_required", "verification_code_required": return "光鸭要求短信验证，请改用短信验证码登录"
        default: return json.string("msg", "message", "error_description").nilIfBlank ?? "光鸭登录失败，请检查账号密码"
        }
    }

    static func credential(_ json: JSON, device: (id: String, sign: String)) throws -> GuangYaCredential {
        let data = json["data"].isObject ? json["data"] : json
        let access = data.string("access_token", "accessToken")
        guard !access.isEmpty else { throw CloudnError("光鸭登录失败，未返回令牌") }
        let expiresIn = data["expires_in"].int64
        return GuangYaCredential(accessToken: access, refreshToken: data.string("refresh_token", "refreshToken"),
                                 deviceId: device.id, deviceSign: device.sign,
                                 expiresAt: expiresIn > 0 ? Int64(Date().timeIntervalSince1970) + expiresIn : 0)
    }
}

// MARK: - 迅雷

/// 迅雷 App 通道登录：v3/login（密码）或 sendsms + smslogin → sessionID → signin/token 换 access_token。
/// 新设备第一次密码登录几乎必然触发短信验证（review_panel），此时提示改用短信登录。
struct XunleiLogin: PasswordLogin {
    let client: HTTPClient
    static let appClientSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"
    static let appKey = "34a062aaa22f906fca4fefe9fb3a3021"
    static let authBase = "https://xluser-ssl.xunlei.com"

    var supportsSMS: Bool { true }
    var accountHint: String { "手机号 / 邮箱 / 迅雷账号" }

    struct Device {
        let id: String
        let peer: String
        var sign: String { "div101." + id + Crypto.md5Hex(Crypto.sha1Hex(id + XunleiResolver.appPackage + "40" + XunleiLogin.appKey)) }

        /// 本机固定的设备号与 peerId：重复登录不被当成新设备
        static var local: Device { Device(id: DeviceFingerprint.hex("xunlei.device"), peer: DeviceFingerprint.hex("xunlei.peer")) }
    }

    func login(account: String, password: String) async throws -> String {
        guard !account.trimmed.isEmpty, !password.isEmpty else { throw CloudnError("请输入账号和密码") }
        let device = Device.local
        var body = Self.baseBody(device, clientVersion: "25.0.5.25", sdkVersion: "513006")
        body += [("userName", .string(account.trimmed)), ("passWord", .string(password)), ("verifyKey", .string("")),
                 ("verifyCode", .string("")), ("isMd5Pwd", .string("0"))]
        let json = try await post("/xluser.core.login/v3/login", body, ua: "android-ok-http-client/xl-acc-sdk/version-5.1.3.513006")
        return try await finish(json, device: device, username: account.trimmed)
    }

    func sendSMS(phone: String) async throws -> SMSChallenge {
        let device = Device.local
        var body = Self.baseBody(device, clientVersion: XunleiResolver.appClientVersion, sdkVersion: "231500")
        body += [("mobile", .string(phone.trimmed)), ("register", .string("0"))]
        let json = try await post("/xluser.core.login/v3/sendsms", body, ua: "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000")
        let token = json["token"].string
        guard json["errorCode"].string == "0" || !token.isEmpty else {
            throw CloudnError(json["errorDesc"].string.nilIfBlank ?? "发送验证码失败，请稍后重试")
        }
        return SMSChallenge(phone: phone.trimmed, state: ["creditkey": json["creditkey"].string, "token": token,
                                                          "device_id": device.id, "peer_id": device.peer],
                            message: json["errorDesc"].string.nilIfBlank ?? "验证码已发送")
    }

    func loginSMS(_ challenge: SMSChallenge, code: String) async throws -> String {
        let device = Device(id: challenge.state["device_id"] ?? "", peer: challenge.state["peer_id"] ?? "")
        var body = Self.baseBody(device, clientVersion: XunleiResolver.appClientVersion, sdkVersion: "231500", creditKey: challenge.state["creditkey"] ?? "")
        body += [("mobile", .string(challenge.phone)), ("smsCode", .string(code.trimmed)), ("token", .string(challenge.state["token"] ?? "")),
                 ("register", .string("0"))]
        let json = try await post("/xluser.core.login/v3/smslogin", body, ua: "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000")
        return try await finish(json, device: device, username: challenge.phone)
    }

    /// 登录成功拿 sessionID → captcha/init → signin/token 换 access_token
    private func finish(_ json: JSON, device: Device, username: String) async throws -> String {
        let ok = json["errorCode"].string == "0" || json["error"].string == "success"
        guard ok, case let session = json["sessionID"].string, !session.isEmpty else {
            if json["error"].string == "review_panel" || json["errorCode"].string == "1007" || !json["verifyType"].string.isEmpty {
                throw CloudnError("迅雷要求短信验证，请改用短信验证码登录")
            }
            throw CloudnError(json.string("errorDesc", "error_description").nilIfBlank ?? "迅雷登录失败，请检查账号密码")
        }
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let captchaBody = OrderedJSON.object([
            ("action", .string("POST:/v1/auth/signin/token")), ("captcha_token", .string("")),
            ("client_id", .string(XunleiResolver.appClientId)), ("device_id", .string(device.id)),
            ("meta", .object([("username", .string(username)), ("client_version", .string(XunleiResolver.appClientVersion)),
                              ("package_name", .string(XunleiResolver.appPackage)), ("timestamp", .string(ts)),
                              ("captcha_sign", .string(XunleiResolver.captchaSign(deviceId: device.id, timestamp: ts))),
                              ("user_id", .string(json["userID"].string))])),
            ("redirect_uri", .string("xlaccsdk01://xunlei.com/callback?state=harbor"))
        ])
        let appHeaders: [(String, String)] = [("User-Agent", XunleiResolver.appUA), ("Accept", "application/json;charset=UTF-8"),
                                              ("Content-Type", "application/json"), ("X-Client-Id", XunleiResolver.appClientId),
                                              ("X-Device-Id", device.id), ("X-Client-Version", XunleiResolver.appClientVersion)]
        let captcha = (try? await client.send(HTTPRequest(url: Self.authBase + "/v1/shield/captcha/init", method: "POST",
                                                          headers: appHeaders, body: Data(captchaBody.text.utf8))))?.json?["captcha_token"].string ?? ""
        var tokenHeaders = appHeaders
        if !captcha.isEmpty { tokenHeaders.append(("X-Captcha-Token", captcha)) }
        let tokenBody = OrderedJSON.object([("client_id", .string(XunleiResolver.appClientId)), ("client_secret", .string(Self.appClientSecret)),
                                            ("provider", .string("access_end_point_token")), ("signin_token", .string(session))])
        let r = try await client.send(HTTPRequest(url: Self.authBase + "/v1/auth/signin/token", method: "POST", headers: tokenHeaders,
                                                  body: Data(tokenBody.text.utf8)))
        let tokens = r.json ?? JSON(nil)
        let access = tokens.string("access_token", "accessToken")
        guard !access.isEmpty else { throw CloudnError(tokens.string("error_description", "error").nilIfBlank ?? "迅雷换取令牌失败，请重试") }
        return XunleiCredential(accessToken: access, refreshToken: tokens.string("refresh_token", "refreshToken"),
                                deviceId: device.id, captchaToken: captcha, source: "app").serialized
    }

    private func post(_ path: String, _ body: [(String, OrderedJSON)], ua: String) async throws -> JSON {
        let r = try await client.send(HTTPRequest(url: Self.authBase + path, method: "POST",
                                                  headers: [("User-Agent", ua), ("Content-Type", "application/json")],
                                                  body: Data(OrderedJSON.object(body).text.utf8)))
        guard let json = r.json, json.isObject else { throw CloudnError("迅雷登录响应解析失败（HTTP \(r.status)）") }
        return json
    }

    /// 登录请求公共体（对齐官方 App 抓包字段）
    static func baseBody(_ device: Device, clientVersion: String, sdkVersion: String, creditKey: String = "") -> [(String, OrderedJSON)] {
        [("protocolVersion", .string("301")), ("sequenceNo", .string(String(Int.random(in: 10_000_000...99_999_999)))),
         ("platformVersion", .string("10")), ("isCompressed", .string("0")), ("appid", .string("40")),
         ("clientVersion", .string(clientVersion)), ("peerID", .string(device.peer)),
         ("appName", .string("ANDROID-com.xunlei.downloadprovider")), ("sdkVersion", .string(sdkVersion)),
         ("devicesign", .string(device.sign)), ("netWorkType", .string("WIFI")), ("providerName", .string("NONE")),
         ("deviceModel", .string("M2004J7AC")), ("deviceName", .string("Xiaomi_M2004j7ac")), ("OSVersion", .string("12")),
         ("creditkey", .string(creditKey)), ("hl", .string("zh-CN"))]
    }
}

// MARK: - 蓝奏云优享版

/// 蓝奏优享凭据（JSON 存储）：appToken + 设备 uuid + userId（取链的 downloadId 要用）
public struct ILanzouCredential: Equatable, Sendable {
    public var appToken: String
    public var uuid: String
    public var userId: String

    public static func parse(_ raw: String) -> ILanzouCredential? {
        guard let json = JSON(text: raw.trimmed), json.isObject, !json["appToken"].string.isEmpty else { return nil }
        return ILanzouCredential(appToken: json["appToken"].string, uuid: json["uuid"].string, userId: json["userId"].string)
    }

    public var serialized: String {
        OrderedJSON.object([("appToken", .string(appToken)), ("uuid", .string(uuid)), ("userId", .string(userId))]).text
    }
}

struct ILanzouLogin: PasswordLogin {
    let client: HTTPClient
    var accountHint: String { "蓝奏云优享版账号" }

    func login(account: String, password: String) async throws -> String {
        let name = account.trimmed
        guard !name.isEmpty, !password.isEmpty else { throw CloudnError("请输入蓝奏优享账号和密码") }
        let base = "https://apis.ilanzou.com"
        let uuidURL = base + "/unproved/getUuid?" + ILanzouResolver.query(ILanzouResolver.commonParams(uuid: "", devModel: "chrome") + [("extra", "2")])
        let uuid = (try await client.send(.get(uuidURL, headers: ILanzouResolver.headers))).json?["uuid"].string ?? ""
        guard ILanzouResolver.uuidRx.matches(uuid) else { throw CloudnError("蓝奏优享未返回有效设备标识，请稍后重试") }
        let loginURL = base + "/unproved/login?" + ILanzouResolver.query(ILanzouResolver.commonParams(uuid: uuid, devModel: "chrome") + [("extra", "2")])
        let r = try await client.send(.postJSON(loginURL, ["loginName": name, "loginPwd": password], headers: ILanzouResolver.headers))
        guard let json = r.json, json.isObject else {
            throw CloudnError(r.status == 409 ? "蓝奏优享的访问验证未通过，请稍后重试" : "蓝奏优享登录失败（HTTP \(r.status)）")
        }
        guard json["code"].int == 200, case let token = json["data"]["appToken"].string, token.count >= 16 else {
            throw CloudnError(json["msg"].string.nilIfBlank ?? "蓝奏优享登录失败，请检查账号密码")
        }
        let info = await ILanzouResolver.accountInfo(appToken: token, uuid: uuid, client: client)
        return ILanzouCredential(appToken: token, uuid: uuid, userId: info?.userId ?? "").serialized
    }
}

// MARK: - 蓝奏云

/// accounts.woozooo.com 表单登录（可能先返回 acw_sc__v2 人机校验页）→ 中转地址下发 pc.woozooo.com 的登录 Cookie
struct LanzouLogin: PasswordLogin {
    let client: HTTPClient
    var accountHint: String { "蓝奏云账号（手机号）" }
    static let accounts = "https://accounts.woozooo.com/accounts.php"

    func login(account: String, password: String) async throws -> String {
        let name = account.trimmed
        guard !name.isEmpty, !password.isEmpty else { throw CloudnError("请输入蓝奏云账号和密码") }
        var jar = CookieJar()
        let headers: [(String, String)] = [
            ("User-Agent", LanzouResolver.ua), ("Origin", "https://accounts.woozooo.com"),
            ("Referer", "https://accounts.woozooo.com/accounts.php?action=login&ref=pc.woozooo.com"),
            ("X-Requested-With", "XMLHttpRequest"), ("Accept", "application/json, text/javascript, */*; q=0.01")
        ]
        var body = ""
        for _ in 0..<5 {
            let r = try await client.send(.postForm(Self.accounts, [("task", "uselogin"), ("username", name), ("password", password),
                                                                    ("ref", "pc.woozooo.com")],
                                                    headers: headers + jar.header(for: Self.accounts)))
            jar.absorb(r)
            body = r.text
            // 人机校验页：算出 acw_sc__v2 后重试
            guard body.contains("arg1="), !body.contains("\"zt\""), let cookie = LanzouResolver.challengeCookie(body) else { break }
            jar.set("accounts.woozooo.com", "acw_sc__v2", cookie)
        }
        guard let json = JSON(text: body), json.isObject else { throw CloudnError("蓝奏云登录失败，请稍后重试") }
        guard json["zt"].string == "1" else { throw CloudnError(json["msgs"].string.nilIfBlank ?? "蓝奏云登录失败，请检查账号密码") }
        let relay = json["msgs"].string
        if !relay.isEmpty { try await follow(relay, jar: &jar) }
        // 再访问一次文件页：固定 PHPSESSID（vei 与该会话绑定）
        try await follow(LanzouAccount.filesPage, jar: &jar)
        let cookie = jar.cookieString(host: "pc.woozooo.com")
        guard cookie.contains("ylogin"), cookie.contains("phpdisk_info") else { throw CloudnError("蓝奏云登录未获取到有效凭据，请重试") }
        return cookie
    }

    /// 手动跟随跳转，逐跳收集 Set-Cookie（HTTPClient 不管理 Cookie，自动跳转会丢掉中间响应下发的 Cookie）
    private func follow(_ start: String, jar: inout CookieJar) async throws {
        var url = start
        for _ in 0..<8 {
            let r = try await client.send(.get(url, headers: [("User-Agent", LanzouResolver.ua), ("Referer", "https://accounts.woozooo.com/")]
                                                + jar.header(for: url), followRedirects: false))
            jar.absorb(r)
            guard (300..<400).contains(r.status), let loc = r.header("Location") else { return }
            url = URL(string: loc, relativeTo: URL(string: url))?.absoluteString ?? loc
        }
    }

    /// 按 host 保存的简易 Cookie 罐
    struct CookieJar {
        var jar: [String: [String: String]] = [:]

        mutating func set(_ host: String, _ name: String, _ value: String) { jar[host, default: [:]][name] = value }

        mutating func absorb(_ r: HTTPResponse) {
            guard let host = URL(string: r.url)?.host else { return }
            for c in r.cookies { set(host, c.name, c.value) }
        }

        func cookieString(host: String) -> String {
            (jar[host] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }

        func header(for url: String) -> [(String, String)] {
            guard let host = URL(string: url)?.host else { return [] }
            let c = cookieString(host: host)
            return c.isEmpty ? [] : [("Cookie", c)]
        }
    }
}

/// 蓝奏云个人盘登录态：mydisk 文件页里能取到 uid / vei 才算有效
public enum LanzouAccount {
    static let filesPage = "https://pc.woozooo.com/mydisk.php?item=files&action=index"

    public static func isValidCookie(_ cookie: String) -> Bool { cookie.contains("ylogin") && cookie.contains("phpdisk_info") }

    /// 校验并返回 (uid, vei)
    public static func loginParams(cookie: String, client: HTTPClient = .shared) async -> (uid: String, vei: String)? {
        guard isValidCookie(cookie),
              let r = try? await client.send(.get(filesPage, headers: [("Cookie", cookie), ("User-Agent", LanzouResolver.ua),
                                                                       ("Referer", "https://pc.woozooo.com/mydisk.php")])),
              r.isSuccess else { return nil }
        let html = r.text
        guard let uid = Rx(#"uid['"]?\s*[=:]\s*['"]?(\d{1,20})"#).first(in: html),
              let vei = Rx(#"vei['"]?\s*[=:]\s*['"]?([A-Za-z0-9_\-+/=]{1,256})"#).first(in: html) else { return nil }
        return (uid, vei)
    }
}
