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
    /// 与 variants 一一对应：该清晰度引用的独立音轨组（EXT-X-STREAM-INF 的 AUDIO 属性）
    var variantAudioGroups: [String?] = []
    /// 独立音轨：组名 → 音轨播放列表地址（同组有多条时取 DEFAULT=YES 的）
    var audioRenditions: [String: String] = [:]
    /// 与 variants 一一对应：RESOLUTION 的短边（如 1280x720 → 720），没写为 0
    var variantHeights: [Int] = []
    var segments: [Segment] = []
    var mapURL: String?
    /// 各分片 EXTINF 时长之和（秒）
    var totalDuration: Double = 0

    var isMaster: Bool { !variants.isEmpty }

    static func parse(_ text: String, baseURL: String) -> M3U8 {
        var playlist = M3U8()
        var key: Key?
        var sequence = 0
        var pendingBandwidth: Int?
        var pendingAudio: String?
        var pendingHeight = 0
        var defaultAudio = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmed
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = Int(attribute("BANDWIDTH", in: line) ?? "") ?? 0
                pendingAudio = attribute("AUDIO", in: line)
                let size = (attribute("RESOLUTION", in: line) ?? "").lowercased().split(separator: "x").compactMap { Int($0) }
                pendingHeight = size.count == 2 ? min(size[0], size[1]) : 0
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
                playlist.totalDuration += Double(value.trimmed) ?? 0
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                guard attribute("TYPE", in: line) == "AUDIO", let group = attribute("GROUP-ID", in: line),
                      let uri = attribute("URI", in: line) else { continue }
                let isDefault = attribute("DEFAULT", in: line) == "YES"
                if playlist.audioRenditions[group] == nil || (isDefault && !defaultAudio.contains(group)) {
                    playlist.audioRenditions[group] = resolve(uri, base: baseURL)
                }
                if isDefault { defaultAudio.insert(group) }
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
                playlist.variantAudioGroups.append(pendingAudio)
                playlist.variantHeights.append(pendingHeight)
                pendingHeight = 0
                pendingBandwidth = nil
                pendingAudio = nil
            } else {
                playlist.segments.append(Segment(url: resolve(line, base: baseURL), key: key, sequence: sequence))
                sequence += 1
            }
        }
        return playlist
    }

    /// 码率最高的清晰度，以及它引用的独立音轨（没有则为 nil）
    var bestVariant: (url: String, audio: String?)? {
        guard let i = variants.indices.max(by: { variants[$0].bandwidth < variants[$1].bandwidth }) else { return nil }
        let group = i < variantAudioGroups.count ? variantAudioGroups[i] : nil
        return (variants[i].url, group.flatMap { audioRenditions[$0] })
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
    var limiter: RateLimiter?

    /// 下载结果：视频（或音视频一体）文件，以及独立音轨文件（有的话）
    struct Output {
        let video: URL
        let audio: URL?
    }

    /// 返回拼接后的文件。主播放列表里最高清晰度带独立音轨时（Reddit、Vimeo 等），音轨也一并下载，交给调用方合并
    func run() async throws -> Output {
        var playlist = try await load(url)
        var audioURL: String?
        if playlist.isMaster {
            guard let best = playlist.bestVariant else { throw TransferError("播放列表为空") }
            audioURL = best.audio
            playlist = try await load(best.url)
        }
        guard !playlist.segments.isEmpty else { throw TransferError("播放列表里没有分片") }
        var audioPlaylist: M3U8?
        if let audioURL, let list = try? await load(audioURL), !list.segments.isEmpty { audioPlaylist = list }

        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let audioDir = workDir.appendingPathComponent("audio", isDirectory: true)
        if audioPlaylist != nil { try fm.createDirectory(at: audioDir, withIntermediateDirectories: true) }
        let total = playlist.segments.count + (audioPlaylist?.segments.count ?? 0)
        let done = playlist.segments.indices.filter { fm.fileExists(atPath: segmentURL($0, in: workDir).path) }.count
            + (audioPlaylist?.segments.indices.filter { fm.fileExists(atPath: segmentURL($0, in: audioDir).path) }.count ?? 0)
        progress.setSegments(done: done, total: total)

        let video = try await download(playlist, in: workDir, name: "output")
        guard let audioPlaylist else { return Output(video: video, audio: nil) }
        let audio = try await download(audioPlaylist, in: audioDir, name: "audio")
        return Output(video: video, audio: audio)
    }

    /// 并发下载一个媒体播放列表的全部分片并按序拼接；fMP4 输出 .mp4，否则 .ts
    private func download(_ playlist: M3U8, in dir: URL, name: String) async throws -> URL {
        let fm = FileManager.default
        let segments = playlist.segments
        var keys: [String: Data] = [:]
        for uri in Set(segments.compactMap { $0.key?.uri }) {
            let r = try await client.send(.get(uri, headers: headers.sortedPairs))
            guard r.isSuccess, r.body.count == 16 else { throw TransferError("获取视频密钥失败") }
            keys[uri] = r.body
        }

        let pending = segments.indices.filter { !fm.fileExists(atPath: segmentURL($0, in: dir).path) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<max(1, min(connections, 6, pending.count)) {
                guard let i = iterator.next() else { break }
                group.addTask { try await self.fetchSegment(i, segments[i], keys: keys, dir: dir) }
            }
            while try await group.next() != nil {
                if let i = iterator.next() { group.addTask { try await self.fetchSegment(i, segments[i], keys: keys, dir: dir) } }
            }
        }

        let isFMP4 = playlist.mapURL != nil
        let output = dir.appendingPathComponent(name + (isFMP4 ? ".mp4" : ".ts"))
        _ = fm.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        if let map = playlist.mapURL {
            let r = try await client.send(.get(map, headers: headers.sortedPairs))
            guard r.isSuccess else { throw TransferError("获取初始化分片失败") }
            try out.write(contentsOf: r.body)
        }
        for i in segments.indices {
            try out.write(contentsOf: try Data(contentsOf: segmentURL(i, in: dir)))
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

    private func segmentURL(_ i: Int, in dir: URL) -> URL {
        dir.appendingPathComponent(String(format: "seg_%05d.bin", i))
    }

    private func fetchSegment(_ index: Int, _ segment: M3U8.Segment, keys: [String: Data], dir: URL) async throws {
        var attempt = 0
        while true {
            do {
                let r = try await client.send(HTTPRequest(url: segment.url, headers: headers.sortedPairs, timeout: 60))
                guard r.isSuccess else { throw TransferError(RangeTransfer.statusMessage(r.status)) }
                try await limiter?.throttleAsync(r.body.count)
                var data = r.body
                if let key = segment.key {
                    guard key.method == "AES-128", let k = keys[key.uri] else { throw TransferError("不支持的加密方式 \(key.method)") }
                    data = try Self.decrypt(data, key: k, iv: key.iv ?? Self.sequenceIV(segment.sequence))
                }
                // 已被暂停的这一轮不再落盘；原子写入自带唯一临时文件，快速暂停 / 继续时两轮不会写同一个 .tmp
                if Task.isCancelled { throw CancellationError() }
                try data.write(to: segmentURL(index, in: dir), options: .atomic)
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
