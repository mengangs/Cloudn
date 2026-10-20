// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

struct Account: Codable, Equatable {
    var cookie: String
    var nickname: String
    var updatedAt: Date
}

/// 解析器侧的凭证源：钥匙串为唯一真源，服务端续期 Cookie 时在这里回写。
/// 每个平台一个主账号（钥匙串键为平台名，兼容旧数据）+ 若干附加账号（键为「平台名.extra」）。
actor AccountVault: CredentialStore {
    private var cache: [AccountKind: Account] = [:]
    private var extras: [AccountKind: [Account]] = [:]
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        for kind in AccountKind.allCases {
            if let data = Keychain.read(kind.rawValue), let account = try? JSONDecoder().decode(Account.self, from: data) {
                cache[kind] = account
            }
            if let data = Keychain.read(kind.rawValue + ".extra"), let list = try? JSONDecoder().decode([Account].self, from: data), !list.isEmpty {
                extras[kind] = list
            }
        }
    }

    /// 默认返回主账号；多账号下载时按 AccountSlot 轮换
    func cookie(for kind: AccountKind) async -> String? {
        let slot = AccountSlot.current
        let all = list(kind)
        guard slot > 0, all.count > 1 else { return cache[kind]?.cookie }
        return all[slot % all.count].cookie
    }

    func updateCookie(_ new: String, replacing old: String, for kind: AccountKind) async {
        if var account = cache[kind], account.cookie == old {
            account.cookie = new
            account.updatedAt = Date()
            save(account, for: kind)
            return
        }
        guard var list = extras[kind], let i = list.firstIndex(where: { $0.cookie == old }) else { return }
        list[i].cookie = new
        list[i].updatedAt = Date()
        saveExtras(list, for: kind)
    }

    func all() -> [AccountKind: Account] { cache }
    func allExtras() -> [AccountKind: [Account]] { extras }

    /// 主账号在前
    func list(_ kind: AccountKind) -> [Account] { (cache[kind].map { [$0] } ?? []) + (extras[kind] ?? []) }

    func save(_ account: Account, for kind: AccountKind) {
        cache[kind] = account
        if let data = try? JSONEncoder().encode(account) { Keychain.write(kind.rawValue, data) }
        onChange()
    }

    func saveExtras(_ list: [Account], for kind: AccountKind) {
        extras[kind] = list.isEmpty ? nil : list
        if list.isEmpty {
            Keychain.delete(kind.rawValue + ".extra")
        } else if let data = try? JSONEncoder().encode(list) {
            Keychain.write(kind.rawValue + ".extra", data)
        }
        onChange()
    }

    /// 添加账号：没有主账号时成为主账号；同一凭据或同名账号直接替换。
    /// 「×× 用户」这类拿不到真实昵称时的占位名不能用来判断是不是同一个账号
    func add(_ account: Account, for kind: AccountKind) {
        let placeholder = account.nickname.hasSuffix("用户")
        func same(_ other: Account) -> Bool {
            other.cookie == account.cookie || (!placeholder && other.nickname == account.nickname)
        }
        guard let primary = cache[kind], !same(primary) else {
            save(account, for: kind)
            return
        }
        var list = extras[kind] ?? []
        if let i = list.firstIndex(where: same) {
            list[i] = account
        } else {
            list.append(account)
        }
        saveExtras(list, for: kind)
    }

    /// 把第 index 个账号（按 list 顺序）设为主账号
    func makePrimary(_ index: Int, for kind: AccountKind) {
        var all = list(kind)
        guard index > 0, index < all.count else { return }
        let chosen = all.remove(at: index)
        save(chosen, for: kind)
        saveExtras(all, for: kind)
    }

    /// 移除第 index 个账号；移除主账号时由下一个顶上
    func remove(_ index: Int, for kind: AccountKind) {
        var all = list(kind)
        guard index >= 0, index < all.count else { return }
        all.remove(at: index)
        if let first = all.first {
            save(first, for: kind)
            saveExtras(Array(all.dropFirst()), for: kind)
        } else {
            remove(kind)
        }
    }

    /// 退出该平台全部账号
    func remove(_ kind: AccountKind) {
        cache[kind] = nil
        extras[kind] = nil
        Keychain.delete(kind.rawValue)
        Keychain.delete(kind.rawValue + ".extra")
        onChange()
    }
}

