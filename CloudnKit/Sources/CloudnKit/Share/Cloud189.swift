// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 天翼云盘分享解析：getShareInfoByCodeV2 / checkAccessCode / listShareDir 匿名访问；
// 取直链要登录：getFileDownloadUrl（带 shareId）再跟随一次 302 拿到真实地址。
// 账号密码登录参考 OpenList（AGPL-3.0）drivers/189pc：unifyLoginForPC → appConf / encryptConf →
// RSA 加密账号密码 → loginSubmit → getSessionForPC 换 sessionKey / accessToken / refreshToken。
// 登录后的接口走 cloud.189.cn 网页接口（?sessionKey= + AppKey 签名），参考 wes-lin/cloud189-sdk 与
// OpenList drivers/189_share（power721/alist）、tickstep/cloudpan189-api（Apache-2.0）。
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 天翼云盘登录凭据。两种形态：
/// - 应用内账号密码登录：JSON（accessToken / refreshToken / sessionKey / sessionSecret / loginName）；
/// - 网页登录：189.cn 的 Cookie 串（含 COOKIE_LOGIN_USER），sessionKey 运行时用 getUserBriefInfo 换取。
public struct Cloud189Credential: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var sessionKey: String
    public var sessionSecret: String
    public var loginName: String
    /// 网页登录的 Cookie（与令牌互斥）
    public var cookie: String

    public init(accessToken: String = "", refreshToken: String = "", sessionKey: String = "", sessionSecret: String = "",
                loginName: String = "", cookie: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.sessionKey = sessionKey
        self.sessionSecret = sessionSecret
        self.loginName = loginName
        self.cookie = cookie
    }

    public var isCookie: Bool { !cookie.isEmpty }

    public static func parse(_ raw: String) -> Cloud189Credential? {
        var text = raw.trimmed
        if text.hasPrefix("\""), let unquoted = JSON(text: text)?.raw as? String { text = unquoted.trimmed }
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("{") {
            guard let obj = JSON(text: text), obj.isObject else { return nil }
            let cred = Cloud189Credential(accessToken: obj.string("accessToken", "access_token"),
                                          refreshToken: obj.string("refreshToken", "refresh_token"),
                                          sessionKey: obj.string("sessionKey", "session_key"),
                                          sessionSecret: obj.string("sessionSecret", "session_secret"),
                                          loginName: obj.string("loginName", "login_name", "nickname"),
                                          cookie: obj.string("cookie"))
            guard !cred.accessToken.isEmpty || !cred.refreshToken.isEmpty || !cred.sessionKey.isEmpty || cred.isCookie else { return nil }
            return cred
        }
        guard text.contains("COOKIE_LOGIN_USER=") else { return nil }
        return Cloud189Credential(cookie: text)
    }

    /// 网页 Cookie 原样保存（应用的网页登录据此判断登录态）；令牌存 JSON
    public var serialized: String {
        if isCookie && accessToken.isEmpty && refreshToken.isEmpty && sessionKey.isEmpty { return cookie }
        var pairs: [(String, OrderedJSON)] = [("accessToken", .string(accessToken)), ("refreshToken", .string(refreshToken)),
                                              ("sessionKey", .string(sessionKey)), ("sessionSecret", .string(sessionSecret)),
                                              ("loginName", .string(loginName))]
        if isCookie { pairs.append(("cookie", .string(cookie))) }
        return OrderedJSON.object(pairs).text
    }
}

