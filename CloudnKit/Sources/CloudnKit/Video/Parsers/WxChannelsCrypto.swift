// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 Bob Jenkins 的 ISAAC64（公有领域）与公开的视频号加密方案（WechatSphDecrypt：首 128KB 与 ISAAC64 密钥流异或）。
import Foundation

/// 微信视频号加密视频的解密。
///
/// 客户端内（带 `decodeKey` 的）视频文件只加密开头 `limit` 字节（固定 131072 = 128KB）：
/// 以 decodeKey（十进制 UInt64）作 ISAAC64 种子 seed[0]、其余为 0 做 randinit，
/// 按标准 ISAAC64 从 255 号往 0 号倒序取数，每个 UInt64 按大端展开成 8 字节密钥流，与文件逐字节异或。
/// 异或是对称的：同一函数既加密也解密。
///
/// 注意：经腾讯元宝 + finder-preview 拿到的分享直链（WxChannelsParser 的来源）是网页可直接播放的明文流，
/// 不需要解密；这里只为可能出现的 decodeKey 备用。
public enum WxChannelsCrypto {
    /// 视频号加密区长度
    public static let defaultLimit = 131072

    /// 解析 decodeKey（十进制字符串，可能超出 Int64 范围）
    public static func parseKey(_ text: String) -> UInt64? {
        UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 密钥流前 count 字节
    public static func keystream(key: UInt64, count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var rng = WxChannelsISAAC64(seed: key)
        var out = [UInt8]()
        out.reserveCapacity(count + 8)
        while out.count < count {
            let v = rng.next()
            var shift: UInt64 = 56
            for _ in 0..<8 {
                out.append(UInt8(truncatingIfNeeded: v >> shift))
                if shift >= 8 { shift -= 8 }
            }
        }
        if out.count > count { out.removeLast(out.count - count) }
        return out
    }

    /// 原地解密：data 是文件里从 offset 开始的一段（整文件时 offset = 0），只处理文件位置 < limit 的字节
    public static func decrypt(_ data: inout Data, key: UInt64, limit: Int = defaultLimit, offset: Int = 0) {
        guard !data.isEmpty, limit > 0, offset >= 0, offset < limit else { return }
        let end = min(limit, offset + data.count)
        let stream = keystream(key: key, count: end)
        let n = end - offset
        data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            for i in 0..<n {
                buf[i] = buf[i] ^ stream[offset + i]
            }
        }
    }

    /// decodeKey 为字符串时的便捷版本；key 不是合法的十进制 UInt64 时不动数据并返回 false
    @discardableResult
    public static func decrypt(_ data: inout Data, key: String, limit: Int = defaultLimit, offset: Int = 0) -> Bool {
        guard let k = parseKey(key) else { return false }
        decrypt(&data, key: k, limit: limit, offset: offset)
        return true
    }
}

/// 标准 ISAAC64（RANDSIZL = 8），只把 randrsl[0] 设为种子
struct WxChannelsISAAC64 {
    private var rsl = [UInt64](repeating: 0, count: 256)
    private var mm = [UInt64](repeating: 0, count: 256)
    private var aa: UInt64 = 0
    private var bb: UInt64 = 0
    private var cc: UInt64 = 0
    private var cnt = 255

    init(seed: UInt64) {
        rsl[0] = seed
        var v = [UInt64](repeating: 0x9e37_79b9_7f4a_7c13, count: 8)
        for _ in 0..<4 { Self.mix(&v) }
        for pass in 0..<2 {
            for i in stride(from: 0, to: 256, by: 8) {
                for j in 0..<8 {
                    let src: UInt64 = pass == 0 ? rsl[i + j] : mm[i + j]
                    v[j] = v[j] &+ src
                }
                Self.mix(&v)
                for j in 0..<8 { mm[i + j] = v[j] }
            }
        }
        isaac()
        cnt = 255
    }

    /// 倒序消费 rsl[255] … rsl[0]，用完再生成一轮
    mutating func next() -> UInt64 {
        let r = rsl[cnt]
        if cnt == 0 {
            isaac()
            cnt = 255
        } else {
            cnt -= 1
        }
        return r
    }

    private mutating func isaac() {
        cc = cc &+ 1
        bb = bb &+ cc
        for i in 0..<256 {
            var a = aa
            switch i & 3 {
            case 0: a = ~(a ^ (a << 21))
            case 1: a = a ^ (a >> 5)
            case 2: a = a ^ (a << 12)
            default: a = a ^ (a >> 33)
            }
            a = a &+ mm[(i + 128) & 255]
            aa = a
            let x = mm[i]
            let y = mm[Int((x >> 3) & 255)] &+ a &+ bb
            mm[i] = y
            bb = mm[Int((y >> 11) & 255)] &+ x
            rsl[i] = bb
        }
    }

    private static func mix(_ v: inout [UInt64]) {
        var a = v[0], b = v[1], c = v[2], d = v[3]
        var e = v[4], f = v[5], g = v[6], h = v[7]
        a = a &- e; f ^= h >> 9; h = h &+ a
        b = b &- f; g ^= a << 9; a = a &+ b
        c = c &- g; h ^= b >> 23; b = b &+ c
        d = d &- h; a ^= c << 15; c = c &+ d
        e = e &- a; b ^= d >> 14; d = d &+ e
        f = f &- b; c ^= e << 20; e = e &+ f
        g = g &- c; d ^= f >> 17; f = f &+ g
        h = h &- d; e ^= g << 14; g = g &+ h
        v = [a, b, c, d, e, f, g, h]
    }
}
