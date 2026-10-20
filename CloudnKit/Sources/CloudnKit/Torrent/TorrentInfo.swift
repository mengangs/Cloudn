// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 磁力链接：magnet:?xt=urn:btih:<40 位十六进制或 32 位 Base32>&dn=<名称>&tr=<tracker>
public struct MagnetLink: Sendable, Hashable {
    public let infoHash: [UInt8]
    public let displayName: String
    public let trackers: [String]

    public init(infoHash: [UInt8], displayName: String = "", trackers: [String] = []) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
    }

    public var hexHash: String { Crypto.hex(infoHash) }

    /// 规范化的磁力链接（下载任务里保存这一条）
    public var uri: String {
        var s = "magnet:?xt=urn:btih:" + hexHash
        if !displayName.isEmpty { s += "&dn=" + Self.encode(displayName) }
        for t in trackers { s += "&tr=" + Self.encode(t) }
        return s
    }

    /// 在一段文本里找磁力链接；也接受单独的 40 位十六进制特征码
    public static func find(in text: String) -> MagnetLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 40, let bytes = Crypto.bytes(hex: trimmed), bytes.count == 20 {
            return MagnetLink(infoHash: bytes)
        }
        guard let r = trimmed.range(of: "magnet:?", options: .caseInsensitive) else { return nil }
        let tail = trimmed[r.lowerBound...]
        let end = tail.firstIndex(where: { $0.isWhitespace || $0 == "\"" || $0 == "<" || $0 == ">" }) ?? tail.endIndex
        return parse(String(tail[..<end]))
    }

    public static func parse(_ text: String) -> MagnetLink? {
        guard let q = text.range(of: "magnet:?", options: [.caseInsensitive, .anchored]) else { return nil }
        var hash: [UInt8]?
        var name = ""
        var trackers: [String] = []
        for part in text[q.upperBound...].split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            let value = decode(String(kv[1]))
            switch key {
            case "xt":
                let lower = value.lowercased()
                guard hash == nil, lower.hasPrefix("urn:btih:") else { continue }
                let h = String(value.dropFirst(9))
                if h.count == 40 { hash = Crypto.bytes(hex: h) } else if h.count == 32 { hash = base32(h) }
            case "dn": name = value
            case "tr": if !value.isEmpty, !trackers.contains(value) { trackers.append(value) }
            default: break
            }
        }
        guard let hash, hash.count == 20 else { return nil }
        return MagnetLink(infoHash: hash, displayName: name, trackers: trackers)
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func base32(_ s: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer = 0, bits = 0
        var out = [UInt8]()
        for c in s.uppercased() {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        return out
    }
}

/// 种子里的一个文件
public struct TorrentFile: Sendable, Hashable, Identifiable {
    /// 在种子文件列表里的序号
    public let id: Int
    /// 相对路径（不含种子名那一层）
    public let path: [String]
    public let length: Int64
    /// 在整个种子数据里的起始偏移
    public let offset: Int64
    /// BEP 47 填充文件：只占位、不落盘、不展示
    public let isPadding: Bool

    public var name: String { path.last ?? "" }
    public var relativePath: String { path.joined(separator: "/") }
}

/// 种子元数据（info 字典）
public struct TorrentInfo: Sendable {
    public let infoHash: [UInt8]
    public let name: String
    public let pieceLength: Int64
    public let pieceHashes: [Data]
    public let files: [TorrentFile]
    /// 单文件种子：文件直接叫 name；多文件种子：name 是目录
    public let isSingleFile: Bool
    public let totalLength: Int64
    /// info 字典原始字节（缓存元数据、续传时直接用）
    public let rawInfo: Data

    public var pieceCount: Int { pieceHashes.count }
    public var hexHash: String { Crypto.hex(infoHash) }
    /// 展示用的文件（去掉填充文件）
    public var visibleFiles: [TorrentFile] { files.filter { !$0.isPadding } }

    public func pieceSize(_ index: Int) -> Int {
        let start = Int64(index) * pieceLength
        return Int(min(pieceLength, totalLength - start))
    }

