// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 各网盘签名 / 加密参数用到的摘要与对称加密。纯 Swift 实现：Linux 上没有 CommonCrypto，
// 测试与 iOS 走同一份代码；处理的都是几十字节的参数，性能无关紧要。
import Foundation

public enum Crypto {
    // MARK: 十六进制 / Base64

    public static func hex(_ data: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }

    /// 宽松 Base64 解码：兼容 URL-safe 字母表、缺失的填充与夹杂的空白
    public static func base64Decode(_ text: String) -> Data? {
        var s = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    // MARK: 摘要

    public static func md5Hex(_ s: String) -> String { hex(md5(Array(s.utf8))) }
    public static func sha1Hex(_ s: String) -> String { hex(sha1(Array(s.utf8))) }

    public static func md5(_ message: [UInt8]) -> [UInt8] {
        let shifts: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let table: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476

        var msg = message
        let bitLength = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = chunk + i * 4
                m[i] = UInt32(msg[j]) | UInt32(msg[j + 1]) << 8 | UInt32(msg[j + 2]) << 16 | UInt32(msg[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ table[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ rotl(f, shifts[i])
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        var out = [UInt8]()
        for v in [a0, b0, c0, d0] {
            for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) }
        }
        return out
    }

    public static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var msg = message
        let bitLength = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(msg[j]) << 24 | UInt32(msg[j + 1]) << 16 | UInt32(msg[j + 2]) << 8 | UInt32(msg[j + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = t
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        var out = [UInt8]()
        for v in h {
            for i in (0..<4).reversed() { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) }
        }
        return out
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    // MARK: CRC-32（IEEE 802.3，与 zlib.crc32 一致）

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    /// CRC-32 的小写十六进制（不补前导 0，与 Java Long.toHexString / Python format(x, 'x') 一致）
    public static func crc32Hex(_ s: String) -> String { String(crc32(Array(s.utf8)), radix: 16) }
}

// MARK: - AES

/// AES（128/192/256）ECB / CBC + PKCS#7 填充
public struct AES: Sendable {
    public enum Mode: Sendable { case ecb, cbc(iv: [UInt8]) }

    private let roundKeys: [UInt32]
    private let rounds: Int

    public init?(key: [UInt8]) {
        guard [16, 24, 32].contains(key.count) else { return nil }
        let nk = key.count / 4
        rounds = nk + 6
        var w = [UInt32](repeating: 0, count: 4 * (rounds + 1))
        for i in 0..<nk {
            w[i] = UInt32(key[4 * i]) << 24 | UInt32(key[4 * i + 1]) << 16 | UInt32(key[4 * i + 2]) << 8 | UInt32(key[4 * i + 3])
        }
        var rcon: UInt32 = 0x01
        for i in nk..<w.count {
            var t = w[i - 1]
            if i % nk == 0 {
                t = AES.subWord((t << 8) | (t >> 24)) ^ (rcon << 24)
                rcon = UInt32(AES.xtime(UInt8(rcon)))
            } else if nk > 6 && i % nk == 4 {
                t = AES.subWord(t)
            }
            w[i] = w[i - nk] ^ t
        }
        roundKeys = w
    }

    public func encrypt(_ plain: [UInt8], mode: Mode = .ecb) -> [UInt8] {
        let pad = 16 - plain.count % 16
        let data = plain + [UInt8](repeating: UInt8(pad), count: pad)
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var prev: [UInt8]
        if case .cbc(let iv) = mode { prev = iv } else { prev = [] }
        for i in stride(from: 0, to: data.count, by: 16) {
            var block = Array(data[i..<i + 16])
            if case .cbc = mode { for j in 0..<16 { block[j] ^= prev[j] } }
            let enc = encryptBlock(block)
            out += enc
            prev = enc
        }
        return out
    }

    /// 解密并去除 PKCS#7 填充；密文长度或填充不合法返回 nil
    public func decrypt(_ cipher: [UInt8], mode: Mode = .ecb) -> [UInt8]? {
        guard !cipher.isEmpty, cipher.count % 16 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(cipher.count)
        var prev: [UInt8]
        if case .cbc(let iv) = mode { prev = iv } else { prev = [] }
        for i in stride(from: 0, to: cipher.count, by: 16) {
            let block = Array(cipher[i..<i + 16])
            var dec = decryptBlock(block)
            if case .cbc = mode { for j in 0..<16 { dec[j] ^= prev[j] } }
            out += dec
            prev = block
        }
        guard let pad = out.last, pad >= 1, pad <= 16, out.suffix(Int(pad)).allSatisfy({ $0 == pad }) else { return nil }
        return Array(out.dropLast(Int(pad)))
    }

    // MARK: 分组运算（state 按列主序：state[c*4 + r]）

    private func addRoundKey(_ s: inout [UInt8], _ round: Int) {
        for c in 0..<4 {
            let k = roundKeys[round * 4 + c]
            s[c * 4] ^= UInt8(truncatingIfNeeded: k >> 24)
            s[c * 4 + 1] ^= UInt8(truncatingIfNeeded: k >> 16)
            s[c * 4 + 2] ^= UInt8(truncatingIfNeeded: k >> 8)
            s[c * 4 + 3] ^= UInt8(truncatingIfNeeded: k)
        }
    }

    func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        var s = input
        addRoundKey(&s, 0)
        for round in 1...rounds {
            for i in 0..<16 { s[i] = AES.sbox[Int(s[i])] }
            // ShiftRows：第 r 行左移 r
            var t = s
            for c in 0..<4 { for r in 0..<4 { t[c * 4 + r] = s[((c + r) % 4) * 4 + r] } }
            s = t
            if round != rounds {
                for c in 0..<4 {
                    let a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3]
                    s[c * 4] = AES.mul(a0, 2) ^ AES.mul(a1, 3) ^ a2 ^ a3
                    s[c * 4 + 1] = a0 ^ AES.mul(a1, 2) ^ AES.mul(a2, 3) ^ a3
                    s[c * 4 + 2] = a0 ^ a1 ^ AES.mul(a2, 2) ^ AES.mul(a3, 3)
                    s[c * 4 + 3] = AES.mul(a0, 3) ^ a1 ^ a2 ^ AES.mul(a3, 2)
                }
            }
            addRoundKey(&s, round)
        }
        return s
    }

    func decryptBlock(_ input: [UInt8]) -> [UInt8] {
        var s = input
        addRoundKey(&s, rounds)
        for round in stride(from: rounds - 1, through: 0, by: -1) {
            // InvShiftRows：第 r 行右移 r
            var t = s
            for c in 0..<4 { for r in 0..<4 { t[((c + r) % 4) * 4 + r] = s[c * 4 + r] } }
            s = t
            for i in 0..<16 { s[i] = AES.invSbox[Int(s[i])] }
            addRoundKey(&s, round)
            if round != 0 {
                for c in 0..<4 {
                    let a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3]
                    s[c * 4] = AES.mul(a0, 14) ^ AES.mul(a1, 11) ^ AES.mul(a2, 13) ^ AES.mul(a3, 9)
                    s[c * 4 + 1] = AES.mul(a0, 9) ^ AES.mul(a1, 14) ^ AES.mul(a2, 11) ^ AES.mul(a3, 13)
                    s[c * 4 + 2] = AES.mul(a0, 13) ^ AES.mul(a1, 9) ^ AES.mul(a2, 14) ^ AES.mul(a3, 11)
                    s[c * 4 + 3] = AES.mul(a0, 11) ^ AES.mul(a1, 13) ^ AES.mul(a2, 9) ^ AES.mul(a3, 14)
                }
            }
        }
        return s
    }