/// 界面侧的账号状态镜像
@MainActor
@Observable
final class AccountStore {
    /// 各平台主账号
    private(set) var accounts: [AccountKind: Account] = [:]
    /// 各平台附加账号
    private(set) var extras: [AccountKind: [Account]] = [:]
    @ObservationIgnored private(set) var vault: AccountVault!
    /// 正在为该平台「添加账号」：接下来这次登录作为附加账号保存
    @ObservationIgnored var pendingAdd: AccountKind?
    /// 主账号的登录态检测结果；存进 UserDefaults，重启后不必重测
    private(set) var health: [AccountKind: HealthRecord] = AccountStore.loadHealth()
    /// 正在检测的平台
    private(set) var checking = Set<AccountKind>()

    init() {
        vault = AccountVault { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
        Task { await reload() }
    }

    func reload() async {
        accounts = await vault.all()
        extras = await vault.allExtras()
    }

    func isLoggedIn(_ kind: AccountKind) -> Bool { accounts[kind] != nil }

    func count(for kind: AccountKind) -> Int { (accounts[kind] == nil ? 0 : 1) + (extras[kind]?.count ?? 0) }

    /// 主账号在前
    func list(_ kind: AccountKind) -> [Account] { (accounts[kind].map { [$0] } ?? []) + (extras[kind] ?? []) }

    /// 校验 Cookie 后保存；返回昵称，无效返回 nil。adding 为 true 时作为附加账号加入（不替换主账号）
    func login(_ kind: AccountKind, cookie: String, adding: Bool = false) async -> String? {
        let normalized = AccountValidator.normalize(kind, cookie)
        guard !normalized.isEmpty, let nickname = await AccountValidator.validate(kind, cookie: normalized) else { return nil }
        let account = Account(cookie: normalized, nickname: nickname, updatedAt: Date())
        let adding = adding || pendingAdd == kind
        pendingAdd = nil
        if adding {
            await vault.add(account, for: kind)
        } else {
            await vault.save(account, for: kind)
            recordHealth(kind, valid: true)
        }
        await reload()
        return nickname
    }

    /// 从备份恢复：覆盖同平台的现有账号
    func restore(_ restored: [AccountKind: Account], extras restoredExtras: [AccountKind: [Account]] = [:]) async {
        // 备份里有的平台整体覆盖：主账号与附加账号都以备份为准（备份里没有附加账号就清空本机的）
        for (kind, account) in restored {
            await vault.save(account, for: kind)
            await vault.saveExtras(restoredExtras[kind] ?? [], for: kind)
        }
        await reload()
    }

    func makePrimary(_ index: Int, for kind: AccountKind) async {
        await vault.makePrimary(index, for: kind)
        await reload()
    }

    func remove(_ index: Int, for kind: AccountKind) async {
        await vault.remove(index, for: kind)
        await reload()
    }

    func logout(_ kind: AccountKind) async {
        await vault.remove(kind)
        health[kind] = nil
        saveHealth()
        await reload()
    }
}

// MARK: - 登录态检测

/// 只在「我的」页出现时检测，同一平台 6 小时内最多一次（手动检测除外），每次只发一个轻量请求
/// （和登录校验同一个接口）。容量能取到的网盘直接算有效，不再额外请求。
/// 请求失败时先看网络是否通：连不上平台算「未知」，保留上次结果，不会因为断网把账号标成失效
extension AccountStore {
    struct HealthRecord: Codable, Equatable {
        var expired: Bool
        var checkedAt: Date
    }

    static let healthInterval: TimeInterval = 6 * 3600
    private static let healthKey = "accountHealth"

    /// 主账号登录已失效。失效后账号又被更新过（重新登录、服务端续期回写）就不再算失效
    func isExpired(_ kind: AccountKind) -> Bool {
        guard let account = accounts[kind], let record = health[kind], record.expired else { return false }
        return account.updatedAt <= record.checkedAt
    }

    func recordHealth(_ kind: AccountKind, valid: Bool) {
        health[kind] = HealthRecord(expired: !valid, checkedAt: Date())
        saveHealth()
    }

    enum CheckResult: Sendable { case valid, expired, unreachable }

