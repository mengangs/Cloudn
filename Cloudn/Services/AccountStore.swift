// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

struct Account: Codable, Equatable {
    var cookie: String
    var nickname: String
    var updatedAt: Date
}

/// 解析器侧的凭证源：钥匙串为唯一真源，服务端续期 Cookie 时在这里回写
actor AccountVault: CredentialStore {
    private var cache: [AccountKind: Account] = [:]
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        for kind in AccountKind.allCases {
            if let data = Keychain.read(kind.rawValue), let account = try? JSONDecoder().decode(Account.self, from: data) {
                cache[kind] = account
            }
        }
    }

    func cookie(for kind: AccountKind) async -> String? { cache[kind]?.cookie }

    func updateCookie(_ new: String, replacing old: String, for kind: AccountKind) async {
        guard var account = cache[kind], account.cookie == old else { return }
        account.cookie = new
        account.updatedAt = Date()
        save(account, for: kind)
    }

    func account(for kind: AccountKind) -> Account? { cache[kind] }
    func all() -> [AccountKind: Account] { cache }

    func save(_ account: Account, for kind: AccountKind) {
        cache[kind] = account
        if let data = try? JSONEncoder().encode(account) { Keychain.write(kind.rawValue, data) }
        onChange()
    }

    func remove(_ kind: AccountKind) {
        cache[kind] = nil
        Keychain.delete(kind.rawValue)
        onChange()
    }
}

/// 界面侧的账号状态镜像
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [AccountKind: Account] = [:]
    @ObservationIgnored private(set) var vault: AccountVault!

    init() {
        vault = AccountVault { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
        Task { await reload() }
    }

    func reload() async {
        accounts = await vault.all()
    }

    func isLoggedIn(_ kind: AccountKind) -> Bool { accounts[kind] != nil }

    /// 校验 Cookie 后保存；返回昵称，无效返回 nil
    func login(_ kind: AccountKind, cookie: String) async -> String? {
        let normalized = AccountValidator.normalize(kind, cookie)
        guard !normalized.isEmpty, let nickname = await AccountValidator.validate(kind, cookie: normalized) else { return nil }
        await vault.save(Account(cookie: normalized, nickname: nickname, updatedAt: Date()), for: kind)
        await reload()
        return nickname
    }

    func logout(_ kind: AccountKind) async {
        await vault.remove(kind)
        await reload()
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
        case .baidu: return URL(string: BaiduResolver.loginURL)!
        case .xunlei: return URL(string: XunleiCredential.loginURL)!
        case .pan123: return URL(string: Pan123Resolver.loginURL)!
        case .pan115: return URL(string: Pan115Resolver.loginURL)!
        case .c139: return URL(string: C139Resolver.loginURL)!
        case .bilibili: return URL(string: "https://passport.bilibili.com/login")!
        // 必须直指 /login：站点根地址会跳到桌面信息流再叠登录弹窗
        case .xiaohongshu: return URL(string: "https://www.xiaohongshu.com/login")!
        case .pixiv: return URL(string: "https://accounts.pixiv.net/login")!
        }
    }

    var loginUserAgent: String {
        switch self {
        case .quark: return QuarkFamilyConfig.quark.loginUserAgent
        case .uc: return QuarkFamilyConfig.uc.loginUserAgent
        case .baidu: return BaiduResolver.webUA
        // 网页版登录态只在桌面版页面写入
        case .xunlei: return XunleiCredential.desktopUA
        case .pan123: return Pan123Resolver.webUA
        case .pan115: return Pan115Resolver.webUA
        // 139 的 PC 版页面在 WebView 里会因环境检测白屏，用移动版
        case .c139: return C139Resolver.loginUA
        case .bilibili: return VideoHTTP.uaChrome
        // 移动 UA 下没有登录页（/login 返回 404）
        case .xiaohongshu: return VideoHTTP.uaChrome
        case .pixiv: return VideoHTTP.uaChrome
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
        case .bilibili: return .cookies(["bilibili.com"])
        case .xiaohongshu: return .cookies(["xiaohongshu.com"])
        case .pixiv: return .cookies(["pixiv.net"])
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
        case .bilibili: return credential.contains("SESSDATA=")
        // 游客也会被种 web_session，这里只是触发校验的前置条件，真正结论由 AccountValidator 探测得出
        case .xiaohongshu: return credential.contains("web_session=")
        case .pixiv: return credential.contains("PHPSESSID=")
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
        case .bilibili: return "登录后可解析 1080P 及以上清晰度"
        case .xiaohongshu: return "小红书网页端要求登录后才能查看笔记"
        case .pixiv: return "粘贴 Cookie 后可解析 R18 与受限作品"
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
        case .bilibili: return "需包含 SESSDATA"
        case .xiaohongshu: return "需包含 web_session（登录后的值）"
        case .pixiv: return "在电脑浏览器登录 pixiv.net 后复制 Cookie，需包含 PHPSESSID"
        }
    }

    var manualPlaceholder: String {
        switch self {
        case .xunlei, .pan123: return "在电脑浏览器登录后，从开发者工具复制登录凭据"
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
        case .bilibili: return "play.tv.fill"
        case .xiaohongshu: return "book.closed.fill"
        case .pixiv: return "paintpalette.fill"
        }
    }

    /// Pixiv 登录页背后是 reCAPTCHA Enterprise，在 WebView 里走不完，只支持手动粘贴 Cookie
    var supportsWebLogin: Bool { self != .pixiv }

    /// 登录页加载完成后注入的脚本：桌面布局在手机宽度下会被裁掉表单
    var loginPageScript: String? {
        switch self {
        case .xunlei: return LoginWebView.xunleiRenderFix
        case .xiaohongshu: return LoginWebView.viewportScript(width: 1280)
        default: return nil
        }
    }
}
