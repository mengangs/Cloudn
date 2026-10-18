// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// m3u8 播放列表（只解析下载需要的部分）
struct M3U8 {
    struct Key: Equatable {
        let method: String
        let uri: String
        let iv: Data?
    }

    struct Segment {
        let url: String
        let key: Key?
        let sequence: Int
    }

    var variants: [(bandwidth: Int, url: String)] = []
    var segments: [Segment] = []
    var mapURL: String?

    var isMaster: Bool { !variants.isEmpty }

    static func parse(_ text: String, baseURL: String) -> M3U8 {
        var playlist = M3U8()
        var key: Key?
        var sequence = 0
        var pendingBandwidth: Int?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmed
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = Int(attribute("BANDWIDTH", in: line) ?? "") ?? 0
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                if method == "NONE" {
                    key = nil
                } else {
                    let iv = attribute("IV", in: line).flatMap { hexData($0) }
                    key = Key(method: method, uri: resolve(attribute("URI", in: line) ?? "", base: baseURL), iv: iv)
                }
            } else if line.hasPrefix("#EXT-X-MAP") {
                if let uri = attribute("URI", in: line) { playlist.mapURL = resolve(uri, base: baseURL) }
            } else if line.hasPrefix("#") {
                continue
            } else if let bw = pendingBandwidth {
                playlist.variants.append((bw, resolve(line, base: baseURL)))
                pendingBandwidth = nil
            } else {
                playlist.segments.append(Segment(url: resolve(line, base: baseURL), key: key, sequence: sequence))
                sequence += 1
            }
        }
        return playlist
    }

    static func attribute(_ name: String, in line: String) -> String? {
        if let quoted = Rx(Rx.escape(name) + #"="([^"]*)""#).first(in: line) { return quoted }
        return Rx(#"(?:^|[:,])"# + Rx.escape(name) + #"=([^,]*)"#).first(in: line)
    }

    static func resolve(_ uri: String, base: String) -> String {
        VideoHTTP.absolutize(base: base, uri)
    }

    static func hexData(_ hex: String) -> Data? {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var data = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        return data
    }
}

/// HLS 下载：分片并发下载到工作目录，完成后按序拼接；fMP4（有 EXT-X-MAP）输出 .mp4，否则 .ts
struct HLSTransfer {
    let url: String
    let headers: [String: String]
    let workDir: URL
    let progress: TransferProgress
    let connections: Int
    let retryCount: Int
    let client: HTTPClient

    /// 返回拼接后的文件
    func run() async throws -> URL {
        var playlistURL = url
        var playlist = try await load(playlistURL)
        if playlist.isMaster {
            guard let best = playlist.variants.max(by: { $0.bandwidth < $1.bandwidth }) else { throw TransferError("播放列表为空") }
            playlistURL = best.url
            playlist = try await load(playlistURL)
        }
        let segments = playlist.segments
        guard !segments.isEmpty else { throw TransferError("播放列表里没有分片") }

        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let done = segments.indices.filter { fm.fileExists(atPath: segmentURL($0).path) }.count
        progress.setSegments(done: done, total: segments.count)

        var keys: [String: Data] = [:]
        for uri in Set(segments.compactMap { $0.key?.uri }) {
            let r = try await client.send(.get(uri, headers: headers.sortedPairs))
            guard r.isSuccess, r.body.count == 16 else { throw TransferError("获取视频密钥失败") }
            keys[uri] = r.body
        }

        let pending = segments.indices.filter { !fm.fileExists(atPath: segmentURL($0).path) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<max(1, min(connections, 6, pending.count)) {
                guard let i = iterator.next() else { break }
                group.addTask { try await self.fetchSegment(i, segments[i], keys: keys) }
            }
            while try await group.next() != nil {
                if let i = iterator.next() { group.addTask { try await self.fetchSegment(i, segments[i], keys: keys) } }
            }
        }

        let isFMP4 = playlist.mapURL != nil
        let output = workDir.appendingPathComponent(isFMP4 ? "output.mp4" : "output.ts")
        _ = fm.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        if let map = playlist.mapURL {
            let r = try await client.send(.get(map, headers: headers.sortedPairs))
            guard r.isSuccess else { throw TransferError("获取初始化分片失败") }
            try out.write(contentsOf: r.body)
        }
        for i in segments.indices {
            try out.write(contentsOf: try Data(contentsOf: segmentURL(i)))
        }
        return output
    }

    private func load(_ url: String) async throws -> M3U8 {
        let r = try await client.send(.get(url, headers: headers.sortedPairs))
        guard r.isSuccess else { throw TransferError(RangeTransfer.statusMessage(r.status)) }
        let text = r.text
        guard text.contains("#EXTM3U") else { throw TransferError("不是有效的 m3u8 播放列表") }
        return M3U8.parse(text, baseURL: r.url)
    }

    private func segmentURL(_ i: Int) -> URL {
        workDir.appendingPathComponent(String(format: "seg_%05d.bin", i))
    }

    private func fetchSegment(_ index: Int, _ segment: M3U8.Segment, keys: [String: Data]) async throws {
        var attempt = 0
        while true {
            do {
                let r = try await client.send(HTTPRequest(url: segment.url, headers: headers.sortedPairs, timeout: 60))
                guard r.isSuccess else { throw TransferError(RangeTransfer.statusMessage(r.status)) }
                var data = r.body
                if let key = segment.key {
                    guard key.method == "AES-128", let k = keys[key.uri] else { throw TransferError("不支持的加密方式 \(key.method)") }
                    data = try Self.decrypt(data, key: k, iv: key.iv ?? Self.sequenceIV(segment.sequence))
                }
                let tmp = segmentURL(index).appendingPathExtension("tmp")
                try data.write(to: tmp)
                try FileManager.default.moveItem(at: tmp, to: segmentURL(index))
                progress.segmentFinished(bytes: Int64(data.count))
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                attempt += 1
                if attempt > retryCount { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
            }
        }
    }

    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var n = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &n) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        #if canImport(CommonCrypto)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLength = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress, inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw TransferError("视频分片解密失败") }
        return out.prefix(outLength)
        #else
        throw TransferError("当前平台不支持 AES-128 解密")
        #endif
    }
}
