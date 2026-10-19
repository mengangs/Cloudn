// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 百度网盘分享解析：share/verify 换 sekey → xpan/share 列目录 → 转存到临时目录 → locatedownload 取明文直链 → 删除转存。
// 协议细节参考 YunX（AGPL-3.0）的 BaiduApi / BaiduResolveRepository。
// 我的网盘管理参考 YunX（AGPL-3.0）的 BaiduApi 云盘接口与 BaiduCloudViewModel。
import Foundation

public final class BaiduResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .baidu }
    public var supportsGuestDownload: Bool { false }

    public static let loginURL = "https://pan.baidu.com/"
    public static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let netdiskUA = "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0"
    static let appId = "250528"
    static let tempDirName = "Cloudn临时转存"

    private let credentials: CredentialStore
    private let client: HTTPClient
    private let state = State()

    /// surl → (share_id, uk)，转存时必需，由列表接口返回
    private actor State {
        var shareInfo: [String: (shareId: String, uk: String)] = [:]
        var bdstoken: [String: String] = [:]
        func setInfo(_ surl: String, _ shareId: String, _ uk: String) { shareInfo[surl] = (shareId, uk) }
        func setToken(_ cookie: String, _ v: String) { bdstoken[cookie] = v }
    }

    public init(credentials: CredentialStore, client: HTTPClient = .shared) {
        self.credentials = credentials
        self.client = client
    }

    private func loginCookie() async -> String? {
        guard let c = await credentials.cookie(for: .baidu), Self.isValidCookie(c) else { return nil }
        return c
    }

    public static func isValidCookie(_ cookie: String) -> Bool { CookieUtil.value(of: "BDUSS", in: cookie)?.isEmpty == false }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let cookie = await loginCookie() ?? ""
        let effective = pwd?.nilIfBlank ?? share.pwd ?? ""
        // 公开分享跳过 verify，sekey 为空即可直接列目录
        var sekey = ""
        if !effective.isEmpty { sekey = try await verify(share.shareId, pwd: effective, cookie: cookie) }
        var session = ShareSession(platform: .baidu, shareId: share.shareId, stoken: sekey, title: "百度网盘分享", rootId: "/")
        let page = try await listPage(session, dir: "/", page: 1, cookie: cookie)
        let title = page.title.substringAfterLast("/").trimmed
        if !title.isEmpty {
            session = ShareSession(platform: .baidu, shareId: share.shareId, stoken: sekey, title: title, rootId: "/")
        }
        return session
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let cookie = await loginCookie() ?? ""
        var all: [ShareFile] = []
        var page = 1
        while page <= 100 {
            let result = try await listPage(session, dir: dirId.nilIfBlank ?? "/", page: page, cookie: cookie)
            all += result.files
            if result.files.count < 100 { break }
            page += 1
        }
        return all
    }

    /// 转存到临时目录 → locatedownload 取 appall 明文直链（自带签名，删除转存后仍有效）→ 立即删除转存
    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard let cookie = await loginCookie() else {
            throw CloudnError("百度网盘需要登录后才能下载，请到「我的」页登录百度网盘")
        }
        let info = try await shareInfo(session, cookie: cookie)
        let bdstoken = try await self.bdstoken(cookie)
        let dir = await ensureTempDir(cookie: cookie, bdstoken: bdstoken)
        guard let saved = try await transfer(info: info, sekey: session.stoken, fsIds: [file.fid], toDir: dir, cookie: cookie, bdstoken: bdstoken).first else {
            throw CloudnError("转存失败：未返回新文件")
        }
        let link: String
        do {
            link = try await locateDownload(saved, cookie: cookie)
        } catch {
            await delete(saved, cookie: cookie, bdstoken: bdstoken)
            throw error
        }
        await delete(saved, cookie: cookie, bdstoken: bdstoken)
        return DownloadLink(fileName: file.name, url: link, size: file.size,
                            headers: ["User-Agent": Self.netdiskUA, "Cookie": cookie])
    }

    // MARK: 账号

    public func fetchNickname(cookie: String) async -> String? {
        guard let result = await templateVariable(cookie, fields: #"["username"]"#) else { return nil }
        return result["username"].string.nilIfBlank ?? "百度网盘用户"
    }

    // MARK: 分享

    private func verify(_ surl: String, pwd: String, cookie: String) async throws -> String {
        let r = try await client.send(.postForm("https://pan.baidu.com/share/verify?surl=\(surl)", [("pwd", pwd), ("vcode_str", ""), ("vcode", "")],
                                                headers: [("Cookie", cookie), ("User-Agent", Self.webUA), ("Referer", "https://pan.baidu.com/s/1\(surl)")]))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        if json["errno"].int == -12 || json["errno"].int == -9 { throw CloudnError("提取码错误，请检查后重新解析", code: json["errno"].int) }
        try Self.check(json, fallback: "验证提取码失败")
        // randsk 已是 URL 编码形式，直接作为 sekey / BDCLND 使用
        let randsk = json["randsk"].string
        guard !randsk.isEmpty else { throw CloudnError("未返回分享密钥") }
        return randsk
    }

    struct Page {
        let title: String
        let files: [ShareFile]
    }

    private func listPage(_ session: ShareSession, dir: String, page: Int, cookie: String) async throws -> Page {
        let surl = session.shareId
        let sekey = session.stoken
        let isRoot = dir == "/"
        // 子目录必须 root=0（root=1 时百度忽略 dir），且要带 BDCLND（= randsk）
        var url = "https://pan.baidu.com/rest/2.0/xpan/share?method=list&shorturl=\(surl)&page=\(page)&num=100" +
            "&root=\(isRoot ? 1 : 0)&dir=\(dir.formEncoded)"
        if !sekey.isEmpty { url += "&sekey=\(sekey)" }
        let r = try await client.send(.get(url, headers: [("Cookie", Self.withBDCLND(cookie, sekey)), ("User-Agent", Self.webUA),
                                                          ("Referer", "https://pan.baidu.com/s/1\(surl)")]))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        let errno = json["errno"].int
        if errno != 0 && sekey.isEmpty {
            throw CloudnError(errno == -6 ? "该分享需要提取码，或需要先登录百度网盘" : "该分享需要提取码", code: errno)
        }
        try Self.check(json, fallback: "获取分享文件列表失败")
        await state.setInfo(surl, json["share_id"].string, json["uk"].string)
        let files = json["list"].array.map { item -> ShareFile in
            let isDir = item["isdir"].string == "1"
            let path = item["path"].string
            // 目录用 path 导航、文件用 fs_id 取链；token 统一存 fs_id，文件夹转存要用
            return ShareFile(fid: isDir ? path : item["fs_id"].string, name: item["server_filename"].string, size: item["size"].int64,
                             isDirectory: isDir, parentId: dir, token: item["fs_id"].string, modified: item["server_mtime"].string)
        }
        return Page(title: json["title"].string, files: files)
    }

    private func shareInfo(_ session: ShareSession, cookie: String) async throws -> (shareId: String, uk: String) {
        if let info = await state.shareInfo[session.shareId], !info.shareId.isEmpty { return info }
        _ = try await listPage(session, dir: "/", page: 1, cookie: cookie)
        guard let info = await state.shareInfo[session.shareId], !info.shareId.isEmpty else { throw CloudnError("未获取到分享信息") }
        return info
    }

    static func withBDCLND(_ cookie: String, _ sekey: String) -> String {
        guard !sekey.isEmpty, CookieUtil.value(of: "BDCLND", in: cookie) == nil else { return cookie }
        return cookie.isEmpty ? "BDCLND=\(sekey)" : "\(cookie); BDCLND=\(sekey)"
    }

    // MARK: 转存与取链

    private func templateVariable(_ cookie: String, fields: String) async -> JSON? {
        let url = "https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=\(Self.appId)&web=1&fields=\(fields.formEncoded)"
        guard let r = try? await client.send(.get(url, headers: [("Cookie", cookie), ("User-Agent", Self.webUA)])),
              let json = r.json, json["errno"].int == 0, json.has("errno") else { return nil }
        return json["result"]
    }

    private func bdstoken(_ cookie: String) async throws -> String {
        if let cached = await state.bdstoken[cookie] { return cached }
        guard let token = await templateVariable(cookie, fields: #"["bdstoken"]"#)?["bdstoken"].string, !token.isEmpty else {
            throw CloudnError("百度网盘登录已失效，请到「我的」页重新登录")
        }
        await state.setToken(cookie, token)
        return token
    }

    /// 临时目录已存在就复用，否则创建；创建失败退回根目录
    private func ensureTempDir(cookie: String, bdstoken: String) async -> String {
        let dir = "/" + Self.tempDirName
        let listURL = "https://pan.baidu.com/api/list?clienttype=0&app_id=\(Self.appId)&web=1&order=time&desc=1&dir=%2F&num=1000&page=1"
        if let r = try? await client.send(.get(listURL, headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA)])),
           let json = r.json, json["list"].array.contains(where: { $0["path"].string == dir }) {
            return dir
        }
        let create = "https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1&app_id=\(Self.appId)&clienttype=0&bdstoken=\(bdstoken)"
        let r = try? await client.send(.postForm(create, [("path", dir), ("isdir", "1"), ("block_list", "[]"), ("method", "post"), ("dataType", "json")],
                                                 headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA), ("Referer", "https://yun.baidu.com/disk/main")]))
        return r?.json?["errno"].int == 0 && r?.json?.has("errno") == true ? dir : "/"
    }

    /// 同步转存，返回转存后的完整路径（与 fsIds 同序）
    private func transfer(info: (shareId: String, uk: String), sekey: String, fsIds: [String], toDir: String,
                          cookie: String, bdstoken: String) async throws -> [String] {
        let url = "https://pan.baidu.com/share/transfer?shareid=\(info.shareId)&from=\(info.uk)&channel=chunlei&sekey=\(sekey)" +
            "&ondup=newcopy&web=1&app_id=\(Self.appId)&bdstoken=\(bdstoken)&clienttype=0"
        let r = try await client.send(.postForm(url, [("fsidlist", Self.fsidList(fsIds)), ("path", toDir)],
                                                headers: [("Cookie", Self.withBDCLND(cookie, sekey)), ("User-Agent", Self.webUA),
                                                          ("Origin", "https://pan.baidu.com"), ("Referer", "https://pan.baidu.com/s/")]))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: "转存失败")
        return json["extra"]["list"].array.map { $0["to"].string }.filter { !$0.isEmpty }
    }

    /// fsidlist 参数：`["1","2"]`
    static func fsidList(_ ids: [String]) -> String {
        "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// 个人网盘某目录下的子文件夹（文件夹 id 即完整路径）
    private func personalFolders(_ dir: String, cookie: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        for page in 1...20 {
            let url = "https://pan.baidu.com/api/list?clienttype=0&app_id=\(Self.appId)&web=1&order=name&desc=0" +
                "&dir=\(dir.formEncoded)&num=1000&page=\(page)"
            let r = try await client.send(.get(url, headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA)]))
            guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
            try Self.check(json, fallback: "获取文件夹失败")
            let items = json["list"].array
            all += items.filter { $0["isdir"].int == 1 }.map {
                ShareFile(fid: $0["path"].string, name: $0["server_filename"].string, size: 0, isDirectory: true, parentId: dir)
            }
            if items.count < 1000 { break }
        }
        return all
    }

    /// locatedownload 返回多个候选：优先 encrypt=0 的 https 明文直链（d2-ant 那路是加密通道，排除）
    private func locateDownload(_ path: String, cookie: String) async throws -> String {
        let time = Int64(Date().timeIntervalSince1970)
        let url = "https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload&app_id=\(Self.appId)&clienttype=17&ver=4.0" +
            "&ant=1&check_blue=1&es=1&esl=1&apn_id=1_-1&freeisp=0&queryfree=0&use=1&dtype=1&eck=1&ehps=1" +
            "&err_ver=1.0&network_type=WIFI&channel=0&path=\(path.formEncoded)&time=\(time)" +
            "&rand=5ed606e9da222cde0474cdf70eda884b&devuid=0F1E9FC2E084472DA5A61C4CF4C759AF" +
            "&cuid=0F1E9FC2E084472DA5A61C4CF4C759AF&deviceid=348642637967375013" +
            "&psign=860a071f77c860e8cea06e4e54c518f3&version=2.2.111.34&version_app=12.24.6&vip=0"
        let r = try await client.send(HTTPRequest(url: url, method: "POST",
                                                  headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA), ("Content-Type", "application/x-www-form-urlencoded")],
                                                  body: Data("0".utf8)))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: "获取下载链接失败")
        guard let link = Self.pickURL(json["urls"].array) else { throw CloudnError("百度网盘未返回下载链接") }
        return link
    }

    static func pickURL(_ candidates: [JSON]) -> String? {
        let valid = candidates.filter { !$0["url"].string.isEmpty }
        let plain = valid.filter { $0.has("encrypt") && $0["encrypt"].int == 0 }
        return plain.first(where: { $0["url"].string.hasPrefix("https") })?["url"].string
            ?? plain.first?["url"].string
            ?? valid.first(where: { $0["url"].string.hasPrefix("https") })?["url"].string
            ?? valid.first?["url"].string
    }

    private func delete(_ path: String, cookie: String, bdstoken: String) async {
        let url = "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&bdstoken=\(bdstoken)" +
            "&newVerify=1&clienttype=0&app_id=\(Self.appId)&web=1"
        _ = try? await client.send(.postForm(url, [("filelist", "[\"\(path)\"]")],
                                             headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA)]))
    }

    static func check(_ json: JSON, fallback: String) throws {
        let errno = json["errno"].int
        guard errno != 0 else { return }
        let msg = json.string("err_msg", "show_msg")
        throw CloudnError(msg.isEmpty ? "\(fallback)（errno=\(errno)）" : msg, code: errno)
    }
}