    /// 检测这些平台的主账号；force 为 false 时跳过 6 小时内测过的
    @discardableResult
    func checkHealth(_ kinds: [AccountKind], resolvers: ShareResolvers, force: Bool = false) async -> [AccountKind: CheckResult] {
        let now = Date()
        let targets: [(AccountKind, String)] = kinds.compactMap { kind in
            guard let account = accounts[kind], !checking.contains(kind) else { return nil }
            if !force, let record = health[kind], now.timeIntervalSince(record.checkedAt) < Self.healthInterval,
               !(record.expired && account.updatedAt > record.checkedAt) { return nil }
            return (kind, account.cookie)
        }
        guard !targets.isEmpty else { return [:] }
        checking.formUnion(targets.map(\.0))
        let results = await withTaskGroup(of: (AccountKind, CheckResult).self) { group -> [AccountKind: CheckResult] in
            for (kind, cookie) in targets {
                let probe = "https://" + (kind.loginURL.host ?? "")
                group.addTask { (kind, await AccountStore.probeLogin(kind, cookie: cookie, probe: probe, resolvers: resolvers)) }
            }
            var out: [AccountKind: CheckResult] = [:]
            for await (kind, result) in group { out[kind] = result }
            return out
        }
        for (kind, result) in results {
            checking.remove(kind)
            switch result {
            case .valid: recordHealth(kind, valid: true)
            case .expired:
                recordHealth(kind, valid: false)
                Log.info("登录态检测：\(kind.displayName) 主账号已失效")
            case .unreachable: break
            }
        }
        return results
    }

    nonisolated private static func probeLogin(_ kind: AccountKind, cookie: String, probe: String, resolvers: ShareResolvers) async -> CheckResult {
        let valid: Bool
        if kind == .xunlei, let xunlei = resolvers.resolver(for: .xunlei) as? XunleiResolver {
            valid = await xunlei.checkLogin()
        } else {
            valid = await AccountValidator.validate(kind, cookie: cookie) != nil
        }
        if valid { return .valid }
        return await AccountValidator.reachable(probe) ? .expired : .unreachable
    }

    nonisolated private static func loadHealth() -> [AccountKind: HealthRecord] {
        guard let data = UserDefaults.standard.data(forKey: healthKey),
              let raw = try? JSONDecoder().decode([String: HealthRecord].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in AccountKind(rawValue: k).map { ($0, v) } })
    }

    private func saveHealth() {
        let raw = Dictionary(uniqueKeysWithValues: health.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: Self.healthKey) }
    }
}

/// 网页登录后从哪里读取凭据
enum LoginCapture {
    /// 拼出这些域（含子域）下的 Cookie，靠前的域优先
    case cookies([String])
    /// 在页面里执行脚本，返回值即凭据（空串表示还没登录）
    case script(String)
}

extension AccountKind {
    var loginURL: URL {
        switch self {
        case .quark: return URL(string: QuarkFamilyConfig.quark.loginURL)!
        case .uc: return URL(string: QuarkFamilyConfig.uc.loginURL)!
        case .baidu: return URL(string: BaiduResolver.mobileLoginURL)!
        case .xunlei: return URL(string: XunleiCredential.loginURL)!
        case .pan123: return URL(string: Pan123Resolver.loginURL)!
        case .pan115: return URL(string: Pan115Resolver.loginURL)!
        case .c139: return URL(string: C139Resolver.loginURL)!
        case .guangya: return URL(string: "https://www.guangyapan.com/")!
        case .ilanzou: return URL(string: "https://www.ilanzou.com/")!
        case .lanzou: return URL(string: "https://up.woozooo.com/account.php?action=login")!
        case .bilibili: return URL(string: "https://passport.bilibili.com/login")!
        // 必须直指 /login：站点根地址会跳到桌面信息流再叠登录弹窗
        case .xiaohongshu: return URL(string: "https://www.xiaohongshu.com/login")!
        case .pixiv: return URL(string: "https://accounts.pixiv.net/login")!
        case .zhihu: return URL(string: "https://www.zhihu.com/signin")!
        case .yuanbao: return URL(string: YuanbaoAccount.loginURL)!
        // 海外平台都用手机网页版登录页
        case .twitter, .instagram, .tiktok, .reddit, .facebook:
            return URL(string: OverseasAccount.loginURL(self) ?? "https://x.com/i/flow/login")!
        }
    }

    var loginUserAgent: String {
        switch self {
        case .quark: return QuarkFamilyConfig.quark.loginUserAgent
        case .uc: return QuarkFamilyConfig.uc.loginUserAgent
        // 桌面版登录弹窗在键盘弹出时会重新居中、页面乱跳：用手机版登录页
        case .baidu: return BaiduResolver.mobileUA
        // 网页版登录态只在桌面版页面写入
        case .xunlei: return XunleiCredential.desktopUA
        case .pan123: return Pan123Resolver.webUA
        case .pan115: return Pan115Resolver.webUA
        // 139 的 PC 版页面在 WebView 里会因环境检测白屏，用移动版
        case .c139: return C139Resolver.loginUA
        case .guangya, .ilanzou, .lanzou: return VideoHTTP.uaChrome
        case .bilibili: return VideoHTTP.uaChrome
        // 移动 UA 下没有登录页（/login 返回 404）
        case .xiaohongshu: return VideoHTTP.uaChrome
        case .pixiv: return VideoHTTP.uaChrome
        case .zhihu: return VideoHTTP.uaChrome
        case .yuanbao: return VideoHTTP.uaChrome
        // 桌面版登录页在手机宽度下要么被裁、要么叠弹窗：配合手机版登录页用手机 UA
        case .twitter, .instagram, .tiktok, .reddit, .facebook: return VideoHTTP.uaIPhone
        }
    }

