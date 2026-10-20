// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 网页 MSE 录制用：识别页面追加给 SourceBuffer 的数据开头是不是初始化段，以及初始化段有多长。
/// fMP4：初始化段 = 开头的 ftyp + moov（及其间的 free / skip 等盒子），之后是 styp / sidx / moof / mdat 媒体段；
/// WebM：初始化段 = EBML 头 + Segment 头 + 第一个 Cluster 之前的元素（Info、Tracks 等）。
public enum MSESegments {
    /// 开头像初始化段：fMP4 第一个盒子是 ftyp / moov，或 WebM 的 EBML 头
    public static func startsWithInit(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(8))
        if b.count >= 8 {
            let type = String(decoding: b[4..<8], as: UTF8.self)
            if type == "ftyp" || type == "moov" { return true }
        }
        return b.count >= 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3
    }

    /// 开头初始化段的字节数；不是初始化段或解析不了时为 nil
    public static func initLength(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard startsWithInit(data) else { return nil }
        if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
            return webmInitLength(bytes)
        }
        return mp4InitLength(bytes)
    }

    // MARK: fMP4

    static func mp4InitLength(_ b: [UInt8]) -> Int? {
        let header: Set<String> = ["ftyp", "moov", "free", "skip", "pdin", "uuid", "udta", "meta", "wide"]
        var offset = 0
        var sawMoov = false
        while offset + 8 <= b.count {
            let size32 = readUInt(b, offset, 4)
            let type = String(decoding: b[(offset + 4)..<(offset + 8)], as: UTF8.self)
            guard header.contains(type) else { break }
            var size = Int(size32)
            if size32 == 1 {
                guard offset + 16 <= b.count else { return nil }
                let large = readUInt(b, offset + 8, 8)
                guard large <= UInt64(Int.max) else { return nil }
                size = Int(large)
            } else if size32 == 0 {
                size = b.count - offset
            }
            guard size >= 8, offset + size <= b.count else { return nil }
            if type == "moov" { sawMoov = true }
            offset += size
        }
        return sawMoov ? offset : nil
    }

    static func readUInt(_ b: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count { value = value << 8 | UInt64(b[offset + i]) }
        return value
    }

    // MARK: WebM

    /// 第一个 Cluster 之前的长度；数据里没有 Cluster 时整段都是初始化段
    static func webmInitLength(_ b: [UInt8]) -> Int? {
        // EBML 头
        guard let headId = readId(b, 0), let headSize = readSize(b, headId.next) else { return nil }
        guard let headLength = headSize.value else { return nil }
        var offset = headSize.next + headLength
        guard offset <= b.count else { return nil }
        if offset == b.count { return offset }
        // Segment（大小通常是「未知」）
        guard let segId = readId(b, offset), segId.id == 0x1853_8067, let segSize = readSize(b, segId.next) else { return nil }
        offset = segSize.next
        while offset < b.count {
            guard let child = readId(b, offset) else { return nil }
            if child.id == 0x1F43_B675 { return offset }
            guard let size = readSize(b, child.next), let length = size.value else { return nil }
            offset = size.next + length
        }
        return offset == b.count ? offset : nil
    }

    /// EBML 元素 ID（保留长度标记位）
    static func readId(_ b: [UInt8], _ offset: Int) -> (id: UInt32, next: Int)? {
        guard offset < b.count else { return nil }
        let first = b[offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 4, offset + length <= b.count else { return nil }
        var id: UInt32 = 0
        for i in 0..<length { id = id << 8 | UInt32(b[offset + i]) }
        return (id, offset + length)
    }

    /// EBML 变长大小；全 1 表示未知大小（value 为 nil）
    static func readSize(_ b: [UInt8], _ offset: Int) -> (value: Int?, next: Int)? {
        guard offset < b.count else { return nil }
        let first = b[offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard offset + length <= b.count else { return nil }
        let mask: UInt8 = length >= 8 ? 0 : UInt8(0xFF >> length)
        var value = UInt64(first & mask)
        var allOnes = (first & mask) == mask
        for i in 1..<length {
            let byte = b[offset + i]
            if byte != 0xFF { allOnes = false }
            value = value << 8 | UInt64(byte)
        }
        if allOnes { return (nil, offset + length) }
        guard value <= UInt64(Int.max / 2) else { return nil }
        return (Int(value), offset + length)
    }
}
