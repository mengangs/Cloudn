// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 动态 JSON 访问（语义对齐 org.json 的 opt* 系列：取不到给默认值，不抛异常）。
/// 各平台接口字段多、结构随版本漂移，用 Codable 逐个建模代价太高。
public struct JSON: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }

    public init?(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        self.init(obj)
    }

    public init?(text: String) {
        guard let data = text.data(using: .utf8) else { return nil }
        self.init(data: data)
    }

    public static func object(_ dict: [String: Any]) -> JSON { JSON(dict) }

    public subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSON {
        guard let arr = raw as? [Any], index >= 0, index < arr.count else { return JSON(nil) }
        return JSON(arr[index])
    }

    public var isNull: Bool { raw == nil }
    public var dictionary: [String: Any]? { raw as? [String: Any] }
    public var isObject: Bool { raw is [String: Any] }
    public var array: [JSON] { (raw as? [Any])?.map { JSON($0) } ?? [] }
    public var isArray: Bool { raw is [Any] }
    public var keys: [String] { dictionary.map { Array($0.keys) } ?? [] }

    /// 字符串值；数字/布尔会被转成字符串，缺失与 JSON null 返回空串（避免 "null" 被当成内容）
    public var string: String {
        switch raw {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeIDCompat.isBool(n) { return n.boolValue ? "true" : "false" }
            if n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 9.0e15 { return String(n.int64Value) }
            return n.stringValue
        default: return ""
        }
    }

    public var int: Int { Int(int64) }

    /// 超出 Int64 范围的数（如 1e30）、字符串 "nan" / "inf" 不能直接转 Int64（会崩溃）：按范围截断，非有限值给 0
    public var int64: Int64 {
        switch raw {
        case let n as NSNumber:
            let d = n.doubleValue
            if d.isFinite, abs(d) < 9.0e18 { return n.int64Value }
            return Int64(saturating: d)
        case let s as String: return Int64(s.trimmed) ?? Int64(saturating: Double(s.trimmed) ?? 0)
        default: return 0
        }
    }

    /// nan / inf（字符串 "inf"，或宽松 JS 解析出的 Infinity）当作 0：下游常把时长等转成整数，非有限值会让转换崩溃
    public var double: Double {
        let d: Double
        switch raw {
        case let n as NSNumber: d = n.doubleValue
        case let s as String: d = Double(s.trimmed) ?? 0
        default: return 0
        }
        return d.isFinite ? d : 0
    }

    public var bool: Bool {
        switch raw {
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return false
        }
    }

    /// 是否存在该键（值为 null 也算存在）
    public func has(_ key: String) -> Bool { (raw as? [String: Any])?.keys.contains(key) ?? false }

    /// 依次尝试多个候选键，返回第一个非空字符串
    public func string(_ keys: String...) -> String {
        for k in keys { let v = self[k].string; if !v.isEmpty { return v } }
        return ""
    }

    /// 依次尝试多个候选键，返回第一个对象
    public func object(_ keys: String...) -> JSON {
        for k in keys where self[k].isObject { return self[k] }
        return JSON(nil)
    }

    /// 依次尝试多个候选键，返回第一个数组
    public func arrayValue(_ keys: String...) -> [JSON] {
        for k in keys where self[k].isArray { return self[k].array }
        return []
    }

    public static func serialize(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data("{}".utf8)
    }
}

public extension Int64 {
    /// Double → Int64 不崩溃：超范围截断到 min / max，NaN 给 0（Int64(Double) 遇到这些会直接崩溃）
    init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= 9.223372036854775e18 {
            self = .max
        } else if value <= -9.223372036854775e18 {
            self = .min
        } else {
            self = Int64(value)
        }
    }
}

public extension Int {
    /// Double → Int 不崩溃：超范围截断，NaN 给 0
    init(saturating value: Double) { self = Int(truncatingIfNeeded: Int64(saturating: value)) }
}

/// NSNumber 是否为布尔值（Linux 上没有 CFBooleanGetTypeID，按 objCType 判断）
enum CFGetTypeIDCompat {
    static func isBool(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        return String(cString: n.objCType) == "c" && (n.int8Value == 0 || n.int8Value == 1) && n is Bool
        #endif
    }
}

/// 保持键顺序的紧凑 JSON 编码（对齐 org.json 的 toString）：部分平台按「明文 body 字符串」签名，
/// JSONSerialization 不保证键顺序，签名就会对不上。
public indirect enum OrderedJSON: Sendable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    case int(Int64)
    case bool(Bool)
    case null

    public var text: String {
        switch self {
        case .null: return "null"
        case .object(let pairs): return "{" + pairs.map { OrderedJSON.quote($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .string(let s): return OrderedJSON.quote(s)
        case .int(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
