// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 种子数据落盘：校验通过的分块按偏移写进各个文件；没选中的文件不建、对应字节直接丢弃
final class TorrentStorage: @unchecked Sendable {
    let info: TorrentInfo
    let root: URL
    let selected: Set<Int>
    private let lock = NSLock()

    init(info: TorrentInfo, root: URL, selected: Set<Int>) {
        self.info = info
        self.root = root
        self.selected = selected
    }

    /// 下载完成后交给引擎的产物：单文件种子是那个文件，多文件种子是以种子名命名的目录
    var outputURL: URL {
        info.isSingleFile ? root.appendingPathComponent(info.files[0].path[0]) : root.appendingPathComponent(info.name, isDirectory: true)
    }

    func fileURL(_ f: TorrentFile) -> URL {
        if info.isSingleFile { return outputURL }
        return f.path.reduce(outputURL) { $0.appendingPathComponent($1) }
    }

    /// 预先建好选中的文件（长度为 0 的文件不会有数据写入，也要出现在结果里）
    func prepare() throws {
        let fm = FileManager.default
        for f in info.files where selected.contains(f.id) && !f.isPadding {
            let url = fileURL(f)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
        }
    }

    func write(piece index: Int, data: Data) throws {
        let start = Int64(index) * info.pieceLength
        let end = start + Int64(data.count)
        lock.lock()
        defer { lock.unlock() }
        // 文件按偏移有序：二分找到第一个可能重叠的文件
        var lo = 0, hi = info.files.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if info.files[mid].offset + info.files[mid].length <= start { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < info.files.count, info.files[i].offset < end {
            let f = info.files[i]
            i += 1
            guard f.length > 0, selected.contains(f.id), !f.isPadding else { continue }
            let from = max(start, f.offset), to = min(end, f.offset + f.length)
            guard from < to else { continue }
            let url = fileURL(f)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(from - f.offset))
            let lower = data.startIndex + Int(from - start)
            try handle.write(contentsOf: data[lower ..< lower + Int(to - from)])
        }
    }
}

/// 续传状态：已校验的分块位图 + 当时选中的文件
struct TorrentResumeState: Codable {
    var have: Data
    var selected: [Int]

    static func load(_ url: URL) -> TorrentResumeState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TorrentResumeState.self, from: data)
    }

    func save(_ url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: [.atomic]) }
    }
}

/// 元数据缓存：解析页取到的种子信息存在这里，开始下载时不必再向 peer 要一遍
public enum TorrentMetadataCache {
    public static func url(in directory: URL, infoHash: [UInt8]) -> URL {
        directory.appendingPathComponent(Crypto.hex(infoHash) + ".info")
    }

    public static func load(in directory: URL, infoHash: [UInt8]) -> TorrentInfo? {
        guard let raw = try? Data(contentsOf: url(in: directory, infoHash: infoHash)) else { return nil }
        return try? TorrentInfo.parse(info: raw, expectedHash: infoHash)
    }

    public static func save(_ info: TorrentInfo, in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? info.rawInfo.write(to: url(in: directory, infoHash: info.infoHash), options: [.atomic])
    }
}
