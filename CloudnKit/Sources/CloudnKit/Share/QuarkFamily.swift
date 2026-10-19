// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 夸克 / UC 网盘分享解析。两者是同一套 clouddrive 接口，只在域名、pr 参数、UA 与少量字段上不同。
// 协议细节参考 YunX（AGPL-3.0）的 QuarkApi / UCApi 及其仓库层实现。
import Foundation

public struct QuarkFamilyConfig: Sendable {
    public enum Listing: Sendable { case sharepageDetail, transferShareDetail }

    let platform: SharePlatform
    let account: AccountKind
    let apiBase: String
    let prQuery: String
    /// 登录态接口与下载用 UA
    let apiUA: String
    /// 游客取链 / 游客下载用 UA（UC 的游客链路风控更严，需客户端 UA + Sec-Ch-Ua）
    let guestUA: String
    let guestSecChUa: String?
    let webOrigin: String
    let tokenExtra: [String: Bool]
    let listing: Listing
    let pageSize: Int
    let downloadURL: String
    /// 登录态下载是否需要带 Origin
    let downloadOrigin: Bool
    /// 免转存取链失败时能否回退「转存到临时目录再取链」
    let transferFallback: Bool
    let accountInfoURL: String

    var referer: String { webOrigin + "/" }

    public static let quark = QuarkFamilyConfig(
        platform: .quark,
        account: .quark,
        apiBase: "https://drive-pc.quark.cn",
        prQuery: "pr=ucpro&fr=pc",
        apiUA: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch",
        guestUA: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch",
        guestSecChUa: nil,
        webOrigin: "https://pan.quark.cn",
        tokenExtra: ["support_visit_limit_private_share": true],
        listing: .sharepageDetail,
        pageSize: 100,
        downloadURL: "https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2",
        downloadOrigin: false,
        transferFallback: true,
        accountInfoURL: "https://pan.quark.cn/account/info"
    )

    public static let uc = QuarkFamilyConfig(
        platform: .uc,
        account: .uc,
        apiBase: "https://pc-api.uc.cn",
        prQuery: "pr=UCBrowser&fr=pc",
        apiUA: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        guestUA: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch",
        guestSecChUa: "\"Not=A?Brand\";v=\"99\", \"Chromium\";v=\"100\", \"Google Chrome\";v=\"100\"",
        webOrigin: "https://drive.uc.cn",
        tokenExtra: ["share_for_transfer": true],
        listing: .transferShareDetail,
        pageSize: 50,
        downloadURL: "https://pc-api.uc.cn/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser",
        downloadOrigin: true,
        transferFallback: false,
        accountInfoURL: "https://drive.uc.cn/account/info"
    )

    /// 登录页（WebView 登录用）
    public var loginURL: String { platform == .quark ? "https://pan.quark.cn/?fr=pc&platform=pc" : "https://drive.uc.cn/" }
    /// 登录页 WebView UA（PC 版页面）
    public var loginUserAgent: String {
        platform == .quark
            ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 QuarkPC/6.0.8.649"
            : apiUA
    }
    public var cookieDomain: String { platform == .quark ? "quark.cn" : "uc.cn" }
}

public final class QuarkFamilyResolver: ShareResolver, @unchecked Sendable {
    public let config: QuarkFamilyConfig
    private let credentials: CredentialStore
    private let client: HTTPClient
    private let state = State()

    static let tempDirName = "Cloudn临时转存"
    /// __puus 约 3 小时过期，提前到 90 分钟主动续期
    static let refreshInterval: TimeInterval = 90 * 60
    static let trackedCookies: Set<String> = ["__puus", "__pus"]

    private actor State {
        var guestPugs = ""
        var lastRefresh: Date = .distantPast
        func setPugs(_ v: String) { guestPugs = v }
        func markRefreshed() { lastRefresh = Date() }
    }

    public var platform: SharePlatform { config.platform }
    public var supportsGuestDownload: Bool { true }

    public init(config: QuarkFamilyConfig, credentials: CredentialStore, client: HTTPClient = .shared) {
        self.config = config
        self.credentials = credentials
        self.client = client
    }

    private func url(_ path: String, _ extra: String = "") -> String {
        "\(config.apiBase)\(path)?\(config.prQuery)\(extra)"
    }