// MARK: - 转存到我的网盘

extension BaiduResolver: ShareSaver {
    public var rootFolderId: String { "/" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        return try await personalFolders(parentId, cookie: cookie)
    }

    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let info = try await shareInfo(session, cookie: cookie)
        let bdstoken = try await self.bdstoken(cookie)
        // 列表项的 token 是 fs_id（文件夹也有）；旧会话里的文件退回用 fid
        let ids = files.map { $0.token.isEmpty || $0.token.hasPrefix("/") ? $0.fid : $0.token }
        for start in stride(from: 0, to: ids.count, by: 100) {
            _ = try await transfer(info: info, sekey: session.stoken, fsIds: Array(ids[start..<min(start + 100, ids.count)]),
                                   toDir: folderId, cookie: cookie, bdstoken: bdstoken)
        }
    }
}

// MARK: - 我的网盘管理

/// 百度按绝对路径操作：fid = 完整路径（目录导航 / 重命名 / 移动 / 删除 / 取链），token = fs_id（创建分享）
extension BaiduResolver: DriveManager {
    public var driveRootId: String { "/" }
    public var driveCapabilities: DriveCapabilities { .all }

    static let diskReferer = "https://yun.baidu.com/disk/main"

    public func listDrive(_ folderId: String) async throws -> [ShareFile] {
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let dir = folderId.nilIfBlank ?? "/"
        var all: [ShareFile] = []
        for page in 1...100 {
            let listURL = "https://yun.baidu.com/api/list?clienttype=0&app_id=\(Self.appId)&web=1&order=time&desc=1" +
                "&dir=\(dir.formEncoded)&num=100&page=\(page)"
            let r = try await client.send(.get(listURL, headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA),
                                                                  ("X-Requested-With", "XMLHttpRequest"), ("Referer", Self.diskReferer)]))
            guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
            try Self.check(json, fallback: "获取文件列表失败")
            let items = Self.parseDriveList(json, dir: dir)
            all += items
            if items.count < 100 { break }
        }
        return all
    }

    /// locatedownload 按路径取明文直链；下载带 netdisk UA + Cookie
    public func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹不能直接下载") }
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let link = try await locateDownload(file.fid, cookie: cookie)
        return DownloadLink(fileName: file.name, url: link, size: file.size,
                            headers: ["User-Agent": Self.netdiskUA, "Cookie": cookie])
    }

    /// 官方新建文件夹走 api/create?a=commit（filemanager?opera=mkdir 在纯 Cookie 认证下恒 errno=2）
    public func createFolder(_ name: String, in parentId: String) async throws {
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let bdstoken = try await self.bdstoken(cookie)
        let create = "https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1&app_id=\(Self.appId)&clienttype=0&bdstoken=\(bdstoken)"
        let r = try await client.send(.postForm(create, [("path", Self.childPath(parentId, name)), ("isdir", "1"), ("block_list", "[]"),
                                                         ("method", "post"), ("dataType", "json")],
                                                headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA), ("Referer", Self.diskReferer)]))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: "新建文件夹失败")
    }

    public func rename(_ file: ShareFile, to name: String) async throws {
        try await fileManager("rename", host: "yun.baidu.com", asyncMode: 0, newVerify: false,
                              filelist: Self.renameFilelist(path: file.fid, name: name))
    }

    public func move(_ files: [ShareFile], to folderId: String) async throws {
        guard !files.isEmpty else { return }
        try await fileManager("move", host: "pan.baidu.com", asyncMode: 2, newVerify: false,
                              filelist: Self.moveFilelist(paths: files.map(\.fid), dest: folderId.nilIfBlank ?? "/"))
    }

    public func delete(_ files: [ShareFile]) async throws {
        guard !files.isEmpty else { return }
        try await fileManager("delete", host: "pan.baidu.com", asyncMode: 2, newVerify: true,
                              filelist: Self.pathList(files.map(\.fid)))
    }

    /// share/set：永久有效（period=0）+ 随机 4 位提取码
    public func createShare(_ files: [ShareFile]) async throws -> DriveShareLink {
        let fsIds = files.map(\.token).filter { !$0.isEmpty }
        guard !fsIds.isEmpty, fsIds.count == files.count else { throw CloudnError("请刷新列表后重试分享") }
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let bdstoken = try await self.bdstoken(cookie)
        let pwd = Self.randomSharePwd()
        let setURL = "https://pan.baidu.com/share/set?channel=chunlei&web=1&app_id=\(Self.appId)&bdstoken=\(bdstoken)&clienttype=0"
        let r = try await client.send(.postForm(setURL, [("fid_list", Self.shareFidList(fsIds)), ("schannel", "4"), ("channel_list", "[]"),
                                                         ("period", "0"), ("pwd", pwd)],
                                                headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA), ("Referer", Self.diskReferer)]))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: "创建分享失败")
        guard let link = Self.parseShareLink(json) else { throw CloudnError("未返回分享链接") }
        return DriveShareLink(url: link, pwd: pwd)
    }

    public func quota() async -> DriveQuota? {
        guard let cookie = await loginCookie() else { return nil }
        let quotaURL = "https://yun.baidu.com/api/quota?clienttype=0&app_id=\(Self.appId)&web=1&channel=chunlei" +
            "&version=\(Int64(Date().timeIntervalSince1970 * 1000))"
        guard let r = try? await client.send(.get(quotaURL, headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA),
                                                                      ("X-Requested-With", "XMLHttpRequest"), ("Referer", Self.diskReferer)])),
              let json = r.json else { return nil }
        return Self.parseQuota(json)
    }

    // MARK: 管理辅助

    /// filemanager 批量操作（filelist 为 JSON 文本，按完整路径）
    private func fileManager(_ opera: String, host: String, asyncMode: Int, newVerify: Bool, filelist: String) async throws {
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let bdstoken = try await self.bdstoken(cookie)
        let target = "https://\(host)/api/filemanager?async=\(asyncMode)&onnest=fail&opera=\(opera)&bdstoken=\(bdstoken)" +
            (newVerify ? "&newVerify=1" : "") + "&clienttype=0&app_id=\(Self.appId)&web=1"
        let r = try await client.send(.postForm(target, [("filelist", filelist)],
                                                headers: [("Cookie", cookie), ("User-Agent", Self.netdiskUA), ("Referer", Self.diskReferer)]))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: "操作失败")
    }

    static func parseDriveList(_ json: JSON, dir: String) -> [ShareFile] {
        json["list"].array.map { item -> ShareFile in
            let isDir = item["isdir"].int == 1
            return ShareFile(fid: item["path"].string, name: item["server_filename"].string, size: isDir ? 0 : item["size"].int64,
                             isDirectory: isDir, parentId: dir, token: item["fs_id"].string, modified: item["server_mtime"].string)
        }
    }

    /// 父目录 + 名称 → 完整路径
    static func childPath(_ parent: String, _ name: String) -> String {
        var base = parent.nilIfBlank ?? "/"
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/" + name
    }

    /// `[{"path":"/a","newname":"b"}]`
    static func renameFilelist(path: String, name: String) -> String {
        OrderedJSON.array([.object([("path", .string(path)), ("newname", .string(name))])]).text
    }

    /// `[{"path":"/a/x","dest":"/b","newname":"x"}]`（newname 保持原名）
    static func moveFilelist(paths: [String], dest: String) -> String {
        OrderedJSON.array(paths.map { p -> OrderedJSON in
            .object([("path", .string(p)), ("dest", .string(dest)), ("newname", .string(p.substringAfterLast("/")))])
        }).text
    }

    /// `["/a","/b"]`
    static func pathList(_ paths: [String]) -> String {
        OrderedJSON.array(paths.map { OrderedJSON.string($0) }).text
    }

    /// share/set 的 fid_list：fs_id 是数字，不加引号 `[1,2]`
    static func shareFidList(_ ids: [String]) -> String {
        "[" + ids.joined(separator: ",") + "]"
    }

    static func randomSharePwd() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<4).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    static func parseShareLink(_ json: JSON) -> String? {
        json.string("shorturl", "link").nilIfBlank
    }

    /// api/quota：errno=0 时 used / total
    static func parseQuota(_ json: JSON) -> DriveQuota? {
        guard json.has("errno"), json["errno"].int == 0, json.has("total") else { return nil }
        return DriveQuota(used: json["used"].int64, total: json["total"].int64)
    }
}
