// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// B 编码的值（BitTorrent 元数据、tracker 响应、DHT 消息都用它）
public indirect enum BValue: Equatable, Sendable {
    case int(Int64)
    case bytes(Data)
    case list([BValue])
    case dict([Data: BValue])

    public init(_ string: String) { self = .bytes(Data(string.utf8)) }

    public subscript(key: String) -> BValue? {
        guard case .dict(let d) = self else { return nil }
        return d[Data(key.utf8)]
    }

    public var int: Int64? { if case .int(let v) = self { return v }; return nil }
    public var data: Data? { if case .bytes(let v) = self { return v }; return nil }
    public var list: [BValue]? { if case .list(let v) = self { return v }; return nil }
    public var dict: [Data: BValue]? { if case .dict(let v) = self { return v }; return nil }

    /// 按 UTF-8 解码；不是合法 UTF-8 时按 Latin-1 兜底（老种子常见 GBK 文件名，至少不丢字符）
    public var string: String? {
        guard let d = data else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }

    public static func dict(_ pairs: [(String, BValue)]) -> BValue {
        var d: [Data: BValue] = [:]
        for (k, v) in pairs { d[Data(k.utf8)] = v }
        return .dict(d)
    }
}

public struct BencodeError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum Bencode {
    public static func decode(_ data: Data) throws -> BValue {
        var p = Parser(bytes: [UInt8](data))
        let v = try p.value(depth: 0)
        guard p.i == p.bytes.count else { throw BencodeError(message: "B 编码末尾有多余数据") }
        return v
    }

    /// 解码开头的一个值，返回它和占用的字节数（ut_metadata 的数据消息在字典后面直接跟原始数据）
    public static func decodePrefix(_ data: Data) throws -> (BValue, Int) {
        var p = Parser(bytes: [UInt8](data))
        let v = try p.value(depth: 0)
        return (v, p.i)
    }

    /// 顶层字典里某个键对应值的原始字节（种子文件的 info 字典要按原样算 SHA1）
    public static func rawValue(forKey key: String, in data: Data) throws -> Data? {
        var p = Parser(bytes: [UInt8](data))
        p.capture = Array(key.utf8)
        _ = try p.value(depth: 0)
        guard let r = p.captured else { return nil }
        return Data(p.bytes[r])
    }

    public static func encode(_ value: BValue) -> Data {
        var out = [UInt8]()
        write(value, into: &out)
        return Data(out)
    }

    private static func write(_ value: BValue, into out: inout [UInt8]) {
        switch value {
        case .int(let v):
            out.append(UInt8(ascii: "i")); out += Array(String(v).utf8); out.append(UInt8(ascii: "e"))
        case .bytes(let d):
            out += Array(String(d.count).utf8); out.append(UInt8(ascii: ":")); out += d
        case .list(let l):
            out.append(UInt8(ascii: "l")); for v in l { write(v, into: &out) }; out.append(UInt8(ascii: "e"))
        case .dict(let d):
            out.append(UInt8(ascii: "d"))
            // 键按原始字节升序
            for k in d.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                write(.bytes(k), into: &out)
                write(d[k]!, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        var capture: [UInt8]?
        var captured: Range<Int>?

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func value(depth: Int) throws -> BValue {
            guard depth < 64 else { throw BencodeError(message: "B 编码嵌套过深") }
            guard i < bytes.count else { throw BencodeError(message: "B 编码数据不完整") }
            switch bytes[i] {
            case UInt8(ascii: "i"):
                i += 1
                let end = try find(UInt8(ascii: "e"))
                guard let s = String(bytes: bytes[i..<end], encoding: .ascii), let v = Int64(s) else {
                    throw BencodeError(message: "B 编码整数无效")
                }
                i = end + 1
                return .int(v)
            case UInt8(ascii: "l"):
                i += 1
                var list: [BValue] = []
                while true {
                    guard i < bytes.count else { throw BencodeError(message: "B 编码列表未结束") }
                    if bytes[i] == UInt8(ascii: "e") { i += 1; break }
                    list.append(try value(depth: depth + 1))
                }
                return .list(list)
            case UInt8(ascii: "d"):
                i += 1
                var dict: [Data: BValue] = [:]
                while true {
                    guard i < bytes.count else { throw BencodeError(message: "B 编码字典未结束") }
                    if bytes[i] == UInt8(ascii: "e") { i += 1; break }
                    let key = try string()
                    let start = i
                    let v = try value(depth: depth + 1)
                    if depth == 0, let capture, captured == nil, key.elementsEqual(capture) { captured = start..<i }
                    dict[Data(key)] = v
                }
                return .dict(dict)
            default:
                return .bytes(Data(try string()))
            }
        }

        mutating func string() throws -> ArraySlice<UInt8> {
            let colon = try find(UInt8(ascii: ":"))
            guard colon > i, colon - i <= 12, let s = String(bytes: bytes[i..<colon], encoding: .ascii), let n = Int(s), n >= 0 else {
                throw BencodeError(message: "B 编码字符串长度无效")
            }
            let start = colon + 1
            guard start + n <= bytes.count else { throw BencodeError(message: "B 编码字符串不完整") }
            i = start + n
            return bytes[start..<start + n]
        }

        func find(_ byte: UInt8) throws -> Int {
            var j = i
            while j < bytes.count {
                if bytes[j] == byte { return j }
                j += 1
            }
            throw BencodeError(message: "B 编码数据不完整")
        }
    }
}