    private func loginCookie() async -> String? {
        guard let c = await credentials.cookie(for: config.account), Self.isValidCookie(c) else { return nil }
        return c
    }

    /// 关键 Cookie 字段缺失即视为未登录
    public static func isValidCookie(_ cookie: String) -> Bool {
        cookie.contains("__pus=")
    }

    // MARK: 会话与列表

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let cookie = await loginCookie()
        var body: [String: Any] = ["pwd_id": share.shareId, "passcode": (pwd?.nilIfBlank ?? share.pwd) ?? ""]
        for (k, v) in config.tokenExtra { body[k] = v }
        let data = try await callData(.postJSON(url("/1/clouddrive/share/sharepage/token"), body, headers: apiHeaders(cookie)), cookie: cookie)
        let stoken = data["stoken"].string
        guard !stoken.isEmpty else { throw CloudnError("未获取到分享凭证") }
        let title = data["title"].string
        return ShareSession(platform: platform, shareId: share.shareId, stoken: stoken, title: title.isEmpty ? config.platform.displayName + "分享" : title)
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let cookie = await loginCookie()
        var all: [ShareFile] = []
        var page = 1
        while page <= 100 {
            let batch = try await listPage(session, dirId: dirId, page: page, cookie: cookie)
            all += batch
            if batch.count < config.pageSize { break }
            page += 1
        }
        return all
    }

    private func listPage(_ session: ShareSession, dirId: String, page: Int, cookie: String?) async throws -> [ShareFile] {
        let req: HTTPRequest
        switch config.listing {
        case .sharepageDetail:
            let q = "&pwd_id=\(session.shareId)&stoken=\(session.stoken.urlQueryEncoded)&pdir_fid=\(dirId)&ver=2&force=0" +
                "&_page=\(page)&_size=\(config.pageSize)&_fetch_banner=0&_fetch_share=0&fetch_relate_conversation=0" +
                "&_fetch_total=1&_sort=file_type:asc,file_name:asc"
            req = .get(url("/1/clouddrive/share/sharepage/detail", q),
                       headers: apiHeaders(cookie) + [("Origin", config.webOrigin), ("Referer", config.referer)])
        case .transferShareDetail:
            // UC 必须用 transfer_share/detail（带 stoken）：返回的 share_fid_token 与 stoken 绑定，取链才能过校验
            let q = "&entry=ft&pwd_id=\(session.shareId)&pdir_fid=\(dirId)&fetch_file_list=1&passcode=" +
                "&_page=\(page)&_size=\(config.pageSize)&_fetch_total=1&_fetch_task=1&_fetch_share=1&_sort=" +
                "&stoken=\(session.stoken.urlQueryEncoded)"
            req = .get(url("/1/clouddrive/transfer_share/detail", q),
                       headers: apiHeaders(cookie) + [("Origin", "https://fast.uc.cn"), ("Referer", "https://fast.uc.cn/")])
        }
        let data = try await callData(req, cookie: cookie)
        let items = data["list"].isArray ? data["list"].array : data["detail_info"]["list"].array
        return items.map { item in
            ShareFile(
                fid: item["fid"].string,
                name: item.string("file_name", "fname"),
                size: item["size"].int64,
                isDirectory: item["dir"].bool || item["isdir"].int == 1,
                parentId: item["pdir_fid"].string,
                token: item["share_fid_token"].string,
                modified: item["updated_at"].string
            )
        }
    }

    // MARK: 取直链

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard let cookie = await freshCookie() else { return try await guestLink(session, file: file) }

        if config.platform == .uc, FileNames.kind(of: file.name) == .video,
           let preview = try? await ucVideoPreview(session, file: file, cookie: cookie) {
            // UC 非会员下载视频会被换成宣传片；分享态 video_preview 给的是原画直链
            return preview
        }
        do {
            return try await shareLinkWithoutSave(session, file: file, cookie: cookie)
        } catch {
            guard config.transferFallback else { throw error }
            // 个别分享类型服务端要求先转存再取链
            return try await transferAndLink(session, file: file, cookie: cookie)
        }
    }

    /// 登录态免转存取链：分享凭证直接换直链，不在用户网盘留临时目录
    private func shareLinkWithoutSave(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        var body: [String: Any] = ["fids": [file.fid], "fids_token": [file.token], "pwd_id": session.shareId, "stoken": session.stoken]
        if config.platform == .quark {
            body["speedup_session"] = ""
            body["token"] = ""
        }
        let r = try await client.send(.postJSON(config.downloadURL, body, headers: apiHeaders(cookie)))
        await absorbCookies(r, cookie: cookie)
        let current = await freshCookieNoRefresh() ?? cookie
        return try parseLink(r, file: file, headers: loginDownloadHeaders(current)) { code, message in
            switch code {
            case 31001: return "\(self.config.platform.displayName)登录态已失效，请到「账号」页重新登录"
            default: return message
            }
        }
    }

    /// 游客取链：同一个 download 端点，不带账号 Cookie；服务端随响应下发游客态 __pugs，下载必须带上它
    private func guestLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        var body: [String: Any] = ["fids": [file.fid], "fids_token": [file.token], "pwd_id": session.shareId, "stoken": session.stoken]
        if config.platform == .quark {
            body["speedup_session"] = ""
            body["token"] = ""
        }
        let cached = await state.guestPugs
        var headers: [(String, String)] = [("User-Agent", config.guestUA)]
        if let sec = config.guestSecChUa { headers.append(("Sec-Ch-Ua", sec)) }
        if !cached.isEmpty { headers.append(("Cookie", cached)) }
        let r = try await client.send(.postJSON(config.downloadURL, body, headers: headers))
        // 直链与同一次响应下发的 __pugs 绑定，优先用本次的值
        let pugs = r.cookie("__pugs").map { "__pugs=\($0)" } ?? cached
        if !pugs.isEmpty { await state.setPugs(pugs) }
        var dl: [String: String] = ["User-Agent": config.guestUA, "Referer": config.referer]
        if !pugs.isEmpty { dl["Cookie"] = pugs }
        if let sec = config.guestSecChUa { dl["Sec-Ch-Ua"] = sec; dl["Origin"] = config.webOrigin }
        let name = config.platform.displayName
        return try parseLink(r, file: file, headers: dl) { code, message in
            switch code {
            case 23018: return self.config.platform == .quark
                ? "该文件超出游客可下载的大小上限（夸克约 50MB），请先登录夸克网盘"
                : "该文件超出游客可下载的大小上限，请先登录\(name)"
            case 31001: return "该分享需要登录\(name)后才能下载"
            case 14001: return "分享已失效或提取码有误，请重新解析"
            case 41020: return "文件令牌已过期，请重新解析分享"
            default: return message
            }
        }
    }

    private func ucVideoPreview(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink? {
        let q = "?pr=UCBrowser&fr=h5&pwd_id=\(session.shareId.urlQueryEncoded)&stoken=\(session.stoken.urlQueryEncoded)" +
            "&fid=\(file.fid.urlQueryEncoded)&fid_token=\(file.token.urlQueryEncoded)"
        let r = try await client.send(.get("\(config.apiBase)/1/clouddrive/share/sharepage/video_preview" + q,
                                           headers: apiHeaders(cookie) + [("Origin", config.webOrigin), ("Referer", config.referer)]))
        guard let json = r.json, json["status"].int == 200 || json["code"].int == 0 else { return nil }
        let info = json["data"]["play_info"]
        let direct = info["url"].string
        guard !direct.isEmpty else { return nil }
        return DownloadLink(fileName: file.name, url: direct, size: info["size"].int64 > 0 ? info["size"].int64 : file.size,
                            headers: loginDownloadHeaders(cookie))
    }

    /// 夸克兜底：转存到「Cloudn临时转存/tr_<唯一>」→ 取直链；唯一子目录绕开转存去重（否则会拿到已删 fid）
    private func transferAndLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        let base = try await ensureTempDir(cookie: cookie)
        let subName = "tr_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 0..<1_000_000))"
        let sub = try await createFolder(subName, parent: base, cookie: cookie)
        let savedFid = try await saveShare(session, files: [file], parent: file.parentId, to: sub, cookie: cookie, attempts: 10)
        let r = try await client.send(.postJSON(config.downloadURL, ["fids": [savedFid]], headers: apiHeaders(cookie)))
        await absorbCookies(r, cookie: cookie)
        let current = await freshCookieNoRefresh() ?? cookie
        let link = try parseLink(r, file: file, headers: loginDownloadHeaders(current)) { _, m in m }
        return DownloadLink(fileName: link.fileName, url: link.url, size: link.size, headers: link.headers, cleanupToken: sub)
    }

    private func ensureTempDir(cookie: String) async throws -> String {
        if let dir = try await personalFolders("0", cookie: cookie).first(where: { $0.name == Self.tempDirName }) {
            return dir.fid
        }
        return try await createFolder(Self.tempDirName, parent: "0", cookie: cookie)
    }

    /// 个人网盘某目录下的子文件夹（file/sort 分页）
    private func personalFolders(_ parent: String, cookie: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        for page in 1...50 {
            let q = "&uc_param_str=&pdir_fid=\(parent.urlQueryEncoded)&_page=\(page)&_size=100&_fetch_total=1" +
                "&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc"
            let data = try await callData(.get(url("/1/clouddrive/file/sort", q),
                                               headers: apiHeaders(cookie) + [("Origin", config.webOrigin), ("Referer", config.referer)]), cookie: cookie)
            let items = data["list"].array
            all += items.filter { $0["dir"].bool || $0["isdir"].int == 1 }.map {
                ShareFile(fid: $0["fid"].string, name: $0.string("file_name", "fname"), size: 0, isDirectory: true, parentId: parent,
                          modified: $0["updated_at"].string)
            }
            if items.count < 100 { break }
        }
        return all
    }

    /// sharepage/save + 轮询任务；同一批文件必须来自同一个父目录。返回转存后的第一个 fid
    private func saveShare(_ session: ShareSession, files: [ShareFile], parent: String, to target: String,
                           cookie: String, attempts: Int) async throws -> String {
        let save = try await callData(.postJSON(url("/1/clouddrive/share/sharepage/save"), [
            "pwd_id": session.shareId, "stoken": session.stoken, "pdir_fid": parent,
            "to_pdir_fid": target, "fid_list": files.map(\.fid), "fid_token_list": files.map(\.token), "scene": "link"
        ], headers: apiHeaders(cookie)), cookie: cookie)
        let taskId = save["task_id"].string
        guard !taskId.isEmpty else { throw CloudnError("转存失败") }
        guard let savedFid = try await pollSaveTask(taskId, cookie: cookie, attempts: attempts) else {
            throw CloudnError("转存仍在进行，请稍后到\(config.platform.displayName)里查看")
        }
        return savedFid
    }

    private func createFolder(_ name: String, parent: String, cookie: String) async throws -> String {
        let data = try await callData(.postJSON(url("/1/clouddrive/file"), [
            "pdir_fid": parent, "file_name": name, "dir_path": "", "dir_init_lock": false
        ], headers: apiHeaders(cookie)), cookie: cookie)
        let fid = data["fid"].string
        guard !fid.isEmpty else { throw CloudnError("创建临时目录失败") }
        return fid
    }

    private func pollSaveTask(_ taskId: String, cookie: String, attempts: Int) async throws -> String? {
        for _ in 0..<attempts {
            if let r = try? await client.send(.get(url("/1/clouddrive/task", "&task_id=\(taskId.urlQueryEncoded)&retry_index=0"), headers: apiHeaders(cookie))),
               let json = r.json, json["status"].int == 200 {
                let data = json["data"]
                let finished = data["finished_at"].int64 > 0 || data["status"].int == 2 || data["task_status"].int == 2
                let fid = data["save_as"]["save_as_top_fids"][0].string
                if finished && !fid.isEmpty { return fid }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    /// 下载完成后删除临时转存子目录（连同其中文件）；失败不影响下载结果
    public func cleanup(token: String) async {
        guard !token.isEmpty, let cookie = await loginCookie() else { return }
        _ = try? await client.send(.postJSON(url("/1/clouddrive/file/delete", "&uc_param_str="), [
            "action_type": 2, "filelist": [token], "exclude_fids": [String]()
        ], headers: apiHeaders(cookie)))
    }

    // MARK: 账号

    /// 校验 Cookie 并返回昵称；无效返回 nil
    public func fetchNickname(cookie: String) async -> String? {
        guard let r = try? await client.send(.get(config.accountInfoURL, headers: [("Cookie", cookie), ("User-Agent", config.apiUA)])),
              r.isSuccess, let json = r.json, json["success"].bool else { return nil }
        let name = json["data"]["nickname"].string
        return name.isEmpty ? "\(config.platform.displayName)用户" : name
    }

    /// 返回 __puus 未过期的 Cookie：超过刷新间隔就剥掉 __puus 请求 /config，让服务端重新下发
    private func freshCookie() async -> String? {
        guard let cookie = await loginCookie() else { return nil }
        guard Date().timeIntervalSince(await state.lastRefresh) > Self.refreshInterval else { return cookie }
        let req = HTTPRequest.get(url("/1/clouddrive/config"), headers: [
            ("Cookie", CookieUtil.removing("__puus", from: cookie)), ("User-Agent", config.apiUA), ("Referer", config.referer)
        ])
        if let r = try? await client.send(req) {
            await absorbCookies(r, cookie: cookie)
            await state.markRefreshed()
        }
        return await loginCookie() ?? cookie
    }

    private func freshCookieNoRefresh() async -> String? { await loginCookie() }

    /// 响应若续期了 __puus/__pus，合并后回写账号
    private func absorbCookies(_ r: HTTPResponse, cookie: String?) async {
        guard let cookie, !r.cookies.isEmpty else { return }
        let merged = CookieUtil.merge(cookie, with: r.cookies, tracked: Self.trackedCookies)
        if merged != cookie { await credentials.updateCookie(merged, replacing: cookie, for: config.account) }
    }

    // MARK: 请求构造与响应解析

    private func apiHeaders(_ cookie: String?) -> [(String, String)] {
        var h: [(String, String)] = [("User-Agent", config.apiUA)]
        if let cookie, !cookie.isEmpty { h.append(("Cookie", cookie)) }
        return h
    }

    private func loginDownloadHeaders(_ cookie: String) -> [String: String] {
        var h = ["Cookie": cookie, "User-Agent": config.apiUA, "Referer": config.referer]
        if config.downloadOrigin { h["Origin"] = config.webOrigin }
        return h
    }

    /// 通用响应：status == 200 才算成功，返回 data；失败透传服务端 message（如「提取码错误」）
    private func callData(_ req: HTTPRequest, cookie: String?) async throws -> JSON {
        let r = try await client.send(req)
        await absorbCookies(r, cookie: cookie)
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        guard json["status"].int == 200 else {
            let msg = json["message"].string
            throw CloudnError(msg.isEmpty ? "请求失败（HTTP \(r.status)）" : msg, code: json["code"].int)
        }
        return json["data"]
    }

    private func parseLink(_ r: HTTPResponse, file: ShareFile, headers: [String: String],
                           message: (Int, String) -> String) throws -> DownloadLink {
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        let code = json["code"].int
        if json["status"].int != 200 && code != 0 {
            let m = json["message"].string
            throw CloudnError(message(code, m.isEmpty ? "获取下载链接失败" : m), code: code)
        }
        let item = json["data"][0]
        let link = item["download_url"].string
        guard !link.isEmpty else { throw CloudnError("未返回下载链接") }
        let name = item.string("file_name", "filename")
        return DownloadLink(fileName: name.isEmpty ? file.name : name, url: link,
                            size: item["size"].int64 > 0 ? item["size"].int64 : file.size, headers: headers)
    }
}

// MARK: - 转存到我的网盘

extension QuarkFamilyResolver: ShareSaver {
    public var rootFolderId: String { "0" }

    public func listFolders(_ parentId: String) async throws -> [ShareFile] {
        guard let cookie = await freshCookie() else { throw config.platform.loginRequired }
        return try await personalFolders(parentId, cookie: cookie)
    }

    public func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        guard let cookie = await freshCookie() else { throw config.platform.loginRequired }
        // 同一次 save 只能是同一个父目录下的条目
        for (parent, group) in Dictionary(grouping: files, by: \.parentId) {
            for start in stride(from: 0, to: group.count, by: 100) {
                let batch = Array(group[start..<min(start + 100, group.count)])
                _ = try await saveShare(session, files: batch, parent: parent, to: folderId, cookie: cookie, attempts: 60)
            }
        }
    }
}
