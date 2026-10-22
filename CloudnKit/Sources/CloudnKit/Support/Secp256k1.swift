// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// secp256k1 ECDSA：阿里云盘个人盘接口要求的设备会话签名（X-Signature）用它。CryptoKit 只有 NIST 曲线，这里用 BigUInt 自己实现：
// 雅可比坐标做点运算（只在最后求一次逆），域元素按 p = 2^256 − 2^32 − 977 的特殊形式快速约简。只用于签名一条固定消息，不追求常数时间。
import Foundation

enum Secp256k1 {
    static let p = BigUInt(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")!
    static let n = BigUInt(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")!
    static let gx = BigUInt(hex: "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")!
    static let gy = BigUInt(hex: "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8")!
    /// 2^256 mod p
    private static let fold = BigUInt(0x1_0000_03D1)
    private static let halfN = n.shiftedRight1()

    // MARK: 域运算（mod p）

    /// 2^256 以上的部分乘以 (2^32 + 977) 折回低位，最多折两三次
    static func reduce(_ t: BigUInt) -> BigUInt {
        var t = t
        while t.limbs.count > 8 {
            let lo = BigUInt(limbs: Array(t.limbs[0..<8]))
            let hi = BigUInt(limbs: Array(t.limbs[8...]))
            t = lo + hi * fold
        }
        while !(t < p) { t = t - p }
        return t
    }

    static func mul(_ a: BigUInt, _ b: BigUInt) -> BigUInt { reduce(a * b) }
    static func add(_ a: BigUInt, _ b: BigUInt) -> BigUInt { reduce(a + b) }
    static func sub(_ a: BigUInt, _ b: BigUInt) -> BigUInt { b < a || b == a ? a - b : a + p - b }

    // MARK: 点运算（雅可比坐标，z == 0 为无穷远点）

    struct Point: Equatable {
        var x: BigUInt
        var y: BigUInt
        var z: BigUInt
        static let infinity = Point(x: BigUInt(1), y: BigUInt(1), z: BigUInt(0))
        var isInfinity: Bool { z.isZero }
    }

    static let g = Point(x: gx, y: gy, z: BigUInt(1))

    static func double(_ a: Point) -> Point {
        if a.isInfinity || a.y.isZero { return .infinity }
        let y2 = mul(a.y, a.y)
        let s = mul(BigUInt(4), mul(a.x, y2))
        let m = mul(BigUInt(3), mul(a.x, a.x))
        let x3 = sub(mul(m, m), add(s, s))
        let y3 = sub(mul(m, sub(s, x3)), mul(BigUInt(8), mul(y2, y2)))
        let z3 = mul(add(a.y, a.y), a.z)
        return Point(x: x3, y: y3, z: z3)
    }

    static func add(_ a: Point, _ b: Point) -> Point {
        if a.isInfinity { return b }
        if b.isInfinity { return a }
        let z1z1 = mul(a.z, a.z), z2z2 = mul(b.z, b.z)
        let u1 = mul(a.x, z2z2), u2 = mul(b.x, z1z1)
        let s1 = mul(a.y, mul(b.z, z2z2)), s2 = mul(b.y, mul(a.z, z1z1))
        if u1 == u2 { return s1 == s2 ? double(a) : .infinity }
        let h = sub(u2, u1), r = sub(s2, s1)
        let hh = mul(h, h), hhh = mul(h, hh)
        let v = mul(u1, hh)
        let x3 = sub(sub(mul(r, r), hhh), add(v, v))
        let y3 = sub(mul(r, sub(v, x3)), mul(s1, hhh))
        let z3 = mul(h, mul(a.z, b.z))
        return Point(x: x3, y: y3, z: z3)
    }

    static func multiply(_ k: BigUInt, _ point: Point = g) -> Point {
        var result = Point.infinity
        for i in stride(from: k.bitWidth - 1, through: 0, by: -1) {
            result = double(result)
            if k.bit(i) { result = add(result, point) }
        }
        return result
    }

    static func affine(_ a: Point) -> (x: BigUInt, y: BigUInt)? {
        guard !a.isInfinity else { return nil }
        let zi = a.z.power(p - BigUInt(2), modulus: p)
        let zi2 = mul(zi, zi)
        return (mul(a.x, zi2), mul(a.y, mul(zi2, zi)))
    }

    // MARK: 密钥与签名

    /// 未压缩公钥去掉 04 前缀：X(32) ‖ Y(32)
    static func publicKey(_ priv: [UInt8]) -> [UInt8]? {
        let d = BigUInt(bytes: priv) % n
        guard !d.isZero, let q = affine(multiply(d)) else { return nil }
        return q.x.bytes(length: 32) + q.y.bytes(length: 32)
    }

    /// 对 32 字节摘要签名，返回 r(32) ‖ s(32) ‖ v(1)：s 取低位（s ≤ n/2），v 为恢复 id（0 / 1）
    static func sign(hash: [UInt8], priv: [UInt8], nonce: (() -> [UInt8])? = nil) -> [UInt8]? {
        let d = BigUInt(bytes: priv) % n
        guard !d.isZero else { return nil }
        let z = BigUInt(bytes: hash) % n
        for _ in 0..<16 {
            let k = BigUInt(bytes: nonce?() ?? randomScalar()) % n
            guard !k.isZero, let r1 = affine(multiply(k)) else { continue }
            let r = r1.x % n
            guard !r.isZero else { continue }
            let kInv = k.power(n - BigUInt(2), modulus: n)
            var s = (kInv * ((z + r * d) % n)) % n
            guard !s.isZero else { continue }
            var v: UInt8 = r1.y.bit(0) ? 1 : 0
            if halfN < s {
                s = n - s
                v ^= 1
            }
            return r.bytes(length: 32) + s.bytes(length: 32) + [v]
        }
        return nil
    }

    /// 校验签名（测试用）：公钥为 X ‖ Y
    static func verify(hash: [UInt8], signature: [UInt8], publicKey: [UInt8]) -> Bool {
        guard signature.count >= 64, publicKey.count == 64 else { return false }
        let r = BigUInt(bytes: Array(signature[0..<32])), s = BigUInt(bytes: Array(signature[32..<64]))
        guard !r.isZero, !s.isZero, r < n, s < n else { return false }
        let q = Point(x: BigUInt(bytes: Array(publicKey[0..<32])), y: BigUInt(bytes: Array(publicKey[32..<64])), z: BigUInt(1))
        let z = BigUInt(bytes: hash) % n
        let w = s.power(n - BigUInt(2), modulus: n)
        let u1 = (z * w) % n, u2 = (r * w) % n
        guard let x = affine(add(multiply(u1), multiply(u2, q))) else { return false }
        return x.x % n == r
    }

    private static func randomScalar() -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
}

extension BigUInt {
    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        let count = Swift.max(a.limbs.count, b.limbs.count)
        var r = [UInt32](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let t = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            r[i] = UInt32(truncatingIfNeeded: t)
            carry = t >> 32
        }
        r[count] = UInt32(carry)
        return BigUInt(limbs: r)
    }

    /// a − b（要求 a ≥ b）
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(!(a < b), "BigUInt 减法结果为负")
        var r = a.limbs
        var borrow: Int64 = 0
        for i in 0..<r.count {
            var t = Int64(r[i]) - Int64(i < b.limbs.count ? b.limbs[i] : 0) - borrow
            if t < 0 { t += 1 << 32; borrow = 1 } else { borrow = 0 }
            r[i] = UInt32(t)
        }
        return BigUInt(limbs: r)
    }

    func shiftedRight1() -> BigUInt {
        var r = limbs
        for i in 0..<r.count {
            r[i] = r[i] >> 1 | (i + 1 < r.count ? r[i + 1] << 31 : 0)
        }
        return BigUInt(limbs: r)
    }
}
