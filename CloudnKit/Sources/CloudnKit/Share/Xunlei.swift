// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 迅雷网盘分享解析：drive/v1/share 匿名列目录（子目录走 share/detail）→ 登录态转存到临时目录 →
// 文件详情取直链 → 删除转存。登录凭据来自网页版 localStorage（access / refresh token + 设备号）。
// 协议细节（含 captcha_sign 十层加盐 md5）参考 YunX（AGPL-3.0）的 XunleiApi / XunleiWebCredential。
import Foundation

/// 迅雷网页登录凭据，以 JSON 存在账号的 Cookie 槽位里
public struct XunleiCredential: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var deviceId: String
    public var captchaToken: String

    public init(accessToken: String, refreshToken: String, deviceId: String = "", captchaToken: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceId = deviceId
        self.captchaToken = captchaToken
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
                                captchaToken: isValidToken(captcha) ? captcha : "")
    }

    public var serialized: String {
        OrderedJSON.object([("access_token", .string(accessToken)), ("refresh_token", .string(refreshToken)),
                            ("device_id", .string(deviceId)), ("captcha_token", .string(captchaToken))]).text
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
    private let guestDevice = (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()

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
        let body = OrderedJSON.object([
            ("share_id", .string(session.shareId)), ("pass_code_token", .string(session.stoken)), ("parent_id", .string(dir)),
            ("ancestor_ids", .array([])), ("file_ids", .array([.string(file.fid)])), ("specify_parent_id", .bool(true))
        ])
        let restored = try await pan("POST:/drive/v1/share/restore", url: panBase + "/drive/v1/share/restore", body: body, identity: id)
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
            throw CloudnError("迅雷网盘需要登录后才能下载，请到「账号」页登录迅雷网盘")
        }
        let exp = XunleiCredential.jwtClaim(cred.accessToken, "exp").int64
        if cred.accessToken.isEmpty || (exp > 0 && exp - Int64(Date().timeIntervalSince1970) < 60) {
            guard let renewed = await refresh(cred) else { throw CloudnError("迅雷登录已过期，请到「账号」页重新登录") }
            cred = renewed
            await credentials.updateCookie(cred.serialized, replacing: raw, for: .xunlei)
        }
        let device = cred.deviceId.nilIfBlank ?? guestDevice
        let captcha = await state.captcha ?? cred.captchaToken
        return Identity(token: cred.accessToken, deviceId: device, captcha: captcha,
                        userId: XunleiCredential.jwtClaim(cred.accessToken, "sub").string)
    }

    /// 网页 token 只能用网页 client_id 刷新：JSON + 桌面 UA + Origin，且不能带 client_secret
    private func refresh(_ cred: XunleiCredential) async -> XunleiCredential? {
        guard !cred.refreshToken.isEmpty else { return nil }
        let body: [String: Any] = ["grant_type": "refresh_token", "client_id": XunleiCredential.webClientId, "refresh_token": cred.refreshToken]
        let device = cred.deviceId.nilIfBlank ?? guestDevice
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

    private func ensureTempDir(_ id: Identity) async throws -> String {
        let filters = #"{"trashed":{"eq":false}}"#
        var pageToken = ""
        for _ in 0..<20 {
            let url = panBase + "/drive/v1/files?parent_id=&page_token=\(pageToken.formEncoded)&limit=100&with_audit=true&filters=\(filters.formEncoded)"
            let data = try await pan("GET:/drive/v1/files", url: url, identity: id)
            if let dir = data["files"].array.first(where: { $0["kind"].string == "drive#folder" && $0["name"].string == Self.tempDirName }) {
                return dir["id"].string
            }
            pageToken = data["next_page_token"].string
            if pageToken.isEmpty { break }
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
    private func pan(_ action: String, url: String, body: OrderedJSON? = nil, identity: Identity, anonymous: Bool = false) async throws -> JSON {
        var id = identity
        for attempt in 0..<2 {
            var req = HTTPRequest(url: url, headers: panHeaders(id))
            if let body {
                req.method = "POST"
                req.body = Data(body.text.utf8)
            }
            let r = try await client.send(req)
            guard let json = r.json, json.isObject else { throw CloudnError("迅雷响应解析失败（HTTP \(r.status)）") }
            let err = json["error"].string
            if r.isSuccess && !json.has("error") { return json["data"].isObject ? json["data"] : json }
            if !anonymous && attempt == 0 && err == "captcha_invalid",
               let fresh = await initCaptcha(action: action, identity: id) {
                await state.setCaptcha(fresh)
                id = Identity(token: id.token, deviceId: id.deviceId, captcha: fresh, userId: id.userId)
                continue
            }
            if r.status == 401 || err == "unauthenticated" {
                throw CloudnError(anonymous ? "迅雷拒绝了匿名访问，请稍后重试" : "迅雷登录已失效，请到「账号」页重新登录")
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
