// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 迅雷网盘分享解析：drive/v1/share 匿名列目录（子目录走 share/detail）→ 登录态转存到临时目录 →
// 文件详情取直链 → 删除转存。登录凭据来自网页版 localStorage（access / refresh token + 设备号）。
// 协议细节（含 captcha_sign 十层加盐 md5）参考 YunX（AGPL-3.0）的 XunleiApi / XunleiWebCredential。
// 我的网盘管理参考 YunX（AGPL-3.0）：drive/v1/files 列目录 / 新建 / PATCH 重命名、files:batchMove / batchTrash、
// POST drive/v1/share 创建分享、drive/v1/about 容量。
import Foundation

/// 迅雷网页登录凭据，以 JSON 存在账号的 Cookie 槽位里
public struct XunleiCredential: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var deviceId: String
    public var captchaToken: String
    /// 令牌来源：web（网页 localStorage）或 app（应用内账号密码 / 短信登录）。两者的刷新方式不同
    public var source: String

    public init(accessToken: String, refreshToken: String, deviceId: String = "", captchaToken: String = "", source: String = "web") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceId = deviceId
        self.captchaToken = captchaToken
        self.source = source
    }

    /// 网页版 OAuth client_id：网页 token 只能用它刷新（不带 client_secret）
    public static let webClientId = "Xqp0kJBXWhwaTpB6"
    public static let loginURL = "https://pan.xunlei.com/"
    public static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// 从网页 localStorage 读出登录态（credentials_<clientId>，子账号为 credentials_<clientId>@<sub>），
    /// 附上未过期的 captcha token 与 deviceid Cookie；未登录返回空串
    public static let readScript = """
    (function(){try{
      var prefix='credentials_\(webClientId)';
      var sub=localStorage.getItem('current_sub');
      var raw=sub?localStorage.getItem(prefix+'@'+sub):localStorage.getItem(prefix);
      if(!raw)return '';
      var data=JSON.parse(raw);
      if(!data||typeof data!=='object'||Array.isArray(data))return '';
      try{
        var c=JSON.parse(localStorage.getItem('captcha_\(webClientId)')||'{}');
        if(c&&c.token&&Date.parse(c.expires_at)>Date.now())data.captcha_token=c.token;
      }catch(e){}
      try{
        var all=document.cookie.split(';');
        for(var i=0;i<all.length;i++){
          var s=all[i].trim();
          if(s.indexOf('deviceid=')!==0)continue;
          var d=decodeURIComponent(s.slice(9));
          data.device_id=(d.indexOf('.')>-1&&d.length>32)?d.split('.')[1].slice(0,32):d;
          break;
        }
      }catch(e){}
      return JSON.stringify(data);
    }catch(e){return ''}})()
    """

    /// 解析存储串 / 网页对象 / 手动粘贴的裸 access_token；token 不合法（登录中间态）返回 nil
    public static func parse(_ raw: String) -> XunleiCredential? {
        var text = raw.trimmed
        if text.hasPrefix("\""), let unquoted = JSON(text: text)?.raw as? String { text = unquoted.trimmed }
        guard !text.isEmpty else { return nil }
        if !text.hasPrefix("{") {
            let token = Rx(#"^Bearer\s+"#, ignoreCase: true).replacing(in: text, with: "").trimmed
            return isValidToken(token) ? XunleiCredential(accessToken: token, refreshToken: "") : nil
        }
        guard var obj = JSON(text: text), obj.isObject else { return nil }
        for _ in 0..<2 where obj.string("access_token", "accessToken", "refresh_token", "refreshToken").isEmpty {
            let nested = obj.object("credentials", "token", "data")
            guard nested.isObject else { break }
            obj = nested
        }
        let access = obj.string("access_token", "accessToken")
        let refresh = obj.string("refresh_token", "refreshToken")
        if !access.isEmpty && !isValidToken(access) { return nil }
        if !refresh.isEmpty && !isValidToken(refresh) { return nil }
        guard !access.isEmpty || !refresh.isEmpty else { return nil }
        let captcha = obj.string("captcha_token", "captchaToken")
        return XunleiCredential(accessToken: access, refreshToken: refresh, deviceId: obj.string("device_id", "deviceId"),
                                captchaToken: isValidToken(captcha) ? captcha : "", source: obj["source"].string == "app" ? "app" : "web")
    }

    public var serialized: String {
        OrderedJSON.object([("access_token", .string(accessToken)), ("refresh_token", .string(refreshToken)),
                            ("device_id", .string(deviceId)), ("captcha_token", .string(captchaToken)), ("source", .string(source))]).text
    }

    static let tokenRx = Rx(#"^[A-Za-z0-9._~+/=-]+$"#)

    public static func isValidToken(_ v: String) -> Bool {
        (16...16384).contains(v.count) && tokenRx.matches(v) && v != "null" && v != "undefined"
    }

    /// JWT 载荷里的某个字段（exp / sub）
    static func jwtClaim(_ token: String, _ key: String) -> JSON {
        let parts = token.components(separatedBy: ".")
        guard parts.count > 1, let data = Crypto.base64Decode(parts[1]), let json = JSON(data: data) else { return JSON(nil) }
        return json[key]
    }
}

public final class XunleiResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .xunlei }
    public var supportsGuestDownload: Bool { false }

    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    static let appClientId = "Xp6vsxz_7IYVw2BB"
    static let appClientVersion = "8.31.0.9726"
    static let appPackage = "com.xunlei.downloadprovider"
    static let appUA = "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 deviceName/Xiaomi_M2004j7ac " +
        "deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 " +
        "(Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)"
    static let captchaSalts = [
        "9uJNVj/wLmdwKrJaVj/omlQ", "Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf", "Eb+L7Ce+Ej48u", "jKY0",
        "ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd", "wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK",
        "gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O", "5IiCoM9B1/788ntB", "P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf", "+oK0AN"
    ]
    static let tempDirName = "Cloudn临时转存"

    private let credentials: CredentialStore
    private let client: HTTPClient
    private let panBase: String
    private let authBase: String
    private let state = State()
    /// 未登录（及凭据里没有设备号）时用的进程内设备号
    /// 本机固定的设备号（游客访问与没带设备号的凭据共用）
    private let guestDevice = DeviceFingerprint.hex("xunlei.device")

    private actor State {
        /// shareId → 提取码（根目录列表与转存都要带）
        var passCodes: [String: String] = [:]
        /// captcha_invalid 后刷新出的新 captcha token
        var captcha: String?
        func setPass(_ id: String, _ v: String) { passCodes[id] = v }
        func setCaptcha(_ v: String) { captcha = v }
    }

    /// 一次请求的身份：access_token + 设备号 + captcha token（三者属于同一账号）
    struct Identity {
        let token: String
        let deviceId: String
        let captcha: String
        let userId: String
    }

    public init(credentials: CredentialStore, client: HTTPClient = .shared,
                panBase: String = "https://api-pan.xunlei.com", authBase: String = "https://xluser-ssl.xunlei.com") {
        self.credentials = credentials
        self.client = client
        self.panBase = panBase
        self.authBase = authBase
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let pass = pwd?.nilIfBlank ?? share.pwd ?? ""
        await state.setPass(share.shareId, pass)
        let page = try await sharePage(share.shareId, pass: pass, pageToken: "", identity: await guestIdentity())
        let title = page.data["title"].string
        return ShareSession(platform: .xunlei, shareId: share.shareId, stoken: page.data["pass_code_token"].string,
                            title: title.isEmpty ? "迅雷网盘分享" : title, rootId: "")
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        // 分享接口允许匿名访问；带上失效的 Bearer 反而会被判 unauthenticated，所以列目录一律匿名
        let identity = await guestIdentity()
        let pass = await state.passCodes[session.shareId] ?? ""
        var files: [ShareFile] = []
        var pageToken = ""
        for _ in 0..<100 {
            let page: (data: JSON, next: String)
            if dirId.isEmpty || dirId == "0" {
                page = try await sharePage(session.shareId, pass: pass, pageToken: pageToken, identity: identity)
            } else {
                let url = panBase + "/drive/v1/share/detail?share_id=\(session.shareId.formEncoded)&parent_id=\(dirId.formEncoded)" +
                    "&pass_code_token=\(session.stoken.formEncoded)&limit=100&page_token=\(pageToken.formEncoded)&thumbnail_size=SIZE_SMALL"
                let data = try await pan("GET:/drive/v1/share/detail", url: url, identity: identity, anonymous: true)
                page = (data: data, next: data["next_page_token"].string)
            }
            files += page.data["files"].array.map(Self.parseFile)
            pageToken = page.next
            if pageToken.isEmpty { break }
        }
        return files
    }

    /// 转存 → 文件详情取直链（自带签名）→ 删除转存的文件
    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let id = try await loginIdentity()
        let dir = try await ensureTempDir(id)
        let restored = try await restore(session, ids: [file.fid], to: dir, identity: id)
        // params.trace_file_ids 是 JSON 字符串：{"分享文件 id":"转存后新 id"}
        let trace = JSON(text: restored["params"]["trace_file_ids"].string)
        let savedId = trace?[file.fid].string.nilIfBlank ?? restored["file_id"].string
        guard !savedId.isEmpty else { throw CloudnError("迅雷转存失败，请稍后重试") }
        defer {
            Task { [self] in
                let del = OrderedJSON.object([("ids", .array([.string(savedId)])), ("space", .string(""))])
                _ = try? await pan("POST:/drive/v1/files:batchDelete", url: panBase + "/drive/v1/files:batchDelete", body: del, identity: id)
            }
        }
        let detailURL = panBase + "/drive/v1/files/\(savedId)?_magic=2021&usage=PLAY&thumbnail_size=SIZE_LARGE&with=public_share_tag"
        let detail = try await pan("GET:/drive/v1/files/\(savedId)", url: detailURL, identity: id)
        let link = detail["links"]["application/octet-stream"]["url"].string.nilIfBlank ?? detail["web_content_link"].string
        guard !link.isEmpty else { throw CloudnError("迅雷未返回下载链接") }
        let size = detail["size"].int64
        return DownloadLink(fileName: file.name, url: link, size: size > 0 ? size : file.size, headers: ["User-Agent": Self.webUA])
    }

    // MARK: 账号

    /// 校验网页登录凭据：真实打一次 /drive/v1/about；有效返回昵称（取不到时用通用名）
    public func validate(_ credential: XunleiCredential) async -> Bool {
        guard !credential.accessToken.isEmpty else { return false }
        let id = Identity(token: credential.accessToken, deviceId: credential.deviceId.nilIfBlank ?? guestDevice,
                          captcha: credential.captchaToken, userId: XunleiCredential.jwtClaim(credential.accessToken, "sub").string)
        guard let r = try? await client.send(.get(panBase + "/drive/v1/about", headers: panHeaders(id))), r.isSuccess,
              let json = r.json else { return false }
        return json["data"].isObject || json["kind"].string == "drive#about"
    }

    // MARK: 身份

    private func guestIdentity() async -> Identity {
        Identity(token: "", deviceId: guestDevice, captcha: "", userId: "")
    }

    /// 读取登录凭据；access_token 即将过期（< 60s）时先用 refresh_token 续期并回写账号
    private func loginIdentity() async throws -> Identity {
        guard let raw = await credentials.cookie(for: .xunlei), var cred = XunleiCredential.parse(raw) else {
            throw CloudnError("迅雷网盘需要登录后才能下载，请到「我的」页登录迅雷网盘")
        }
        let exp = XunleiCredential.jwtClaim(cred.accessToken, "exp").int64
        if cred.accessToken.isEmpty || (exp > 0 && exp - Int64(Date().timeIntervalSince1970) < 60) {
            guard let renewed = await refresh(cred) else { throw CloudnError("迅雷登录已过期，请到「我的」页重新登录") }
            cred = renewed
            await credentials.updateCookie(cred.serialized, replacing: raw, for: .xunlei)
        }
        let device = cred.deviceId.nilIfBlank ?? guestDevice
        let captcha = await state.captcha ?? cred.captchaToken
        return Identity(token: cred.accessToken, deviceId: device, captcha: captcha,
                        userId: XunleiCredential.jwtClaim(cred.accessToken, "sub").string)
    }

    /// 网页 token 只能用网页 client_id 刷新：JSON + 桌面 UA + Origin，且不能带 client_secret；
    /// 应用内登录拿到的 app token 用 app client_id + client_secret 表单刷新
    private func refresh(_ cred: XunleiCredential) async -> XunleiCredential? {
        guard !cred.refreshToken.isEmpty else { return nil }
        let device = cred.deviceId.nilIfBlank ?? guestDevice
        if cred.source == "app" {
            guard let r = try? await client.send(.postForm(authBase + "/v1/auth/token", [
                ("grant_type", "refresh_token"), ("client_id", Self.appClientId), ("client_secret", XunleiLogin.appClientSecret),
                ("refresh_token", cred.refreshToken)
            ], headers: [("X-Device-Id", device)])), let json = r.json, !json.string("access_token", "accessToken").isEmpty else { return nil }
            var renewed = cred
            renewed.accessToken = json.string("access_token", "accessToken")
            renewed.refreshToken = json.string("refresh_token", "refreshToken").nilIfBlank ?? cred.refreshToken
            return renewed
        }
        let body: [String: Any] = ["grant_type": "refresh_token", "client_id": XunleiCredential.webClientId, "refresh_token": cred.refreshToken]
        guard let r = try? await client.send(.postJSON(authBase + "/v1/auth/token", body, headers: [
            ("X-Device-Id", device), ("X-Client-Id", XunleiCredential.webClientId), ("Origin", "https://pan.xunlei.com"),
            ("Referer", "https://pan.xunlei.com/"), ("User-Agent", XunleiCredential.desktopUA),
            ("Sec-Ch-Ua", "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\""),
            ("Sec-Ch-Ua-Mobile", "?0"), ("Sec-Ch-Ua-Platform", "\"Windows\"")
        ])), let json = r.json else { return nil }
        let access = json.string("access_token", "accessToken")
        guard !access.isEmpty else { return nil }
        var renewed = cred
        renewed.accessToken = access
        renewed.refreshToken = json.string("refresh_token", "refreshToken").nilIfBlank ?? cred.refreshToken
        return renewed
    }

    // MARK: 分享与网盘

    private func sharePage(_ shareId: String, pass: String, pageToken: String, identity: Identity) async throws -> (data: JSON, next: String) {
        let url = panBase + "/drive/v1/share?share_id=\(shareId.formEncoded)&pass_code=\(pass.formEncoded)&limit=100" +
            "&page_token=\(pageToken.formEncoded)&thumbnail_size=SIZE_SMALL"
        let data = try await pan("GET:/drive/v1/share", url: url, identity: identity, anonymous: identity.token.isEmpty)
        // 提取码问题时服务端仍返回 HTTP 200 + 空列表，必须看 share_status
        switch data["share_status"].string {
        case "PASS_CODE_EMPTY", "PASS_CODE_NEED": throw CloudnError("该分享需要提取码，请填写后重新解析")
        case "PASS_CODE_ERROR": throw CloudnError("提取码错误，请检查后重新解析")
        default: break
        }
        return (data, data["next_page_token"].string)
    }

    /// share/restore：把分享里的条目转存到 parent（同步返回，trace_file_ids 里是新旧 id 映射）
    private func restore(_ session: ShareSession, ids: [String], to parent: String, identity: Identity) async throws -> JSON {
        let body = OrderedJSON.object([
            ("share_id", .string(session.shareId)), ("pass_code_token", .string(session.stoken)), ("parent_id", .string(parent)),
            ("ancestor_ids", .array([])), ("file_ids", .array(ids.map { .string($0) })), ("specify_parent_id", .bool(true))
        ])
        return try await pan("POST:/drive/v1/share/restore", url: panBase + "/drive/v1/share/restore", body: body, identity: identity)
    }

    /// 个人网盘某目录下的子文件夹
    private func personalFolders(_ parent: String, identity: Identity) async throws -> [ShareFile] {
        let filters = #"{"kind":{"eq":"drive#folder"},"trashed":{"eq":false}}"#
        var all: [ShareFile] = []
        var pageToken = ""
        for _ in 0..<50 {
            let url = panBase + "/drive/v1/files?parent_id=\(parent.formEncoded)&page_token=\(pageToken.formEncoded)&limit=100" +
                "&with_audit=true&filters=\(filters.formEncoded)"
            let data = try await pan("GET:/drive/v1/files", url: url, identity: identity)
            all += data["files"].array.map(Self.parseFile).filter(\.isDirectory)
            pageToken = data["next_page_token"].string
            if pageToken.isEmpty { break }
        }
        return all
    }

    private func ensureTempDir(_ id: Identity) async throws -> String {
        if let dir = try await personalFolders("", identity: id).first(where: { $0.name == Self.tempDirName }) {
            return dir.fid
        }
        let body = OrderedJSON.object([("kind", .string("drive#folder")), ("name", .string(Self.tempDirName)),
                                       ("parent_id", .string("")), ("space", .string(""))])
        let created = try await pan("POST:/drive/v1/files", url: panBase + "/drive/v1/files", body: body, identity: id)
        let dirId = created["file"]["id"].string.nilIfBlank ?? created["id"].string
        guard !dirId.isEmpty else { throw CloudnError("创建迅雷临时目录失败") }
        return dirId
    }

    static func parseFile(_ item: JSON) -> ShareFile {
        ShareFile(fid: item["id"].string, name: item["name"].string, size: item["size"].int64,
                  isDirectory: item["kind"].string == "drive#folder", parentId: item["parent_id"].string,
                  modified: item["modified_time"].string)
    }

    // MARK: 请求

    private func panHeaders(_ id: Identity) -> [(String, String)] {
        var h: [(String, String)] = [("User-Agent", Self.webUA), ("X-Device-Id", id.deviceId), ("X-Client-Version", Self.appClientVersion),
                                     ("Content-Type", "application/json"), ("Origin", "https://pan.xunlei.com"), ("Referer", "https://pan.xunlei.com/")]
        if !id.token.isEmpty { h.append(("Authorization", "Bearer \(id.token)")) }
        if !id.captcha.isEmpty { h.append(("X-Captcha-Token", id.captcha)) }
        return h
    }

    /// pan 请求；登录态遇到 captcha_invalid 时按本次 action 重新初始化 captcha token 后重试一次
    private func pan(_ action: String, url: String, method: String? = nil, body: OrderedJSON? = nil, identity: Identity,
                     anonymous: Bool = false) async throws -> JSON {
        var id = identity
        for attempt in 0..<3 {
            var req = HTTPRequest(url: url, headers: panHeaders(id))
            if let body {
                req.method = "POST"
                req.body = Data(body.text.utf8)
            }
            if let method { req.method = method }
            let r = try await client.send(req)
            guard let json = r.json, json.isObject else { throw CloudnError("迅雷响应解析失败（HTTP \(r.status)）") }
            let err = json["error"].string
            if r.isSuccess && !json.has("error") { return json["data"].isObject ? json["data"] : json }
            // 验证码相关的错误（captcha_invalid / captcha_required / 验证码无效…）：第一次带旧 token 重新初始化，
            // 还不行再从零初始化一个全新的
            let captchaError = err.lowercased().contains("captcha") || json["error_description"].string.contains("验证码")
            if !anonymous && attempt < 2 && captchaError {
                Log.error("迅雷 \(action) 需要刷新验证：error=\(err) code=\(json["error_code"].string)")
                let seed = attempt == 0 ? id : Identity(token: id.token, deviceId: id.deviceId, captcha: "", userId: id.userId)
                if let fresh = await initCaptcha(action: action, identity: seed) {
                    await state.setCaptcha(fresh)
                    id = Identity(token: id.token, deviceId: id.deviceId, captcha: fresh, userId: id.userId)
                    continue
                }
            }
            if r.status == 401 || err == "unauthenticated" {
                throw CloudnError(anonymous ? "迅雷拒绝了匿名访问，请稍后重试" : "迅雷登录已失效，请到「我的」页重新登录")
            }
            let msg = json.string("error_description", "message").nilIfBlank ?? err.nilIfBlank ?? "迅雷请求失败（HTTP \(r.status)）"
            throw CloudnError(msg)
        }
        throw CloudnError("迅雷验证码刷新后仍失败，请稍后重试")
    }

    private func initCaptcha(action: String, identity: Identity) async -> String? {
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let body = OrderedJSON.object([
            ("client_id", .string(Self.appClientId)), ("action", .string(action)), ("device_id", .string(identity.deviceId)),
            ("redirect_uri", .string("xlaccsdk01://xunlei.com/callback?state=harbor")),
            ("meta", .object([("client_version", .string(Self.appClientVersion)), ("package_name", .string(Self.appPackage)),
                              ("timestamp", .string(ts)), ("captcha_sign", .string(Self.captchaSign(deviceId: identity.deviceId, timestamp: ts))),
                              ("user_id", .string(identity.userId))])),
            ("captcha_token", .string(identity.captcha))
        ])
        let req = HTTPRequest(url: authBase + "/v1/shield/captcha/init", method: "POST", headers: [
            ("User-Agent", Self.appUA), ("Accept", "application/json;charset=UTF-8"), ("Content-Type", "application/json"),
            ("X-Client-Id", Self.appClientId), ("X-Device-Id", identity.deviceId), ("X-Client-Version", Self.appClientVersion)
        ], body: Data(body.text.utf8))
        return (try? await client.send(req))?.json?["captcha_token"].string.nilIfBlank
    }

    /// captcha_sign = "1." + 依次 md5(上一轮 + salt)，初值为 client_id + version + package + device_id + 毫秒时间戳
    static func captchaSign(deviceId: String, timestamp: String) -> String {
        var h = appClientId + appClientVersion + appPackage + deviceId + timestamp
        for salt in captchaSalts { h = Crypto.md5Hex(h + salt) }
        return "1." + h
    }
}