public final class Cloud189Resolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .cloud189 }
    public var supportsGuestDownload: Bool { false }

    let credentials: CredentialStore
    let client: HTTPClient
    let state = State()

    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared) {
        self.credentials = credentials
        self.client = client
    }

    public static let loginURL = "https://cloud.189.cn/web/login.html"
    public static let cookieDomains = ["189.cn"]

    /// 网页登录完成的判据
    public static func looksLoggedIn(cookie: String) -> Bool { cookie.contains("COOKIE_LOGIN_USER=") }

    static let webURL = "https://cloud.189.cn"
    static let apiURL = "https://api.cloud.189.cn"
    static let authURL = "https://open.e.189.cn"
    static let uploadURL = "https://upload.cloud.189.cn"
    /// 官方 PC 端 appId：登录与换取 session 必须用同一个（OpenList 189pc）
    static let appId = "9317140619"
    static let clientType = "10020"
    static let version = "7.2.4.0"
    static let pcClient = "TELEPC"
    static let channelId = "web_cloud.189.cn"
    static let returnURL = "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html"
    /// 网页 /api/open/ 接口签名用的 AppKey（cloud189-sdk signatureAppKey）
    static let webAppKey = "600100422"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static let expired = CloudnError("天翼云盘登录已失效，请到「我的」页重新登录", code: 401)

    actor State {
        /// 网页 Cookie → sessionKey（getUserBriefInfo 换来，只放内存）
        var webKeys: [String: String] = [:]
        /// sessionKey → 上传用的 RSA 公钥
        var rsaKeys: [String: (key: Cloud189UploadKey, until: Date)] = [:]
        func webKey(_ raw: String) -> String? { webKeys[raw] }
        func setWebKey(_ raw: String, _ key: String?) { webKeys[raw] = key }
        func rsaKey(_ session: String) -> Cloud189UploadKey? {
            guard let k = rsaKeys[session], k.until > Date() else { return nil }
            return k.key
        }
        func setRSAKey(_ session: String, _ key: Cloud189UploadKey, until: Date) { rsaKeys[session] = (key, until) }
    }

    // MARK: 链接识别与凭据

    private static let linkRx = Rx(#"(?:^|[/.])cloud\.189\.cn/(?:t/|web/share\?(?:[^#\s]*&)?code=|(?:web/)?share\.html#/t/)([A-Za-z0-9]+)"#, ignoreCase: true)
    private static let inlinePwdRx = Rx(#"(?:访问码|提取码|密码)\s*[：:]\s*([A-Za-z0-9]{4,8})"#)
    private static let queryPwdRx = Rx(#"[?&](?:pwd|accessCode)=([A-Za-z0-9]{4,8})"#, ignoreCase: true)

    /// 从链接识别分享 id 与链接自带的访问码；不是本平台返回 nil
    static func shareTarget(_ url: String) -> (id: String, pwd: String?)? {
        let decoded = url.removingPercentEncoding ?? url
        guard let code = linkRx.first(in: decoded) ?? linkRx.first(in: url) else { return nil }
        return (code, inlinePwdRx.first(in: decoded) ?? queryPwdRx.first(in: decoded))
    }

    /// 凭据统一成保存的形态
    static func normalizeCredential(_ raw: String) -> String {
        Cloud189Credential.parse(raw)?.serialized ?? raw.trimmed
    }

    /// 校验凭据，返回昵称；无效返回 nil
    static func validate(cookie: String) async -> String? {
        guard let cred = Cloud189Credential.parse(cookie) else { return nil }
        return await accountName(cred, client: .shared)
    }

    /// 能换到 sessionKey 即有效：昵称取 getUserBriefInfo，取不到用登录名
    static func accountName(_ cred: Cloud189Credential, client: HTTPClient) async -> String? {
        if cred.isCookie {
            guard let info = try? await briefInfo(cookie: cred.cookie, sessionKey: "", client: client),
                  !info["sessionKey"].string.isEmpty else { return nil }
            return displayName(info, fallback: cred.loginName)
        }
        if !cred.sessionKey.isEmpty, let info = try? await briefInfo(cookie: "", sessionKey: cred.sessionKey, client: client),
           info["res_code"].string == "0" || !info["sessionKey"].string.isEmpty {
            return displayName(info, fallback: cred.loginName)
        }
        // sessionKey 失效：只用 accessToken 续一次 session（不消耗 refreshToken）
        guard !cred.accessToken.isEmpty, let renewed = try? await sessionForPC(accessToken: cred.accessToken, client: client) else { return nil }
        let info = try? await briefInfo(cookie: "", sessionKey: renewed.sessionKey, client: client)
        return info.map { displayName($0, fallback: renewed.loginName.nilIfBlank ?? cred.loginName) }
            ?? (renewed.loginName.nilIfBlank ?? cred.loginName.nilIfBlank ?? "天翼云盘用户")
    }

    static func displayName(_ info: JSON, fallback: String) -> String {
        info.string("nickname", "nickName", "userAccount", "loginName").nilIfBlank ?? fallback.nilIfBlank ?? "天翼云盘用户"
    }

    // MARK: 分享

    /// 会话里带的分享参数（存在 ShareSession.stoken）
    struct ShareMeta: Equatable {
        var shareId: String
        var shareMode: String
        var accessCode: String
        var isFolder: Bool
        var fileId: String
        var fileName: String
        var fileSize: Int64

        var encoded: String {
            OrderedJSON.object([("shareId", .string(shareId)), ("shareMode", .string(shareMode)), ("accessCode", .string(accessCode)),
                                ("isFolder", .bool(isFolder)), ("fileId", .string(fileId)), ("fileName", .string(fileName)),
                                ("fileSize", .int(fileSize))]).text
        }

        static func decode(_ s: String) -> ShareMeta? {
            guard let j = JSON(text: s), j.isObject, !j["shareId"].string.isEmpty else { return nil }
            return ShareMeta(shareId: j["shareId"].string, shareMode: j["shareMode"].string, accessCode: j["accessCode"].string,
                             isFolder: j["isFolder"].bool, fileId: j["fileId"].string, fileName: j["fileName"].string,
                             fileSize: j["fileSize"].int64)
        }
    }

    private func shareHeaders(_ code: String) -> [(String, String)] {
        [("Accept", "application/json;charset=UTF-8"), ("User-Agent", Self.userAgent),
         ("Referer", "\(Self.webURL)/web/share?code=\(code)")]
    }

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let code = share.shareId
        let access = pwd?.nilIfBlank?.trimmed ?? share.pwd?.trimmed ?? ""
        let info = try await shareGet("/api/open/share/getShareInfoByCodeV2.action", [("shareCode", code)], code: code)
        var shareId = Self.idString(info["shareId"])
        if shareId.isEmpty {
            guard !access.isEmpty else { throw CloudnError("此天翼云盘分享需要访问码，请填写后重新解析") }
            let check = try await shareGet("/api/open/share/checkAccessCode.action", [("shareCode", code), ("accessCode", access)], code: code)
            shareId = Self.idString(check["shareId"])
            guard !shareId.isEmpty else { throw CloudnError("天翼云盘访问码错误，请检查后重新解析") }
        }
        let meta = Self.shareMeta(info, shareId: shareId, accessCode: access)
        guard !meta.fileId.isEmpty else { throw CloudnError("天翼云盘分享信息为空，链接可能已失效") }
        return ShareSession(platform: .cloud189, shareId: code, stoken: meta.encoded,
                            title: meta.fileName.nilIfBlank ?? "天翼云盘分享", rootId: meta.fileId)
    }

    static func shareMeta(_ info: JSON, shareId: String, accessCode: String) -> ShareMeta {
        ShareMeta(shareId: shareId, shareMode: info["shareMode"].string.nilIfBlank ?? "1", accessCode: accessCode,
                  isFolder: info["isFolder"].bool, fileId: idString(info["fileId"]), fileName: info["fileName"].string,
                  fileSize: info["fileSize"].int64)
    }

    /// id 字段可能是数字（超过 2^53 的长整数）或字符串
    static func idString(_ j: JSON) -> String {
        let s = j.string
        return s == "0" ? "" : s
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        guard let meta = ShareMeta.decode(session.stoken) else { throw CloudnError("天翼云盘分享会话已失效，请重新解析") }
        let dir = dirId.isEmpty ? meta.fileId : dirId
        // 单文件分享：根目录就是这个文件
        if !meta.isFolder && dir == meta.fileId {
            return [ShareFile(fid: meta.fileId, name: meta.fileName, size: meta.fileSize, isDirectory: false, parentId: "")]
        }
        var files: [ShareFile] = []
        let pageSize = 100
        for page in 1...200 {
            let json = try await shareGet("/api/open/share/listShareDir.action", Self.listShareParams(meta, dir: dir, page: page, pageSize: pageSize),
                                          code: session.shareId)
            let (items, count) = Self.parseFileList(json, parent: dir)
            files += items
            if items.count < pageSize || files.count >= count { break }
        }
        return files
    }

    static func listShareParams(_ meta: ShareMeta, dir: String, page: Int, pageSize: Int) -> [(String, String)] {
        [("pageNum", String(page)), ("pageSize", String(pageSize)), ("fileId", dir), ("shareDirFileId", dir),
         ("isFolder", "true"), ("shareId", meta.shareId), ("shareMode", meta.shareMode), ("iconOption", "5"),
         ("orderBy", "filename"), ("descending", "false"), ("accessCode", meta.accessCode)]
    }

    /// fileListAO.folderList / fileList → 文件列表（文件夹在前）与总数
    static func parseFileList(_ json: JSON, parent: String) -> (files: [ShareFile], count: Int) {
        let ao = json["fileListAO"]
        let folders = ao["folderList"].array.map {
            ShareFile(fid: idString($0["id"]), name: unescapeName($0["name"].string), size: 0, isDirectory: true,
                      parentId: idString($0["parentId"]).nilIfBlank ?? parent, modified: $0["lastOpTime"].string)
        }
        let files = ao["fileList"].array.map {
            ShareFile(fid: idString($0["id"]), name: unescapeName($0["name"].string), size: $0["size"].int64, isDirectory: false,
                      parentId: parent, token: $0["md5"].string, modified: $0["lastOpTime"].string)
        }
        let all = (folders + files).filter { !$0.fid.isEmpty }
        return (all, max(ao["count"].int, all.count))
    }

    /// 189 的文件名里单引号有时被转义成 \'
    static func unescapeName(_ name: String) -> String { name.replacingOccurrences(of: "\\'", with: "'") }

    /// 分享的直链：登录后 getFileDownloadUrl（dt=1 + shareId）→ 跟随 302
    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹不能直接下载") }
        guard let meta = ShareMeta.decode(session.stoken) else { throw CloudnError("天翼云盘分享会话已失效，请重新解析") }
        let json = try await web("/api/open/file/getFileDownloadUrl.action", params: [("fileId", file.fid), ("dt", "1"), ("shareId", meta.shareId)])
        return try await downloadLink(json, name: file.name, size: file.size)
    }

    func downloadLink(_ json: JSON, name: String, size: Int64) async throws -> DownloadLink {
        guard let raw = json.string("fileDownloadUrl", "downloadUrl", "url").nilIfBlank else {
            throw CloudnError("天翼云盘没有返回下载地址，可尝试先转存到自己的网盘")
        }
        let url = await resolveRedirect(Self.cleanDownloadURL(raw))
        return DownloadLink(fileName: name, url: url, size: size, headers: ["User-Agent": Self.userAgent])
    }

    static func cleanDownloadURL(_ raw: String) -> String {
        var url = raw.replacingOccurrences(of: "&amp;", with: "&")
        if url.hasPrefix("//") { url = "https:" + url }
        if url.hasPrefix("http://") { url = "https://" + url.dropFirst("http://".count) }
        return url
    }

    /// 下载地址会 302 到 CDN：只取 1 字节、不跟随跳转，拿到 Location
    private func resolveRedirect(_ url: String) async -> String {
        let req = HTTPRequest(url: url, headers: [("User-Agent", Self.userAgent), ("Range", "bytes=0-0")], followRedirects: false, timeout: 15)
        guard let r = try? await client.send(req), [301, 302, 303, 307, 308].contains(r.status),
              let location = r.header("location")?.nilIfBlank else { return url }
        return location
    }

    private func shareGet(_ path: String, _ params: [(String, String)], code: String) async throws -> JSON {
        let url = Self.webURL + path + "?" + Self.query(params + [("noCache", String(Double.random(in: 0..<1)))])
        let r = try await client.send(HTTPRequest(url: url, headers: shareHeaders(code)))
        guard let json = r.json, json.isObject else {
            throw CloudnError(r.isSuccess ? "天翼云盘返回了无法识别的内容" : "天翼云盘请求失败（HTTP \(r.status)）")
        }
        if let err = Self.shareError(json) ?? Self.apiError(json, status: r.status) { throw err }
        return json
    }

    static func shareError(_ json: JSON) -> CloudnError? {
        let code = json["res_code"].string.nilIfBlank ?? json["errorCode"].string
        switch code {
        case "", "0": return nil
        case "ShareNotFound", "ShareInfoNotFound", "ShareNotFoundOrCancel", "ShareDirNotFound": return CloudnError("天翼云盘分享不存在或已被取消")
        case "ShareExpiredError", "ShareExpire", "ShareOverdue": return CloudnError("天翼云盘分享已过期")
        case "ShareAuditWaiting": return CloudnError("天翼云盘分享正在审核中，请稍后再试")
        case "ShareAuditNotPass", "ShareAuditNotPassed": return CloudnError("天翼云盘分享未通过审核")
        case "ShareAccessCodeError", "AccessCodeError", "ShareAccessCodeInvalid": return CloudnError("天翼云盘访问码错误，请检查后重新解析")
        case "FileNotFound": return CloudnError("天翼云盘分享的文件已被删除")
        default: return nil
        }
    }

    // MARK: 登录态请求

    /// 一次请求的身份：保存的凭据串 + 解析结果 + 当前 sessionKey
    struct Auth {
        let raw: String
        let cred: Cloud189Credential
        let sessionKey: String
    }

    func session() async throws -> Auth {
        guard let raw = await credentials.cookie(for: .cloud189)?.nilIfBlank, let cred = Cloud189Credential.parse(raw) else {
            throw CloudnError("天翼云盘需要登录后才能下载，请到「我的」页登录天翼云盘")
        }
        if cred.isCookie {
            if let key = await state.webKey(raw) { return Auth(raw: raw, cred: cred, sessionKey: key) }
            return try await renewSession(Auth(raw: raw, cred: cred, sessionKey: ""))
        }
        if !cred.sessionKey.isEmpty { return Auth(raw: raw, cred: cred, sessionKey: cred.sessionKey) }
        return try await renewSession(Auth(raw: raw, cred: cred, sessionKey: ""))
    }

    /// sessionKey 失效：网页 Cookie 重新换一次；令牌用 accessToken 续 session，不行再用 refreshToken（并发合并成一次）
    func renewSession(_ auth: Auth) async throws -> Auth {
        if auth.cred.isCookie {
            await state.setWebKey(auth.raw, nil)
            guard let info = try? await Self.briefInfo(cookie: auth.cred.cookie, sessionKey: "", client: client),
                  let key = info["sessionKey"].string.nilIfBlank else { throw Self.expired }
            await state.setWebKey(auth.raw, key)
            return Auth(raw: auth.raw, cred: auth.cred, sessionKey: key)
        }
        let current = auth.cred
        let renewedRaw = try await CredentialRenewal.shared.renew(.cloud189, raw: auth.raw) { [self] in
            let renewed = try await Self.renew(current, client: client)
            await credentials.updateCookie(renewed.serialized, replacing: auth.raw, for: .cloud189)
            return renewed.serialized
        }
        guard let cred = Cloud189Credential.parse(renewedRaw), !cred.sessionKey.isEmpty else { throw Self.expired }
        return Auth(raw: renewedRaw, cred: cred, sessionKey: cred.sessionKey)
    }

    static func renew(_ cred: Cloud189Credential, client: HTTPClient) async throws -> Cloud189Credential {
        if !cred.accessToken.isEmpty, let s = try? await sessionForPC(accessToken: cred.accessToken, client: client) {
            return merge(cred, s)
        }
        guard !cred.refreshToken.isEmpty else { throw expired }
        let tokens = try await refreshToken(cred.refreshToken, client: client)
        var next = cred
        next.accessToken = tokens.accessToken
        next.refreshToken = tokens.refreshToken.nilIfBlank ?? cred.refreshToken
        guard let s = try? await sessionForPC(accessToken: next.accessToken, client: client) else { throw expired }
        return merge(next, s)
    }

    static func merge(_ cred: Cloud189Credential, _ s: Cloud189Credential) -> Cloud189Credential {
        var next = cred
        next.sessionKey = s.sessionKey
        next.sessionSecret = s.sessionSecret.nilIfBlank ?? cred.sessionSecret
        next.accessToken = s.accessToken.nilIfBlank ?? cred.accessToken
        next.refreshToken = s.refreshToken.nilIfBlank ?? cred.refreshToken
        next.loginName = s.loginName.nilIfBlank ?? cred.loginName
        return next
    }

    /// 客户端公共参数（OpenList clientSuffix）
    static func clientSuffix() -> [(String, String)] {
        [("clientType", pcClient), ("version", version), ("channelId", channelId),
         ("rand", "\(Int.random(in: 0..<100_000))_\(Int64.random(in: 0..<10_000_000_000))")]
    }

    /// getSessionForPC：accessToken（续期）或 redirectURL（登录）换 sessionKey
    static func sessionForPC(accessToken: String = "", redirectURL: String = "", client: HTTPClient) async throws -> Cloud189Credential {
        var params = clientSuffix() + [("returnType", "JSON")]
        if !accessToken.isEmpty { params += [("appId", appId), ("accessToken", accessToken)] }
        if !redirectURL.isEmpty { params.append(("redirectURL", redirectURL)) }
        let req = HTTPRequest(url: apiURL + "/getSessionForPC.action?" + query(params), method: redirectURL.isEmpty ? "GET" : "POST",
                              headers: [("Accept", "application/json;charset=UTF-8"), ("User-Agent", userAgent),
                                        ("X-Request-ID", UUID().uuidString.lowercased())])
        let r = try await client.send(req)
        guard let json = r.json, json.isObject else { throw CloudnError("天翼云盘登录失败（HTTP \(r.status)）") }
        let key = json["sessionKey"].string
        guard !key.isEmpty else {
            let msg = json.string("res_message", "errorMsg", "message", "msg")
            throw CloudnError(msg.isEmpty ? "天翼云盘登录失败" : "天翼云盘登录失败：\(msg)")
        }
        return Cloud189Credential(accessToken: json["accessToken"].string, refreshToken: json["refreshToken"].string,
                                  sessionKey: key, sessionSecret: json["sessionSecret"].string, loginName: json["loginName"].string)
    }

    /// open.e.189.cn refreshToken.do（失败也是 HTTP 200，看 result / accessToken）
    static func refreshToken(_ token: String, client: HTTPClient) async throws -> (accessToken: String, refreshToken: String) {
        let req = HTTPRequest.postForm(authURL + "/api/oauth2/refreshToken.do",
                                       [("clientId", appId), ("refreshToken", token), ("grantType", "refresh_token"), ("format", "json")],
                                       headers: [("Accept", "application/json;charset=UTF-8"), ("User-Agent", userAgent)])
        let r = try await client.send(req)
        guard let json = r.json, json["result"].int == 0, let access = json["accessToken"].string.nilIfBlank else { throw expired }
        return (access, json["refreshToken"].string)
    }

    /// 账号简要信息（含网页 sessionKey 与昵称）：Cookie 或 sessionKey 二选一
    static func briefInfo(cookie: String, sessionKey: String, client: HTTPClient) async throws -> JSON {
        var lastError: Error = expired
        for path in ["/api/portal/v2/getUserBriefInfo.action", "/v2/getUserBriefInfo.action"] {
            var params: [(String, String)] = [("noCache", String(Double.random(in: 0..<1)))]
            if !sessionKey.isEmpty { params.append(("sessionKey", sessionKey)) }
            var headers: [(String, String)] = [("Accept", "application/json;charset=UTF-8"), ("User-Agent", userAgent),
                                               ("Referer", webURL + "/web/main/")]
            if !cookie.isEmpty { headers.append(("Cookie", cookie)) }
            do {
                let r = try await client.send(HTTPRequest(url: webURL + path + "?" + query(params), headers: headers, followRedirects: false))
                guard let json = r.json, json.isObject else { continue }
                if let err = apiError(json, status: r.status) { lastError = err; continue }
                if json["sessionKey"].string.isEmpty && json.string("nickname", "userAccount", "loginName").isEmpty { continue }
                return json
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// cloud.189.cn 网页接口：参数 + sessionKey；/api/open/ 下的接口加 AppKey 签名（Sign-Type 1，md5(排序后的参数 + AppKey + Timestamp)）
    static func webRequest(_ path: String, method: String = "GET", params: [(String, String)], sessionKey: String, cookie: String,
                           timestamp: String = String(Int64(Date().timeIntervalSince1970 * 1000))) -> HTTPRequest {
        var headers: [(String, String)] = [("Accept", "application/json;charset=UTF-8"), ("User-Agent", userAgent),
                                           ("Referer", webURL + "/web/main/")]
        if path.contains("/open/") {
            let signature = sign(params + [("Timestamp", timestamp), ("AppKey", webAppKey)])
            headers += [("Sign-Type", "1"), ("Signature", signature), ("Timestamp", timestamp), ("AppKey", webAppKey)]
        }
        if !cookie.isEmpty { headers.append(("Cookie", cookie)) }
        let session: [(String, String)] = sessionKey.isEmpty ? [] : [("sessionKey", sessionKey)]
        if method == "GET" {
            return HTTPRequest(url: webURL + path + "?" + query(params + session), headers: headers)
        }
        var req = HTTPRequest.postForm(webURL + path + (session.isEmpty ? "" : "?" + query(session)), params, headers: headers)
        req.method = method
        return req
    }

    /// cloud189-sdk getSignature：「键=值」按字典序排序后用 & 连接，取 md5
    static func sign(_ params: [(String, String)]) -> String {
        let pairs = params.map { "\($0.0)=\($0.1)" }.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        return Crypto.md5Hex(pairs.joined(separator: "&"))
    }

    /// 查询串：值按 RFC 3986 编码
    static func query(_ params: [(String, String)]) -> String {
        params.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
    }

    static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return set
    }()

    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }

    /// JS encodeURIComponent（上传时文件名先这样编码再放进加密参数）
    static func encodeURIComponent(_ s: String) -> String {
        var set = unreserved
        set.insert(charactersIn: "!*'()")
        return s.addingPercentEncoding(withAllowedCharacters: set) ?? s
    }

    /// 接口错误：res_code 非 0、errorCode、errorVO.errorCode；HTTP 失败兜底
    static func apiError(_ json: JSON, status: Int) -> CloudnError? {
        let resCode = json["res_code"].string
        let code = (resCode.isEmpty || resCode == "0") ? (json["errorCode"].string.nilIfBlank ?? json["errorVO"]["errorCode"].string) : resCode
        if code.isEmpty {
            return (200..<300).contains(status) || status == 0 ? nil : CloudnError("天翼云盘请求失败（HTTP \(status)）", code: status)
        }
        let message = json.string("res_message", "errorMsg", "message", "msg").nilIfBlank ?? json["errorVO"]["errorMsg"].string
        switch code {
        case "InvalidSessionKey", "UserInvalidOpenToken", "InvalidAccessToken", "NotLogin", "UserNotLogin": return expired
        case "FileAlreadyExists", "FolderAlreadyExists", "FileAlreadyExist": return CloudnError("目标位置已有同名文件")
        case "FileNotFound", "FolderNotFound": return CloudnError("文件不存在或已被删除")
        case "InsufficientStorageSpace": return CloudnError("天翼云盘空间不足")
        case "ShareCreateOverload": return CloudnError("今日分享次数已达上限，请明天再试")
        case "PermissionDenied", "NoPermission": return CloudnError("没有权限执行此操作")
        case "UserDayFlowOverLimited": return CloudnError("天翼云盘今日上传流量已用完")
        default: return CloudnError(message.isEmpty ? "天翼云盘请求失败（\(code)）" : "天翼云盘：\(message)")
        }
    }

    static func isSessionError(_ text: String) -> Bool {
        ["InvalidSessionKey", "userSessionBO is null", "UserInvalidOpenToken", "InvalidAccessToken", "NotLogin"].contains { text.contains($0) }
    }

    /// 登录态的网页接口请求：sessionKey 失效时续一次再重试
    func web(_ path: String, method: String = "GET", params: [(String, String)]) async throws -> JSON {
        var auth = try await session()
        for attempt in 0..<2 {
            let r = try await client.send(Self.webRequest(path, method: method, params: params, sessionKey: auth.sessionKey, cookie: auth.cred.cookie))
            if attempt == 0, Self.isSessionError(r.text) {
                auth = try await renewSession(auth)
                continue
            }
            guard let json = r.json, json.isObject else {
                throw CloudnError(r.isSuccess ? "天翼云盘返回了无法识别的内容" : "天翼云盘请求失败（HTTP \(r.status)）")
            }
            if let err = Self.apiError(json, status: r.status) { throw err }
            return json
        }
        throw Self.expired
    }
}

/// 天翼云盘账号密码登录（OpenList drivers/189pc loginByPassword）
struct Cloud189Login: PasswordLogin {
    let client: HTTPClient
    var accountHint: String { "手机号 / 邮箱" }

    typealias R = Cloud189Resolver

    /// 登录页参数：请求头 lt / REQID、表单 paramId、老页面才有的 captchaToken、后续请求的 Referer
    struct LoginParams: Equatable {
        var lt: String
        var reqId: String
        var paramId: String
        var captchaToken: String
        var referer: String
    }

    /// 登录过程的 Cookie（open.e.189.cn 用会话 Cookie 关联 lt）
    final class Jar: @unchecked Sendable {
        private(set) var pairs: [(name: String, value: String)] = []
        func merge(_ cookies: [(name: String, value: String)]) {
            for c in cookies {
                if let i = pairs.firstIndex(where: { $0.name == c.name }) { pairs[i].value = c.value } else { pairs.append(c) }
            }
        }
        var header: String { pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
    }

    func login(account: String, password: String) async throws -> String {
        let account = account.trimmed
        guard !account.isEmpty, !password.isEmpty else { throw CloudnError("请输入天翼云盘账号和密码") }
        let jar = Jar()
        let finger = DeviceFingerprint.hex("cloud189.finger", length: 16).compactMap(\.hexDigitValue).map(String.init).joined().prefix(10)
        var params = try await loginParams(jar: jar, finger: String(finger))

        // RSA 公钥（与前缀 {NRP} 等）
        let conf = try await postJSON(R.authURL + "/api/logbox/config/encryptConf.do", [("appId", R.appId)], params: nil, jar: jar, finger: "")
        let pubKey = conf["data"]["pubKey"].string
        let pre = conf["data"]["pre"].string
        guard !pubKey.isEmpty, let user = Cloud189RSA.encryptHex(account, publicKey: pubKey),
              let pass = Cloud189RSA.encryptHex(password, publicKey: pubKey) else { throw CloudnError("天翼云盘登录失败：获取加密公钥失败") }
        let rsaUser = pre + user
        let rsaPass = pre + pass

        // 需要图形验证码时让用户改用网页登录
        let need = try await client.send(.postForm(R.authURL + "/api/logbox/oauth2/needcaptcha.do",
                                                   [("appKey", R.appId), ("accountType", "02"), ("userName", rsaUser)],
                                                   headers: headers(params, jar: jar, finger: String(finger))))
        jar.merge(need.cookies)
        if need.text.trimmed != "0" && !need.text.trimmed.isEmpty {
            throw CloudnError("天翼云盘要求输入图形验证码，请改用网页登录")
        }
        if params.paramId.isEmpty { params.paramId = try await paramId(params, jar: jar, finger: String(finger)) }

        let form: [(String, String)] = [
            ("version", "v2.0"), ("apToken", ""), ("appKey", R.appId), ("pageKey", "normal"), ("accountType", "02"),
            ("userName", rsaUser), ("password", rsaPass), ("epd", rsaPass), ("validateCode", ""),
            ("captchaToken", params.captchaToken), ("returnUrl", R.returnURL), ("dynamicCheck", "FALSE"),
            ("clientType", R.clientType), ("cb_SaveName", "1"), ("isOauth2", "false"), ("state", ""), ("paramId", params.paramId),
        ]
        let result = try await postJSON(R.authURL + "/api/logbox/oauth2/loginSubmit.do", form, params: params, jar: jar, finger: String(finger))
        if let err = Self.loginError(result) { throw err }
        let toUrl = result["toUrl"].string
        let session = try await R.sessionForPC(redirectURL: toUrl, client: client)
        return session.serialized
    }

    /// loginSubmit 的结果 → 错误（成功返回 nil）
    static func loginError(_ json: JSON) -> CloudnError? {
        let result = json["result"].int
        let msg = json.string("msg", "message")
        if result == -133 { return CloudnError("天翼云盘要求短信验证新设备，请改用网页登录") }
        if result == 0 && !json["toUrl"].string.isEmpty { return nil }
        if msg.contains("验证码") { return CloudnError("天翼云盘要求输入验证码，请改用网页登录") }
        return CloudnError(msg.isEmpty ? "天翼云盘登录失败" : "天翼云盘登录失败：\(msg)")
    }

    private func headers(_ p: LoginParams?, jar: Jar, finger: String) -> [(String, String)] {
        var h: [(String, String)] = [("Accept", "application/json;charset=UTF-8"), ("User-Agent", R.userAgent)]
        if let p {
            h += [("REQID", p.reqId), ("lt", p.lt), ("Referer", p.referer.nilIfBlank ?? R.authURL)]
            if !finger.isEmpty { h.append(("user-finger", finger)) }
        }
        if !jar.header.isEmpty { h.append(("Cookie", jar.header)) }
        return h
    }

    private func postJSON(_ url: String, _ form: [(String, String)], params: LoginParams?, jar: Jar, finger: String) async throws -> JSON {
        let r = try await client.send(.postForm(url, form, headers: headers(params, jar: jar, finger: finger)))
        jar.merge(r.cookies)
        guard let json = r.json, json.isObject else { throw CloudnError("天翼云盘登录失败（HTTP \(r.status)）") }
        return json
    }

    /// unifyLoginForPC 一路跳转到 logbox 登录页（手动跟随，收集 Cookie）
    private func loginParams(jar: Jar, finger: String) async throws -> LoginParams {
        var url = R.webURL + "/api/portal/unifyLoginForPC.action?" + R.query([
            ("appId", R.appId), ("clientType", R.clientType), ("returnURL", R.returnURL),
            ("timeStamp", String(Int64(Date().timeIntervalSince1970 * 1000))),
        ])
        var body = ""
        for _ in 0..<10 {
            let r = try await client.send(HTTPRequest(url: url, headers: headers(nil, jar: jar, finger: finger), followRedirects: false))
            jar.merge(r.cookies)
            if (300..<400).contains(r.status), let loc = r.header("location"), let next = URL(string: loc, relativeTo: URL(string: url)) {
                url = next.absoluteURL.absoluteString
                continue
            }
            body = r.text
            break
        }
        guard let params = Self.parseLoginParams(finalURL: url, page: body) else { throw CloudnError("天翼云盘登录失败：获取登录参数失败") }
        return params
    }

    /// 新登录页把 lt / reqId 放在跳转地址上（paramId 另取），老页面写在页内变量里
    static func parseLoginParams(finalURL: String, page: String) -> LoginParams? {
        if let comps = URLComponents(string: finalURL) {
            let items = comps.queryItems ?? []
            let lt = items.first { $0.name == "lt" }?.value ?? ""
            let reqId = items.first { $0.name == "reqId" }?.value ?? ""
            if !lt.isEmpty && !reqId.isEmpty {
                return LoginParams(lt: lt, reqId: reqId, paramId: Rx(#"paramId = "(.+?)""#).first(in: page) ?? "",
                                   captchaToken: Rx(#"'captchaToken' value='(.+?)'"#).first(in: page) ?? "", referer: finalURL)
            }
        }
        guard let lt = Rx(#"lt = "(.+?)""#).first(in: page), let reqId = Rx(#"reqId = "(.+?)""#).first(in: page) else { return nil }
        var referer = R.authURL + "/api/logbox/separate/web/index.html?appId=\(R.encode(R.appId))&lt=\(R.encode(lt))&reqId=\(R.encode(reqId))"
        if let enc = Rx(#"encryptUrl = "(.+?)""#).first(in: page) { referer += "&encryptUrl=\(R.encode(enc))" }
        return LoginParams(lt: lt, reqId: reqId, paramId: Rx(#"paramId = "(.+?)""#).first(in: page) ?? "",
                           captchaToken: Rx(#"'captchaToken' value='(.+?)'"#).first(in: page) ?? "", referer: referer)
    }

    /// 新登录页的 paramId 由 appConf.do 下发
    private func paramId(_ p: LoginParams, jar: Jar, finger: String) async throws -> String {
        let json = try await postJSON(R.authURL + "/api/logbox/oauth2/appConf.do", [("version", "2.0"), ("appKey", R.appId)],
                                      params: p, jar: jar, finger: finger)
        guard let id = json["data"]["paramId"].string.nilIfBlank else {
            let msg = json.string("msg", "message")
            throw CloudnError(msg.isEmpty ? "天翼云盘登录失败：获取登录参数失败" : "天翼云盘登录失败：\(msg)")
        }
        return id
    }
}

// MARK: - RSA（PKCS#1 v1.5 公钥加密）

/// 天翼云盘登录与上传签名用的 RSA 公钥加密：公钥为 base64 的 SubjectPublicKeyInfo（或 PKCS#1 RSAPublicKey）
enum Cloud189RSA {
    struct PublicKey: Equatable {
        let modulus: BigUInt
        let exponent: BigUInt
        let size: Int
    }

    static func parse(_ base64: String) -> PublicKey? {
        let cleaned = base64.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
            .replacingOccurrences(of: " ", with: "")
        guard let data = Crypto.base64Decode(cleaned) else { return nil }
        return parse(der: Array(data))
    }

    /// DER：SEQUENCE { SEQUENCE { 算法 }, BIT STRING { SEQUENCE { INTEGER n, INTEGER e } } }
    static func parse(der: [UInt8]) -> PublicKey? {
        guard let outer = tlv(der, at: 0), outer.tag == 0x30 else { return nil }
        // 直接是 RSAPublicKey
        if let first = tlv(der, at: outer.start), first.tag == 0x02 { return rsaKey(der, from: outer.start) }
        var pos = outer.start
        while pos < outer.end, let item = tlv(der, at: pos) {
            if item.tag == 0x03, item.end - item.start > 1 {
                let inner = Array(der[(item.start + 1)..<item.end])
                guard let seq = tlv(inner, at: 0), seq.tag == 0x30 else { return nil }
                return rsaKey(inner, from: seq.start)
            }
            pos = item.end
        }
        return nil
    }

    private static func rsaKey(_ bytes: [UInt8], from start: Int) -> PublicKey? {
        guard let n = tlv(bytes, at: start), n.tag == 0x02, let e = tlv(bytes, at: n.end), e.tag == 0x02 else { return nil }
        var nBytes = Array(bytes[n.start..<n.end])
        while nBytes.first == 0 { nBytes.removeFirst() }
        guard !nBytes.isEmpty else { return nil }
        return PublicKey(modulus: BigUInt(bytes: nBytes), exponent: BigUInt(bytes: Array(bytes[e.start..<e.end])), size: nBytes.count)
    }

    /// 读一个 TLV：返回标签与内容的起止下标
    private static func tlv(_ b: [UInt8], at pos: Int) -> (tag: UInt8, start: Int, end: Int)? {
        guard pos + 1 < b.count else { return nil }
        let tag = b[pos]
        var len = Int(b[pos + 1])
        var start = pos + 2
        if len & 0x80 != 0 {
            let count = len & 0x7f
            guard count > 0, count <= 4, start + count <= b.count else { return nil }
            len = 0
            for i in 0..<count { len = len << 8 | Int(b[start + i]) }
            start += count
        }
        guard start + len <= b.count else { return nil }
        return (tag, start, start + len)
    }

    /// EM = 00 02 PS(非零随机) 00 M，再做 m^e mod n
    static func encrypt(_ message: [UInt8], key: PublicKey) -> [UInt8]? {
        let k = key.size
        guard message.count <= k - 11 else { return nil }
        var em: [UInt8] = [0, 2]
        for _ in 0..<(k - 3 - message.count) { em.append(UInt8.random(in: 1...255)) }
        em.append(0)
        em += message
        return BigUInt(bytes: em).power(key.exponent, modulus: key.modulus).bytes(length: k)
    }

    /// 加密后转大写十六进制（登录的 userName / password）
    static func encryptHex(_ text: String, publicKey: String) -> String? {
        guard let key = parse(publicKey), let out = encrypt(Array(text.utf8), key: key) else { return nil }
        return Crypto.hex(out).uppercased()
    }
}
