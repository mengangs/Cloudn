// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Cookie 字符串工具（请求头形态 `a=1; b=2`）。
public enum CookieUtil {
    /// `a=1; b=2` → 有序键值对（重复键保留最后一个）
    public static func parse(_ cookie: String) -> [(name: String, value: String)] {
        var result: [(String, String)] = []
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            guard let eq = kv.firstIndex(of: "="), eq != kv.startIndex else { continue }
            let name = String(kv[..<eq])
            let value = String(kv[kv.index(after: eq)...])
            if let i = result.firstIndex(where: { $0.0 == name }) { result[i].1 = value } else { result.append((name, value)) }
        }
        return result
    }

    public static func build(_ pairs: [(name: String, value: String)]) -> String {
        pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public static func value(of name: String, in cookie: String) -> String? {
        parse(cookie).first(where: { $0.name == name })?.value
    }

    /// 设置或替换一个键
    public static func setting(_ name: String, _ value: String, in cookie: String) -> String {
        var pairs = parse(cookie)
        if let i = pairs.firstIndex(where: { $0.name == name }) { pairs[i].value = value } else { pairs.append((name, value)) }
        return build(pairs)
    }

    public static func removing(_ name: String, from cookie: String) -> String {
        build(parse(cookie).filter { $0.name != name })
    }

    /// 只把 `tracked` 里的键从响应 Cookie 合并回原 Cookie（夸克/UC 的 __puus/__pus 续期）
    public static func merge(_ original: String, with cookies: [(name: String, value: String)], tracked: Set<String>) -> String {
        var merged = original
        for c in cookies where tracked.contains(c.name) && !c.value.isEmpty {
            merged = setting(c.name, c.value, in: merged)
        }
        return merged
    }

    /// 合并两段 Cookie 串（后者覆盖前者同名键）
    public static func join(_ a: String, _ b: String) -> String {
        var pairs = parse(a)
        for (n, v) in parse(b) {
            if let i = pairs.firstIndex(where: { $0.name == n }) { pairs[i].value = v } else { pairs.append((n, v)) }
        }
        return build(pairs)
    }

    /// 切分被逗号拼接过的 Set-Cookie 头：只在「逗号后紧跟 name=」处切，避开 Expires 里的逗号
    static func splitSetCookieHeader(_ raw: String) -> [(String, String)] {
        let entries = Rx(#",\s*(?=[^;,\s=]+=)"#).replacing(in: raw, with: "\n").split(separator: "\n")
        var result: [(String, String)] = []
        for entry in entries {
            let kv = String(entry).substringBefore(";").trimmingCharacters(in: .whitespaces)
            guard let eq = kv.firstIndex(of: "="), eq != kv.startIndex else { continue }
            let name = String(kv[..<eq])
            let lower = name.lowercased()
            // 属性名不是 Cookie
            if ["expires", "path", "domain", "max-age", "samesite"].contains(lower) { continue }
            result.append((name, String(kv[kv.index(after: eq)...])))
        }
        return result
    }
}