    var capture: LoginCapture {
        switch self {
        case .quark: return .cookies([QuarkFamilyConfig.quark.cookieDomain])
        case .uc: return .cookies([QuarkFamilyConfig.uc.cookieDomain])
        case .baidu: return .cookies(["baidu.com"])
        case .xunlei: return .script(XunleiCredential.readScript)
        case .pan123: return .script("(function(){try{return localStorage.getItem('\(Pan123Resolver.tokenStorageKey)')||''}catch(e){return ''}})()")
        case .pan115: return .cookies(Pan115Resolver.cookieDomains)
        case .c139: return .cookies(C139Resolver.cookieDomains)
        case .lanzou: return .cookies(["woozooo.com"])
        case .guangya, .ilanzou: return .cookies([])
        case .bilibili: return .cookies(["bilibili.com"])
        case .xiaohongshu: return .cookies(["xiaohongshu.com"])
        case .pixiv: return .cookies(["pixiv.net"])
        case .zhihu: return .cookies(["zhihu.com"])
        case .yuanbao: return .cookies(["yuanbao.tencent.com", "tencent.com"])
        case .twitter, .instagram, .tiktok, .reddit, .facebook: return .cookies(OverseasAccount.cookieDomains(self))
        }
    }

    /// 登录完成的判据：关键凭据出现
    func looksLoggedIn(_ credential: String) -> Bool {
        switch self {
        case .quark, .uc: return credential.contains("__pus=")
        case .baidu: return BaiduResolver.isValidCookie(credential)
        case .xunlei: return XunleiCredential.parse(credential)?.accessToken.isEmpty == false
        case .pan123: return Pan123Resolver.normalizeToken(credential).count > 16
        case .pan115: return Pan115Resolver.isValidCookie(credential) && credential.contains("SEID=")
        case .c139: return C139Resolver.isValidCookie(credential)
        case .lanzou: return LanzouAccount.isValidCookie(credential)
        case .guangya, .ilanzou: return false
        case .bilibili: return credential.contains("SESSDATA=")
        // 游客也会被种 web_session，这里只是触发校验的前置条件，真正结论由 AccountValidator 探测得出
        case .xiaohongshu: return credential.contains("web_session=")
        // 游客也有 PHPSESSID，登录后的才带「用户 ID_」前缀
        case .pixiv: return PixivSession.isLoggedIn(cookie: credential)
        // d_c0 游客也有；登录后才有 z_c0
        case .zhihu: return credential.contains("z_c0=") && credential.contains("d_c0=")
        case .yuanbao: return YuanbaoAccount.looksLoggedIn(cookie: credential)
        // X：auth_token + ct0；Instagram：sessionid + ds_user_id；TikTok：sessionid；Reddit：reddit_session；Facebook：c_user + xs
        case .twitter, .instagram, .tiktok, .reddit, .facebook: return OverseasAccount.looksLoggedIn(self, cookie: credential)
        }
    }

    var benefit: String {
        switch self {
        case .quark: return "登录后可下载大文件（游客仅约 50MB 以内）"
        case .uc: return "登录后视频可取原画直链，下载更稳定"
        case .baidu: return "登录后可下载（借助临时转存取直链，取完即删）"
        case .xunlei: return "登录后可下载（借助临时转存取直链，取完即删）"
        case .pan123: return "登录后可下载分享文件"
        case .pan115: return "登录后可下载大文件（游客仅限小文件）"
        case .c139: return "登录后可下载分享文件"
        case .guangya: return "登录后可下载受限分享（临时转存后取链），并支持转存"
        case .ilanzou: return "登录后可转存分享到自己的网盘"
        case .lanzou: return "登录后可管理自己的蓝奏云文件"
        case .bilibili: return "登录后可解析 1080P 及以上清晰度"
        case .xiaohongshu: return "小红书网页端要求登录后才能查看笔记"
        case .pixiv: return "登录后可解析 R18 与受限作品"
        case .zhihu: return "知乎接口要求登录后才能解析回答、文章与想法"
        case .yuanbao: return "解析微信视频号需要登录腾讯元宝"
        case .twitter: return "登录后可解析受限推文，避开游客限额"
        case .instagram: return "登录后可解析受限帖子，减少限流"
        case .tiktok: return "登录后可解析需登录或有年龄限制的作品"
        case .reddit: return "登录后可解析 NSFW 与受限社区的帖子"
        case .facebook: return "登录后可解析仅登录可见的视频与帖子"
        }
    }

