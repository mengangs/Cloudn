// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 百度网盘分享解析：share/verify 换 sekey → xpan/share 列目录 → 转存到临时目录 → locatedownload 取明文直链 → 删除转存。
// 协议细节参考 YunX（AGPL-3.0）的 BaiduApi / BaiduResolveRepository。
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
            throw CloudnError("百度网盘需要登录后才能下载，请到「账号」页登录百度网盘")
        }
        let info = try await shareInfo(session, cookie: cookie)
        let bdstoken = try await self.bdstoken(cookie)
        let dir = await ensureTempDir(cookie: cookie, bdstoken: bdstoken)
        let saved = try await transfer(info: info, sekey: session.stoken, fsId: file.fid, toDir: dir, cookie: cookie, bdstoken: bdstoken)
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
            // 目录用 path 导航，文件用 fs_id 转存
            return ShareFile(fid: isDir ? path : item["fs_id"].string, name: item["server_filename"].string, size: item["size"].int64,
                             isDirectory: isDir, parentId: dir, token: path, modified: item["server_mtime"].string)
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
            throw CloudnError("百度网盘登录已失效，请到「账号」页重新登录")
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

    /// 同步转存，返回转存后的完整路径
    private func transfer(info: (shareId: String, uk: String), sekey: String, fsId: String, toDir: String,
                          cookie: String, bdstoken: String) async throws -> String {
        let url = "https://pan.baidu.com/share/transfer?shareid=\(info.shareId)&from=\(info.uk)&channel=chunlei&sekey=\(sekey)" +
            "&ondup=newcopy&web=1&app_id=\(Self.appId)&bdstoken=\(bdstoken)&clienttype=0"
        let r = try await client.send(.postForm(url, [("fsidlist", "[\"\(fsId)\"]"), ("path", toDir)],
                                                headers: [("Cookie", Self.withBDCLND(cookie, sekey)), ("User-Agent", Self.webUA),
                                                          ("Origin", "https://pan.baidu.com"), ("Referer", "https://pan.baidu.com/s/")]))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.check(json, fallback: "转存失败")
        let path = json["extra"]["list"][0]["to"].string
        guard !path.isEmpty else { throw CloudnError("转存失败：未返回新文件") }
        return path
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
