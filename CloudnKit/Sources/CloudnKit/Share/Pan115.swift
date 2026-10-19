// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 115 网盘分享解析：share/snap 列目录 → share/downurl 取直链；大文件网页端被拒（50029）时，
// 登录态下转存到临时目录，再走「电脑端」加密接口 proapi.115.com/app/chrome/downurl 取链，下载完成后清理。
// 协议细节参考 YunX（AGPL-3.0）的 Pan115Api / Pan115Crypto / Pan115ResolveRepository。
import Foundation

public final class Pan115Resolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .pan115 }
    public var supportsGuestDownload: Bool { true }

    public static let loginURL = "https://115.com/"
    public static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    public static let cookieDomains = ["115.com"]
    static let referer = "https://115.com/"
    static let tempDirName = "Cloudn临时转存"
    static let pageLimit = 100

    private let credentials: CredentialStore
    private let client: HTTPClient
    private let apiBase: String
    private let state = State()

    /// 115 校验客户端版本：UA 里版本过低直接 50029，所以版本号从官方接口拉取
    private actor State {
        var clientVersion = "36.0.1"
        var versionFetched = false
        func setVersion(_ v: String) { clientVersion = v }
        func markFetched() -> Bool {
            defer { versionFetched = true }
            return versionFetched
        }
    }

    public init(credentials: CredentialStore, client: HTTPClient = .shared, apiBase: String = "https://webapi.115.com") {
        self.credentials = credentials
        self.client = client
        self.apiBase = apiBase
    }

    private func loginCookie() async -> String? {
        guard let c = await credentials.cookie(for: .pan115), Self.isValidCookie(c) else { return nil }
        return c
    }

    public static func isValidCookie(_ cookie: String) -> Bool {
        CookieUtil.value(of: "UID", in: cookie)?.isEmpty == false
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let code = pwd?.nilIfBlank ?? share.pwd ?? ""
        // 先探根目录：校验访问码，并拿到分享者 UID（取直链的 user_id 只能是分享者）与标题
        let data = try await snap(share.shareId, code: code, cid: "0", offset: 0, cookie: await loginCookie() ?? "")
        let uid = data["userinfo"]["user_id"].string
        let title = data["shareinfo"]["share_title"].string
        return ShareSession(platform: .pan115, shareId: share.shareId, stoken: "\(code)|\(uid)",
                            title: title.isEmpty ? "115 网盘分享" : title, rootId: "0")
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let (code, _) = Self.decodeToken(session.stoken)
        let cookie = await loginCookie() ?? ""
        var all: [ShareFile] = []
        var offset = 0
        while offset < 100_000 {
            let data = try await snap(session.shareId, code: code, cid: dirId.nilIfBlank ?? "0", offset: offset, cookie: cookie)
            let files = Self.parseShareFiles(data["list"].array)
            all += files
            offset += files.count
            let total = data["count"].int
            if files.isEmpty || files.count < Self.pageLimit || (total > 0 && all.count >= total) { break }
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let (code, uid) = Self.decodeToken(session.stoken)
        guard !uid.isEmpty else { throw CloudnError("缺少分享者标识，请重新解析分享链接") }
        let cookie = await loginCookie()
        await refreshClientVersion()
        do {
            return try await shareDownURL(session.shareId, code: code, uid: uid, file: file, cookie: cookie ?? "")
        } catch {
            // 网页端对大文件拒发直链；已登录则走「转存 + 电脑端接口」
            guard let cookie else {
                if let e = error as? CloudnError, e.code == 50029 || e.code == 50028 {
                    throw CloudnError("该文件较大，115 只向客户端下发直链：请到「账号」页登录 115 网盘后重试", code: e.code)
                }
                throw error
            }
            return try await viaTempTransfer(session.shareId, code: code, file: file, cookie: cookie)
        }
    }

    /// cleanupToken = "<临时根目录 cid>|<本次子目录 cid>"
    public func cleanup(token: String) async {
        let parts = token.components(separatedBy: "|")
        guard parts.count == 2, let cookie = await loginCookie() else { return }
        _ = try? await post(apiBase + "/rb/delete", [("pid", parts[0]), ("fid[0]", parts[1]), ("ignore_warn", "1")], cookie: cookie)
    }

    // MARK: 账号

    /// 校验 Cookie：已登录时 data 为脱敏手机号
    public func fetchNickname(cookie: String) async -> String? {
        guard let json = try? await get(apiBase + "/user/info?ct=json", cookie: cookie), Self.ok(json) else { return nil }
        return json["data"].string.nilIfBlank ?? "115 网盘用户"
    }

    // MARK: 分享

    private func snap(_ shareCode: String, code: String, cid: String, offset: Int, cookie: String) async throws -> JSON {
        let url = apiBase + "/share/snap?share_code=\(shareCode.formEncoded)&receive_code=\(code.formEncoded)" +
            "&offset=\(offset)&limit=\(Self.pageLimit)&asc=0&cid=\(cid.formEncoded)&format=json"
        let json = try await get(url, cookie: cookie, referer: Self.shareReferer(shareCode, code))
        try Self.check(json, fallback: "获取分享列表失败")
        return json["data"]
    }

    /// share/downurl：必须用客户端 UA；响应头下发 path 绑定的 CDN Cookie，下载时要带上
    private func shareDownURL(_ shareCode: String, code: String, uid: String, file: ShareFile, cookie: String) async throws -> DownloadLink {
        var url = apiBase + "/share/downurl?dl=1&user_id=\(uid.formEncoded)&share_code=\(shareCode.formEncoded)&file_id=\(file.fid.formEncoded)"
        if !code.isEmpty { url += "&receive_code=\(code.formEncoded)" }
        let ua = await clientUA()
        let r = try await client.send(.get(url, headers: headers(cookie: cookie, referer: Self.shareReferer(shareCode, code), ua: ua)))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: "获取下载链接失败")
        let data = json["data"]
        let link = data["file_url_302"].string.nilIfBlank ?? data["file_url"].string.nilIfBlank ?? data["url"]["url"].string
        guard !link.isEmpty else { throw CloudnError("115 未返回下载链接") }
        return DownloadLink(fileName: file.name, url: link, size: Int64(data["fs"].string) ?? file.size,
                            headers: downloadHeaders(login: cookie, cdn: Self.cdnCookie(r.header("Set-Cookie")), ua: ua))
    }

    /// 转存到「Cloudn临时转存/tr_<唯一>」→ 按文件名认领 pickcode → 电脑端接口取链；cleanupToken 交给下载完成后清理
    private func viaTempTransfer(_ shareCode: String, code: String, file: ShareFile, cookie: String) async throws -> DownloadLink {
        let root = try await listPersonal(cid: "0", cookie: cookie)
        let tempRoot: String
        if let existing = root.first(where: { $0.isDirectory && $0.name == Self.tempDirName }) {
            tempRoot = existing.fid
        } else {
            tempRoot = try await createDir(Self.tempDirName, parent: "0", cookie: cookie)
        }
        let sub = try await createDir("tr_\(Int64(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<1_000_000))", parent: tempRoot, cookie: cookie)
        let cleanupToken = "\(tempRoot)|\(sub)"
        do {
            let json = try await post(apiBase + "/share/receive", [("share_code", shareCode), ("receive_code", code), ("file_id", file.fid), ("cid", sub)],
                                      cookie: cookie)
            try Self.check(json, fallback: "转存失败")
            // receive 不回传新文件 id：列目标目录按文件名认领
            var saved: ShareFile?
            for attempt in 0..<6 where saved == nil {
                if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
                saved = (try? await listPersonal(cid: sub, cookie: cookie))?.first { !$0.isDirectory && Self.matches($0.name, file.name) }
            }
            guard let saved, !saved.token.isEmpty else { throw CloudnError("分享文件转存后未找到，请稍后重试") }
            let link = try await appDownloadLink(pickCode: saved.token, cookie: cookie)
            return DownloadLink(fileName: file.name, url: link.url, size: link.size > 0 ? link.size : file.size,
                                headers: link.headers, cleanupToken: cleanupToken)
        } catch {
            await cleanup(token: cleanupToken)
            throw error
        }
    }

    /// 同名文件已存在时 115 会命名为「原名(1).后缀」
    static func matches(_ candidate: String, _ name: String) -> Bool {
        if candidate == name { return true }
        let ext = name.contains(".") ? name.substringAfterLast(".") : ""
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        guard candidate.hasPrefix(base + "(") else { return false }
        return ext.isEmpty ? candidate.hasSuffix(")") : candidate.hasSuffix(")." + ext)
    }

    private func listPersonal(cid: String, cookie: String) async throws -> [ShareFile] {
        let url = apiBase + "/files?aid=1&cid=\(cid.formEncoded)&o=user_ptime&asc=0&offset=0&show_dir=1&limit=\(Self.pageLimit)" +
            "&snap=0&natsort=1&record_open_time=1&count_folders=1&format=json"
        let json = try await get(url, cookie: cookie)
        try Self.check(json, fallback: "获取文件列表失败")
        // 文件夹没有 fid（自身 id 在 cid）；文件的 pc 是 pickcode
        return json["data"].array.compactMap { item in
            let fid = item["fid"].string
            let isDir = fid.isEmpty
            let id = isDir ? item["cid"].string : fid
            guard !id.isEmpty else { return nil }
            return ShareFile(fid: id, name: item["n"].string, size: isDir ? 0 : item["s"].int64, isDirectory: isDir, token: item["pc"].string)
        }
    }

    private func createDir(_ name: String, parent: String, cookie: String) async throws -> String {
        let json = try await post(apiBase + "/files/add", [("pid", parent), ("cname", name)], cookie: cookie)
        try Self.check(json, fallback: "创建临时目录失败")
        let cid = json["cid"].string.nilIfBlank ?? json["data"]["cid"].string
        guard !cid.isEmpty else { throw CloudnError("创建临时目录失败") }
        return cid
    }

    /// 电脑端接口：data = 加密({"pickcode":…})，响应 data 用同一个 key 解密
    private func appDownloadLink(pickCode: String, cookie: String) async throws -> DownloadLink {
        let key = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let payload = OrderedJSON.object([("pickcode", .string(pickCode))]).text
        let ua = await clientUA()
        let url = "https://proapi.115.com/app/chrome/downurl?t=\(Int64(Date().timeIntervalSince1970))"
        let r = try await client.send(.postForm(url, [("data", Pan115Crypto.encode(payload, key: key))],
                                                headers: headers(cookie: cookie, referer: Self.referer, ua: ua)))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: "获取下载链接失败")
        guard let plain = Pan115Crypto.decode(json["data"].string, key: key), let decoded = JSON(text: plain),
              let info = decoded.keys.map({ decoded[$0] }).first(where: { $0["url"].isObject }) else {
            throw CloudnError("115 电脑端接口未返回下载链接")
        }
        let link = info["url"]["url"].string
        guard !link.isEmpty else { throw CloudnError("115 电脑端接口未返回下载链接") }
        return DownloadLink(fileName: info["file_name"].string, url: link, size: info["file_size"].int64,
                            headers: downloadHeaders(login: cookie, cdn: Self.cdnCookie(r.header("Set-Cookie")), ua: ua))
    }

    // MARK: 请求

    private func refreshClientVersion() async {
        guard !(await state.markFetched()) else { return }
        guard let json = try? await get("https://appversion.115.com/1/web/1.0/api/chrome", cookie: "") else { return }
        let v = json["data"]["win"]["version_code"].string.trimmed
        if !v.isEmpty, v.count <= 16, v.first?.isNumber == true, v.allSatisfy({ $0.isNumber || $0 == "." }) {
            await state.setVersion(v)
        }
    }

    private func clientUA() async -> String {
        let version = await state.clientVersion
        return "Mozilla/5.0 115Browser/\(version)"
    }

    private func headers(cookie: String, referer: String, ua: String = Pan115Resolver.webUA) -> [(String, String)] {
        var h: [(String, String)] = [("User-Agent", ua), ("Accept", "application/json, text/plain, */*"),
                                     ("X-Requested-With", "XMLHttpRequest"), ("Referer", referer)]
        if !cookie.isEmpty { h.append(("Cookie", cookie)) }
        return h
    }

    private func downloadHeaders(login: String, cdn: String?, ua: String) -> [String: String] {
        let cookie = [login, cdn ?? ""].filter { !$0.isEmpty }.joined(separator: "; ")
        var h = ["User-Agent": ua, "Referer": Self.referer]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func get(_ url: String, cookie: String, referer: String = Pan115Resolver.referer) async throws -> JSON {
        let r = try await client.send(.get(url, headers: headers(cookie: cookie, referer: referer)))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        return json
    }

    private func post(_ url: String, _ fields: [(String, String)], cookie: String) async throws -> JSON {
        let r = try await client.send(.postForm(url, fields, headers: headers(cookie: cookie, referer: Self.referer)))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        return json
    }

    // MARK: 解析

    static func shareReferer(_ shareCode: String, _ code: String) -> String {
        code.isEmpty ? "https://115cdn.com/s/\(shareCode)" : "https://115cdn.com/s/\(shareCode)?password=\(code)&"
    }

    static func decodeToken(_ token: String) -> (code: String, uid: String) {
        guard let i = token.firstIndex(of: "|") else { return (token, "") }
        return (String(token[..<i]), String(token[token.index(after: i)...]))
    }

    /// 分享列表：fc == 0 为目录（id 取 cid），否则为文件（id 取 fid）
    static func parseShareFiles(_ items: [JSON]) -> [ShareFile] {
        items.compactMap { item in
            let fid = item["fid"].string
            let isDir = item.has("fc") ? item["fc"].int == 0 : fid.isEmpty
            let id = isDir ? item["cid"].string : fid
            guard !id.isEmpty else { return nil }
            return ShareFile(fid: id, name: item["n"].string, size: isDir ? 0 : item["s"].int64, isDirectory: isDir,
                             parentId: isDir ? item["pid"].string : item["cid"].string, modified: item["t"].string)
        }
    }

    /// 从 Set-Cookie 里挑出 path 绑定到对象路径的那条（直链 CDN 只认它），没有则取第一条
    static func cdnCookie(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let entries = Rx(#",\s*(?=[^;,\s=]+=)"#).replacing(in: raw, with: "\n").split(separator: "\n").map(String.init)
        var fallback: String?
        for entry in entries {
            let pair = entry.substringBefore(";").trimmed
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            let name = pair[..<eq].lowercased()
            if ["expires", "path", "domain", "max-age", "samesite"].contains(name) { continue }
            if fallback == nil { fallback = pair }
            if let path = Rx(#"(?:^|[;\s])path=([^;]+)"#, ignoreCase: true).first(in: entry)?.trimmed, !path.isEmpty, path != "/" {
                return pair
            }
        }
        return fallback
    }

    static func ok(_ json: JSON) -> Bool { json["state"].bool }

    static func check(_ json: JSON, fallback: String) throws {
        guard !ok(json) else { return }
        let errno = json.has("errno") ? json["errno"].int : json["errNo"].int
        let message: String
        switch errno {
        case 990001: message = "115 登录已过期，请到「账号」页重新登录"
        case 4100012: message = "该分享需要访问码，请填写后重试"
        case 4100008: message = "访问码错误，请检查后重试"
        case 4100026: message = "分享链接不存在或已被删除"
        case 990009: message = "上一次操作还没完成，请稍后重试"
        default: message = json.string("error", "msg").nilIfBlank ?? fallback
        }
        throw CloudnError(message, code: errno)
    }
}

/// 115 电脑端下载协议的加解密：请求 data = base64(RSA(key ‖ 对称变换后的明文))；
/// 响应 base64 → RSA 公钥还原 → 去掉 16 字节 salt → 对称变换还原明文。
/// RSA 在客户端侧只是公钥 modPow（服务端用私钥「加密」，公钥即可还原）。
enum Pan115Crypto {
    static let keyTable: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5
    ]
    static let longKey: [UInt8] = [0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46]
    static let modulus = BigUInt(hex: "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021" +
        "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633" +
        "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1" +
        "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683")!
    static let exponent = BigUInt(0x10001)
    static let block = 128

    static func encode(_ payload: String, key: [UInt8]) -> String {
        var body = Array(payload.utf8)
        xor(&body, deriveKey(key, 4))
        body.reverse()
        xor(&body, longKey)
        return Data(rsaEncrypt(key + body)).base64EncodedString()
    }

    static func decode(_ data: String, key: [UInt8]) -> String? {
        guard let raw = Crypto.base64Decode(data), let plain = rsaDecrypt([UInt8](raw)), plain.count > 16 else { return nil }
        let salt = Array(plain[0..<16])
        var body = Array(plain[16...])
        xor(&body, deriveKey(salt, 12))
        body.reverse()
        xor(&body, deriveKey(key, 4))
        return String(decoding: body, as: UTF8.self)
    }

    /// key[i] = ((seed[i] + T[size*i]) & 0xff) ^ T[size*(size-1-i)]
    static func deriveKey(_ seed: [UInt8], _ size: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            let left: UInt8 = keyTable[size * i]
            let right: UInt8 = keyTable[size * (size - 1 - i)]
            let sum: UInt8 = seed[i % seed.count] &+ left
            out[i] = sum ^ right
        }
        return out
    }

    /// 先处理 len % 4 的前缀，其余部分从 key 开头重新对齐
    static func xor(_ data: inout [UInt8], _ key: [UInt8]) {
        let offset = data.count % 4
        for i in 0..<data.count {
            data[i] ^= i < offset ? key[i % key.count] : key[(i - offset) % key.count]
        }
    }

    /// PKCS#1 v1.5 风格分块（117 字节一块，填充 0xff）后做公钥 modPow
    static func rsaEncrypt(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var offset = 0
        while offset < input.count {
            let size = min(block - 11, input.count - offset)
            var b = [UInt8](repeating: 0xff, count: block)
            b[0] = 0
            b[1] = 2
            let separator = block - size - 1
            b[separator] = 0
            b.replaceSubrange((separator + 1)..<block, with: input[offset..<(offset + size)])
            out += BigUInt(bytes: b).power(exponent, modulus: modulus).bytes(length: block)
            offset += size
        }
        return out
    }

    static func rsaDecrypt(_ input: [UInt8]) -> [UInt8]? {
        var out = [UInt8]()
        var offset = 0
        while offset < input.count {
            let size = min(block, input.count - offset)
            let plain = BigUInt(bytes: Array(input[offset..<(offset + size)])).power(exponent, modulus: modulus).bytes(length: block)
            guard let sep = plain[2...].firstIndex(of: 0) else { return nil }
            out += plain[(sep + 1)...]
            offset += size
        }
        return out
    }
}
