// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 海外平台（X、Instagram、TikTok、Reddit、Facebook）的可选登录：登录页、Cookie 域与登录态判据。
/// 网页登录在 App 内 WKWebView 里完成，读取这些域下的 Cookie 后交给 AccountValidator 校验。
/// 登录不是必需的：没有账号时解析器照常走游客方式，有账号时用来解析受限内容、避开游客限额。
public enum OverseasAccount {
    public static let kinds: [AccountKind] = [.twitter, .instagram, .tiktok, .reddit, .facebook]

    /// 登录页：都用手机网页版（配合手机 UA），在 WKWebView 里布局正常、键盘弹出不乱跳
    public static func loginURL(_ kind: AccountKind) -> String? {
        switch kind {
        case .twitter: return "https://x.com/i/flow/login"
        case .instagram: return "https://www.instagram.com/accounts/login/"
        case .tiktok: return "https://www.tiktok.com/login"
        case .reddit: return "https://www.reddit.com/login/"
        case .facebook: return "https://m.facebook.com/login/"
        default: return nil
        }
    }

    /// 读取 Cookie 的域（含子域），靠前的优先
    public static func cookieDomains(_ kind: AccountKind) -> [String] {
        switch kind {
        case .twitter: return ["x.com", "twitter.com"]
        case .instagram: return ["instagram.com"]
        case .tiktok: return ["tiktok.com"]
        case .reddit: return ["reddit.com"]
        case .facebook: return ["facebook.com"]
        default: return []
        }
    }

    /// 登录后才会出现的关键 Cookie（游客没有）
    public static func keyCookies(_ kind: AccountKind) -> [String] {
        switch kind {
        case .twitter: return ["auth_token", "ct0"]
        case .instagram: return ["sessionid", "ds_user_id"]
        case .tiktok: return ["sessionid"]
        // 新版 Reddit 登录后 reddit_session 是 JWT；token_v2 游客也有，不能作判据
        case .reddit: return ["reddit_session"]
        case .facebook: return ["c_user", "xs"]
        default: return []
        }
    }

    /// 网页登录完成的判据：关键 Cookie 都有非空值
    public static func looksLoggedIn(_ kind: AccountKind, cookie: String) -> Bool {
        let keys = keyCookies(kind)
        guard !keys.isEmpty else { return false }
        for key in keys {
            let value = CookieUtil.value(of: key, in: cookie) ?? ""
            if value.isEmpty || value == "\"\"" { return false }
        }
        // Facebook 的 c_user 是数字用户 ID；登出后会被清空或改写
        if kind == .facebook {
            let uid = CookieUtil.value(of: "c_user", in: cookie) ?? ""
            return uid.allSatisfy(\.isNumber)
        }
        return true
    }

    /// 手动粘贴 Cookie 时的格式说明
    public static func manualHint(_ kind: AccountKind) -> String {
        let keys = keyCookies(kind)
        guard !keys.isEmpty else { return "" }
        return "需包含 " + keys.joined(separator: " 与 ")
    }

    // MARK: 用户 ID（用于接口不可用时的兜底名称：带上 ID 末尾，避免多个账号同名互相覆盖）

    /// X 的 twid：`u%3D123`、`"u=123"` → 123
    static func xUserID(cookie: String) -> String? {
        guard let raw = CookieUtil.value(of: "twid", in: cookie) else { return nil }
        var v = raw.removingPercentEncoding ?? raw
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if v.hasPrefix("u=") { v = String(v.dropFirst(2)) }
        guard !v.isEmpty, v.allSatisfy(\.isNumber) else { return nil }
        return v
    }

    static func userID(_ kind: AccountKind, cookie: String) -> String? {
        let raw: String?
        switch kind {
        case .twitter: return xUserID(cookie: cookie)
        case .instagram: raw = CookieUtil.value(of: "ds_user_id", in: cookie)
        case .facebook: raw = CookieUtil.value(of: "c_user", in: cookie)
        default: raw = nil
        }
        guard let id = raw, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return id
    }

    /// 接口暂时不可用（网络、风控、限流）但关键 Cookie 齐全时的显示名
    static func fallbackName(_ kind: AccountKind, cookie: String) -> String {
        let base = "\(kind.displayName) 用户"
        guard let id = userID(kind, cookie: cookie), id.count >= 4 else { return base }
        return "\(base) · \(id.suffix(4))"
    }

    /// 一次登录态探测的结论
    enum Probe: Equatable {
        /// 已登录，附显示名
        case valid(String)
        /// 平台明确表示未登录 / 会话失效
        case invalid
        /// 说不准（限流、风控、改版）：关键 Cookie 齐全时按已登录处理
        case unknown
    }

    /// 探测结论 → AccountValidator 的返回值：只有平台明确说未登录时才返回 nil
    static func conclude(_ probe: Probe, kind: AccountKind, cookie: String) -> String? {
        switch probe {
        case .valid(let name): return name.isEmpty ? fallbackName(kind, cookie: cookie) : name
        case .invalid: return nil
        case .unknown: return fallbackName(kind, cookie: cookie)
        }
    }

    /// 发探测请求：网络不通时算「说不准」（登录页刚能打开，多半是这边的代理 / 网络问题）
    static func probe(_ kind: AccountKind, cookie: String, _ request: HTTPRequest,
                      interpret: (HTTPResponse) -> Probe) async -> String? {
        guard looksLoggedIn(kind, cookie: cookie) else { return nil }
        guard let r = try? await HTTPClient.shared.send(request) else {
            return conclude(.unknown, kind: kind, cookie: cookie)
        }
        return conclude(interpret(r), kind: kind, cookie: cookie)
    }
}
