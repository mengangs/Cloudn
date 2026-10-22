// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// WebDAV（坚果云、群晖 / NAS、Alist / OpenList 的 /dav 等）我的网盘：PROPFIND 列目录、MKCOL 新建、
// MOVE 重命名 / 移动（Overwrite: F）、DELETE 删除、PUT 上传、quota-*-bytes 容量。
// 协议细节参考 OpenList（AGPL-3.0）drivers/webdav 与其使用的 gowebdav；RFC 4918 / RFC 4331。
// WebDAV 没有分享链接：只提供「我的网盘」。
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// WebDAV 登录凭据：服务地址（含路径）+ 用户名 + 密码，以 JSON 存在账号的 Cookie 槽位里
public struct WebDAVCredential: Equatable, Sendable {
    /// 规范化后的服务地址：带协议、以 / 结尾，例如 https://dav.jianguoyun.com/dav/
    public var url: String
    public var username: String
    public var password: String

    public init(url: String, username: String, password: String) {
        self.url = WebDAVCredential.normalizeURL(url)
        self.username = username
        self.password = password
    }

    /// 解析存储的 JSON（兼容 address / user / pass 等别名）；地址不合法返回 nil
    public static func parse(_ raw: String) -> WebDAVCredential? {
        let text = raw.trimmed
        guard text.hasPrefix("{"), let obj = JSON(text: text), obj.isObject else { return nil }
        let url = obj.string("url", "address", "server", "host")
        guard !url.isEmpty else { return nil }
        let cred = WebDAVCredential(url: url, username: obj.string("username", "user", "account"),
                                    password: obj.string("password", "pass"))
        return cred.base == nil ? nil : cred
    }

    public var serialized: String {
        OrderedJSON.object([("url", .string(url)), ("username", .string(username)), ("password", .string(password))]).text
    }

    /// 补上协议、去掉查询串、路径以 / 结尾
    static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmed
        guard !s.isEmpty else { return s }
        // 没写协议默认 https；写了别的协议（ftp:// 等）原样保留，随后的地址校验会拒绝
        if !s.contains("://") { s = "https://" + s }
        // 部分客户端的写法：davs:// / dav://
        if s.lowercased().hasPrefix("davs://") { s = "https://" + s.dropFirst(7) }
        if s.lowercased().hasPrefix("dav://") { s = "http://" + s.dropFirst(6) }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        // 只有主机名时补根路径
        let afterScheme = s.range(of: "://").map { s[$0.upperBound...] } ?? Substring(s)
        if !afterScheme.contains("/") { s += "/" }
        if !s.hasSuffix("/") { s += "/" }
        return s
    }

    /// 协议 + 主机（含端口）与基础路径（已编码，以 / 结尾）
    var base: (origin: String, path: String)? {
        guard let comps = URLComponents(string: url), let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = comps.host, !host.isEmpty else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = comps.port { origin += ":\(port)" }
        var path = comps.percentEncodedPath
        if path.isEmpty { path = "/" }
        if !path.hasSuffix("/") { path += "/" }
        return (origin, path)
    }

    /// 基础路径（解码后、以 / 结尾），用来把服务端返回的 href 换成相对路径
    var decodedBasePath: String {
        let p = base?.path ?? "/"
        return p.removingPercentEncoding ?? p
    }

    /// 显示用的主机名（非默认端口带上端口）
    var host: String? {
        guard let comps = URLComponents(string: url), let host = comps.host else { return nil }
        if let port = comps.port { return "\(host):\(port)" }
        return host
    }

    /// Basic 认证头；没填账号密码时不带
    var authorization: String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

