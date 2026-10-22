// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 阿里云盘分享解析：get_share_by_anonymous 取标题 → get_share_token 换分享令牌（带提取码）→ adrive/v3/file/list 列目录（免登录）；
// 下载必须登录：refresh_token 换 access_token 后调 get_share_link_download_url。
// 协议细节参考 OpenList（AGPL-3.0）的 aliyundrive_share 驱动。
import Foundation

public final class AliyunResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .aliyun }
    public var supportsGuestDownload: Bool { false }

    static let api = "https://api.alipan.com"
    static let authAPI = "https://auth.alipan.com/v2/account/token"
    static let webSite = "https://www.alipan.com"
    public static let loginURL = "https://www.alipan.com/sign/in"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    /// 分享接口要求的客户端标识（不带会被限流）
    static let canary = "client=web,app=share,version=v2.3.1"
    /// 网页版把登录态 JSON 存在 localStorage 的 token 里
    public static let readScript = "(function(){try{return localStorage.getItem('token')||''}catch(e){return ''}})()"

    private let credentials: CredentialStore
    private let client: HTTPClient
    private let tokens = TokenCache()

    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared) {
        self.credentials = credentials
        self.client = client
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let code = pwd?.nilIfBlank ?? share.pwd ?? ""
        let info = try? await call("/adrive/v3/share_link/get_share_by_anonymous?share_id=\(share.shareId)",
                                   ["share_id": share.shareId], fallback: "分享信息获取失败")
        if let info, info["has_pwd"].bool, code.isEmpty {
            throw CloudnError("此阿里云盘分享需要提取码，请填写后重新解析")
        }
        let token = try await shareToken(share.shareId, pwd: code)
        await tokens.setPwd(share.shareId, code)
        let title = info?.string("share_name", "share_title", "display_name").nilIfBlank ?? "阿里云盘分享"
        let root = Self.folderId(in: share.url) ?? "root"
        return ShareSession(platform: .aliyun, shareId: share.shareId, stoken: token, title: title, rootId: root)
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var marker = ""
        for _ in 0..<200 {
            let body: [String: Any] = ["share_id": session.shareId, "parent_file_id": dirId.nilIfBlank ?? "root", "limit": 100,
                                       "order_by": "name", "order_direction": "ASC", "marker": marker]
            let json = try await shareCall("/adrive/v3/file/list", body, session: session, fallback: "获取分享文件列表失败")
            all += json["items"].array.map { Self.parseFile($0, parent: dirId) }
            marker = json["next_marker"].string
            if marker.isEmpty { break }
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard let access = try await accessToken() else {
            throw CloudnError("阿里云盘分享需要登录后才能下载，请先到「我的」页登录阿里云盘")
        }
        let body: [String: Any] = ["drive_id": file.token, "file_id": file.fid, "expire_sec": 600, "share_id": session.shareId]
        let json = try await shareCall("/v2/file/get_share_link_download_url", body, session: session, fallback: "获取下载地址失败", access: access)
        let url = json.string("download_url", "url")
        guard !url.isEmpty else { throw CloudnError("阿里云盘未返回下载地址") }
        return DownloadLink(fileName: file.name, url: url, size: file.size, headers: ["User-Agent": Self.ua, "Referer": Self.webSite + "/"])
    }

    // MARK: 链接

    /// 链接里直接指向分享内某个文件夹：/s/<分享>/folder/<文件夹>
    static func folderId(in url: String) -> String? {
        Rx(#"/s/[A-Za-z0-9]+/folder/([A-Za-z0-9]+)"#).first(in: url)
    }

    static func parseFile(_ j: JSON, parent: String) -> ShareFile {
        ShareFile(fid: j["file_id"].string, name: j["name"].string, size: j["size"].int64, isDirectory: j["type"].string == "folder",
                  parentId: parent, token: j["drive_id"].string, modified: j["updated_at"].string)
    }

    // MARK: 分享令牌

    private func shareToken(_ shareId: String, pwd: String) async throws -> String {
        let json = try await call("/v2/share_link/get_share_token", ["share_id": shareId, "share_pwd": pwd], fallback: "分享令牌获取失败")
        let token = json["share_token"].string
        guard !token.isEmpty else { throw CloudnError("阿里云盘分享令牌获取失败") }
        await tokens.setShare(shareId, token)
        return token
    }

    /// 带分享令牌的请求；令牌过期（约 2 小时）时换新的再试一次
    private func shareCall(_ path: String, _ body: [String: Any], session: ShareSession, fallback: String, access: String? = nil) async throws -> JSON {
        let current = await tokens.share(session.shareId) ?? session.stoken
        do {
            return try await call(path, body, fallback: fallback, shareToken: current, access: access)
        } catch let e as CloudnError where e.code == Self.shareTokenExpired {
            let fresh = try await shareToken(session.shareId, pwd: await tokens.pwd(session.shareId) ?? "")
            return try await call(path, body, fallback: fallback, shareToken: fresh, access: access)
        }
    }

    static let shareTokenExpired = 4011
    static let accessExpired = 4012

    private func call(_ path: String, _ body: [String: Any], fallback: String, shareToken: String? = nil, access: String? = nil) async throws -> JSON {
        var headers: [(String, String)] = [("User-Agent", Self.ua), ("X-Canary", Self.canary), ("Origin", Self.webSite),
                                           ("Referer", Self.webSite + "/")]
        if let shareToken { headers.append(("x-share-token", shareToken)) }
        if let access { headers.append(("Authorization", "Bearer " + access)) }
        let r = try await client.send(.postJSON(Self.api + path, body, headers: headers))
        guard let json = r.json else { throw CloudnError("阿里云盘响应解析失败（HTTP \(r.status)）") }
        if r.isSuccess, json["code"].string.isEmpty { return json }
        throw Self.error(json, status: r.status, fallback: fallback)
    }

    static func error(_ json: JSON, status: Int, fallback: String) -> CloudnError {
        let code = json["code"].string
        let message = json["message"].string
        switch code {
        case "ShareLinkTokenInvalid": return CloudnError("阿里云盘分享令牌已过期", code: shareTokenExpired)
        case "AccessTokenInvalid", "AccessTokenExpired": return CloudnError("阿里云盘登录已失效，请到「我的」页重新登录", code: accessExpired)
        case "InvalidResource.SharePwd", "SharePwdIncorrect": return CloudnError("阿里云盘提取码错误，请重新填写提取码")
        case "ShareLink.Cancelled": return CloudnError("阿里云盘分享已被取消")
        case "ShareLink.Expired": return CloudnError("阿里云盘分享已过期")
        case "ShareLink.Forbidden": return CloudnError("阿里云盘分享因违规被禁止访问")
        case "NotFound.ShareLink": return CloudnError("阿里云盘分享不存在")
        case "TooManyRequests": return CloudnError("阿里云盘请求过于频繁，请稍后再试")
        default:
            return CloudnError("阿里云盘：\(message.nilIfBlank ?? "\(fallback)（HTTP \(status)）")")
        }
    }

    // MARK: 登录

    /// 当前账号的 access_token；未登录返回 nil。快过期时用 refresh_token 续期并回写（refresh_token 每次续期都会换新）
    func accessToken() async throws -> String? {
        guard let raw = await credentials.cookie(for: .aliyun)?.nilIfBlank, let cred = AliyunCredential.parse(raw) else { return nil }
        if !cred.accessToken.isEmpty, cred.expiresAt - 300 > Int64(Date().timeIntervalSince1970) { return cred.accessToken }
        if let cached = await tokens.access(cred.refreshToken) { return cached }
        let renewed = try await AliyunCredential.refresh(cred, client: client)
        await credentials.updateCookie(renewed.serialized, replacing: raw, for: .aliyun)
        await tokens.setAccess(renewed.refreshToken, renewed.accessToken)
        return renewed.accessToken
    }

    /// 登录态检测：走续期流程（续期换来的新 refresh_token 会回写），不能用只校验不保存的 AccountValidator
    public func checkLogin() async -> Bool {
        (try? await accessToken()) != nil
    }

    private actor TokenCache {
        var shares: [String: String] = [:]
        var pwds: [String: String] = [:]
        var accesses: [String: String] = [:]
        func share(_ id: String) -> String? { shares[id] }
        func setShare(_ id: String, _ t: String) { shares[id] = t }
        func pwd(_ id: String) -> String? { pwds[id] }
        func setPwd(_ id: String, _ p: String) { pwds[id] = p }
        func access(_ refresh: String) -> String? { accesses[refresh] }
        func setAccess(_ refresh: String, _ t: String) { accesses[refresh] = t }
    }
}

/// 阿里云盘登录凭据：网页 localStorage 的 token JSON，或手动粘贴的 refresh_token
public struct AliyunCredential: Equatable, Sendable {
    public var refreshToken: String
    public var accessToken: String
    /// access_token 过期时间（Unix 秒）；0 为未知
    public var expiresAt: Int64
    public var nickname: String

    public static func parse(_ raw: String) -> AliyunCredential? {
        let text = raw.trimmed
        if let json = JSON(text: text), json.isObject {
            let refresh = json.string("refresh_token", "refreshToken")
            guard !refresh.isEmpty else { return nil }
            var expires = json["expires_at"].int64
            if expires == 0, let date = ISO8601DateFormatter.flexible(json["expire_time"].string) {
                expires = Int64(date.timeIntervalSince1970)
            }
            return AliyunCredential(refreshToken: refresh, accessToken: json.string("access_token", "accessToken"), expiresAt: expires,
                                    nickname: json.string("nick_name", "user_name", "nickname"))
        }
        // 裸 refresh_token：32 位十六进制
        guard text.count >= 20, text.count <= 128, text.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return AliyunCredential(refreshToken: text, accessToken: "", expiresAt: 0, nickname: "")
    }

    public var serialized: String {
        String(decoding: JSON.serialize(["refresh_token": refreshToken, "access_token": accessToken, "expires_at": expiresAt,
                                         "nick_name": nickname]), as: UTF8.self)
    }

    /// 用 refresh_token 换新的 access_token（同时返回新的 refresh_token）
    public static func refresh(_ cred: AliyunCredential, client: HTTPClient) async throws -> AliyunCredential {
        let r = try await client.send(.postJSON(AliyunResolver.authAPI, ["refresh_token": cred.refreshToken, "grant_type": "refresh_token"],
                                                headers: [("User-Agent", AliyunResolver.ua)]))
        guard let json = r.json else { throw CloudnError("阿里云盘登录续期失败（HTTP \(r.status)）") }
        let access = json["access_token"].string
        guard r.isSuccess, !access.isEmpty else {
            throw CloudnError("阿里云盘登录已失效，请到「我的」页重新登录", code: AliyunResolver.accessExpired)
        }
        let lifetime = json["expires_in"].int64 > 0 ? json["expires_in"].int64 : 7200
        return AliyunCredential(refreshToken: json["refresh_token"].string.nilIfBlank ?? cred.refreshToken, accessToken: access,
                                expiresAt: Int64(Date().timeIntervalSince1970) + lifetime,
                                nickname: json.string("nick_name", "user_name").nilIfBlank ?? cred.nickname)
    }

    /// 校验：access_token 还有效就查用户信息（不消耗 refresh_token），否则续期一次
    public static func nickname(_ cred: AliyunCredential, client: HTTPClient) async -> String? {
        if !cred.accessToken.isEmpty, cred.expiresAt == 0 || cred.expiresAt > Int64(Date().timeIntervalSince1970) {
            if let r = try? await client.send(.postJSON("https://api.alipan.com/v2/user/get", [String: Any](),
                                                        headers: [("Authorization", "Bearer " + cred.accessToken), ("User-Agent", AliyunResolver.ua)])),
               r.isSuccess, let json = r.json, !json["user_id"].string.isEmpty {
                return json.string("nick_name", "user_name").nilIfBlank ?? cred.nickname.nilIfBlank ?? "阿里云盘用户"
            }
        }
        guard let renewed = try? await refresh(cred, client: client) else { return nil }
        return renewed.nickname.nilIfBlank ?? "阿里云盘用户"
    }
}

extension ISO8601DateFormatter {
    /// 带或不带毫秒的 ISO 8601 时间
    static func flexible(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
