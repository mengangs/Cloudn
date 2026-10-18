// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// NSRegularExpression 的轻量封装：Linux 与 Apple 平台行为一致，便于逐条移植正则。
public struct Rx: @unchecked Sendable {
    private let regex: NSRegularExpression

    public init(_ pattern: String, ignoreCase: Bool = false, dotAll: Bool = false) {
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        // 模式均为代码内常量，写错应当在测试里直接暴露
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// 第一处匹配：[0] 为整体，其后为各捕获组（未参与匹配的组为空串）
    public func firstMatch(in text: String) -> [String]? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// 第一处匹配的第 `group` 个捕获组
    public func first(in text: String, group: Int = 1) -> String? {
        guard let groups = firstMatch(in: text), groups.count > group else { return nil }
        return groups[group]
    }

    public func allMatches(in text: String) -> [[String]] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    public func matches(_ text: String) -> Bool { firstMatch(in: text) != nil }

    public func replacing(in text: String, with template: String) -> String {
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    public static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 去掉结尾处属于 `chars` 的字符（中文分享文案里链接后常跟标点）
    func trimmingTrailing(_ chars: String) -> String {
        var s = self
        while let last = s.last, chars.contains(last) { s.removeLast() }
        return s
    }

    func substringBefore(_ sep: Character) -> String {
        guard let i = firstIndex(of: sep) else { return self }
        return String(self[..<i])
    }

    func substringAfterLast(_ sep: Character, default value: String? = nil) -> String {
        guard let i = lastIndex(of: sep) else { return value ?? self }
        return String(self[index(after: i)...])
    }

    var nilIfBlank: String? { trimmed.isEmpty ? nil : self }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