    /// 手动粘贴时的格式说明
    var manualHint: String {
        switch self {
        case .quark, .uc: return "需包含 __pus 与 __puus"
        case .baidu: return "需包含 BDUSS（建议同时包含 STOKEN）"
        case .xunlei: return "粘贴网页 localStorage 中 credentials_\(XunleiCredential.webClientId) 的值（JSON），或 access_token"
        case .pan123: return "粘贴网页 localStorage 中 authorToken 的值"
        case .pan115: return "需包含 UID、CID、SEID"
        case .c139: return "需包含 authorization，或 Os_SSo_Sid 与 RMKEY"
        case .guangya: return "粘贴网页 localStorage 中的 access_token（建议改用账号密码 / 短信登录）"
        case .ilanzou: return "粘贴 {\"appToken\":…,\"uuid\":…} 形式的凭据（建议改用账号密码登录）"
        case .lanzou: return "需包含 ylogin 与 phpdisk_info"
        case .bilibili: return "需包含 SESSDATA"
        case .xiaohongshu: return "需包含 web_session（登录后的值）"
        case .pixiv: return "在电脑浏览器登录 pixiv.net 后复制 Cookie，需包含 PHPSESSID"
        case .zhihu: return "需包含 z_c0 与 d_c0"
        case .yuanbao: return "需包含 hy_user 与 hy_token"
        case .twitter, .instagram, .tiktok, .reddit, .facebook: return OverseasAccount.manualHint(self)
        }
    }

    var manualPlaceholder: String {
        switch self {
        case .xunlei, .pan123, .guangya, .ilanzou: return "在电脑浏览器登录后，从开发者工具复制登录凭据"
        default: return "在电脑浏览器登录后复制请求头里的 Cookie"
        }
    }

    var symbol: String {
        switch self {
        case .quark: return "q.circle.fill"
        case .uc: return "u.circle.fill"
        case .baidu: return "b.circle.fill"
        case .xunlei: return "x.circle.fill"
        case .pan123: return "1.circle.fill"
        case .pan115: return "5.circle.fill"
        case .c139: return "m.circle.fill"
        case .guangya: return "g.circle.fill"
        case .ilanzou: return "y.circle.fill"
        case .lanzou: return "l.circle.fill"
        case .bilibili: return "play.tv.fill"
        case .xiaohongshu: return "book.closed.fill"
        case .pixiv: return "paintpalette.fill"
        case .zhihu: return "questionmark.bubble.fill"
        case .yuanbao: return "sparkles"
        case .twitter: return "at"
        case .instagram: return "camera.fill"
        case .tiktok: return "music.note"
        case .reddit: return "bubble.left.and.bubble.right.fill"
        case .facebook: return "person.2.fill"
        }
    }

    /// 光鸭、蓝奏优享的网页登录态存在 IndexedDB / 加密存储里不便读取，只提供应用内账号密码登录。
    /// Pixiv 登录页带 reCAPTCHA，出现验证时在网页里完成即可；Google / Apple 账号登录会被内嵌网页拦下，需用 pixiv 账号密码
    var supportsWebLogin: Bool { ![.guangya, .ilanzou].contains(self) }

    /// 应用内账号密码 / 短信登录
    var passwordLogin: PasswordLogin? { PasswordLogins.provider(for: self) }

    /// 登录页加载完成后注入的脚本：桌面布局在手机宽度下会被裁掉表单
    var loginPageScript: String? {
        switch self {
        case .xunlei: return LoginWebView.xunleiRenderFix
        case .xiaohongshu: return LoginWebView.viewportScript(width: 1280)
        // 只有桌面版的登录页（115、123、蓝奏云）按手机宽度渲染会被截掉右半边、还禁止滚动：按页面实际宽度缩放到一屏、恢复滚动与缩放
        case .pan115, .pan123, .lanzou, .zhihu: return LoginWebView.fitToWidthScript
        default: return nil
        }
    }

    /// 有应用内账号密码登录、且网页登录不好用的平台，点「登录」先走账号密码
    var prefersPasswordLogin: Bool { [.ilanzou, .lanzou, .guangya].contains(self) && passwordLogin != nil }
}
