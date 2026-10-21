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

    /// EXT-X-BYTERANGE：分片只是某个资源里的一段
    struct ByteRange: Equatable {
        let offset: Int64
        let length: Int64

        var header: String { "bytes=\(offset)-\(offset + length - 1)" }

        /// `n[@o]`；没写 o 时接着 previousEnd（同一资源上一段的末尾之后）
        static func parse(_ spec: String, previousEnd: Int64) -> ByteRange? {
            let parts = spec.trimmed.split(separator: "@", maxSplits: 1).map { String($0).trimmed }
            guard let length = parts.first.flatMap({ Int64($0) }), length > 0 else { return nil }
            let offset = parts.count > 1 ? Int64(parts[1]) : previousEnd
            // offset + length 会参与计算（Range 头、下一段起点），越界的数直接当无效，免得溢出崩溃
            guard let offset, offset >= 0, offset <= Int64.max - length else { return nil }
            return ByteRange(offset: offset, length: length)
        }
    }

    struct Segment {
        let url: String
        let key: Key?
        let sequence: Int
        var range: ByteRange? = nil
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
    /// 初始化分片（EXT-X-MAP）的 BYTERANGE
    var mapRange: ByteRange?
    /// 各分片 EXTINF 时长之和（秒）
    var totalDuration: Double = 0
    /// 有 EXT-X-ENDLIST（点播 / 已结束）
    var hasEndList = false
    /// EXT-X-PLAYLIST-TYPE（VOD / EVENT），没写为 nil
    var playlistType: String?
    /// 用了 FairPlay 等 DRM（SAMPLE-AES、skd:// 密钥）：拿不到明文，无法下载
    var isDRMProtected = false

    var isMaster: Bool { !variants.isEmpty }
    /// 直播：媒体播放列表没有结束标记、也没声明是点播（只能下到当前已有的片段）
    var isLive: Bool { !isMaster && !segments.isEmpty && !hasEndList && playlistType?.uppercased() != "VOD" }

    static let drmMessage = "该视频使用 DRM 加密，无法下载"

    /// 这条 EXT-X-KEY / EXT-X-SESSION-KEY 是不是 DRM（FairPlay / Widevine / PlayReady，或我们解不了的 SAMPLE-AES）
    static func isDRMKey(_ line: String) -> Bool {
        let method = (attribute("METHOD", in: line) ?? "NONE").uppercased()
        if method == "NONE" { return false }
        let uri = (attribute("URI", in: line) ?? "").lowercased()
        let format = (attribute("KEYFORMAT", in: line) ?? "identity").lowercased()
        return method.hasPrefix("SAMPLE-AES") || method == "ISO-23001-7" || uri.hasPrefix("skd://")
            || (format != "identity" && !format.isEmpty)
    }

    static func parse(_ text: String, baseURL: String) -> M3U8 {
        var playlist = M3U8()
        var key: Key?
        var sequence = 0
        var pendingBandwidth: Int?
        var pendingAudio: String?
        var pendingHeight = 0
        var defaultAudio = Set<String>()
        var pendingRange: String?
        // 上一个带 BYTERANGE 的分片：(资源地址, 结束位置之后)
        var lastRange: (url: String, end: Int64)?
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
                // "inf" / "nan" / 超大数会让后面的整数换算崩溃：只累加有限的非负时长
                if let d = Double(value.trimmed), d.isFinite, d >= 0, d < 1e9 { playlist.totalDuration += d }
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                guard attribute("TYPE", in: line) == "AUDIO", let group = attribute("GROUP-ID", in: line),
                      let uri = attribute("URI", in: line) else { continue }
                let isDefault = attribute("DEFAULT", in: line) == "YES"
                if playlist.audioRenditions[group] == nil || (isDefault && !defaultAudio.contains(group)) {
                    playlist.audioRenditions[group] = resolve(uri, base: baseURL)
                }
                if isDefault { defaultAudio.insert(group) }
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = max(0, Int(String(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)).trimmed) ?? 0)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                playlist.hasEndList = true
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                playlist.playlistType = String(line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count)).trimmed
            } else if line.hasPrefix("#EXT-X-SESSION-KEY") {
                if isDRMKey(line) { playlist.isDRMProtected = true }
            } else if line.hasPrefix("#EXT-X-KEY") {
                if isDRMKey(line) { playlist.isDRMProtected = true }
                let method = attribute("METHOD", in: line) ?? "NONE"
                if method == "NONE" {
                    key = nil
                } else {
                    let iv = attribute("IV", in: line).flatMap { hexData($0) }
                    key = Key(method: method, uri: resolve(attribute("URI", in: line) ?? "", base: baseURL), iv: iv)
                }
            } else if line.hasPrefix("#EXT-X-MAP") {
                if let uri = attribute("URI", in: line) { playlist.mapURL = resolve(uri, base: baseURL) }
                playlist.mapRange = attribute("BYTERANGE", in: line).flatMap { ByteRange.parse($0, previousEnd: 0) }
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
                let url = resolve(line, base: baseURL)
                var range: ByteRange?
                if let spec = pendingRange {
                    // 没写起点时接着同一资源上一段之后
                    let previousEnd = lastRange.flatMap { $0.url == url ? $0.end : nil } ?? 0
                    range = ByteRange.parse(spec, previousEnd: previousEnd)
                    if let range { lastRange = (url, range.offset + range.length) }
                }
                pendingRange = nil
                playlist.segments.append(Segment(url: url, key: key, sequence: sequence, range: range))
                sequence &+= 1
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
            if playlist.isDRMProtected { throw TransferError(M3U8.drmMessage, permanent: true) }
            guard let best = playlist.bestVariant else { throw TransferError("播放列表为空") }
            audioURL = best.audio
            playlist = try await load(best.url)
        }
        guard !playlist.segments.isEmpty else { throw TransferError("播放列表里没有分片") }
        if playlist.isDRMProtected { throw TransferError(M3U8.drmMessage, permanent: true) }
        var audioPlaylist: M3U8?
        if let audioURL, let list = try? await load(audioURL), !list.segments.isEmpty {
            if list.isDRMProtected { throw TransferError(M3U8.drmMessage, permanent: true) }
            audioPlaylist = list
        }
        if playlist.isLive {
            // 直播流没有尽头：只能下到当前播放列表里已有的片段
            Log.info("m3u8 没有 EXT-X-ENDLIST，按直播流处理，只下载当前已有的 \(playlist.segments.count) 个分片")
            progress.setNote("直播流：只下载当前已有的片段（约 \(Int(saturating: playlist.totalDuration)) 秒）")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let audioDir = workDir.appendingPathComponent("audio", isDirectory: true)
        if audioPlaylist != nil { try fm.createDirectory(at: audioDir, withIntermediateDirectories: true) }
        let total = playlist.segments.count + (audioPlaylist?.segments.count ?? 0)
        // 续传：已下的分片（含已拼进输出文件的）计入数量和字节数
        let videoDone = existing(playlist, in: workDir, name: "output")
        let audioDone = audioPlaylist.map { existing($0, in: audioDir, name: "audio") } ?? (count: 0, bytes: 0)
        progress.setSegments(done: videoDone.count + audioDone.count, total: total, bytes: videoDone.bytes + audioDone.bytes)

        let video = try await download(playlist, in: workDir, name: "output")
        guard let audioPlaylist else { return Output(video: video, audio: nil) }
        let audio = try await download(audioPlaylist, in: audioDir, name: "audio")
        return Output(video: video, audio: audio)
    }

    /// 已拼进输出文件的进度：前 count 个分片、输出文件前 length 字节。暂停后下次从这里接着拼
    struct AppendState: Equatable {
        var count = 0
        var length: Int64 = 0

        static func url(in dir: URL, name: String) -> URL { dir.appendingPathComponent(name + ".appended") }

        static func load(in dir: URL, name: String) -> AppendState {
            guard let text = try? String(contentsOf: url(in: dir, name: name), encoding: .utf8) else { return AppendState() }
            let parts = text.split(separator: " ").compactMap { Int64(String($0).trimmed) }
            guard parts.count == 2, parts[0] >= 0, parts[1] >= 0 else { return AppendState() }
            return AppendState(count: Int(parts[0]), length: parts[1])
        }

        func save(in dir: URL, name: String) throws {
            try Data("\(count) \(length)".utf8).write(to: Self.url(in: dir, name: name), options: .atomic)
        }
    }

    private func outputURL(_ playlist: M3U8, in dir: URL, name: String) -> URL {
        dir.appendingPathComponent(name + (playlist.mapURL != nil ? ".mp4" : ".ts"))
    }

    /// 上次拼接的进度；输出文件比记录短（被删 / 被动过）或分片数对不上时作废，从头拼
    private func appendState(_ playlist: M3U8, in dir: URL, name: String) -> AppendState {
        let state = AppendState.load(in: dir, name: name)
        guard state.count > 0 else { return AppendState() }
        let size = DownloadEngine.size(of: outputURL(playlist, in: dir, name: name)) ?? -1
        guard state.count <= playlist.segments.count, size >= state.length else { return AppendState() }
        return state
    }

    /// 续传时已完成的分片数与字节数（已拼进输出文件的 + 还在工作目录里的）
    private func existing(_ playlist: M3U8, in dir: URL, name: String) -> (count: Int, bytes: Int64) {
        let state = appendState(playlist, in: dir, name: name)
        var count = state.count
        var bytes = state.length
        for i in playlist.segments.indices where i >= state.count {
            if let size = DownloadEngine.size(of: segmentURL(i, in: dir)) {
                count += 1
                bytes += size
            }
        }
        return (count, bytes)
    }

    /// 并发下载一个媒体播放列表的全部分片并按序拼接；fMP4 输出 .mp4，否则 .ts。
    /// 拼进输出文件的分片随即删除，整个过程只占约一份视频大小的空间
    private func download(_ playlist: M3U8, in dir: URL, name: String) async throws -> URL {
        let fm = FileManager.default
        let segments = playlist.segments
        let output = outputURL(playlist, in: dir, name: name)
        var state = appendState(playlist, in: dir, name: name)
        if state.count == segments.count { return output }

        var keys: [String: Data] = [:]
        for uri in Set(segments[state.count...].compactMap { $0.key?.uri }) {
            let r = try await client.send(.get(uri, headers: headers.sortedPairs))
            guard r.isSuccess, r.body.count == 16 else { throw TransferError("获取视频密钥失败") }
            keys[uri] = r.body
        }

        let pending = segments.indices.filter { $0 >= state.count && !fm.fileExists(atPath: segmentURL($0, in: dir).path) }
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

        if state.count == 0 {
            _ = fm.createFile(atPath: output.path, contents: nil)
        }
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        if state.count == 0 {
            if let map = playlist.mapURL {
                var mapHeaders = headers.sortedPairs
                if let range = playlist.mapRange { mapHeaders.append(("Range", range.header)) }
                let r = try await client.send(.get(map, headers: mapHeaders))
                guard r.isSuccess else { throw TransferError("获取初始化分片失败") }
                let body = try Self.slice(r.body, status: r.status, range: playlist.mapRange)
                try out.write(contentsOf: body)
                state.length = Int64(body.count)
            }
        } else {
            // 上次拼到一半被打断：截掉记录之后多写的部分
            try out.truncate(atOffset: UInt64(state.length))
            try out.seek(toOffset: UInt64(state.length))
        }
        for i in state.count..<segments.count {
            // 暂停后不再往下拼（下一轮会接着拼，两轮不会同时写同一个文件）
            try Task.checkCancellation()
            let segment = segmentURL(i, in: dir)
            let data = try Data(contentsOf: segment)
            try out.write(contentsOf: data)
            state.count = i + 1
            state.length += Int64(data.count)
            try state.save(in: dir, name: name)
            try? fm.removeItem(at: segment)
        }
        return output
    }

    /// 带 BYTERANGE 的分片：206 直接用；服务器忽略 Range 回了整个资源（200）时从中截出这一段
    static func slice(_ body: Data, status: Int, range: M3U8.ByteRange?) throws -> Data {
        guard let range else { return body }
        if status == 206 {
            guard Int64(body.count) >= range.length else { throw TransferError("分片数据不完整") }
            return body.count == Int(range.length) ? body : body.prefix(Int(range.length))
        }
        guard Int64(body.count) >= range.offset + range.length else { throw TransferError("分片数据不完整") }
        let start = body.startIndex + Int(range.offset)
        return body.subdata(in: start ..< start + Int(range.length))
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
        var requestHeaders = headers.sortedPairs
        if let range = segment.range { requestHeaders.append(("Range", range.header)) }
        while true {
            do {
                let r = try await client.send(HTTPRequest(url: segment.url, headers: requestHeaders, timeout: 60))
                guard r.isSuccess else {
                    throw TransferError(status: r.status, retryAfter: RetryPolicy.parseRetryAfter(r.header("retry-after")))
                }
                try await limiter?.throttleAsync(r.body.count)
                var data = try Self.slice(r.body, status: r.status, range: segment.range)
                if let key = segment.key {
                    guard key.method == "AES-128", let k = keys[key.uri] else { throw TransferError("不支持的加密方式 \(key.method)") }
                    data = try Self.decrypt(data, key: k, iv: key.iv ?? Self.sequenceIV(segment.sequence))
                }
                // 已被暂停的这一轮不再落盘；原子写入自带唯一临时文件，快速暂停 / 继续时两轮不会写同一个 .tmp
                if Task.isCancelled { throw CancellationError() }
                try data.write(to: segmentURL(index, in: dir), options: .atomic)
                progress.segmentFinished(bytes: Int64(data.count))
                return
            } catch let e as TransferError where e.permanent {
                throw e
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if DiskSpace.isOutOfSpace(error) { throw TransferError(DiskSpace.writeFailedMessage, permanent: true) }
                attempt += 1
                if attempt > retryCount { throw error }
                // 指数退避（封顶 30 秒），429 / 503 有 Retry-After 时按它
                try await RetryPolicy.sleep(attempt: attempt, retryAfter: (error as? TransferError)?.retryAfter)
            }
        }
    }

    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var n = UInt64(truncatingIfNeeded: sequence).bigEndian
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