    /// 解析 info 字典；给了 expectedHash 时校验 SHA1 一致（从 peer 拿到的元数据必须校验）
    public static func parse(info raw: Data, expectedHash: [UInt8]? = nil) throws -> TorrentInfo {
        let hash = Array(sha1(raw))
        if let expectedHash, hash != expectedHash { throw BencodeError(message: "种子信息校验失败") }
        let info = try Bencode.decode(raw)
        guard let pieceLength = info["piece length"]?.int, pieceLength > 0, pieceLength <= 1 << 28 else {
            throw BencodeError(message: info["meta version"]?.int == 2 ? "暂不支持 BitTorrent v2 专用种子" : "种子缺少分块信息")
        }
        guard let pieces = info["pieces"]?.data, pieces.count % 20 == 0, !pieces.isEmpty else {
            throw BencodeError(message: "种子缺少分块校验值")
        }
        let name = FileNames.sanitize((info["name.utf-8"] ?? info["name"])?.string ?? "")
        var files: [TorrentFile] = []
        var total: Int64 = 0
        if let list = info["files"]?.list {
            for (i, f) in list.enumerated() {
                guard let length = f["length"]?.int, length >= 0 else { throw BencodeError(message: "种子文件长度无效") }
                let parts = ((f["path.utf-8"] ?? f["path"])?.list ?? []).compactMap(\.string).map(FileNames.sanitize).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
                let padding = (f["attr"]?.string ?? "").contains("p") || (parts.last ?? "").hasPrefix("_____padding_file_")
                files.append(TorrentFile(id: i, path: parts.isEmpty ? ["file\(i)"] : parts, length: length, offset: total, isPadding: padding))
                total += length
            }
        } else {
            guard let length = info["length"]?.int, length >= 0 else { throw BencodeError(message: "种子缺少文件长度") }
            files = [TorrentFile(id: 0, path: [name.isEmpty ? "download" : name], length: length, offset: 0, isPadding: false)]
            total = length
        }
        let hashes = stride(from: 0, to: pieces.count, by: 20).map { pieces.subdata(in: pieces.startIndex + $0 ..< pieces.startIndex + $0 + 20) }
        guard Int64(hashes.count) == (total + pieceLength - 1) / pieceLength else { throw BencodeError(message: "种子分块数量与大小不符") }
        return TorrentInfo(infoHash: hash, name: name.isEmpty ? Crypto.hex(hash) : name, pieceLength: pieceLength, pieceHashes: hashes,
                           files: files, isSingleFile: info["files"] == nil, totalLength: total, rawInfo: raw)
    }

    /// 解析 .torrent 文件：返回元数据与里面列出的 tracker
    public static func parse(torrentFile data: Data) throws -> (info: TorrentInfo, trackers: [String]) {
        guard let raw = try Bencode.rawValue(forKey: "info", in: data) else { throw BencodeError(message: "不是有效的种子文件") }
        let root = try Bencode.decode(data)
        var trackers: [String] = []
        for tier in root["announce-list"]?.list ?? [] {
            for t in tier.list ?? [] { if let s = t.string, !trackers.contains(s) { trackers.append(s) } }
        }
        if let s = root["announce"]?.string, !trackers.contains(s) { trackers.insert(s, at: 0) }
        return (try parse(info: raw), trackers)
    }

    /// 选中文件需要的分块（含跨文件边界的分块）
    public func pieces(for selected: Set<Int>) -> [Bool] {
        var need = [Bool](repeating: false, count: pieceCount)
        for f in files where selected.contains(f.id) && !f.isPadding && f.length > 0 {
            let first = Int(f.offset / pieceLength)
            let last = Int((f.offset + f.length - 1) / pieceLength)
            for p in first...last { need[p] = true }
        }
        return need
    }

    static func sha1(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(Insecure.SHA1.hash(data: data))
        #else
        return Data(Crypto.sha1([UInt8](data)))
        #endif
    }
}