// MARK: - 转存到我的网盘

extension XunleiResolver: ShareSaver {
    public var rootFolderId: String { "" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        try await personalFolders(parentId, identity: try await loginIdentity())
    }

    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        let id = try await loginIdentity()
        for start in stride(from: 0, to: files.count, by: 100) {
            let ids = files[start..<min(start + 100, files.count)].map(\.fid)
            _ = try await restore(session, ids: Array(ids), to: folderId, identity: id)
        }
    }
}

// MARK: - 我的网盘

extension XunleiResolver: DriveManager {
    public var driveRootId: String { "" }

    /// drive/v1/files（parent_id 为空=根目录），next_page_token 翻页
    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        let id = try await driveIdentity()
        var all: [ShareFile] = []
        var pageToken = ""
        for _ in 0..<100 {
            let url = Self.driveFilesURL(panBase, parent: Self.driveParent(folderId), pageToken: pageToken)
            let data = try await pan("GET:/drive/v1/files", url: url, identity: id)
            all += data["files"].array.map(Self.parseFile)
            pageToken = data["next_page_token"].string
            if pageToken.isEmpty { break }
        }
        return all
    }

    /// 文件详情 links.application/octet-stream.url（签名直链）；UA 必须用官方 app UA，浏览器 UA 会被 CDN 降级为整文件 200
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹不能直接下载") }
        let id = try await driveIdentity()
        let url = panBase + "/drive/v1/files/\(file.fid)?_magic=2021&usage=PLAY&thumbnail_size=SIZE_LARGE" +
            "&with=hdr10&with=subtitle_files&with=task&with=public_share_tag"
        let detail = try await pan("GET:/drive/v1/files/\(file.fid)", url: url, identity: id)
        let link = detail["links"]["application/octet-stream"]["url"].string.nilIfBlank ?? detail["web_content_link"].string
        guard !link.isEmpty else { throw CloudnError("迅雷未返回下载链接") }
        let size = detail["size"].int64
        return DownloadLink(fileName: file.name, url: link, size: size > 0 ? size : file.size, headers: ["User-Agent": Self.appUA])
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        let id = try await driveIdentity()
        _ = try await pan("POST:/drive/v1/files", url: panBase + "/drive/v1/files",
                          body: Self.createFolderBody(name: name, parent: Self.driveParent(parentId)), identity: id)
    }

    /// PATCH /drive/v1/files/{id}，body {"name"}
    public func rename(_ file: ShareFile, to name: String) async throws {
        let id = try await driveIdentity()
        let body = OrderedJSON.object([("name", .string(name))])
        _ = try await pan("PATCH:/drive/v1/files/\(file.fid)", url: panBase + "/drive/v1/files/\(file.fid)", method: "PATCH",
                          body: body, identity: id)
    }

    /// files:batchMove 是异步任务：返回 task_id 后稍等再让调用方刷新
    public func move(_ files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        let id = try await driveIdentity()
        let body = Self.moveBody(ids: files.map(\.fid), to: Self.driveParent(folderId))
        _ = try await pan("POST:/drive/v1/files:batchMove", url: panBase + "/drive/v1/files:batchMove", body: body, identity: id)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    /// files:batchTrash：移入回收站
    public func delete(_ files: [ShareFile]) async throws {
        guard !files.isEmpty else { return }
        let id = try await driveIdentity()
        _ = try await pan("POST:/drive/v1/files:batchTrash", url: panBase + "/drive/v1/files:batchTrash",
                          body: Self.trashBody(ids: files.map(\.fid)), identity: id)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    /// POST /drive/v1/share：提取码由服务端生成并直接返回
    public func createShare(_ files: [ShareFile], expiry: ShareExpiry) async throws -> DriveShareLink {
        guard !files.isEmpty else { throw CloudnError("请选择要分享的文件") }
        try expiry.require(in: shareExpiryOptions)
        let id = try await driveIdentity()
        let title = files.count == 1 ? files[0].name : "分享 \(files.count) 个文件"
        let data = try await pan("POST:/drive/v1/share", url: panBase + "/drive/v1/share",
                                 body: Self.shareBody(ids: files.map(\.fid), title: title, days: expiry.isForever ? -1 : expiry.days), identity: id)
        guard let link = Self.parseShareLink(data) else { throw CloudnError("迅雷创建分享失败") }
        return link
    }

    /// GET /drive/v1/about：quota.limit / quota.usage
    public func quota() async -> DriveQuota? {
        guard let id = try? await driveIdentity(),
              let data = try? await pan("GET:/drive/v1/about", url: panBase + "/drive/v1/about", identity: id) else { return nil }
        return Self.parseQuota(data)
    }

    /// 未登录统一抛 loginRequired；已登录则沿用 loginIdentity（含过期续期）
    private func driveIdentity() async throws -> Identity {
        guard let raw = await credentials.cookie(for: .xunlei), XunleiCredential.parse(raw) != nil else {
            throw SharePlatform.xunlei.loginRequired
        }
        return try await loginIdentity()
    }

    // MARK: 请求体 / 解析

    static func driveParent(_ folderId: String) -> String { folderId == "0" ? "" : folderId }

    static func driveFilesURL(_ base: String, parent: String, pageToken: String) -> String {
        let filters = #"{"trashed":{"eq":false}}"#
        return base + "/drive/v1/files?parent_id=\(parent.formEncoded)&page_token=\(pageToken.formEncoded)&limit=100" +
            "&with_audit=true&filters=\(filters.formEncoded)"
    }

    /// space 必须是字符串，数字会 400
    static func createFolderBody(name: String, parent: String) -> OrderedJSON {
        .object([("kind", .string("drive#folder")), ("name", .string(name)), ("parent_id", .string(parent)), ("space", .string(""))])
    }

    static func moveBody(ids: [String], to parent: String) -> OrderedJSON {
        .object([("ids", .array(ids.map { .string($0) })),
                 ("to", .object([("parent_id", .string(parent)), ("space", .string(""))])), ("space", .string(""))])
    }

    static func trashBody(ids: [String]) -> OrderedJSON {
        .object([("ids", .array(ids.map { .string($0) })), ("space", .string(""))])
    }

    /// expiration_days 为字符串天数，"-1" = 永久；restore_limit "-1" = 不限转存次数
    static func shareBody(ids: [String], title: String, days: Int = -1) -> OrderedJSON {
        let params = OrderedJSON.object([("subscribe_push", .string("false")), ("WithPassCodeInLink", .string("true")),
                                         ("with_pass_code_in_link", .string("true"))])
        return .object([("file_ids", .array(ids.map { .string($0) })), ("share_to", .string("copy")), ("params", params),
                        ("title", .string(title.nilIfBlank ?? "分享文件")), ("restore_limit", .string("-1")),
                        ("expiration_days", .string(String(days)))])
    }

    static func parseShareLink(_ data: JSON) -> DriveShareLink? {
        let url = data["share_url"].string
        guard !url.isEmpty else { return nil }
        return DriveShareLink(url: url, pwd: data["pass_code"].string)
    }

    static func parseQuota(_ data: JSON) -> DriveQuota? {
        let q = data["quota"]
        guard q.isObject else { return nil }
        let total = q["limit"].int64
        let used = q["usage"].int64
        guard total > 0 || used > 0 else { return nil }
        return DriveQuota(used: used, total: total)
    }
}

// MARK: - 上传到我的网盘

/// 参考 OpenList（AGPL-3.0）thunder / pikpak 驱动：算 GCID → POST drive/v1/files（同 GCID 已存在即秒传）→
/// 用返回的 STS 临时凭证直传对象存储。阿里云 OSS 走 V1 签名，其余按 S3 SigV4（region "xunlei"）
extension XunleiResolver: DriveUploader {
    /// s3manager 的默认分片 5MB，最多 10000 片
    static let s3PartSize: Int64 = 5 << 20

    public func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws {
        let id = try await driveIdentity()
        let size = FileChunks.size(of: file)
        var gcid = GCIDHasher(size: size)
        try FileChunks.scan(file, progress: progress.hashing(total: size)) { _, d in gcid.update(d) }
        let hash = Crypto.hex(gcid.finalize()).uppercased()

        let created = try await pan("POST:/drive/v1/files", url: panBase + "/drive/v1/files",
                                    body: Self.uploadFileBody(name: name, parent: Self.driveParent(folderId), size: size, gcid: hash),
                                    identity: id)
        // 秒传：服务端已有同 GCID 的文件（phase 直接完成，或不再要求断点续传上传）
        if Self.isRapidUpload(created) { progress(.finishing, 1); return }
        guard let ticket = Self.parseUploadTicket(created) else { throw CloudnError("迅雷未返回上传凭证，请稍后重试") }
        try await putObject(file, size: size, ticket: ticket, progress: progress)
        // 对象存储收齐后由迅雷异步落库（OpenList 也不轮询），稍等再让调用方刷新
        progress(.finishing, 1)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: GCID

    /// GCID：文件按块切开，每块 SHA-1 的 20 字节摘要依次喂给外层 SHA-1；空文件即 SHA-1("")
    struct GCIDHasher {
        let blockSize: Int
        private var outer = SHA1Hasher()
        private var inner = SHA1Hasher()
        private var filled = 0

        init(size: Int64) { blockSize = Int(XunleiResolver.gcidBlockSize(size)) }

        mutating func update(_ data: Data) {
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(data.endIndex, start + (blockSize - filled))
                inner.update(data[start..<end])
                filled += end - start
                start = end
                if filled == blockSize { flushBlock() }
            }
        }

        mutating func finalize() -> [UInt8] {
            if filled > 0 { flushBlock() }
            return outer.finalize()
        }

        private mutating func flushBlock() {
            outer.update(Data(inner.finalize()))
            inner = SHA1Hasher()
            filled = 0
        }
    }

    /// 块大小从 256KB 起翻倍，直到块数不超过 512（最大 2MB）。与 OpenList 一样按「size / bs > 512」的实数比较
    static func gcidBlockSize(_ size: Int64) -> Int64 {
        var bs: Int64 = 0x40000
        while size > 0x200 * bs && bs < 0x200000 { bs <<= 1 }
        return bs
    }

    /// 内存里一段数据的 GCID（大写十六进制，网页端即大写）
    static func gcid(_ data: Data) -> String {
        var h = GCIDHasher(size: Int64(data.count))
        h.update(data)
        return Crypto.hex(h.finalize()).uppercased()
    }

    // MARK: 请求体 / 解析

    /// 字段顺序与网页端一致；space 必须是字符串（见 createFolderBody）
    static func uploadFileBody(name: String, parent: String, size: Int64, gcid: String) -> OrderedJSON {
        .object([("kind", .string("drive#file")), ("parent_id", .string(parent)), ("name", .string(name)), ("size", .int(size)),
                 ("hash", .string(gcid)), ("upload_type", .string("UPLOAD_TYPE_RESUMABLE")), ("space", .string(""))])
    }

    /// file.phase 已完成，或服务端给的 upload_type 不是断点续传（OpenList 视为无需上传）
    static func isRapidUpload(_ json: JSON) -> Bool {
        if json["file"]["phase"].string == "PHASE_TYPE_COMPLETE" { return true }
        let type = json["upload_type"].string
        return !type.isEmpty && type != "UPLOAD_TYPE_RESUMABLE"
    }

    /// resumable.params 里的 STS 临时凭证与对象位置
    struct UploadTicket: Equatable {
        let provider: String
        let bucket: String
        /// 去掉 scheme、路径与「bucket.」前缀后的域名
        let endpoint: String
        let key: String
        let accessKeyId: String
        let accessKeySecret: String
        let securityToken: String

        var isAliyun: Bool { provider == "PROVIDER_ALIYUN" || endpoint.hasSuffix("aliyuncs.com") }
        /// 虚拟主机风格（AWS SDK 默认）
        var host: String { bucket + "." + endpoint }
        var path: String { "/" + UploadUtil.encodePath(key) }
        var objectURL: String { "https://" + host + path }
    }

    static func parseUploadTicket(_ json: JSON) -> UploadTicket? {
        let resumable = json["resumable"]
        let p = resumable["params"]
        let bucket = p["bucket"].string.trimmed
        let ticket = UploadTicket(provider: resumable["provider"].string, bucket: bucket,
                                  endpoint: objectEndpoint(p["endpoint"].string, bucket: bucket), key: p["key"].string,
                                  accessKeyId: p["access_key_id"].string, accessKeySecret: p["access_key_secret"].string,
                                  securityToken: p["security_token"].string)
        guard !ticket.bucket.isEmpty, !ticket.endpoint.isEmpty, !ticket.key.isEmpty, !ticket.accessKeyId.isEmpty,
              !ticket.accessKeySecret.isEmpty else { return nil }
        return ticket
    }

    /// endpoint 可能带 scheme，也可能已经是「bucket.域名」：只留下域名本身
    static func objectEndpoint(_ endpoint: String, bucket: String) -> String {
        var host = endpoint.trimmed
        for p in ["https://", "http://"] where host.hasPrefix(p) { host.removeFirst(p.count) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        let prefix = bucket + "."
        if !bucket.isEmpty && host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return host
    }

    /// 分片大小：5MB；超过 10000 片时按 size / 9999 放大（同 s3manager）
    static func uploadPartSize(for size: Int64) -> Int64 {
        let maxParts: Int64 = 10000
        return size > maxParts * s3PartSize ? size / (maxParts - 1) : s3PartSize
    }

    /// URL 查询串：值为空时 OSS 写「键」、S3 写「键=」，与各自签名时的规范串一致
    static func objectQuery(_ query: [(String, String)], oss: Bool) -> String {
        var items: [String] = []
        for (k, v) in query {
            if v.isEmpty {
                items.append(oss ? k : k + "=")
            } else {
                items.append(k + "=" + S3SigV4.rfc3986(v))
            }
        }
        return items.joined(separator: "&")
    }

    // MARK: 对象存储

    enum ObjectSigner {
        case oss(OSSSigner)
        case s3(S3SigV4)

        var isOSS: Bool {
            if case .oss = self { return true }
            return false
        }

        func headers(_ ticket: UploadTicket, method: String, query: [(String, String)], contentType: String, payload: Data) -> [(String, String)] {
            switch self {
            case .oss(let signer):
                return signer.headers(method: method, bucket: ticket.bucket, key: ticket.key, query: query, contentType: contentType)
            case .s3(let signer):
                var h = signer.headers(method: method, host: ticket.host, path: ticket.path, query: query, payload: payload)
                h.append(("Content-Type", contentType))
                return h
            }
        }
    }

    /// 不足一片时单个 PUT；否则 初始化 → 顺序传分片 → 合并
    private func putObject(_ file: URL, size: Int64, ticket: UploadTicket, progress: UploadProgress) async throws {
        let signer: ObjectSigner
        if ticket.isAliyun {
            signer = .oss(OSSSigner(accessKeyId: ticket.accessKeyId, accessKeySecret: ticket.accessKeySecret, securityToken: ticket.securityToken))
        } else {
            signer = .s3(S3SigV4(accessKeyId: ticket.accessKeyId, secret: ticket.accessKeySecret, sessionToken: ticket.securityToken,
                                 region: "xunlei"))
        }
        let octet = "application/octet-stream"
        let total = Double(max(1, size))
        let parts = UploadUtil.parts(size: size, partSize: Self.uploadPartSize(for: size))
        if parts.count <= 1 {
            var data = Data()
            if size > 0 { data = try FileChunks.read(file, offset: 0, length: Int(size)) }
            _ = try await objectRequest(ticket, signer: signer, method: "PUT", query: [], contentType: octet, body: data) { done in
                progress(.uploading, Double(done) / total)
            }
            return
        }

        let initiated = try await objectRequest(ticket, signer: signer, method: "POST", query: [("uploads", "")], contentType: octet, body: Data())
        guard let uploadId = UploadUtil.xmlValue("UploadId", in: initiated.text)?.nilIfBlank else {
            throw CloudnError("迅雷对象存储未返回分片上传 ID")
        }
        var etags: [String] = []
        var sent: Int64 = 0
        for (i, part) in parts.enumerated() {
            // S3 要对分片内容算 SHA-256，一片（默认 5MB）读进内存
            let data = try FileChunks.read(file, offset: part.offset, length: Int(part.length))
            let base = sent
            let query: [(String, String)] = [("partNumber", String(i + 1)), ("uploadId", uploadId)]
            let r = try await objectRequest(ticket, signer: signer, method: "PUT", query: query, contentType: octet, body: data) { done in
                progress(.uploading, Double(base + done) / total)
            }
            guard let etag = r.header("ETag")?.nilIfBlank else { throw CloudnError("迅雷分片上传未返回 ETag") }
            etags.append(etag)
            sent += part.length
        }

        progress(.finishing, 0)
        let xml = UploadUtil.completeXML(etags, s3Namespace: !signer.isOSS)
        let done = try await objectRequest(ticket, signer: signer, method: "POST", query: [("uploadId", uploadId)],
                                           contentType: "application/xml", body: Data(xml.utf8))
        // S3 合并失败时可能是 HTTP 200 + <Error>
        if done.text.contains("<Error>") {
            throw CloudnError("迅雷合并分片失败：\(UploadUtil.xmlValue("Code", in: done.text) ?? "未知错误")")
        }
    }

    /// 发一个签名请求；非 2xx 时重新签名重试，共 3 次
    private func objectRequest(_ ticket: UploadTicket, signer: ObjectSigner, method: String, query: [(String, String)], contentType: String,
                               body: Data, onSent: (@Sendable (Int64) -> Void)? = nil) async throws -> HTTPResponse {
        let q = Self.objectQuery(query, oss: signer.isOSS)
        let url = ticket.objectURL + (q.isEmpty ? "" : "?" + q)
        var last: HTTPResponse?
        for _ in 0..<3 {
            let headers = signer.headers(ticket, method: method, query: query, contentType: contentType, payload: body)
            let r = try await client.upload(HTTPRequest(url: url, method: method, headers: headers), body: .data(body), progress: onSent)
            if r.isSuccess { return r }
            last = r
        }
        let code = last.flatMap { UploadUtil.xmlValue("Code", in: $0.text) } ?? ""
        throw CloudnError("迅雷对象存储上传失败（HTTP \(last?.status ?? 0)\(code.isEmpty ? "" : " " + code)）")
    }
}
