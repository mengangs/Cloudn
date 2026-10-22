// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// OAuth 2.0 授权码 + PKCE（公共客户端，没有密钥）：微软 / Google 的「我的网盘」登录用。
// 应用里用系统的 ASWebAuthenticationSession 打开 authorizeURL，拿到回调里的 code 后在这里换令牌。
import Foundation

public struct OAuthProvider: Sendable, Equatable {
    public let name: String
    public let clientId: String
    public let authorizeEndpoint: String
    public let tokenEndpoint: String
    public let redirectURI: String
    public let scopes: [String]
    /// 授权页额外参数（选择账号、要离线令牌等）
    public let extraAuthorizeParams: [(String, String)]

    public static func == (a: OAuthProvider, b: OAuthProvider) -> Bool { a.name == b.name && a.clientId == b.clientId }

    /// 回调地址的 scheme（交给 ASWebAuthenticationSession 拦截）
    public var callbackScheme: String { URL(string: redirectURI)?.scheme ?? "" }

    public static let microsoft = OAuthProvider(
        name: "Microsoft", clientId: "f6a6cccb-4eb1-476c-89fa-c3ce80650d62",
        authorizeEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        tokenEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        redirectURI: "cloudn://oauth/microsoft",
        scopes: ["Files.ReadWrite.All", "offline_access", "User.Read"],
        extraAuthorizeParams: [("prompt", "select_account")])

    /// iOS 类型的客户端：回调用「反写的客户端 ID」作 scheme；要 offline + consent 才会给 refresh_token
    public static let google = OAuthProvider(
        name: "Google", clientId: "150941028615-uchr3htd2p0cg83gcpbhdja5fa3bb942.apps.googleusercontent.com",
        authorizeEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        tokenEndpoint: "https://oauth2.googleapis.com/token",
        redirectURI: "com.googleusercontent.apps.150941028615-uchr3htd2p0cg83gcpbhdja5fa3bb942:/oauth2redirect",
        scopes: ["https://www.googleapis.com/auth/drive"],
        extraAuthorizeParams: [("access_type", "offline"), ("prompt", "consent select_account")])

    /// 一次授权请求：带 PKCE 校验串与防伪 state
    public struct Request: Sendable {
        public let url: URL
        public let verifier: String
        public let state: String
    }

