// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 ParseHub（MIT，z-mio/ParseHub）的国内平台解析（头条/贴吧/公众号/豆瓣/酷安/皮皮虾/最右）共用的小工具。
import Foundation

/// 不依赖 DOM 库的 HTML 小工具：实体解码、去标签、按 class 取元素、取属性。
enum DomesticHTML {
    private static let entityRegex = try! NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")

    /// HTML 实体解码（&amp; &lt; &#39; &#x3c; 等）
    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in entityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            if let decoded = decodeEntity(body) {
                out += decoded
            } else {
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func decodeEntity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            var value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
            return String(Character(scalar))
        }
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: return nil
        }
    }

    /// 正文 HTML → 纯文本：换行标签转换行，去标签，解实体，压缩空行
    static func text(_ html: String) -> String {
        var s = Rx(#"<br\s*/?>"#, ignoreCase: true).replacing(in: html, with: "\n")
        s = Rx(#"</(?:p|div|section|h[1-6]|li)>"#, ignoreCase: true).replacing(in: s, with: "\n")
        s = Rx(#"<[^>]*>"#).replacing(in: s, with: "")
        s = unescape(s)
        s = Rx(#"[ \t]+\n"#).replacing(in: s, with: "\n")
        s = Rx(#"\n{3,}"#).replacing(in: s, with: "\n\n")
        return s.trimmed
    }

    /// 所有 `<name ...>` 开始标签（整段标签文本）
    static func openTags(_ name: String, in html: String) -> [String] {
        Rx("<" + name + #"\b[^>]*>"#, ignoreCase: true).allMatches(in: html).map { $0[0] }
    }

    /// 标签里某个属性的值（已解实体）；`src` 不会误匹配 `data-src`
    static func attribute(_ name: String, in tag: String) -> String? {
        let rx = Rx(#"\s"# + Rx.escape(name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, ignoreCase: true)
        guard let m = rx.firstMatch(in: tag) else { return nil }
        let value = m.dropFirst().first(where: { !$0.isEmpty }) ?? ""
        return unescape(value)
    }

    /// 第一个 class 含 `cls` 的元素的内部 HTML（按同名标签计数找配对的闭合标签）
    static func element(class cls: String, in html: String) -> String? {
        let pattern = #"<([a-zA-Z][a-zA-Z0-9]*)(?=[\s>])[^>]*?\sclass\s*=\s*(["'])(?:[^"']*\s)?"#
            + Rx.escape(cls) + #"(?:\s[^"']*)?\2[^>]*>"#
        guard let open = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = open.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let tag = ns.substring(with: m.range(at: 1))
        let start = m.range.location + m.range.length
        guard let tagRx = try? NSRegularExpression(pattern: "<(/?)" + tag + #"\b[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        var depth = 1
        let rest = NSRange(location: start, length: ns.length - start)
        for t in tagRx.matches(in: html, range: rest) {
            let closing = t.range(at: 1).length > 0
            if closing {
                depth -= 1
                if depth == 0 {
                    return ns.substring(with: NSRange(location: start, length: t.range.location - start))
                }
            } else if !ns.substring(with: t.range).hasSuffix("/>") {
                depth += 1
            }
        }
        return ns.substring(from: start)
    }

    /// 由直链路径猜图片扩展名
    static func imageExtension(_ url: String, fallback: String = "jpg") -> String {
        let path = URL(string: url)?.path ?? url.substringBefore("?")
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpeg", "jpg": return "jpg"
        case "png", "gif", "webp", "bmp", "heic", "avif": return ext
        default: return fallback
        }
    }

    /// 协议相对 / 明文地址补成 https
    static func absolute(_ url: String) -> String {
        if url.hasPrefix("//") { return "https:" + url }
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        return url
    }
}

/// 宽松的 JS 对象字面量（键无引号、单引号字符串、尾随逗号、注释、`'0' * 1` 这类隐式转换），
/// 也能按原样解析普通 JSON；对象保留键顺序（最右按「最后一个键」取图）。
indirect enum JSLiteral {
    case object([(String, JSLiteral)])
    case array([JSLiteral])
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    static func parse(_ text: String) -> JSLiteral? {
        var p = JSLiteralParser(text)
        return p.parseTop()
    }

    subscript(key: String) -> JSLiteral? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.last(where: { $0.0 == key })?.1
    }

    /// 对象的值（按出现顺序）
    var orderedValues: [JSLiteral] {
        guard case .object(let pairs) = self else { return [] }
        return pairs.map { $0.1 }
    }

    var items: [JSLiteral] {
        guard case .array(let a) = self else { return [] }
        return a
    }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let n): return String(n)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }

    /// 转成 Foundation 对象，再包成 JSON 访问
    var foundation: Any {
        switch self {
        case .object(let pairs):
            var dict: [String: Any] = [:]
            for (k, v) in pairs { dict[k] = v.foundation }
            return dict
        case .array(let a): return a.map { $0.foundation }
        case .string(let s): return s
        case .int(let n): return NSNumber(value: n)
        case .double(let d): return NSNumber(value: d)
        case .bool(let b): return NSNumber(value: b)
        case .null: return NSNull()
        }
    }

    var json: JSON { JSON(foundation) }
}

struct JSLiteralParser {
    private let s: [Unicode.Scalar]
    private var i = 0
    /// 当前嵌套层数：网页里的数据不可信，`[[[[…` 嵌套几万层会把递归解析的栈撑爆（直接崩溃）
    private var depth = 0
    static let maxDepth = 256

    init(_ text: String) { s = Array(text.unicodeScalars) }

    /// 解析开头的一个值，忽略其后的内容
    mutating func parseTop() -> JSLiteral? {
        skipSpace()
        return parseValue()
    }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let j = i + offset
        return j < s.count ? s[j] : nil
    }

    private static func isIdent(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || c == "_" || c == "$" || v > 127
    }

    private mutating func skipSpace() {
        while let c = peek() {
            if c == " " || c == "\n" || c == "\r" || c == "\t" || c == "\u{FEFF}" || c == "\u{A0}" || c == "\u{2028}" || c == "\u{2029}" {
                i += 1
            } else if c == "/" && peek(1) == "/" {
                while let d = peek(), d != "\n" { i += 1 }
            } else if c == "/" && peek(1) == "*" {
                i += 2
                while i < s.count && !(s[i] == "*" && peek(1) == "/") { i += 1 }
                i = min(i + 2, s.count)
            } else {
                return
            }
        }
    }

    private mutating func parseValue() -> JSLiteral? {
        guard var value = parsePrimary() else { return nil }
        // 尾随的「 * 1」隐式转换、「|| 默认值」、「.replace(...)」之类：吃掉，保留首个值
        while true {
            skipSpace()
            guard let c = peek() else { break }
            if c == "*" || c == "+" {
                i += 1
                skipSpace()
                _ = parsePrimary()
            } else if c == "|" && peek(1) == "|" {
                i += 2
                skipSpace()
                let alt = parsePrimary()
                if case .string(let str) = value, str.isEmpty, let alt { value = alt }
            } else {
                break
            }
        }
        return value
    }

    private mutating func parsePrimary() -> JSLiteral? {
        skipSpace()
        guard let c = peek() else { return nil }
        guard depth < Self.maxDepth else { return nil }
        depth += 1
        defer { depth -= 1 }
        var value: JSLiteral?
        switch c {
        case "{": value = parseObject()
        case "[": value = parseArray()
        case "\"", "'", "`": value = parseString().map { JSLiteral.string($0) }
        case "(":
            i += 1
            value = parseValue()
            skipSpace()
            if peek() == ")" { i += 1 }
        default:
            if c == "-" || c == "+" || c == "." || (c.value >= 48 && c.value <= 57) {
                value = parseNumber()
            } else if Self.isIdent(c) {
                value = parseIdentifierValue()
            } else {
                return nil
            }
        }
        skipPostfix()
        return value
    }

    /// `.html(false)`、`.replace(/x/, 'y')` 这类方法调用
    private mutating func skipPostfix() {
        while true {
            let save = i
            skipSpace()
            guard peek() == ".", let n = peek(1), Self.isIdent(n), !(n.value >= 48 && n.value <= 57) else { i = save; return }
            i += 1
            while let d = peek(), Self.isIdent(d) { i += 1 }
            skipSpace()
            if peek() == "(" { skipBalanced() }
        }
    }

    private mutating func skipBalanced() {
        var depth = 0
        while let c = peek() {
            if c == "\"" || c == "'" || c == "`" {
                _ = parseString()
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth <= 0 { i += 1; return }
            }
            i += 1
        }
    }

    private mutating func parseObject() -> JSLiteral? {
        i += 1
        var pairs: [(String, JSLiteral)] = []
        while true {
            skipSpace()
            guard let c = peek() else { return .object(pairs) }
            if c == "}" { i += 1; return .object(pairs) }
            if c == "," { i += 1; continue }
            var key = ""
            if c == "\"" || c == "'" {
                guard let k = parseString() else { return nil }
                key = k
            } else {
                while let d = peek(), Self.isIdent(d) || d == "-" { key.unicodeScalars.append(d); i += 1 }
                if key.isEmpty { return nil }
            }
            skipSpace()
            guard peek() == ":" else { return nil }
            i += 1
            guard let v = parseValue() else { return nil }
            pairs.append((key, v))
            skipSpace()
            if peek() == "," { i += 1 } else if peek() == "}" { i += 1; return .object(pairs) } else { return nil }
        }
    }

    private mutating func parseArray() -> JSLiteral? {
        i += 1
        var items: [JSLiteral] = []
        while true {
            skipSpace()
            guard let c = peek() else { return .array(items) }
            if c == "]" { i += 1; return .array(items) }
            if c == "," { i += 1; continue }
            guard let v = parseValue() else { return nil }
            items.append(v)
            skipSpace()
            if peek() == "," { i += 1 } else if peek() == "]" { i += 1; return .array(items) } else { return nil }
        }
    }

    private mutating func readHex(_ count: Int) -> UInt32? {
        guard i + count <= s.count else { return nil }
        var text = ""
        for k in 0..<count { text.unicodeScalars.append(s[i + k]) }
        guard let v = UInt32(text, radix: 16) else { return nil }
        i += count
        return v
    }

    private mutating func parseString() -> String? {
        guard let quote = peek() else { return nil }
        i += 1
        var out = String.UnicodeScalarView()
        var pendingHigh: UInt32?
        while let c = peek() {
            i += 1
            if c == quote {
                return String(out)
            }
            if c != "\\" {
                out.append(c)
                continue
            }
            guard let e = peek() else { break }
            i += 1
            var code: UInt32?
            switch e {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            case "0": out.append("\u{0}")
            case "\n": break
            case "\r": if peek() == "\n" { i += 1 }
            case "x": code = readHex(2)
            case "u":
                if peek() == "{" {
                    i += 1
                    var hex = ""
                    while let d = peek(), d != "}" { hex.unicodeScalars.append(d); i += 1 }
                    i += 1
                    code = UInt32(hex, radix: 16)
                } else {
                    code = readHex(4)
                }
            default: out.append(e)
            }
            guard let v = code else { continue }
            if v >= 0xD800 && v <= 0xDBFF {
                pendingHigh = v
                continue
            }
            if v >= 0xDC00 && v <= 0xDFFF, let high = pendingHigh {
                pendingHigh = nil
                let combined = 0x10000 + ((high - 0xD800) << 10) + (v - 0xDC00)
                if let scalar = Unicode.Scalar(combined) { out.append(scalar) }
                continue
            }
            if let scalar = Unicode.Scalar(v) { out.append(scalar) }
        }
        return String(out)
    }

    private mutating func parseNumber() -> JSLiteral? {
        var text = ""
        if let c = peek(), c == "-" || c == "+" { text.unicodeScalars.append(c); i += 1 }
        if peek() == "I" {
            _ = parseIdentifierValue()
            return .double(text == "-" ? -Double.infinity : Double.infinity)
        }
        if peek() == "0", let x = peek(1), x == "x" || x == "X" {
            i += 2
            var hex = ""
            while let d = peek(), d.properties.isASCIIHexDigit { hex.unicodeScalars.append(d); i += 1 }
            let v = Int64(hex, radix: 16) ?? 0
            return .int(text == "-" ? -v : v)
        }
        var isFloat = false
        while let d = peek() {
            let isDigit = d.value >= 48 && d.value <= 57
            if isDigit {
                text.unicodeScalars.append(d)
            } else if d == "." || d == "e" || d == "E" {
                isFloat = true
                text.unicodeScalars.append(d)
            } else if (d == "-" || d == "+"), let last = text.unicodeScalars.last, last == "e" || last == "E" {
                text.unicodeScalars.append(d)
            } else {
                break
            }
            i += 1
        }
        if !isFloat, let n = Int64(text) { return .int(n) }
        guard let d = Double(text) else { return nil }
        return .double(d)
    }

    private mutating func parseIdentifierValue() -> JSLiteral? {
        var name = ""
        while let d = peek(), Self.isIdent(d) { name.unicodeScalars.append(d); i += 1 }
        switch name {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null", "undefined": return .null
        case "NaN": return .double(Double.nan)
        case "Infinity": return .double(Double.infinity)
        default:
            // 变量引用 / 函数调用：取不到值，按 null 处理
            skipSpace()
            if peek() == "(" { skipBalanced() }
            return .null
        }
    }
}

/// 同一个视频的一档清晰度（国内各解析器的中间形态）：先按「默认档（最高画质）在前」列出来，
/// 再用 `medias` 统一换成同组的 VideoMedia（去重、限量、文件名互不相同）
struct DomesticVariant: Equatable, Sendable {
    var url: String
    /// 选择器上显示的短标签，如「1080P」「720P · H.265」「超清」
    var label: String
    /// 字节数；未知为 -1
    var size: Int64 = -1
    var isHLS: Bool = false
    var audioURL: String = ""
    /// 这一档单独需要的请求头（为 nil 时用调用方给的）
    var headers: [String: String]?

    init(url: String, label: String, size: Int64 = -1, isHLS: Bool = false, audioURL: String = "", headers: [String: String]? = nil) {
        self.url = url
        self.label = label
        self.size = size > 0 ? size : -1
        self.isHLS = isHLS
        self.audioURL = audioURL
        self.headers = headers
    }

    /// 每个视频最多列出的档数
    static let maxCount = 6

    /// 「短边 + P」（如 1920×1080 → 1080P），H.265 加后缀；宽高未知时用 fallback
    static func label(width: Int, height: Int, hevc: Bool = false, fallback: String = "") -> String {
        let side = width > 0 && height > 0 ? min(width, height) : max(width, height, 0)
        var text = side > 0 ? "\(side)P" : fallback
        if hevc { text = text.isEmpty ? "H.265" : text + " · H.265" }
        return text
    }

    /// 编码名是否为 H.265 / HEVC（含字节系的 bytevc1）
    static func isHEVC(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c.contains("265") || c.contains("hevc") || c.contains("hvc1") || c.contains("hev1") || c.contains("bytevc1")
    }

    /// 去掉空地址、按地址去重（保留先出现的），最多 maxCount 档
    static func normalized(_ list: [DomesticVariant], limit: Int = DomesticVariant.maxCount) -> [DomesticVariant] {
        var seen = Set<String>()
        var out: [DomesticVariant] = []
        for v in list where !v.url.isEmpty && seen.insert(v.url).inserted {
            out.append(v)
            if out.count >= limit { break }
        }
        return out
    }

    /// 标签 → 文件名后缀（「720P · H.265」→「720P_H.265」）
    static func fileSuffix(_ label: String) -> String {
        let replaced = label.replacingOccurrences(of: "·", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: "_")
        return FileNames.sanitize(replaced)
    }

    /// 各档 → VideoMedia：第一档文件名为「base.ext」，其余为「base_标签.ext」；
    /// 只剩一档时不设清晰度组（与以前的单条结果一致）
    static func medias(_ list: [DomesticVariant], base: String, ext: String = "mp4", group: String = "video",
                       kind: MediaKind = .video, headers: [String: String]) -> [VideoMedia] {
        let items = normalized(list)
        let groupName = items.count > 1 ? group : ""
        var usedSuffixes = Set<String>()
        var out: [VideoMedia] = []
        for (i, v) in items.enumerated() {
            let name: String
            if i == 0 {
                name = "\(base).\(ext)"
            } else {
                var suffix = fileSuffix(v.label)
                if suffix.isEmpty || usedSuffixes.contains(suffix) { suffix = suffix.isEmpty ? "v\(i + 1)" : "\(suffix)_\(i + 1)" }
                usedSuffixes.insert(suffix)
                name = "\(base)_\(suffix).\(ext)"
            }
            out.append(VideoMedia(url: v.url, kind: kind, fileName: name, size: v.size > 0 ? v.size : -1, isHLS: v.isHLS,
                                  headers: v.headers ?? headers, quality: v.label, audioURL: v.audioURL, variantGroup: groupName))
        }
        return out
    }
}