    private static func xtime(_ x: UInt8) -> UInt8 { (x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0) }

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, p: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { p ^= a }
            a = xtime(a)
            b >>= 1
        }
        return p
    }

    private static func subWord(_ w: UInt32) -> UInt32 {
        UInt32(sbox[Int(w >> 24)]) << 24 | UInt32(sbox[Int((w >> 16) & 0xff)]) << 16 |
            UInt32(sbox[Int((w >> 8) & 0xff)]) << 8 | UInt32(sbox[Int(w & 0xff)])
    }

    /// S 盒按定义生成：GF(2^8) 乘法逆元 + 仿射变换
    static let sbox: [UInt8] = (0..<256).map { i -> UInt8 in
        var inv: UInt8 = 0
        if i != 0 {
            for c in 1...255 where mul(UInt8(i), UInt8(c)) == 1 { inv = UInt8(c); break }
        }
        var s = inv
        var x = inv
        for _ in 0..<4 {
            x = (x << 1) | (x >> 7)
            s ^= x
        }
        return s ^ 0x63
    }

    static let invSbox: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 256)
        for (i, v) in sbox.enumerated() { t[Int(v)] = UInt8(i) }
        return t
    }()
}

// MARK: - 大整数（仅供 RSA 公钥 modPow）

/// 最小化的无符号大整数：32 位小端分段。只实现公钥运算所需的乘法、取模与模幂，
/// 取模用逐位移减（1024 位模数每块十几次乘方，足够快）。
struct BigUInt: Equatable, Sendable {
    /// 小端 32 位分段，末尾不保留 0
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        var l = limbs
        while let last = l.last, last == 0 { l.removeLast() }
        self.limbs = l
    }

    init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    /// 大端字节
    init(bytes: [UInt8]) {
        var l = [UInt32]()
        var i = bytes.count
        while i > 0 {
            let start = max(0, i - 4)
            var v: UInt32 = 0
            for b in bytes[start..<i] { v = v << 8 | UInt32(b) }
            l.append(v)
            i = start
        }
        self.init(limbs: l)
    }

    init?(hex: String) {
        guard let b = Crypto.bytes(hex: hex.count % 2 == 0 ? hex : "0" + hex) else { return nil }
        self.init(bytes: b)
    }

    var isZero: Bool { limbs.isEmpty }
    var bitWidth: Int { limbs.isEmpty ? 0 : (limbs.count - 1) * 32 + (32 - limbs.last!.leadingZeroBitCount) }

    func bit(_ i: Int) -> Bool {
        let idx = i / 32
        return idx < limbs.count && (limbs[idx] >> UInt32(i % 32)) & 1 == 1
    }

    /// 固定长度大端字节（左补 0；超长截取低位）
    func bytes(length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            let limb = i / 4
            guard limb < limbs.count else { break }
            out[length - 1 - i] = UInt8(truncatingIfNeeded: limbs[limb] >> UInt32((i % 4) * 8))
        }
        return out
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        guard !a.isZero, !b.isZero else { return BigUInt(limbs: []) }
        var r = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let t = ai * UInt64(b.limbs[j]) + UInt64(r[i + j]) + carry
                r[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            var k = i + b.limbs.count
            while carry != 0 {
                let t = UInt64(r[k]) + carry
                r[k] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
                k += 1
            }
        }
        return BigUInt(limbs: r)
    }

    /// a mod m：从最高位起逐位左移并按需减去模数
    static func % (a: BigUInt, m: BigUInt) -> BigUInt {
        precondition(!m.isZero)
        if a < m { return a }
        var r = [UInt32](repeating: 0, count: m.limbs.count + 1)
        let mod = m.limbs + [0]
        for i in stride(from: a.bitWidth - 1, through: 0, by: -1) {
            // r = r << 1 | bit
            var carry: UInt32 = a.bit(i) ? 1 : 0
            for j in 0..<r.count {
                let next = r[j] >> 31
                r[j] = r[j] << 1 | carry
                carry = next
            }
            if !lessThan(r, mod) { subtract(&r, mod) }
        }
        return BigUInt(limbs: r)
    }

    private static func lessThan(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: Int64 = 0
        for i in 0..<a.count {
            var t = Int64(a[i]) - Int64(b[i]) - borrow
            if t < 0 { t += 1 << 32; borrow = 1 } else { borrow = 0 }
            a[i] = UInt32(t)
        }
    }

    func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(1) % modulus
        var base = self % modulus
        for i in 0..<exponent.bitWidth {
            if exponent.bit(i) { result = (result * base) % modulus }
            base = (base * base) % modulus
        }
        return result
    }
}
