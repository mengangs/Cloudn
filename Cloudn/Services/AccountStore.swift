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
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let nickname = await AccountValidator.validate(kind, cookie: trimmed) else { return nil }
        await vault.save(Account(cookie: trimmed, nickname: nickname, updatedAt: Date()), for: kind)
        await reload()
        return nickname
    }

    func logout(_ kind: AccountKind) async {
        await vault.remove(kind)
        await reload()
    }
}

extension AccountKind {
    var loginURL: URL {
        switch self {
        case .quark: return URL(string: QuarkFamilyConfig.quark.loginURL)!
        case .uc: return URL(string: QuarkFamilyConfig.uc.loginURL)!
        case .bilibili: return URL(string: "https://passport.bilibili.com/login")!
        }
    }

    var loginUserAgent: String {
        switch self {
        case .quark: return QuarkFamilyConfig.quark.loginUserAgent
        case .uc: return QuarkFamilyConfig.uc.loginUserAgent
        case .bilibili: return VideoHTTP.uaChrome
        }
    }

    var cookieDomain: String {
        switch self {
        case .quark: return QuarkFamilyConfig.quark.cookieDomain
        case .uc: return QuarkFamilyConfig.uc.cookieDomain
        case .bilibili: return "bilibili.com"
        }
    }

    /// 登录完成的判据：关键 Cookie 出现
    func looksLoggedIn(_ cookie: String) -> Bool {
        switch self {
        case .quark, .uc: return cookie.contains("__pus=")
        case .bilibili: return cookie.contains("SESSDATA=")
        }
    }

    var benefit: String {
        switch self {
        case .quark: return "登录后可下载大文件（游客仅约 50MB 以内）"
        case .uc: return "登录后视频可取原画直链，下载更稳定"
        case .bilibili: return "登录后可解析 1080P 及以上清晰度"
        }
    }

    var symbol: String {
        switch self {
        case .quark: return "q.circle.fill"
        case .uc: return "u.circle.fill"
        case .bilibili: return "play.tv.fill"
        }
    }
}
