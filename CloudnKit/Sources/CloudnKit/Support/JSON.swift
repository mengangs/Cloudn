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

    public var int64: Int64 {
        switch raw {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s.trimmed) ?? Int64(Double(s.trimmed) ?? 0)
        default: return 0
        }
    }

    public var double: Double {
        switch raw {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmed) ?? 0
        default: return 0
        }
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
