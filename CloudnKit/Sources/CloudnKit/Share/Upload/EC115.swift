// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 115 上传初始化接口（uplb.115.com/4.0/initupload.php）的 ec115 加密层。
/// 移植自 SheltonZhu/115driver 的 pkg/crypto/ec115/cipher.go（MIT 许可，可并入 AGPL）。
///
/// 原实现每次随机生成 P-224 密钥对，与服务端固定公钥做 ECDH，共享密钥 S（28 字节）的
/// 前 16 字节作 AES key、后 16 字节作 IV。服务端接受任意客户端公钥，所以这里离线生成一对
/// 固定密钥（scratchpad/p224.py），只内置客户端公钥与算好的 key / IV，运行时不需要任何椭圆曲线运算。
/// 这一层只是混淆：请求本身走 HTTPS。
enum EC115 {
    /// 客户端公钥：[0x1D, Y 奇偶 0x02/0x03] + X（28 字节大端）
    static let pubKey: [UInt8] = [
        0x1d, 0x02, 0xc9, 0x95, 0x09, 0x92, 0xc1, 0x1a, 0x00, 0x58, 0xdf, 0x0d, 0x50, 0x18, 0xcd,
        0xf4, 0x98, 0x44, 0xbf, 0x58, 0x36, 0x0c, 0x12, 0x61, 0x6f, 0xd7, 0x9b, 0x9a, 0x94, 0x14
    ]
    /// 共享密钥 S[0..<16]
    static let aesKey: [UInt8] = [
        0x78, 0xa2, 0x1b, 0xbc, 0xdb, 0xd7, 0x00, 0x03, 0x42, 0x90, 0x7f, 0x57, 0x7d, 0xb5, 0xae, 0x4b
    ]
    /// 共享密钥 S[12..<28]（与 key 有 4 字节重叠，原实现就是这样取的）
    static let aesIV: [UInt8] = [
        0x7d, 0xb5, 0xae, 0x4b, 0xf6, 0x04, 0x01, 0xae, 0xba, 0x29, 0x71, 0x1c, 0xeb, 0x39, 0x26, 0x97
    ]
    static let crcSalt = "^j>WD3Kr?J2gLFjD4W2y@"
    /// 解压上限：原实现固定 0x2000，这里放宽，只防异常数据把内存撑爆
    static let maxPlainSize = 1 << 22

    /// 加密请求体：AES-128-CBC + PKCS#7（Go 里「先异或再 ECB」的循环就是 CBC）
    static func encrypt(_ plain: [UInt8]) -> [UInt8] {
        guard let aes = AES(key: aesKey) else { return [] }
        return aes.encrypt(plain, mode: .cbc(iv: aesIV))
    }

    /// 解密响应：截到 16 的整数倍 → CBC 逐块解密（不去填充）→ 前 2 字节小端为压缩长度 → LZ4 原始块解压
    static func decrypt(_ cipher: [UInt8]) -> [UInt8]? {
        let usable = cipher.count - cipher.count % 16
        guard usable >= 16, let aes = AES(key: aesKey) else { return nil }
        var plain = [UInt8]()
        plain.reserveCapacity(usable)
        var prev = aesIV
        var i = 0
        while i < usable {
            let block = Array(cipher[i..<(i + 16)])
            var dec = aes.decryptBlock(block)
            for j in 0..<16 { dec[j] ^= prev[j] }
            plain.append(contentsOf: dec)
            prev = block
            i += 16
        }
        let low = Int(plain[0])
        let high = Int(plain[1]) << 8
        let length = low | high
        guard length <= plain.count - 2 else { return nil }
        return LZ4Block.decompress(Array(plain[2..<(2 + length)]), maxOutput: maxPlainSize)
    }

    /// k_ec 参数：48 字节 → 标准 Base64。t 为毫秒时间戳（截成 UInt32）
    static func encodeToken(timestamp: Int64) -> String {
        let r1 = UInt8.random(in: 0...255)
        let r2 = UInt8.random(in: 0...255)
        return Data(tokenBytes(timestamp: timestamp, r1: r1, r2: r2)).base64EncodedString()
    }

    /// 公钥前 15 字节 ^ r1 ‖ r1, 0x73^r1 ‖ r1×3 ‖ 时间戳（大端倒序）^ r1 ‖ 公钥后 15 字节 ^ r2 ‖ r2, 0x01^r2 ‖ r2×3 ‖ CRC32（小端）
    static func tokenBytes(timestamp: Int64, r1: UInt8, r2: UInt8) -> [UInt8] {
        let ts = UInt32(truncatingIfNeeded: timestamp)
        // 大端：time[0] 为最高字节
        let time: [UInt8] = [UInt8(truncatingIfNeeded: ts >> 24), UInt8(truncatingIfNeeded: ts >> 16),
                             UInt8(truncatingIfNeeded: ts >> 8), UInt8(truncatingIfNeeded: ts)]
        var tmp = [UInt8]()
        tmp.reserveCapacity(48)
        for i in 0..<15 { tmp.append(pubKey[i] ^ r1) }
        tmp.append(r1)
        tmp.append(0x73 ^ r1)
        for _ in 0..<3 { tmp.append(r1) }
        for i in 0..<4 { tmp.append(r1 ^ time[3 - i]) }
        for i in 15..<pubKey.count { tmp.append(pubKey[i] ^ r2) }
        tmp.append(r2)
        tmp.append(0x01 ^ r2)
        for _ in 0..<3 { tmp.append(r2) }
        var salted: [UInt8] = Array(crcSalt.utf8)
        salted.append(contentsOf: tmp)
        let crc = Crypto.crc32(salted)
        for i in 0..<4 { tmp.append(UInt8(truncatingIfNeeded: crc >> (8 * UInt32(i)))) }
        return tmp
    }
}

/// LZ4 原始块（block format，无帧头）解码。纯 Swift，Linux 测试与 iOS 同一份代码。
enum LZ4Block {
    /// 格式错误、越界或超过 maxOutput 时返回 nil
    static func decompress(_ src: [UInt8], maxOutput: Int = 1 << 22) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(min(maxOutput, max(64, src.count * 4)))
        let n = src.count
        var i = 0
        while i < n {
            let token = Int(src[i])
            i += 1
            // 字面量长度：高 4 位，满 15 时后续字节累加，直到遇到非 255
            var literal = token >> 4
            if literal == 15 {
                while true {
                    guard i < n else { return nil }
                    let b = Int(src[i])
                    i += 1
                    literal += b
                    if b != 255 { break }
                }
            }
            guard literal <= n - i, out.count + literal <= maxOutput else { return nil }
            out.append(contentsOf: src[i..<(i + literal)])
            i += literal
            // 最后一个序列只有字面量
            if i >= n { break }
            guard i + 1 < n else { return nil }
            let offset = Int(src[i]) | (Int(src[i + 1]) << 8)
            i += 2
            guard offset > 0, offset <= out.count else { return nil }
            // 匹配长度：低 4 位 + 4，满 15 时同样续读
            var match = token & 0x0f
            if match == 15 {
                while true {
                    guard i < n else { return nil }
                    let b = Int(src[i])
                    i += 1
                    match += b
                    if b != 255 { break }
                }
            }
            match += 4
            guard out.count + match <= maxOutput else { return nil }
            // 允许重叠（offset < match 时逐字节复制出重复串）
            var from = out.count - offset
            for _ in 0..<match {
                out.append(out[from])
                from += 1
            }
        }
        return out
    }
}
