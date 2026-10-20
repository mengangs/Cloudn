// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// peer 地址
public struct PeerAddress: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// 紧凑格式：IPv4 每个 6 字节、IPv6 每个 18 字节（地址 + 大端端口）
    public static func compact(_ data: Data, ipv6: Bool = false) -> [PeerAddress] {
        let bytes = [UInt8](data)
        let size = ipv6 ? 18 : 6
        var out: [PeerAddress] = []
        var i = 0
        while i + size <= bytes.count {
            let ip = bytes[i..<i + size - 2]
            let port = UInt16(bytes[i + size - 2]) << 8 | UInt16(bytes[i + size - 1])
            let host: String
            if ipv6 {
                host = stride(from: ip.startIndex, to: ip.endIndex, by: 2)
                    .map { String(UInt16(ip[$0]) << 8 | UInt16(ip[$0 + 1]), radix: 16) }.joined(separator: ":")
            } else {
                host = ip.map(String.init).joined(separator: ".")
            }
            if port > 0 { out.append(PeerAddress(host: host, port: port)) }
            i += size
        }
        return out
    }
}

/// peer 线协议消息（BEP 3 + BEP 10 扩展消息）
enum PeerMessage: Equatable {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(Int)
    case bitfield(Data)
    case request(index: Int, begin: Int, length: Int)
    case piece(index: Int, begin: Int, block: Data)
    case cancel(index: Int, begin: Int, length: Int)
    case extended(id: UInt8, payload: Data)
    case other(UInt8)

    /// 单条消息上限：最大的正常消息是 16KB 块或超大种子的位图
    static let maxLength = 4 * 1024 * 1024

    func encoded() -> Data {
        var body = Data()
        func u32(_ v: Int) { body.append(contentsOf: PeerWire.be32(UInt32(truncatingIfNeeded: v))) }
        switch self {
        case .keepAlive: return Data([0, 0, 0, 0])
        case .choke: body.append(0)
        case .unchoke: body.append(1)
        case .interested: body.append(2)
        case .notInterested: body.append(3)
        case .have(let i): body.append(4); u32(i)
        case .bitfield(let d): body.append(5); body.append(d)
        case .request(let i, let b, let l): body.append(6); u32(i); u32(b); u32(l)
        case .piece(let i, let b, let d): body.append(7); u32(i); u32(b); body.append(d)
        case .cancel(let i, let b, let l): body.append(8); u32(i); u32(b); u32(l)
        case .extended(let id, let p): body.append(20); body.append(id); body.append(p)
        case .other(let id): body.append(id)
        }
        return Data(PeerWire.be32(UInt32(body.count))) + body
    }

    /// 解析去掉长度前缀后的消息体
    static func decode(_ body: Data) throws -> PeerMessage {
        let b = [UInt8](body)
        guard let id = b.first else { return .keepAlive }
        func u32(_ at: Int) throws -> Int {
            guard at + 4 <= b.count else { throw TransferError("peer 消息不完整") }
            return Int(PeerWire.readBE32(b, at))
        }
        switch id {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4: return .have(try u32(1))
        case 5: return .bitfield(Data(b[1...]))
        case 6: return .request(index: try u32(1), begin: try u32(5), length: try u32(9))
        case 7:
            guard b.count >= 9 else { throw TransferError("peer 消息不完整") }
            return .piece(index: try u32(1), begin: try u32(5), block: Data(b[9...]))
        case 8: return .cancel(index: try u32(1), begin: try u32(5), length: try u32(9))
        case 20:
            guard b.count >= 2 else { throw TransferError("peer 消息不完整") }
            return .extended(id: b[1], payload: Data(b[2...]))
        default: return .other(id)
        }
    }
}

enum PeerWire {
    static let protocolName = Array("BitTorrent protocol".utf8)
    /// 本客户端的 ut_metadata 扩展编号（对方发元数据给我们时用这个编号）
    static let localMetadataId: UInt8 = 1
    static let blockSize = 16 * 1024
    static let metadataPieceSize = 16 * 1024