    public func makeRequest() -> Request {
        let verifier = Self.randomString(64)
        let state = Self.randomString(24)
        var items = [URLQueryItem(name: "client_id", value: clientId), URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
                     URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
                     URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state)]
        items += extraAuthorizeParams.map { URLQueryItem(name: $0.0, value: $0.1) }
        var components = URLComponents(string: authorizeEndpoint)!
        components.queryItems = items
        return Request(url: components.url!, verifier: verifier, state: state)
    }

    /// 回调地址 → 授权码；用户取消、state 不符或服务端报错时抛出可读的错误
    public func code(from callback: URL, request: Request) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            let detail = Self.brief(value("error_description")?.replacingOccurrences(of: "+", with: " ") ?? "").nilIfBlank ?? error
            throw CloudnError(error == "access_denied" ? "已取消授权" : "\(name) 登录失败：\(detail)")
        }
        guard value("state") == request.state else { throw CloudnError("\(name) 登录失败：回调校验不一致，请重试") }
        guard let code = value("code"), !code.isEmpty else { throw CloudnError("\(name) 登录失败：没有拿到授权码") }
        return code
    }

    public func exchange(code: String, request: Request, client: HTTPClient = .shared) async throws -> OAuthCredential {
        try await token([("client_id", clientId), ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                         ("code_verifier", request.verifier), ("scope", scopes.joined(separator: " "))], previous: nil, client: client)
    }

    public func refresh(_ cred: OAuthCredential, client: HTTPClient = .shared) async throws -> OAuthCredential {
        try await token([("client_id", clientId), ("grant_type", "refresh_token"), ("refresh_token", cred.refreshToken),
                         ("scope", scopes.joined(separator: " "))], previous: cred, client: client)
    }

    private func token(_ fields: [(String, String)], previous: OAuthCredential?, client: HTTPClient) async throws -> OAuthCredential {
        let r = try await client.send(.postForm(tokenEndpoint, fields))
        // 服务端临时故障 / 限流：不是登录失效，稍后重试即可
        if r.status == 429 || r.status >= 500 { throw CloudnError("\(name) 登录服务暂时不可用（HTTP \(r.status)），请稍后重试") }
        guard let json = r.json else { throw CloudnError("\(name) 登录失败（HTTP \(r.status)）") }
        let access = json["access_token"].string
        guard r.isSuccess, !access.isEmpty else {
            let code = json["error"].string
            if code == "invalid_grant" { throw CloudnError("\(name) 登录已失效，请到「我的」页重新登录", code: 401) }
            throw CloudnError("\(name) 登录失败：\(Self.brief(json["error_description"].string).nilIfBlank ?? code.nilIfBlank ?? "HTTP \(r.status)")")
        }
        let lifetime = json["expires_in"].int64 > 0 ? json["expires_in"].int64 : 3600
        return OAuthCredential(refreshToken: json["refresh_token"].string.nilIfBlank ?? previous?.refreshToken ?? "", accessToken: access,
                               expiresAt: Int64(Date().timeIntervalSince1970) + lifetime, name: previous?.name ?? "")
    }

    /// 服务端的错误说明只留第一行（微软的会带上 Trace ID、Correlation ID、时间戳等几行诊断信息），过长截断
    static func brief(_ description: String) -> String {
        var line = description.components(separatedBy: .newlines).first { !$0.trimmed.isEmpty }?.trimmed ?? ""
        if let r = line.range(of: " Trace ID:") { line = String(line[..<r.lowerBound]).trimmed }
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Crypto.sha256(Data(verifier.utf8)))
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var g = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count, using: &g)] })
    }
}

/// OAuth 登录凭据（存进钥匙串的 JSON）
public struct OAuthCredential: Equatable, Sendable {
    public var refreshToken: String
    public var accessToken: String
    /// 访问令牌过期时间（Unix 秒）
    public var expiresAt: Int64
    /// 账号显示名
    public var name: String

    public init(refreshToken: String, accessToken: String, expiresAt: Int64, name: String) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.name = name
    }

    public static func parse(_ raw: String) -> OAuthCredential? {
        guard let json = JSON(text: raw.trimmed), json.isObject, !json["refresh_token"].string.isEmpty else { return nil }
        return OAuthCredential(refreshToken: json["refresh_token"].string, accessToken: json["access_token"].string,
                               expiresAt: json["expires_at"].int64, name: json["name"].string)
    }

    public var serialized: String {
        String(decoding: JSON.serialize(["refresh_token": refreshToken, "access_token": accessToken, "expires_at": expiresAt, "name": name]),
               as: UTF8.self)
    }

    /// 还能用至少 5 分钟
    public var isFresh: Bool { !accessToken.isEmpty && expiresAt - 300 > Int64(Date().timeIntervalSince1970) }

    /// 已保存账号的访问令牌；没登录返回 nil。快过期、或 rejected 正是刚被服务端拒绝（401）的那个时续期并回写。
    /// 别的请求已经续期过（保存的令牌已不是 rejected）就直接用新的；并发续期合并成一次
    static func accessToken(_ kind: AccountKind, provider: OAuthProvider, credentials: CredentialStore, client: HTTPClient,
                            rejecting rejected: String? = nil) async throws -> String? {
        guard let raw = await credentials.cookie(for: kind)?.nilIfBlank, let cred = parse(raw) else { return nil }
        if cred.isFresh, cred.accessToken != rejected { return cred.accessToken }
        let renewed = try await CredentialRenewal.shared.renew(kind, raw: raw) {
            let renewed = try await provider.refresh(cred, client: client)
            await credentials.updateCookie(renewed.serialized, replacing: raw, for: kind)
            return renewed.serialized
        }
        return parse(renewed)?.accessToken
    }
}
