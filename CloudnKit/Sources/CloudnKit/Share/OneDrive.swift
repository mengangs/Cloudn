// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// OneDrive 分享解析（无需登录），两种来源走同一套 OneDrive v2.0 接口（shares/u!<base64 链接>/driveitem）：
// - 个人版（1drv.ms、onedrive.live.com）：先向 api-badgerp.svc.ms 换一个匿名 Badger 令牌，接口在 my.microsoftpersonalcontent.com；
// - 工作或学校版（*.sharepoint.com/:x:/…）：打开分享链接拿到访客 FedAuth Cookie，接口在该 SharePoint 站点。
// 列表里每个文件都带免 Cookie、支持断点的 @content.downloadUrl。设了密码的分享按 SharePoint 访客页表单提交密码换 FedAuth。
// SharePoint 访客 Cookie 与密码表单的做法参考 OpenList（AGPL-3.0）的 onedrive_sharelink 驱动。
import Foundation

public final class OneDriveResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .onedrive }
    public var supportsGuestDownload: Bool { true }

    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let personalAPI = "https://my.microsoftpersonalcontent.com/_api/v2.0"
    static let badgerURL = "https://api-badgerp.svc.ms/v1.0/token"
    /// OneDrive 网页版换匿名令牌用的应用 ID
    static let badgerAppId = "5cbed6ac-a083-4e14-b191-b4ba07653de2"
    static let itemFields = "id,name,size,folder,file,lastModifiedDateTime,parentReference,@content.downloadUrl"

    private let client: HTTPClient
    private let contexts = ContextCache()

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    /// 一次分享会话的访问方式
    struct Context: Sendable {
        /// 接口根：…/_api/v2.0
        let api: String
        /// 鉴权头：Badger 令牌或 FedAuth Cookie
        let auth: [(String, String)]
        let expiresAt: Date
        /// 分享根条目
        var root: ShareFile?
    }

    static func isSharePoint(_ url: String) -> Bool {
        URL(string: url)?.host?.lowercased().hasSuffix(".sharepoint.com") ?? false
    }

    /// shares 接口的分享 id：u! + base64url(链接)
    static func shareToken(_ url: String) -> String {
        "u!" + Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let link = share.url
        let password = pwd?.nilIfBlank ?? share.pwd
        var context = try await makeContext(link, password: password)
        let root = try await rootItem(link, context: &context, password: password)
        context.root = root
        await contexts.set(link, context)
        return ShareSession(platform: .onedrive, shareId: link, stoken: password ?? "", title: root.name.nilIfBlank ?? "OneDrive 分享",
                            rootId: root.isDirectory ? root.fid : "")
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let context = try await context(for: session)
        if dirId.isEmpty || session.rootId.isEmpty {
            guard let root = context.root else { throw CloudnError("OneDrive 会话已失效，请重新解析") }
            if !root.isDirectory { return [root] }
        }
        let first: String
        if dirId == session.rootId || dirId.isEmpty {
            first = "\(context.api)/shares/\(Self.shareToken(session.shareId))/driveitem/children?$top=200&$select=\(Self.itemFields)"
        } else {
            guard let drive = context.root?.token.nilIfBlank else {
                throw CloudnError("OneDrive 会话已失效，请重新解析")
            }
            first = "\(context.api)/drives/\(drive)/items/\(dirId)/children?$top=200&$select=\(Self.itemFields)"
        }
        var all: [ShareFile] = []
        var next: String? = first
        var pages = 0
        while let url = next, pages < 200 {
            pages += 1
            let json = try await get(url, context: context)
            all += json["value"].array.map { Self.parseItem($0, parent: dirId) }
            next = json["@odata.nextLink"].string.nilIfBlank
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let context = try await context(for: session)
        // 列表里的直链约 1 小时过期：取链时重新查一次条目
        let url: String
        if let root = context.root, root.fid == file.fid, !root.isDirectory {
            url = "\(context.api)/shares/\(Self.shareToken(session.shareId))/driveitem?$select=\(Self.itemFields)"
        } else {
            url = "\(context.api)/drives/\(file.token)/items/\(file.fid)?$select=\(Self.itemFields)"
        }
        let json = try await get(url, context: context)
        let link = json["@content.downloadUrl"].string
        guard !link.isEmpty else { throw CloudnError("OneDrive 没有返回下载地址，分享者可能禁止了下载") }
        let size = json["size"].int64 > 0 ? json["size"].int64 : file.size
        return DownloadLink(fileName: file.name, url: link, size: size, headers: ["User-Agent": Self.ua])
    }

    // MARK: 会话

    private func context(for session: ShareSession) async throws -> Context {
        if let c = await contexts.get(session.shareId), c.expiresAt > Date() { return c }
        var c = try await makeContext(session.shareId, password: session.stoken.nilIfBlank)
        c.root = await contexts.get(session.shareId)?.root
        if c.root == nil { c.root = try await rootItem(session.shareId, context: &c, password: session.stoken.nilIfBlank) }
        await contexts.set(session.shareId, c)
        return c
    }

    private func makeContext(_ link: String, password: String?) async throws -> Context {
        if Self.isSharePoint(link) {
            return try await sharePointContext(link, password: password)
        }
        return try await personalContext()
    }

    /// 个人版：匿名 Badger 令牌（约 1 小时有效）
    private func personalContext() async throws -> Context {
        let r = try await client.send(.postJSON(Self.badgerURL, ["appId": Self.badgerAppId], headers: [("User-Agent", Self.ua)]))
        guard let json = r.json, !json["token"].string.isEmpty else {
            throw CloudnError("OneDrive 匿名访问令牌获取失败（HTTP \(r.status)）")
        }
        let scheme = json["authScheme"].string.nilIfBlank ?? "Badger"
        return Context(api: Self.personalAPI, auth: [("Authorization", "\(scheme) \(json["token"].string)"), ("Prefer", "autoredeem")],
                       expiresAt: Date().addingTimeInterval(45 * 60), root: nil)
    }

    /// 工作或学校版：打开分享链接，服务端在 302 里种下访客 FedAuth
    private func sharePointContext(_ link: String, password: String?) async throws -> Context {
        guard let host = URL(string: link)?.host else { throw CloudnError("OneDrive 分享链接无效") }
        let api = "https://\(host)/_api/v2.0"
        let r = try await client.send(HTTPRequest(url: link, headers: [("User-Agent", Self.ua)], followRedirects: false))
        if let fed = r.cookie("FedAuth") {
            return Context(api: api, auth: [("Cookie", "FedAuth=\(fed)")], expiresAt: Date().addingTimeInterval(45 * 60), root: nil)
        }
        if r.status == 404 { throw CloudnError("OneDrive 分享链接不存在或已失效") }
        // 没有 302：多半是密码页
        if r.text.contains("txtPassword") || r.text.contains("inputForm") {
            guard let password else { throw CloudnError("此 OneDrive 分享设置了密码，请填写密码后重新解析") }
            let fed = try await submitPassword(page: r, url: link, password: password)
            return Context(api: api, auth: [("Cookie", "FedAuth=\(fed)")], expiresAt: Date().addingTimeInterval(45 * 60), root: nil)
        }
        throw CloudnError("OneDrive 分享无法访问（HTTP \(r.status)），可能需要登录组织账号")
    }

    /// 分享根条目；个人版遇到密码时改用访客页表单换 FedAuth 再访问
    private func rootItem(_ link: String, context: inout Context, password: String?) async throws -> ShareFile {
        let url = "\(context.api)/shares/\(Self.shareToken(link))/driveitem?$select=\(Self.itemFields)"
        do {
            return Self.parseItem(try await get(url, context: context), parent: "")
        } catch let e as PasswordRequired {
            guard let password else { throw CloudnError("此 OneDrive 分享设置了密码，请填写密码后重新解析") }
            guard let fixURL = e.fixItURL.nilIfBlank, let host = URL(string: fixURL)?.host else {
                throw CloudnError("OneDrive 密码分享暂不支持，请在浏览器中打开")
            }
            let page = try await client.send(HTTPRequest(url: fixURL, headers: [("User-Agent", Self.ua)]))
            let fed = try await submitPassword(page: page, url: page.url, password: password)
            context = Context(api: "https://\(host)/_api/v2.0", auth: [("Cookie", "FedAuth=\(fed)")],
                              expiresAt: Date().addingTimeInterval(45 * 60), root: nil)
            return Self.parseItem(try await get(url.replacingOccurrences(of: Self.personalAPI, with: context.api), context: context), parent: "")
        }
    }

    /// SharePoint 访客密码页：带上 __VIEWSTATE / __EVENTVALIDATION 提交 txtPassword，成功时种下 FedAuth
    private func submitPassword(page: HTTPResponse, url: String, password: String) async throws -> String {
        let html = page.text
        func input(_ id: String) -> String {
            Rx(#"<input[^>]*id="\#(id)"[^>]*value="([^"]*)""#).first(in: html)
                ?? Rx(#"<input[^>]*value="([^"]*)"[^>]*id="\#(id)""#).first(in: html) ?? ""
        }
        guard let action = Rx(#"<form[^>]*id="inputForm"[^>]*action="([^"]*)""#).first(in: html)
                ?? Rx(#"<form[^>]*action="([^"]*)"[^>]*id="inputForm""#).first(in: html),
              let base = URL(string: url), let target = URL(string: GoogleDriveResolver.decodeEntities(action), relativeTo: base)?.absoluteString else {
            throw CloudnError("OneDrive 密码页解析失败，请在浏览器中打开")
        }
        let fields = [("txtPassword", password), ("__EVENTVALIDATION", GoogleDriveResolver.decodeEntities(input("__EVENTVALIDATION"))),
                      ("__VIEWSTATE", GoogleDriveResolver.decodeEntities(input("__VIEWSTATE"))), ("__VIEWSTATEENCRYPTED", "")]
        let r = try await client.send(.postForm(target, fields, headers: [("User-Agent", Self.ua)], followRedirects: false))
        guard let fed = r.cookie("FedAuth") else { throw CloudnError("OneDrive 分享密码不正确") }
        return fed
    }

    // MARK: 请求

    struct PasswordRequired: Error {
        let fixItURL: String
    }

    private func get(_ url: String, context: Context) async throws -> JSON {
        var headers: [(String, String)] = [("User-Agent", Self.ua), ("Accept", "application/json;odata.metadata=minimal")]
        headers += context.auth
        let r = try await client.send(HTTPRequest(url: url, headers: headers))
        guard let json = r.json else { throw CloudnError("OneDrive 响应解析失败（HTTP \(r.status)）") }
        if r.isSuccess { return json }
        let error = json["error"]
        let inner = error["innerError"]["code"].string.nilIfBlank ?? error["innererror"]["code"].string
        if inner == "sharingPasswordRequired" { throw PasswordRequired(fixItURL: error["@error.fixItUrl"].string) }
        if inner == "sharingPasswordIncorrect" { throw CloudnError("OneDrive 分享密码不正确") }
        switch r.status {
        case 401, 403: throw CloudnError("OneDrive 分享已失效或只允许指定的人访问")
        case 404: throw CloudnError("OneDrive 分享里的文件不存在或已被删除")
        default: throw CloudnError("OneDrive：\(error["message"].string.nilIfBlank ?? "请求失败（HTTP \(r.status)）")")
        }
    }

    /// token 存所在的 driveId（子目录与取链都要用）
    static func parseItem(_ j: JSON, parent: String) -> ShareFile {
        ShareFile(fid: j["id"].string, name: j["name"].string, size: j["size"].int64, isDirectory: j.has("folder"),
                  parentId: parent, token: j["parentReference"]["driveId"].string, modified: j["lastModifiedDateTime"].string)
    }

    private actor ContextCache {
        var map: [String: Context] = [:]
        func get(_ k: String) -> Context? { map[k] }
        func set(_ k: String, _ v: Context) { map[k] = v }
    }
}