    /// 握手：19 + 协议名 + 8 字节保留位（第 20 位 = 支持扩展协议）+ info_hash + peer_id
    static func handshake(infoHash: [UInt8], peerId: [UInt8]) -> Data {
        var d = Data([19])
        d.append(contentsOf: protocolName)
        d.append(contentsOf: [0, 0, 0, 0, 0, 0x10, 0, 0])
        d.append(contentsOf: infoHash)
        d.append(contentsOf: peerId)
        return d
    }

    /// 校验对方握手，返回是否支持扩展协议
    static func parseHandshake(_ data: Data, infoHash: [UInt8]) throws -> Bool {
        let b = [UInt8](data)
        guard b.count == 68, b[0] == 19, Array(b[1..<20]) == protocolName else { throw TransferError("peer 握手无效") }
        guard Array(b[28..<48]) == infoHash else { throw TransferError("peer 的种子不一致") }
        return b[25] & 0x10 != 0
    }

    /// 生成 peer_id：-CN0100- + 12 位随机
    static func makePeerId() -> [UInt8] {
        Array("-CN0100-".utf8) + (0..<12).map { _ in UInt8.random(in: 0...255) }
    }

    /// 扩展握手：声明 ut_metadata；已知元数据大小时一并告诉对方
    static func extendedHandshake(metadataSize: Int?) -> Data {
        var pairs: [(String, BValue)] = [("m", .dict([("ut_metadata", .int(Int64(localMetadataId)))])), ("v", BValue("Cloudn")),
                                         ("reqq", .int(250))]
        if let metadataSize { pairs.append(("metadata_size", .int(Int64(metadataSize)))) }
        return Bencode.encode(.dict(pairs))
    }

    static func metadataRequest(piece: Int) -> Data {
        Bencode.encode(.dict([("msg_type", .int(0)), ("piece", .int(Int64(piece)))]))
    }

    static func metadataReject(piece: Int) -> Data {
        Bencode.encode(.dict([("msg_type", .int(2)), ("piece", .int(Int64(piece)))]))
    }

    enum MetadataMessage: Equatable {
        case request(piece: Int)
        case data(piece: Int, totalSize: Int, payload: Data)
        case reject(piece: Int)
    }

    static func parseMetadataMessage(_ payload: Data) throws -> MetadataMessage {
        let (head, used) = try Bencode.decodePrefix(payload)
        guard let type = head["msg_type"]?.int, let piece = head["piece"]?.int else { throw TransferError("元数据消息无效") }
        switch type {
        case 0: return .request(piece: Int(piece))
        case 1:
            return .data(piece: Int(piece), totalSize: Int(head["total_size"]?.int ?? 0),
                         payload: payload.subdata(in: payload.startIndex + used ..< payload.endIndex))
        default: return .reject(piece: Int(piece))
        }
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    static func be64(_ v: UInt64) -> [UInt8] { (0..<8).reversed().map { UInt8(v >> (UInt64($0) * 8) & 0xff) } }

    static func readBE32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    static func readBE64(_ b: [UInt8], _ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[at + $1]) }
    }
}

/// 位图（第 0 块在最高位）
struct Bitfield: Equatable {
    private(set) var bytes: [UInt8]
    let count: Int

    init(count: Int) {
        self.count = count
        bytes = [UInt8](repeating: 0, count: (count + 7) / 8)
    }

    init(data: Data, count: Int) {
        self.init(count: count)
        let src = [UInt8](data)
        for i in 0..<min(src.count, bytes.count) { bytes[i] = src[i] }
        // 清掉超出块数的尾部位
        if count % 8 != 0, !bytes.isEmpty { bytes[bytes.count - 1] &= UInt8(0xff << (8 - count % 8) & 0xff) }
    }

    subscript(i: Int) -> Bool {
        get { i >= 0 && i < count && bytes[i / 8] & (0x80 >> UInt8(i % 8)) != 0 }
        set {
            guard i >= 0 && i < count else { return }
            if newValue { bytes[i / 8] |= 0x80 >> UInt8(i % 8) } else { bytes[i / 8] &= ~(0x80 >> UInt8(i % 8)) }
        }
    }

    var data: Data { Data(bytes) }
    var setCount: Int { bytes.reduce(0) { $0 + $1.nonzeroBitCount } }
    var isAllSet: Bool { setCount == count }
}
