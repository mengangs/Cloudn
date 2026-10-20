// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 可分段喂数据的摘要（大文件上传前要边读边算，不能整个读进内存）。
/// Apple 平台走 CryptoKit；Linux（测试）用纯 Swift 实现，结果一致。
public protocol StreamingHasher {
    init()
    mutating func update(_ data: Data)
    mutating func finalize() -> [UInt8]
    static var blockSize: Int { get }
}

public extension StreamingHasher {
    static func digest(_ data: Data) -> [UInt8] {
        var h = Self()
        h.update(data)
        return h.finalize()
    }

    static func hex(_ data: Data) -> String { Crypto.hex(digest(data)) }
}

public struct MD5Hasher: StreamingHasher {
    public static let blockSize = 64
    #if canImport(CryptoKit)
    private var h = Insecure.MD5()
    public init() {}
    public mutating func update(_ data: Data) { h.update(data: data) }
    public mutating func finalize() -> [UInt8] { Array(h.finalize()) }
    #else
    private var core = BlockHashCore(kind: .md5)
    public init() {}
    public mutating func update(_ data: Data) { core.update(data) }
    public mutating func finalize() -> [UInt8] { core.finalize() }
    #endif
}

public struct SHA1Hasher: StreamingHasher {
    public static let blockSize = 64
    #if canImport(CryptoKit)
    private var h = Insecure.SHA1()
    public init() {}
    public mutating func update(_ data: Data) { h.update(data: data) }
    public mutating func finalize() -> [UInt8] { Array(h.finalize()) }
    #else
    private var core = BlockHashCore(kind: .sha1)
    public init() {}
    public mutating func update(_ data: Data) { core.update(data) }
    public mutating func finalize() -> [UInt8] { core.finalize() }
    #endif
}

public struct SHA256Hasher: StreamingHasher {
    public static let blockSize = 64
    #if canImport(CryptoKit)
    private var h = SHA256()
    public init() {}
    public mutating func update(_ data: Data) { h.update(data: data) }
    public mutating func finalize() -> [UInt8] { Array(h.finalize()) }
    #else
    private var core = BlockHashCore(kind: .sha256)
    public init() {}
    public mutating func update(_ data: Data) { core.update(data) }
    public mutating func finalize() -> [UInt8] { core.finalize() }
    #endif
}

public extension Crypto {
    static func sha256(_ data: Data) -> [UInt8] { SHA256Hasher.digest(data) }

    /// HMAC（RFC 2104），H 为 64 字节分组的摘要
    static func hmac<H: StreamingHasher>(_ type: H.Type, key: [UInt8], message: Data) -> [UInt8] {
        var k = key.count > H.blockSize ? H.digest(Data(key)) : key
        k += [UInt8](repeating: 0, count: H.blockSize - k.count)
        var inner = H()
        inner.update(Data(k.map { $0 ^ 0x36 }))
        inner.update(message)
        var outer = H()
        outer.update(Data(k.map { $0 ^ 0x5c }))
        outer.update(Data(inner.finalize()))
        return outer.finalize()
    }

    static func hmacSHA1(key: String, message: String) -> [UInt8] { hmac(SHA1Hasher.self, key: Array(key.utf8), message: Data(message.utf8)) }
    static func hmacSHA256(key: [UInt8], message: String) -> [UInt8] { hmac(SHA256Hasher.self, key: key, message: Data(message.utf8)) }
}

/// 纯 Swift 的分组摘要（MD5 / SHA-1 / SHA-256），每攒满 64 字节处理一组
struct BlockHashCore {
    enum Kind { case md5, sha1, sha256 }
    let kind: Kind
    private var state: [UInt32]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .md5: state = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        case .sha1: state = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        case .sha256: state = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        }
    }

    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        buffer += data
        var offset = 0
        while buffer.count - offset >= 64 {
            process(buffer, offset)
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    mutating func finalize() -> [UInt8] {
        let bits = length &* 8
        var tail = buffer + [0x80]
        while tail.count % 64 != 56 { tail.append(0) }
        let lenBytes = (0..<8).map { UInt8(truncatingIfNeeded: bits >> (8 * UInt64($0))) }
        tail += kind == .md5 ? lenBytes : Array(lenBytes.reversed())
        for off in stride(from: 0, to: tail.count, by: 64) { process(tail, off) }
        var out = [UInt8]()
        for v in state {
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) }
            out += kind == .md5 ? bytes : Array(bytes.reversed())
        }
        return out
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private static let md5Shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                              5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                              4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                              6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let md5Table: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
    private static let sha256K: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    private mutating func process(_ b: [UInt8], _ o: Int) {
        switch kind {
        case .md5:
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = o + i * 4
                m[i] = UInt32(b[j]) | UInt32(b[j + 1]) << 8 | UInt32(b[j + 2]) << 16 | UInt32(b[j + 3]) << 24
            }
            var a = state[0], bb = state[1], c = state[2], d = state[3]
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (bb & c) | (~bb & d); g = i
                case 16..<32: f = (d & bb) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = bb ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (bb | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ Self.md5Table[i] &+ m[g]
                a = d; d = c; c = bb
                bb = bb &+ Self.rotl(f, Self.md5Shifts[i])
            }
            state[0] &+= a; state[1] &+= bb; state[2] &+= c; state[3] &+= d
        case .sha1:
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let j = o + i * 4
                w[i] = UInt32(b[j]) << 24 | UInt32(b[j + 1]) << 16 | UInt32(b[j + 2]) << 8 | UInt32(b[j + 3])
            }
            for i in 16..<80 { w[i] = Self.rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = state[0], bb = state[1], c = state[2], d = state[3], e = state[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (bb & c) | (~bb & d); k = 0x5A827999
                case 20..<40: f = bb ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (bb & c) | (bb & d) | (c & d); k = 0x8F1BBCDC
                default: f = bb ^ c ^ d; k = 0xCA62C1D6
                }
                let t = Self.rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = Self.rotl(bb, 30); bb = a; a = t
            }
            state[0] &+= a; state[1] &+= bb; state[2] &+= c; state[3] &+= d; state[4] &+= e
        case .sha256:
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = o + i * 4
                w[i] = UInt32(b[j]) << 24 | UInt32(b[j + 1]) << 16 | UInt32(b[j + 2]) << 8 | UInt32(b[j + 3])
            }
            for i in 16..<64 {
                let s0 = Self.rotr(w[i - 15], 7) ^ Self.rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = Self.rotr(w[i - 2], 17) ^ Self.rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = state[0], bb = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let s1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ ch &+ Self.sha256K[i] &+ w[i]
                let s0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
                let maj = (a & bb) ^ (a & c) ^ (bb & c)
                let t2 = s0 &+ maj
                h = g; g = f; f = e; e = d &+ t1; d = c; c = bb; bb = a; a = t1 &+ t2
            }
            state[0] &+= a; state[1] &+= bb; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
    }
}

/// 逐块读文件（上传前算摘要、按分片读数据），不把整个文件放进内存
public enum FileChunks {
    /// 从头到尾按 chunkSize 读一遍；回调参数为（偏移, 数据）。progress 为已读字节数
    public static func scan(_ url: URL, chunkSize: Int = 4 << 20, progress: ((Int64) -> Void)? = nil,
                            _ body: (Int64, Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            try body(offset, data)
            offset += Int64(data.count)
            progress?(offset)
        }
    }

    public static func read(_ url: URL, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    public static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
