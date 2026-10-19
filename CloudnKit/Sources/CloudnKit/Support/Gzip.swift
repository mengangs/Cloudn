// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// gzip 解压：剥掉 gzip 头尾后交给系统的原始 DEFLATE 解码（Apple 平台）；其它平台返回 nil
enum Gzip {
    static func decompress(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard i + 2 <= bytes.count else { return nil }
            i += 2 + (Int(bytes[i]) | (Int(bytes[i + 1]) << 8))
        }
        if flags & 0x08 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 }  // FNAME
        if flags & 0x10 != 0 { while i < bytes.count && bytes[i] != 0 { i += 1 }; i += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { i += 2 }  // FHCRC
        guard i < bytes.count - 8 else { return nil }
        let deflate = Data(bytes[i..<(bytes.count - 8)])
        #if canImport(Darwin)
        guard let out = try? (deflate as NSData).decompressed(using: .zlib) else { return nil }
        return [UInt8](out as Data)
        #else
        _ = deflate
        return nil
        #endif
    }
}