public final class WebDAVResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .webdav }
    public var supportsGuestDownload: Bool { false }

    private let credentials: CredentialStore
    private let client: HTTPClient

    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared) {
        self.credentials = credentials
        self.client = client
    }

    static let userAgent = "Cloudn-WebDAV/1.0"

    /// 登录表单：把地址、账号、密码拼成要保存的凭据串（随后走正常的 normalizeCredential + validate）
    public static func makeCredential(url: String, username: String, password: String) -> String {
        WebDAVCredential(url: url, username: username.trimmed, password: password).serialized
    }

    /// 凭据里的服务器主机名（账号列表里显示）
    public static func displayHost(_ credential: String) -> String? {
        WebDAVCredential.parse(credential)?.host
    }

    /// WebDAV 没有分享链接
    static func shareTarget(_ url: String) -> (id: String, pwd: String?)? { nil }

    /// 凭据统一成保存的形态（规范化地址后的 JSON）
    static func normalizeCredential(_ raw: String) -> String {
        WebDAVCredential.parse(raw)?.serialized ?? raw.trimmed
    }

    /// 对根目录 PROPFIND（Depth: 0）：成功返回「用户名@主机」，认证失败 / 不是 WebDAV 返回 nil
    static func validate(cookie: String) async -> String? {
        guard let cred = WebDAVCredential.parse(cookie), let host = cred.host else { return nil }
        let resolver = WebDAVResolver()
        guard (try? await resolver.propfind(cred, path: "/", depth: "0", body: propfindBody)) != nil else { return nil }
        return cred.username.isEmpty ? host : "\(cred.username)@\(host)"
    }

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        throw CloudnError("WebDAV 没有分享链接，请在「我的网盘」里浏览")
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] { [] }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        throw CloudnError("WebDAV 没有分享链接，请在「我的网盘」里下载")
    }

    // MARK: 请求

    private func credential() async throws -> WebDAVCredential {
        guard let raw = await credentials.cookie(for: .webdav)?.nilIfBlank, let cred = WebDAVCredential.parse(raw) else {
            throw SharePlatform.webdav.loginRequired
        }
        return cred
    }

    /// ASCII 非保留字符之外一律百分号编码（中文、空格、#、? 等）
    static let segmentAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@")
        return set
    }()

    /// 相对路径（解码后，以 / 开头）→ 完整地址；目录可要求以 / 结尾
    static func resourceURL(_ cred: WebDAVCredential, path: String, directory: Bool = false) -> String {
        guard let base = cred.base else { return cred.url }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? String($0)
        }
        var url = base.origin + base.path + segments.joined(separator: "/")
        if directory && !segments.isEmpty && !url.hasSuffix("/") { url += "/" }
        return url
    }

    /// 服务端返回的 href（完整地址或路径，已编码）→ 相对路径（解码后，以 / 开头，不以 / 结尾；根为 /）
    static func relativePath(href: String, cred: WebDAVCredential) -> String {
        var path = href.trimmed
        if let comps = URLComponents(string: path), comps.scheme != nil {
            path = comps.percentEncodedPath
        } else if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<q])
        }
        var decoded = path.removingPercentEncoding ?? path
        if !decoded.hasPrefix("/") { decoded = "/" + decoded }
        let base = cred.decodedBasePath
        if decoded.hasPrefix(base) {
            decoded = "/" + decoded.dropFirst(base.count)
        } else if decoded + "/" == base {
            decoded = "/"
        } else if decoded.lowercased().hasPrefix(base.lowercased()) {
            // 个别服务端返回的大小写与配置的地址不同
            decoded = "/" + decoded.dropFirst(base.count)
        }
        while decoded.count > 1 && decoded.hasSuffix("/") { decoded.removeLast() }
        while decoded.contains("//") { decoded = decoded.replacingOccurrences(of: "//", with: "/") }
        return decoded
    }

    static func parentPath(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/"), i != path.startIndex else { return "/" }
        return String(path[..<i])
    }

    static func join(_ parent: String, _ name: String) -> String {
        (parent == "/" || parent.isEmpty ? "" : parent) + "/" + name
    }

    private func headers(_ cred: WebDAVCredential, _ extra: [(String, String)] = []) -> [(String, String)] {
        var h: [(String, String)] = [("User-Agent", Self.userAgent)]
        if let auth = cred.authorization { h.append(("Authorization", auth)) }
        return h + extra
    }

    static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/>\
    <d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
    """

    static let quotaBody = """
    <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:quota-available-bytes/>\
    <d:quota-used-bytes/></d:prop></d:propfind>
    """

    static func statusError(_ status: Int, action: String) -> CloudnError {
        switch status {
        case 401: return CloudnError("WebDAV 账号或密码错误，请重新登录")
        case 403: return CloudnError("没有权限\(action)")
        case 404: return CloudnError("文件不存在或已被删除")
        case 405: return CloudnError("服务器不允许\(action)（可能已存在同名文件）")
        case 409: return CloudnError("目标文件夹不存在")
        case 412: return CloudnError("目标位置已有同名文件")
        case 423: return CloudnError("文件已被锁定")
        case 507: return CloudnError("WebDAV 空间不足")
        default: return CloudnError("\(action)失败（HTTP \(status)）")
        }
    }

    func propfind(_ cred: WebDAVCredential, path: String, depth: String, body: String) async throws -> [WebDAVEntry] {
        let req = HTTPRequest(url: Self.resourceURL(cred, path: path, directory: true), method: "PROPFIND",
                              headers: headers(cred, [("Depth", depth), ("Content-Type", "application/xml; charset=utf-8")]),
                              body: Data(body.utf8))
        let r = try await client.send(req)
        guard r.status == 207 || r.status == 200 else { throw Self.statusError(r.status, action: "读取目录") }
        guard let entries = WebDAVMultistatus.parse(r.body) else { throw CloudnError("服务器返回的不是 WebDAV 目录") }
        return entries
    }

    private func perform(_ cred: WebDAVCredential, method: String, url: String, extra: [(String, String)] = [], action: String) async throws {
        let r = try await client.send(HTTPRequest(url: url, method: method, headers: headers(cred, extra)))
        guard (200..<300).contains(r.status) else { throw Self.statusError(r.status, action: action) }
    }

    /// 移动 / 重命名：目录的源地址以 / 结尾（与 gowebdav 一致），不覆盖同名
    private func moveItem(_ cred: WebDAVCredential, from path: String, isDirectory: Bool, to dest: String, action: String) async throws {
        try await perform(cred, method: "MOVE", url: Self.resourceURL(cred, path: path, directory: isDirectory),
                          extra: [("Destination", Self.resourceURL(cred, path: dest)), ("Overwrite", "F")], action: action)
    }
}

// MARK: - 我的网盘

extension WebDAVResolver: DriveManager {
    /// 目录 id 为相对凭据地址的路径（解码后），根为 /
    public var driveRootId: String { "/" }
    public var driveCapabilities: DriveCapabilities { [.createFolder, .rename, .move, .delete] }

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        let cred = try await credential()
        let dir = folderId.isEmpty ? "/" : folderId
        let entries = try await propfind(cred, path: dir, depth: "1", body: Self.propfindBody)
        return Self.files(entries, in: dir, cred: cred)
    }

    /// PROPFIND 结果 → 文件列表：去掉目录自身，名字取 href 末段（displayname 兜底）
    static func files(_ entries: [WebDAVEntry], in dir: String, cred: WebDAVCredential) -> [ShareFile] {
        let current = relativePath(href: resourceURL(cred, path: dir, directory: true), cred: cred)
        var seen = Set<String>()
        var result: [ShareFile] = []
        for e in entries {
            let path = relativePath(href: e.href, cred: cred)
            guard path != current, path != "/", !seen.contains(path) else { continue }
            seen.insert(path)
            let last = path.substringAfterLast("/", default: path)
            let name = last.isEmpty ? e.displayName : last
            guard !name.isEmpty else { continue }
            result.append(ShareFile(fid: path, name: name, size: e.isCollection ? 0 : e.size, isDirectory: e.isCollection,
                                    parentId: parentPath(path), modified: listText(e.lastModified)))
        }
        return result
    }

    /// getlastmodified（RFC 1123）→「yyyy-MM-dd HH:mm」，认不出原样返回
    static func listText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            input.dateFormat = format
            if let date = input.date(from: text) {
                let out = DateFormatter()
                out.locale = Locale(identifier: "en_US_POSIX")
                out.dateFormat = "yyyy-MM-dd HH:mm"
                return out.string(from: date)
            }
        }
        return ISO8601DateFormatter.listText(text)
    }

    /// 文件地址 + Basic 认证头。Alist / OpenList 的 /dav 会 302 到真实存储：先不跟随跳转 HEAD 一次取 Location，
    /// 跳到别的主机时不再带认证头（直链自带签名）
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹不能直接下载") }
        let cred = try await credential()
        let url = Self.resourceURL(cred, path: file.fid)
        var headers = ["User-Agent": Self.userAgent]
        if let auth = cred.authorization { headers["Authorization"] = auth }
        // 用 HEAD 探测：不支持 Range 的服务端对 GET 会回整个文件
        let probe = HTTPRequest(url: url, method: "HEAD", headers: self.headers(cred), followRedirects: false, timeout: 20)
        if let r = try? await client.send(probe) {
            if r.status == 401 { throw Self.statusError(401, action: "下载") }
            if r.status == 404 { throw Self.statusError(404, action: "下载") }
            if [301, 302, 303, 307, 308].contains(r.status), let location = r.header("location")?.nilIfBlank,
               let target = URL(string: location, relativeTo: URL(string: url))?.absoluteURL.absoluteString {
                if URL(string: target)?.host?.lowercased() != URL(string: url)?.host?.lowercased() {
                    headers.removeValue(forKey: "Authorization")
                }
                return DownloadLink(fileName: file.name, url: target, size: file.size, headers: headers)
            }
        }
        return DownloadLink(fileName: file.name, url: url, size: file.size, headers: headers)
    }

    public func createFolder(_ name: String, in parentId: String) async throws {
        let cred = try await credential()
        let path = Self.join(parentId.isEmpty ? "/" : parentId, name)
        try await perform(cred, method: "MKCOL", url: Self.resourceURL(cred, path: path, directory: true), action: "新建文件夹")
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        let cred = try await credential()
        let dest = Self.join(Self.parentPath(file.fid), name)
        guard dest != file.fid else { return }
        try await moveItem(cred, from: file.fid, isDirectory: file.isDirectory, to: dest, action: "重命名")
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        let cred = try await credential()
        let target = folderId.isEmpty ? "/" : folderId
        for file in files {
            let dest = Self.join(target, file.name)
            guard dest != file.fid else { continue }
            try await moveItem(cred, from: file.fid, isDirectory: file.isDirectory, to: dest, action: "移动")
        }
    }

    public func delete(_ files: [ShareFile]) async throws {
        let cred = try await credential()
        for file in files {
            try await perform(cred, method: "DELETE", url: Self.resourceURL(cred, path: file.fid, directory: file.isDirectory), action: "删除")
        }
    }

    /// RFC 4331 quota-used-bytes / quota-available-bytes；服务端不支持时返回 nil
    public func quota() async -> DriveQuota? {
        guard let cred = try? await credential(),
              let entries = try? await propfind(cred, path: "/", depth: "0", body: Self.quotaBody) else { return nil }
        return Self.quota(entries)
    }

    static func quota(_ entries: [WebDAVEntry]) -> DriveQuota? {
        guard let e = entries.first(where: { $0.quotaUsed != nil || $0.quotaAvailable != nil }) else { return nil }
        let used = max(0, e.quotaUsed ?? 0)
        guard let available = e.quotaAvailable, available >= 0 else { return nil }
        return DriveQuota(used: used, total: used + available)
    }
}

// MARK: - 上传

extension WebDAVResolver: DriveUploader {
    /// PUT 整个文件（流式从磁盘读，不进内存）
    public func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws {
        let cred = try await credential()
        let size = FileChunks.size(of: file)
        let url = Self.resourceURL(cred, path: Self.join(folderId.isEmpty ? "/" : folderId, name))
        let req = HTTPRequest(url: url, method: "PUT", headers: headers(cred, [("Content-Type", "application/octet-stream")]))
        progress(.uploading, 0)
        let r = try await client.upload(req, body: .file(file, offset: 0, length: size)) { sent in
            progress(.uploading, size > 0 ? Double(sent) / Double(size) : 1)
        }
        guard (200..<300).contains(r.status) else { throw Self.statusError(r.status, action: "上传") }
        progress(.finishing, 1)
    }
}

// MARK: - PROPFIND 响应解析

/// multistatus 里的一条 response（只取 200 的 propstat）
struct WebDAVEntry: Equatable, Sendable {
    var href = ""
    var displayName = ""
    var size: Int64 = 0
    var lastModified = ""
    var isCollection = false
    var quotaUsed: Int64?
    var quotaAvailable: Int64?
}

/// 最小的 multistatus 解析器（XMLParser）：忽略命名空间前缀（D: / d: / lp1: 等）
final class WebDAVMultistatus: NSObject, XMLParserDelegate {
    private var entries: [WebDAVEntry] = []
    private var current: WebDAVEntry?
    private var pending = WebDAVEntry()
    private var propstatStatus = ""
    private var inPropstat = false
    private var stack: [String] = []
    private var text = ""
    private var sawMultistatus = false

    /// 不是合法的 multistatus 返回 nil
    static func parse(_ data: Data) -> [WebDAVEntry]? {
        let delegate = WebDAVMultistatus()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() || !delegate.entries.isEmpty, delegate.sawMultistatus else { return nil }
        return delegate.entries
    }

    private static func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = Self.local(elementName)
        stack.append(name)
        text = ""
        switch name {
        case "multistatus": sawMultistatus = true
        case "response": current = WebDAVEntry()
        case "propstat":
            inPropstat = true
            propstatStatus = ""
            pending = WebDAVEntry()
        case "collection" where stack.contains("resourcetype"): pending.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.local(elementName)
        let value = text.trimmed
        if stack.last == name { stack.removeLast() }
        switch name {
        case "href" where !inPropstat:
            if current?.href.isEmpty == true { current?.href = value }
        case "status" where inPropstat: propstatStatus = value
        case "displayname": pending.displayName = value
        case "getcontentlength": pending.size = Int64(value) ?? 0
        case "getlastmodified": pending.lastModified = value
        case "quota-used-bytes": pending.quotaUsed = Int64(value)
        case "quota-available-bytes": pending.quotaAvailable = Int64(value)
        case "propstat":
            inPropstat = false
            // 没写状态或 2xx 的才算数（不支持的属性会放在 404 的 propstat 里）
            let ok = propstatStatus.isEmpty || propstatStatus.range(of: #"\s2\d\d(\s|$)"#, options: .regularExpression) != nil
            if ok, var c = current {
                if !pending.displayName.isEmpty { c.displayName = pending.displayName }
                if pending.size > 0 { c.size = pending.size }
                if !pending.lastModified.isEmpty { c.lastModified = pending.lastModified }
                if pending.isCollection { c.isCollection = true }
                if let q = pending.quotaUsed { c.quotaUsed = q }
                if let q = pending.quotaAvailable { c.quotaAvailable = q }
                current = c
            }
        case "response":
            if let c = current, !c.href.isEmpty { entries.append(c) }
            current = nil
        default: break
        }
        text = ""
    }
}
