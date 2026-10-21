// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// MPEG-TS → MP4 无损转封装（不重新编码，纯 Swift，Linux / iOS / macOS 通用）。
///
/// HLS 的 TS 分片拼接后是 `.ts`，相册 / 文件 App 多数播不了，这里把其中的视频（H.264 / HEVC）和音频（AAC ADTS）
/// 原样搬进标准（非分片）MP4：
/// - 流式读取 TS（188 字节包，按 0x47 同步），解析 PAT / PMT，按 PID 重组 PES；33 位 PTS / DTS 处理回绕。
/// - 视频：Annex-B 起始码切 NAL，去掉 AUD / 填充以及与样本描述里相同的参数集，改成 4 字节长度前缀的样本；
///   SPS / PPS（HEVC 还有 VPS）放进 avcC / hvcC，并从 SPS 解析宽高。
/// - 音频：去掉 ADTS 头得到裸 AAC 帧，生成 2 字节 AudioSpecificConfig 放进 esds；每帧 1024 个采样。
/// - 输出布局：ftyp → free(8) → mdat → moov。样本边解析边写进 mdat，内存里只保留样本表和当前 PES，
///   多 GB 的 TS 也不会整体读入内存；mdat 超过 4GB 时把前面的 free 改写成 64 位 largesize 头。
/// - 时间轴：视频时间刻度 90000，音频为采样率。以所有轨道里最早的显示时间为 0 点；
///   视频首帧 PTS ≠ 首帧 DTS（有 B 帧）时用 elst 的 media_time 跳过 CTS 偏移，晚于 0 点开始的轨道前面加空白编辑，
///   这样音画按 PTS 对齐。
///
/// 局限：只取第一个节目的第一路视频和第一路 AAC；PAT / PMT 须在单个 TS 包内（HLS 都是）；
/// 视频 DTS 倒退或跳变超过 10 秒（HLS 不连续点）时直接接在上一帧之后；音频按帧数连续排列，不补洞；
/// 不支持一个 PES 里含多个视频访问单元、一个 ADTS 帧含多个 raw_data_block 的流；
/// 中途更换分辨率的参数集保留在样本里（avc1 / hvc1 的严格播放器可能不认）。
public enum TSRemuxer {
    /// 把 `ts` 的视频轨（以及没有单独音频文件时它自带的 AAC）转封装到 `output`。
    /// `audio` 是主播放列表里独立音轨的 TS，取其中的 AAC，与视频按各自 PTS 相对最早时刻对齐。
    /// `shouldCancel` 在读每一批数据前检查一次，返回 true 时抛出 CancellationError 并删掉未完成的输出（暂停 / 删除任务时用）。
    public static func remux(video ts: URL, audio: URL? = nil, to output: URL, shouldCancel: () -> Bool = { false }) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: output)
        guard fm.createFile(atPath: output.path, contents: nil) else { throw TransferError("无法创建 MP4 文件") }
        let handle = try FileHandle(forWritingTo: output)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? fm.removeItem(at: output) }
        }

        let sink = MP4SampleSink(handle: handle)
        try sink.writeHeader()
        let clock = TSClock()
        let videoTrack = VideoTrackBuilder()
        let audioTrack = AudioTrackBuilder()
        let ownAudio: AudioTrackBuilder? = audio == nil ? audioTrack : nil
        try TSDemuxer(url: ts, video: videoTrack, audio: ownAudio, clock: clock, sink: sink).run(shouldCancel: shouldCancel)
        try videoTrack.finish(clock: clock, sink: sink)
        if let audio {
            try TSDemuxer(url: audio, video: nil, audio: audioTrack, clock: clock, sink: sink).run(shouldCancel: shouldCancel)
        }
        if shouldCancel() { throw CancellationError() }
        let hasVideo = videoTrack.sampleCount > 0
        let hasAudio = audioTrack.sampleCount > 0 && audioTrack.config != nil
        guard hasVideo || hasAudio else { throw TransferError("TS 里没有可转封装的 H.264 / HEVC / AAC 数据") }

        try sink.finishMdat()
        let moov = MP4Builder.moov(video: hasVideo ? videoTrack : nil, audio: hasAudio ? audioTrack : nil)
        try sink.handle.write(contentsOf: Data(moov))
        succeeded = true
    }
}

// MARK: - 时间戳

/// 33 位 90kHz 时间戳的回绕处理；`anchor` 是整个转封装过程里第一个出现的时间戳，各轨道以它为起点展开，
/// 这样视频文件和独立音轨文件跨回绕时也能对齐
final class TSClock {
    static let period: Int64 = 1 << 33
    private(set) var anchor: Int64?

    /// 轨道第一个时间戳展开时参照的值：已有锚点就用锚点，否则以它自己为锚点
    func reference(for raw: Int64) -> Int64 {
        if let anchor { return anchor }
        anchor = raw
        return raw
    }

    /// 把 33 位原始值 `raw` 展开到离 `ref` 最近的那一圈
    static func unwrap(_ raw: Int64, near ref: Int64) -> Int64 {
        let half = period / 2
        var value = raw + ((ref >> 33) << 33)
        if value - ref > half {
            value -= period
        } else if ref - value > half {
            value += period
        }
        return value
    }
}

// MARK: - 输出

/// 样本表：每个样本的大小，以及合并成块（chunk）的文件偏移。同一轨道连续写入的样本归入同一块
struct MP4SampleTable {
    var sizes: [UInt32] = []
    var chunkOffsets: [UInt64] = []
    var chunkCounts: [UInt32] = []
    private var nextOffset: UInt64 = .max

    var count: Int { sizes.count }

    mutating func add(offset: UInt64, size: Int) {
        if offset == nextOffset, !chunkCounts.isEmpty {
            chunkCounts[chunkCounts.count - 1] += 1
        } else {
            chunkOffsets.append(offset)
            chunkCounts.append(1)
        }
        sizes.append(UInt32(clamping: size))
        nextOffset = offset + UInt64(size)
    }
}

/// 顺序写出 MP4：ftyp + free + mdat 头 → 样本数据（带 1MB 写缓冲）→ 回填 mdat 大小
final class MP4SampleSink {
    let handle: FileHandle
    private var buffer: [UInt8] = []
    /// 已写出（含缓冲区里）的总字节数，即下一个字节的文件偏移
    private(set) var offset: UInt64 = 0
    /// ftyp 32 字节，其后 8 字节 free，再后 8 字节 mdat 头
    static let ftypSize: UInt64 = 32
    static let payloadStart: UInt64 = 48
    private static let flushThreshold = 1 << 20

    init(handle: FileHandle) {
        self.handle = handle
        buffer.reserveCapacity(Self.flushThreshold + 65536)
    }

    func writeHeader() throws {
        var w = ByteWriter()
        let s = w.begin("ftyp")
        w.fourcc("isom")
        w.u32(512)
        w.fourcc("isom")
        w.fourcc("iso2")
        w.fourcc("avc1")
        w.fourcc("mp41")
        w.end(s)
        // 占位：mdat 不超过 4GB 时 free 保持原样、mdat 用 32 位大小；超过时这 16 字节改写成 64 位 mdat 头
        w.u32(8)
        w.fourcc("free")
        w.u32(0)
        w.fourcc("mdat")
        try write(w.bytes)
    }

    func write(_ bytes: [UInt8]) throws {
        buffer.append(contentsOf: bytes)
        offset += UInt64(bytes.count)
        if buffer.count >= Self.flushThreshold { try flush() }
    }

    func write(_ bytes: ArraySlice<UInt8>) throws {
        buffer.append(contentsOf: bytes)
        offset += UInt64(bytes.count)
        if buffer.count >= Self.flushThreshold { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }

    /// 回填 mdat 大小，文件指针回到末尾以便追加 moov
    func finishMdat() throws {
        try flush()
        let payload = offset - Self.payloadStart
        var w = ByteWriter()
        if payload + 8 <= UInt64(UInt32.max) {
            w.u32(UInt32(payload + 8))
            try handle.seek(toOffset: Self.ftypSize + 8)
        } else {
            w.u32(1)
            w.fourcc("mdat")
            w.u64(payload + 16)
            try handle.seek(toOffset: Self.ftypSize)
        }
        try handle.write(contentsOf: Data(w.bytes))
        _ = try handle.seekToEnd()
    }
}

/// 大端字节写入，盒子用 begin / end 回填长度
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func u24(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func u64(_ v: UInt64) {
        u32(UInt32(truncatingIfNeeded: v >> 32))
        u32(UInt32(truncatingIfNeeded: v))
    }

    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

    mutating func zeros(_ n: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: n)) }

    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }

    mutating func fourcc(_ s: String) {
        let code = Array(s.utf8)
        precondition(code.count == 4, "fourcc 必须 4 字节")
        bytes.append(contentsOf: code)
    }

    /// 开始一个盒子，返回其起始位置
    mutating func begin(_ type: String) -> Int {
        let start = bytes.count
        u32(0)
        fourcc(type)
        return start
    }

    /// 开始一个 FullBox（version + flags）
    mutating func beginFull(_ type: String, version: UInt8 = 0, flags: UInt32 = 0) -> Int {
        let start = begin(type)
        u8(version)
        u24(flags)
        return start
    }

    /// 结束盒子：回填长度
    mutating func end(_ start: Int) {
        let size = UInt32(clamping: bytes.count - start)
        bytes[start] = UInt8(truncatingIfNeeded: size >> 24)
        bytes[start + 1] = UInt8(truncatingIfNeeded: size >> 16)
        bytes[start + 2] = UInt8(truncatingIfNeeded: size >> 8)
        bytes[start + 3] = UInt8(truncatingIfNeeded: size)
    }
}

// MARK: - TS 解复用

/// 一个 PID 上正在拼接的 PES
final class PESBuffer {
    var data: [UInt8] = []
    var active = false
}

/// 流式读取一个 TS 文件，把选中的视频 / 音频 PES 交给对应轨道
final class TSDemuxer {
    private let url: URL
    private let video: VideoTrackBuilder?
    private let audio: AudioTrackBuilder?
    private let clock: TSClock
    private let sink: MP4SampleSink
    private var pmtPID: Int?
    private var pmtParsed = false
    private var videoPID: Int?
    private var audioPID: Int?
    private let videoPES = PESBuffer()
    private let audioPES = PESBuffer()

    static let packetSize = 188

    init(url: URL, video: VideoTrackBuilder?, audio: AudioTrackBuilder?, clock: TSClock, sink: MP4SampleSink) {
        self.url = url
        self.video = video
        self.audio = audio
        self.clock = clock
        self.sink = sink
    }

    func run(shouldCancel: () -> Bool = { false }) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = Self.packetSize
        let chunk = size * 4096
        var buf: [UInt8] = []
        var pos = 0
        var eof = false
        while true {
            if buf.count - pos < size + 1 && !eof {
                // 每读一批（约 770KB）检查一次是否已取消
                if shouldCancel() { throw CancellationError() }
                let data = try file.read(upToCount: chunk) ?? Data()
                if data.isEmpty {
                    eof = true
                } else {
                    buf.removeSubrange(0..<pos)
                    pos = 0
                    buf.append(contentsOf: data)
                }
                continue
            }
            if buf.count - pos < size { break }
            // 丢失同步：逐字节找 0x47，且下一包开头也得是 0x47（文件末尾除外）
            if buf[pos] != 0x47 || (pos + size < buf.count && buf[pos + size] != 0x47) {
                pos += 1
                continue
            }
            try packet(buf, at: pos)
            pos += size
        }
        try complete(videoPES, isVideo: true)
        try complete(audioPES, isVideo: false)
    }

    private func packet(_ b: [UInt8], at s: Int) throws {
        let b1 = b[s + 1]
        if b1 & 0x80 != 0 { return }  // transport_error_indicator
        let pusi = b1 & 0x40 != 0
        let pid = (Int(b1 & 0x1F) << 8) | Int(b[s + 2])
        let control = (b[s + 3] >> 4) & 0x03
        guard control == 1 || control == 3 else { return }  // 没有负载
        var start = s + 4
        if control == 3 { start += 1 + Int(b[s + 4]) }
        let end = s + Self.packetSize
        guard start < end else { return }
        let payload = b[start..<end]

        if pid == 0 {
            if pusi && pmtPID == nil { parsePAT(Array(payload)) }
            return
        }
        if let pmt = pmtPID, pid == pmt {
            if pusi && !pmtParsed { parsePMT(Array(payload)) }
            return
        }
        if let v = videoPID, pid == v {
            try feed(videoPES, payload, pusi: pusi, isVideo: true)
        } else if let a = audioPID, pid == a {
            try feed(audioPES, payload, pusi: pusi, isVideo: false)
        }
    }

    /// PAT：取第一个节目的 PMT PID
    private func parsePAT(_ p: [UInt8]) {
        guard !p.isEmpty else { return }
        let i = 1 + Int(p[0])
        guard i + 8 <= p.count, p[i] == 0x00 else { return }
        let sectionLength = (Int(p[i + 1] & 0x0F) << 8) | Int(p[i + 2])
        let end = min(i + 3 + sectionLength - 4, p.count)
        var j = i + 8
        while j + 4 <= end {
            let program = (Int(p[j]) << 8) | Int(p[j + 1])
            let pid = (Int(p[j + 2] & 0x1F) << 8) | Int(p[j + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            j += 4
        }
    }

    /// PMT：第一路 H.264（0x1B）/ HEVC（0x24）视频，第一路 AAC ADTS（0x0F）音频；其他（ID3 0x15 等）忽略
    private func parsePMT(_ p: [UInt8]) {
        guard !p.isEmpty else { return }
        let i = 1 + Int(p[0])
        guard i + 12 <= p.count, p[i] == 0x02 else { return }
        let sectionLength = (Int(p[i + 1] & 0x0F) << 8) | Int(p[i + 2])
        let end = min(i + 3 + sectionLength - 4, p.count)
        let programInfoLength = (Int(p[i + 10] & 0x0F) << 8) | Int(p[i + 11])
        var j = i + 12 + programInfoLength
        while j + 5 <= end {
            let type = p[j]
            let pid = (Int(p[j + 1] & 0x1F) << 8) | Int(p[j + 2])
            let infoLength = (Int(p[j + 3] & 0x0F) << 8) | Int(p[j + 4])
            if let video, videoPID == nil, type == 0x1B || type == 0x24 {
                videoPID = pid
                video.setCodec(type == 0x1B ? .h264 : .hevc)
            } else if audio != nil, audioPID == nil, type == 0x0F {
                audioPID = pid
            }
            j += 5 + infoLength
        }
        pmtParsed = true
    }

    private func feed(_ buf: PESBuffer, _ payload: ArraySlice<UInt8>, pusi: Bool, isVideo: Bool) throws {
        if pusi {
            if buf.active { try complete(buf, isVideo: isVideo) }
            buf.data.removeAll(keepingCapacity: true)
            buf.active = true
        }
        guard buf.active else { return }
        buf.data.append(contentsOf: payload)
        // 声明了长度的 PES（音频通常如此）收齐就交付，不必等下一个 PUSI
        if buf.data.count >= 6 {
            let length = (Int(buf.data[4]) << 8) | Int(buf.data[5])
            if length > 0 && buf.data.count >= 6 + length { try complete(buf, isVideo: isVideo) }
        }
    }

    private func complete(_ buf: PESBuffer, isVideo: Bool) throws {
        guard buf.active else { return }
        buf.active = false
        let d = buf.data
        guard d.count >= 9, d[0] == 0, d[1] == 0, d[2] == 1 else { return }
        let length = (Int(d[4]) << 8) | Int(d[5])
        var end = d.count
        if length > 0 { end = min(end, 6 + length) }
        let flags = d[7] >> 6
        let start = 9 + Int(d[8])
        guard start <= end else { return }
        var pts: Int64?
        var dts: Int64?
        if flags & 0x02 != 0, d.count >= 14 { pts = Self.timestamp(d, 9) }
        if flags == 0x03, d.count >= 19 { dts = Self.timestamp(d, 14) }
        let payload = d[start..<end]
        if isVideo {
            try video?.handlePES(payload, pts: pts, dts: dts, clock: clock, sink: sink)
        } else {
            try audio?.handlePES(payload, pts: pts, clock: clock, sink: sink)
        }
    }

    /// PES 头里 5 字节的 33 位时间戳
    static func timestamp(_ d: [UInt8], _ i: Int) -> Int64 {
        let a = Int64((d[i] >> 1) & 0x07) << 30
        let b = Int64(d[i + 1]) << 22
        let c = Int64(d[i + 2] >> 1) << 15
        let e = Int64(d[i + 3]) << 7
        let f = Int64(d[i + 4] >> 1)
        return a | b | c | e | f
    }
}

// MARK: - 视频

/// 视频轨：PES → 访问单元 → 长度前缀样本
final class VideoTrackBuilder {
    enum Codec { case h264, hevc }

    private(set) var codec: Codec = .h264
    var table = MP4SampleTable()
    /// 每个样本的 DTS（90kHz，已展开回绕、接好不连续点）
    private(set) var decodeTimes: [Int64] = []
    /// 每个样本的 PTS - DTS（不小于 0）
    private(set) var compositionOffsets: [Int64] = []
    /// 关键帧样本序号（从 1 开始）
    private(set) var syncSamples: [UInt32] = []
    private(set) var vps: [[UInt8]] = []
    private(set) var sps: [[UInt8]] = []
    private(set) var pps: [[UInt8]] = []
    /// 已写出样本里最小的 PTS
    private(set) var minPTS: Int64?

    private var pending: [UInt8] = []
    private var pendingPTS: Int64?
    private var pendingDTS: Int64?
    private var started = false
    private var lastRawDTS: Int64?
    private var shift: Int64 = 0
    /// DTS 跳变超过这个值视为不连续点（10 秒）
    private let maxGap: Int64 = 90_000 * 10

    var sampleCount: Int { table.count }

    func setCodec(_ c: Codec) { codec = c }

    /// 带 PTS 的 PES 开始一个新的访问单元；不带 PTS 的视为上一个访问单元的延续
    func handlePES(_ payload: ArraySlice<UInt8>, pts: Int64?, dts: Int64?, clock: TSClock, sink: MP4SampleSink) throws {
        if let pts {
            try flush(clock: clock, sink: sink)
            pending.removeAll(keepingCapacity: true)
            pendingPTS = pts
            pendingDTS = dts ?? pts
            pending.append(contentsOf: payload)
        } else if pendingPTS != nil {
            pending.append(contentsOf: payload)
        }
    }

    /// 文件读完：交付最后一个访问单元
    func finish(clock: TSClock, sink: MP4SampleSink) throws {
        try flush(clock: clock, sink: sink)
    }

    private enum NALRole { case drop, keep, parameterSet(Int) }

    private func flush(clock: TSClock, sink: MP4SampleSink) throws {
        guard let ptsRaw = pendingPTS, let dtsRaw = pendingDTS else { return }
        pendingPTS = nil
        pendingDTS = nil

        var kept: [Range<Int>] = []
        var keyframe = false
        for r in AnnexB.nalRanges(pending) {
            let role = classify(pending[r.lowerBound])
            switch role {
            case .drop:
                continue
            case .keep:
                if isKeyframe(pending[r.lowerBound]) { keyframe = true }
                kept.append(r)
            case .parameterSet(let kind):
                if !storeParameterSet(kind, Array(pending[r])) { kept.append(r) }
            }
        }
        if !started {
            // 第一个关键帧（且已拿到参数集）之前的帧无法解码，丢掉
            guard keyframe, !sps.isEmpty, !pps.isEmpty else { return }
            started = true
        }
        guard !kept.isEmpty else { return }

        // 时间戳：展开回绕 → 处理不连续点
        let ref = lastRawDTS ?? clock.reference(for: dtsRaw)
        let rawDTS = TSClock.unwrap(dtsRaw, near: ref)
        lastRawDTS = rawDTS
        let rawPTS = TSClock.unwrap(ptsRaw, near: rawDTS)
        var dts = rawDTS + shift
        if let last = decodeTimes.last {
            let diff = dts - last
            if diff <= 0 || diff > maxGap {
                var step: Int64 = 3000
                let n = decodeTimes.count
                if n >= 2 {
                    let previous = decodeTimes[n - 1] - decodeTimes[n - 2]
                    if previous > 0 { step = previous }
                }
                let fixed = last + step
                shift += fixed - dts
                dts = fixed
            }
        }
        let pts = rawPTS + shift

        var total = 0
        for r in kept { total += 4 + r.count }
        var sample: [UInt8] = []
        sample.reserveCapacity(total)
        for r in kept {
            let n = UInt32(r.count)
            sample.append(UInt8(truncatingIfNeeded: n >> 24))
            sample.append(UInt8(truncatingIfNeeded: n >> 16))
            sample.append(UInt8(truncatingIfNeeded: n >> 8))
            sample.append(UInt8(truncatingIfNeeded: n))
            sample.append(contentsOf: pending[r])
        }
        let offset = sink.offset
        try sink.write(sample)
        table.add(offset: offset, size: sample.count)
        decodeTimes.append(dts)
        compositionOffsets.append(max(0, pts - dts))
        if keyframe { syncSamples.append(UInt32(table.count)) }
        if let m = minPTS {
            if pts < m { minPTS = pts }
        } else {
            minPTS = pts
        }
    }

    private func classify(_ header: UInt8) -> NALRole {
        switch codec {
        case .h264:
            let type = Int(header & 0x1F)
            switch type {
            case 9, 12: return .drop            // AUD、填充
            case 7: return .parameterSet(1)     // SPS
            case 8: return .parameterSet(2)     // PPS
            default: return .keep
            }
        case .hevc:
            let type = Int((header >> 1) & 0x3F)
            switch type {
            case 35, 38: return .drop           // AUD、填充
            case 32: return .parameterSet(0)    // VPS
            case 33: return .parameterSet(1)    // SPS
            case 34: return .parameterSet(2)    // PPS
            default: return .keep
            }
        }
    }

    private func isKeyframe(_ header: UInt8) -> Bool {
        switch codec {
        case .h264:
            return header & 0x1F == 5
        case .hevc:
            let type = (header >> 1) & 0x3F
            return type >= 16 && type <= 21
        }
    }

    /// 收进样本描述返回 true（样本里去掉）；开始写样本后出现的新参数集返回 false（留在样本里）
    private func storeParameterSet(_ kind: Int, _ nal: [UInt8]) -> Bool {
        switch kind {
        case 0:
            if vps.contains(nal) { return true }
            if started || vps.count >= 16 { return false }
            vps.append(nal)
        case 1:
            if sps.contains(nal) { return true }
            if started || sps.count >= 31 { return false }
            sps.append(nal)
        default:
            if pps.contains(nal) { return true }
            if started || pps.count >= 255 { return false }
            pps.append(nal)
        }
        return true
    }
}

/// Annex-B 字节流工具
enum AnnexB {
    /// 按 00 00 01 起始码切出各 NAL（不含起始码，去掉末尾的 0）
    static func nalRanges(_ d: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let n = d.count
        var start = -1
        var i = 0
        while i + 2 < n {
            if d[i + 2] > 1 {
                i += 3
            } else if d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 {
                if start >= 0 { appendRange(&ranges, d, start, i) }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 { appendRange(&ranges, d, start, n) }
        return ranges
    }

    private static func appendRange(_ ranges: inout [Range<Int>], _ d: [UInt8], _ start: Int, _ end: Int) {
        var e = end
        while e > start && d[e - 1] == 0 { e -= 1 }
        if e > start { ranges.append(start..<e) }
    }

    /// 去掉防竞争字节（00 00 03 → 00 00）得到 RBSP
    static func unescape(_ d: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(d.count)
        var zeros = 0
        for b in d {
            if zeros >= 2 && b == 0x03 {
                zeros = 0
                continue
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }
}

/// 位读取（含指数哥伦布码）
struct BitReader {
    struct OutOfData: Error {}

    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bit() throws -> Int {
        let index = position >> 3
        guard index < bytes.count else { throw OutOfData() }
        let shift = 7 - (position & 7)
        position += 1
        return Int((bytes[index] >> UInt8(shift)) & 1)
    }

    mutating func bits(_ n: Int) throws -> Int {
        var v = 0
        for _ in 0..<n {
            let b = try bit()
            v = (v << 1) | b
        }
        return v
    }

    mutating func skip(_ n: Int) throws {
        guard position + n <= bytes.count * 8 else { throw OutOfData() }
        position += n
    }

    /// 无符号指数哥伦布码 ue(v)
    mutating func ue() throws -> Int {
        var zeros = 0
        while true {
            let b = try bit()
            if b == 1 { break }
            zeros += 1
            if zeros > 31 { throw OutOfData() }
        }
        if zeros == 0 { return 0 }
        let rest = try bits(zeros)
        return (1 << zeros) - 1 + rest
    }

    /// 有符号指数哥伦布码 se(v)
    mutating func se() throws -> Int {
        let k = try ue()
        return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

/// H.264 SPS 里写 avcC / tkhd 需要的字段
struct H264SPSInfo: Equatable {
    var profile: Int
    var compatibility: Int
    var level: Int
    var chromaFormat: Int
    var bitDepthLumaMinus8: Int
    var bitDepthChromaMinus8: Int
    var width: Int
    var height: Int

    /// 解析 SPS NAL（含 1 字节 NAL 头、可含防竞争字节）
    static func parse(_ nal: [UInt8]) -> H264SPSInfo? {
        let rbsp = AnnexB.unescape(nal)
        guard rbsp.count >= 4 else { return nil }
        var r = BitReader(Array(rbsp.dropFirst()))
        do {
            let profile = try r.bits(8)
            let compatibility = try r.bits(8)
            let level = try r.bits(8)
            _ = try r.ue()  // seq_parameter_set_id
            var chromaFormat = 1
            var separateColourPlane = 0
            var lumaDepth = 0
            var chromaDepth = 0
            let highProfiles: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
            if highProfiles.contains(profile) {
                chromaFormat = try r.ue()
                if chromaFormat == 3 { separateColourPlane = try r.bit() }
                lumaDepth = try r.ue()
                chromaDepth = try r.ue()
                _ = try r.bit()  // qpprime_y_zero_transform_bypass_flag
                let scalingMatrixPresent = try r.bit()
                if scalingMatrixPresent == 1 {
                    let lists = chromaFormat == 3 ? 12 : 8
                    for i in 0..<lists {
                        let present = try r.bit()
                        if present == 1 { try skipScalingList(&r, size: i < 6 ? 16 : 64) }
                    }
                }
            }
            _ = try r.ue()  // log2_max_frame_num_minus4
            let pocType = try r.ue()
            if pocType == 0 {
                _ = try r.ue()  // log2_max_pic_order_cnt_lsb_minus4
            } else if pocType == 1 {
                _ = try r.bit()  // delta_pic_order_always_zero_flag
                _ = try r.se()   // offset_for_non_ref_pic
                _ = try r.se()   // offset_for_top_to_bottom_field
                let cycle = try r.ue()
                guard cycle <= 255 else { return nil }
                for _ in 0..<cycle { _ = try r.se() }
            }
            _ = try r.ue()   // max_num_ref_frames
            _ = try r.bit()  // gaps_in_frame_num_value_allowed_flag
            let widthInMbs = try r.ue() + 1
            let heightInMapUnits = try r.ue() + 1
            let frameMbsOnly = try r.bit()
            if frameMbsOnly == 0 { _ = try r.bit() }  // mb_adaptive_frame_field_flag
            _ = try r.bit()  // direct_8x8_inference_flag
            var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0
            if try r.bit() == 1 {
                cropLeft = try r.ue()
                cropRight = try r.ue()
                cropTop = try r.ue()
                cropBottom = try r.ue()
            }
            let chromaArrayType = separateColourPlane == 1 ? 0 : chromaFormat
            var cropUnitX = 1
            var cropUnitY = 2 - frameMbsOnly
            if chromaArrayType != 0 {
                let subWidth = chromaFormat == 3 ? 1 : 2
                let subHeight = chromaFormat == 1 ? 2 : 1
                cropUnitX = subWidth
                cropUnitY = subHeight * (2 - frameMbsOnly)
            }
            let width = widthInMbs * 16 - cropUnitX * (cropLeft + cropRight)
            let height = (2 - frameMbsOnly) * heightInMapUnits * 16 - cropUnitY * (cropTop + cropBottom)
            return H264SPSInfo(profile: profile, compatibility: compatibility, level: level, chromaFormat: chromaFormat,
                               bitDepthLumaMinus8: lumaDepth, bitDepthChromaMinus8: chromaDepth,
                               width: max(0, width), height: max(0, height))
        } catch {
            return nil
        }
    }

    private static func skipScalingList(_ r: inout BitReader, size: Int) throws {
        var last = 8
        var next = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = try r.se()
                next = (last + delta + 256) % 256
            }
            if next != 0 { last = next }
        }
    }
}

/// HEVC SPS 里写 hvcC / tkhd 需要的字段
struct HEVCSPSInfo: Equatable {
    var profileSpace = 0
    var tier = 0
    var profileIdc = 1
    var compatibilityFlags: UInt32 = 0x6000_0000
    var constraintFlags: [UInt8] = [0x90, 0, 0, 0, 0, 0]
    var level = 93
    var chromaFormat = 1
    var bitDepthLumaMinus8 = 0
    var bitDepthChromaMinus8 = 0
    var width = 0
    var height = 0
    var temporalLayers = 1
    var temporalIdNested = true

    /// 解析 SPS NAL（含 2 字节 NAL 头）。profile_tier_level 解析失败返回 nil；宽高部分失败则宽高为 0
    static func parse(_ nal: [UInt8]) -> HEVCSPSInfo? {
        let rbsp = AnnexB.unescape(nal)
        guard rbsp.count >= 15 else { return nil }
        var r = BitReader(Array(rbsp.dropFirst(2)))
        var info = HEVCSPSInfo()
        var maxSubLayersMinus1 = 0
        do {
            _ = try r.bits(4)  // sps_video_parameter_set_id
            maxSubLayersMinus1 = try r.bits(3)
            info.temporalIdNested = try r.bit() == 1
            info.temporalLayers = maxSubLayersMinus1 + 1
            info.profileSpace = try r.bits(2)
            info.tier = try r.bit()
            info.profileIdc = try r.bits(5)
            let compatibility = try r.bits(32)
            info.compatibilityFlags = UInt32(truncatingIfNeeded: compatibility)
            var constraint: [UInt8] = []
            for _ in 0..<6 {
                let byte = try r.bits(8)
                constraint.append(UInt8(truncatingIfNeeded: byte))
            }
            info.constraintFlags = constraint
            info.level = try r.bits(8)
        } catch {
            return nil
        }
        do {
            var profilePresent: [Int] = []
            var levelPresent: [Int] = []
            for _ in 0..<maxSubLayersMinus1 {
                let profileFlag = try r.bit()
                let levelFlag = try r.bit()
                profilePresent.append(profileFlag)
                levelPresent.append(levelFlag)
            }
            if maxSubLayersMinus1 > 0 {
                for _ in maxSubLayersMinus1..<8 { try r.skip(2) }
            }
            for i in 0..<maxSubLayersMinus1 {
                if profilePresent[i] == 1 { try r.skip(88) }
                if levelPresent[i] == 1 { try r.skip(8) }
            }
            _ = try r.ue()  // sps_seq_parameter_set_id
            let chroma = try r.ue()
            var separateColourPlane = 0
            if chroma == 3 { separateColourPlane = try r.bit() }
            let width = try r.ue()
            let height = try r.ue()
            var left = 0, right = 0, top = 0, bottom = 0
            if try r.bit() == 1 {
                left = try r.ue()
                right = try r.ue()
                top = try r.ue()
                bottom = try r.ue()
            }
            info.chromaFormat = chroma
            info.bitDepthLumaMinus8 = try r.ue()
            info.bitDepthChromaMinus8 = try r.ue()
            var subWidth = 1
            var subHeight = 1
            if separateColourPlane == 0 {
                if chroma == 1 || chroma == 2 { subWidth = 2 }
                if chroma == 1 { subHeight = 2 }
            }
            info.width = max(0, width - subWidth * (left + right))
            info.height = max(0, height - subHeight * (top + bottom))
        } catch {
            info.width = 0
            info.height = 0
        }
        return info
    }
}

// MARK: - 音频

/// ADTS 帧头
struct ADTSHeader: Equatable {
    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    let headerLength: Int
    let frameLength: Int
    /// AAC 对象类型（profile + 1，LC = 2）
    let objectType: Int
    let frequencyIndex: Int
    let channelConfig: Int

    var sampleRate: Int { Self.sampleRates[frequencyIndex] }

    /// 2 字节 AudioSpecificConfig
    var audioSpecificConfig: [UInt8] {
        let ot = UInt8(objectType & 0x1F)
        let fi = UInt8(frequencyIndex & 0x0F)
        let ch = UInt8(channelConfig & 0x0F)
        return [(ot << 3) | (fi >> 1), ((fi & 1) << 7) | (ch << 3)]
    }

    init?(_ b: [UInt8], at i: Int) {
        guard i + 7 <= b.count, b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { return nil }
        let protectionAbsent = b[i + 1] & 0x01
        let profile = Int(b[i + 2] >> 6)
        let frequency = Int((b[i + 2] >> 2) & 0x0F)
        let channelHigh = Int(b[i + 2] & 0x01) << 2
        let channel = channelHigh | Int(b[i + 3] >> 6)
        let lengthHigh = Int(b[i + 3] & 0x03) << 11
        let length = lengthHigh | (Int(b[i + 4]) << 3) | Int(b[i + 5] >> 5)
        let header = protectionAbsent == 1 ? 7 : 9
        guard frequency < Self.sampleRates.count, length > header else { return nil }
        headerLength = header
        frameLength = length
        objectType = profile + 1
        frequencyIndex = frequency
        channelConfig = channel
    }
}

/// 音频轨：PES → ADTS 帧（可跨 PES）→ 裸 AAC 样本
final class AudioTrackBuilder {
    var table = MP4SampleTable()
    /// 第一帧的配置（采样率、声道、ASC 都取自它）
    private(set) var config: ADTSHeader?
    /// 第一帧的 PTS（90kHz，已展开回绕）
    private(set) var firstPTS: Int64?
    private var candidatePTS: Int64?
    private var lastRawPTS: Int64?
    private var buffer: [UInt8] = []

    var sampleCount: Int { table.count }

    func handlePES(_ payload: ArraySlice<UInt8>, pts: Int64?, clock: TSClock, sink: MP4SampleSink) throws {
        if let pts, firstPTS == nil {
            let ref = lastRawPTS ?? clock.reference(for: pts)
            let value = TSClock.unwrap(pts, near: ref)
            lastRawPTS = value
            if buffer.isEmpty { candidatePTS = value }
            if candidatePTS == nil { candidatePTS = value }
        }
        buffer.append(contentsOf: payload)
        var i = 0
        let n = buffer.count
        while i + 7 <= n {
            guard let header = ADTSHeader(buffer, at: i) else {
                i += 1
                continue
            }
            let end = i + header.frameLength
            if end > n { break }
            // 下一帧开头也得是 ADTS 同步字，否则视为误判的同步字
            if end + 1 < n && !(buffer[end] == 0xFF && buffer[end + 1] & 0xF6 == 0xF0) {
                i += 1
                continue
            }
            if config == nil {
                config = header
                firstPTS = candidatePTS
            }
            let offset = sink.offset
            try sink.write(buffer[(i + header.headerLength)..<end])
            table.add(offset: offset, size: header.frameLength - header.headerLength)
            i = end
        }
        if i > 0 { buffer.removeFirst(i) }
    }
}

// MARK: - moov

enum MP4Builder {
    static let movieTimescale: Int64 = 1000
    static let videoTimescale: Int64 = 90000

    struct Edit {
        var duration: Int64   // 电影时间刻度
        var mediaTime: Int64  // 媒体时间刻度，-1 表示空白
    }

    /// 一条轨道写 trak 所需的全部信息
    struct TrackPlan {
        var id: UInt32
        var isVideo: Bool
        var timescale: Int64
        var mediaDuration: Int64
        var edits: [Edit]
        var trackDuration: Int64
        var width: Int
        var height: Int
        var sampleEntry: [UInt8]
        var deltas: [UInt32]
        var compositionOffsets: [Int64]
        var syncSamples: [UInt32]?
        var table: MP4SampleTable
        /// mdhd 里的 ISO 639-2 语言代码（三个小写字母，其他值写 und）
        var language: String = "und"
    }

    static func moov(video: VideoTrackBuilder?, audio: AudioTrackBuilder?) -> [UInt8] {
        // 0 点：所有轨道里最早的显示时间
        var starts: [Int64] = []
        if let video, let p = video.minPTS { starts.append(p) }
        if let audio, let a = audio.firstPTS { starts.append(a) }
        let origin = starts.min() ?? 0

        var plans: [TrackPlan] = []
        if let video, let plan = videoPlan(video, id: UInt32(plans.count + 1), origin: origin) { plans.append(plan) }
        if let audio, let plan = audioPlan(audio, id: UInt32(plans.count + 1), origin: origin) { plans.append(plan) }
        return moov(plans: plans)
    }

    /// 按已经算好的各轨道计划写 moov（mvhd + 每条 trak）
    static func moov(plans: [TrackPlan]) -> [UInt8] {
        var w = ByteWriter()
        let moov = w.begin("moov")
        let movieDuration = plans.map(\.trackDuration).max() ?? 0
        let mvhd = w.beginFull("mvhd")
        w.u32(0)
        w.u32(0)
        w.u32(UInt32(movieTimescale))
        w.u32(UInt32(clamping: movieDuration))
        w.u32(0x0001_0000)  // rate 1.0
        w.u16(0x0100)       // volume 1.0
        w.zeros(10)
        matrix(&w)
        w.zeros(24)
        w.u32(UInt32(plans.count + 1))
        w.end(mvhd)
        for plan in plans { trak(&w, plan) }
        w.end(moov)
        return w.bytes
    }

    static func videoPlan(_ v: VideoTrackBuilder, id: UInt32, origin: Int64) -> TrackPlan? {
        let times = v.decodeTimes
        guard !times.isEmpty, let firstSPS = v.sps.first else { return nil }
        var deltas: [UInt32] = []
        deltas.reserveCapacity(times.count)
        for i in 1..<max(1, times.count) {
            deltas.append(UInt32(clamping: max(1, times[i] - times[i - 1])))
        }
        deltas.append(deltas.last ?? 3000)
        var mediaDuration: Int64 = 0
        for d in deltas { mediaDuration += Int64(d) }

        let firstDTS = times[0]
        let firstPTS = v.minPTS ?? firstDTS
        let mediaTime = max(0, firstPTS - firstDTS)
        // 显示结束时刻（媒体时间）：有 B 帧时最后显示的那帧不一定是最后解码的那帧
        let offsets = v.compositionOffsets
        var presentationEnd: Int64 = 0
        for i in times.indices {
            let end = times[i] - firstDTS + offsets[i] + Int64(deltas[i])
            if end > presentationEnd { presentationEnd = end }
        }
        let (edits, trackDuration) = makeEdits(startOffset: firstPTS - origin, mediaTime: mediaTime,
                                               mediaEnd: presentationEnd, timescale: videoTimescale)

        var width = 0
        var height = 0
        let entry: [UInt8]
        switch v.codec {
        case .h264:
            let info = H264SPSInfo.parse(firstSPS)
            width = info?.width ?? 0
            height = info?.height ?? 0
            entry = visualEntry("avc1", width: width, height: height, config: avcC(sps: v.sps, pps: v.pps, info: info))
        case .hevc:
            let info = HEVCSPSInfo.parse(firstSPS) ?? HEVCSPSInfo()
            width = info.width
            height = info.height
            entry = visualEntry("hvc1", width: width, height: height,
                                config: hvcC(vps: v.vps, sps: v.sps, pps: v.pps, info: info))
        }
        return TrackPlan(id: id, isVideo: true, timescale: videoTimescale, mediaDuration: mediaDuration, edits: edits,
                         trackDuration: trackDuration, width: width, height: height, sampleEntry: entry, deltas: deltas,
                         compositionOffsets: v.compositionOffsets, syncSamples: v.syncSamples, table: v.table)
    }

    static func audioPlan(_ a: AudioTrackBuilder, id: UInt32, origin: Int64) -> TrackPlan? {
        guard let config = a.config, a.sampleCount > 0 else { return nil }
        let rate = Int64(config.sampleRate)
        let mediaDuration = Int64(a.sampleCount) * 1024
        let start = a.firstPTS ?? origin
        let (edits, trackDuration) = makeEdits(startOffset: start - origin, mediaTime: 0,
                                               mediaEnd: mediaDuration, timescale: rate)
        let entry = audioEntry(config, esId: UInt16(clamping: Int(id)))
        let deltas = [UInt32](repeating: 1024, count: a.sampleCount)
        return TrackPlan(id: id, isVideo: false, timescale: rate, mediaDuration: mediaDuration, edits: edits,
                         trackDuration: trackDuration, width: 0, height: 0, sampleEntry: entry, deltas: deltas,
                         compositionOffsets: [], syncSamples: nil, table: a.table)
    }

    /// 编辑列表：`startOffset`（90kHz）是轨道首个显示时刻晚于 0 点的量，`mediaTime` / `mediaEnd` 是媒体时间里
    /// 首个显示时刻和显示结束时刻。前两者都为 0 时不需要 elst，返回空列表；第二个值是轨道时长（电影时间刻度）
    static func makeEdits(startOffset: Int64, mediaTime: Int64, mediaEnd: Int64, timescale: Int64) -> ([Edit], Int64) {
        let main = max(0, mediaEnd - mediaTime) * movieTimescale / timescale
        var edits: [Edit] = []
        if startOffset > 0 {
            let empty = startOffset * movieTimescale / videoTimescale
            if empty > 0 { edits.append(Edit(duration: empty, mediaTime: -1)) }
        }
        if edits.isEmpty && mediaTime == 0 { return ([], main) }
        edits.append(Edit(duration: main, mediaTime: mediaTime))
        var total: Int64 = 0
        for e in edits { total += e.duration }
        return (edits, total)
    }

    static func matrix(_ w: inout ByteWriter) {
        let values: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
        for v in values { w.u32(v) }
    }

    static func trak(_ w: inout ByteWriter, _ p: TrackPlan) {
        let trak = w.begin("trak")

        let tkhd = w.beginFull("tkhd", flags: 0x000003)
        w.u32(0)
        w.u32(0)
        w.u32(p.id)
        w.u32(0)
        w.u32(UInt32(clamping: p.trackDuration))
        w.zeros(8)
        w.u16(0)  // layer
        w.u16(0)  // alternate_group
        w.u16(p.isVideo ? 0 : 0x0100)
        w.u16(0)
        matrix(&w)
        w.u32(UInt32(clamping: p.width) << 16)
        w.u32(UInt32(clamping: p.height) << 16)
        w.end(tkhd)

        if !p.edits.isEmpty {
            let edts = w.begin("edts")
            let elst = w.beginFull("elst")
            w.u32(UInt32(p.edits.count))
            for e in p.edits {
                w.u32(UInt32(clamping: e.duration))
                w.i32(Int32(clamping: e.mediaTime))
                w.u16(1)
                w.u16(0)
            }
            w.end(elst)
            w.end(edts)
        }

        let mdia = w.begin("mdia")
        let mdhd = w.beginFull("mdhd")
        w.u32(0)
        w.u32(0)
        w.u32(UInt32(clamping: p.timescale))
        w.u32(UInt32(clamping: p.mediaDuration))
        w.u16(packedLanguage(p.language))
        w.u16(0)
        w.end(mdhd)

        let hdlr = w.beginFull("hdlr")
        w.u32(0)
        w.fourcc(p.isVideo ? "vide" : "soun")
        w.zeros(12)
        w.append(Array((p.isVideo ? "VideoHandler" : "SoundHandler").utf8))
        w.u8(0)
        w.end(hdlr)

        let minf = w.begin("minf")
        if p.isVideo {
            let vmhd = w.beginFull("vmhd", flags: 1)
            w.zeros(8)
            w.end(vmhd)
        } else {
            let smhd = w.beginFull("smhd")
            w.zeros(4)
            w.end(smhd)
        }
        let dinf = w.begin("dinf")
        let dref = w.beginFull("dref")
        w.u32(1)
        let url = w.beginFull("url ", flags: 1)
        w.end(url)
        w.end(dref)
        w.end(dinf)
        stbl(&w, p)
        w.end(minf)
        w.end(mdia)
        w.end(trak)
    }

    static func stbl(_ w: inout ByteWriter, _ p: TrackPlan) {
        let stbl = w.begin("stbl")

        let stsd = w.beginFull("stsd")
        w.u32(1)
        w.append(p.sampleEntry)
        w.end(stsd)

        // stts：相同间隔合并
        var stts: [(UInt32, UInt32)] = []
        for d in p.deltas {
            if let last = stts.last, last.1 == d {
                stts[stts.count - 1].0 += 1
            } else {
                stts.append((1, d))
            }
        }
        let sttsBox = w.beginFull("stts")
        w.u32(UInt32(stts.count))
        for e in stts {
            w.u32(e.0)
            w.u32(e.1)
        }
        w.end(sttsBox)

        // ctts：只在存在 PTS ≠ DTS 时写
        if p.compositionOffsets.contains(where: { $0 != 0 }) {
            var ctts: [(UInt32, UInt32)] = []
            for o in p.compositionOffsets {
                let v = UInt32(clamping: o)
                if let last = ctts.last, last.1 == v {
                    ctts[ctts.count - 1].0 += 1
                } else {
                    ctts.append((1, v))
                }
            }
            let cttsBox = w.beginFull("ctts")
            w.u32(UInt32(ctts.count))
            for e in ctts {
                w.u32(e.0)
                w.u32(e.1)
            }
            w.end(cttsBox)
        }

        if let sync = p.syncSamples {
            let stss = w.beginFull("stss")
            w.u32(UInt32(sync.count))
            for s in sync { w.u32(s) }
            w.end(stss)
        }

        // stsc：每块样本数变化时记一条
        var stsc: [(UInt32, UInt32)] = []
        for (i, c) in p.table.chunkCounts.enumerated() where stsc.last?.1 != c {
            stsc.append((UInt32(i + 1), c))
        }
        let stscBox = w.beginFull("stsc")
        w.u32(UInt32(stsc.count))
        for e in stsc {
            w.u32(e.0)
            w.u32(e.1)
            w.u32(1)
        }
        w.end(stscBox)

        let stsz = w.beginFull("stsz")
        w.u32(0)
        w.u32(UInt32(p.table.sizes.count))
        for s in p.table.sizes { w.u32(s) }
        w.end(stsz)

        let maxOffset = p.table.chunkOffsets.max() ?? 0
        if maxOffset > UInt64(UInt32.max) {
            let co64 = w.beginFull("co64")
            w.u32(UInt32(p.table.chunkOffsets.count))
            for o in p.table.chunkOffsets { w.u64(o) }
            w.end(co64)
        } else {
            let stco = w.beginFull("stco")
            w.u32(UInt32(p.table.chunkOffsets.count))
            for o in p.table.chunkOffsets { w.u32(UInt32(o)) }
            w.end(stco)
        }

        w.end(stbl)
    }

    static func visualEntry(_ type: String, width: Int, height: Int, config: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        let s = w.begin(type)
        w.zeros(6)
        w.u16(1)        // data_reference_index
        w.zeros(16)     // pre_defined / reserved
        w.u16(UInt16(clamping: width))
        w.u16(UInt16(clamping: height))
        w.u32(0x0048_0000)
        w.u32(0x0048_0000)
        w.u32(0)
        w.u16(1)        // frame_count
        w.zeros(32)     // compressorname
        w.u16(0x0018)   // depth
        w.u16(0xFFFF)   // pre_defined = -1
        w.append(config)
        w.end(s)
        return w.bytes
    }

    static func avcC(sps: [[UInt8]], pps: [[UInt8]], info: H264SPSInfo?) -> [UInt8] {
        var w = ByteWriter()
        let s = w.begin("avcC")
        let first = sps.first ?? []
        w.u8(1)
        w.u8(first.count > 1 ? first[1] : 66)
        w.u8(first.count > 2 ? first[2] : 0)
        w.u8(first.count > 3 ? first[3] : 30)
        w.u8(0xFF)  // lengthSizeMinusOne = 3
        let spsList = Array(sps.prefix(31))
        w.u8(0xE0 | UInt8(spsList.count))
        for x in spsList {
            w.u16(UInt16(clamping: x.count))
            w.append(x)
        }
        let ppsList = Array(pps.prefix(255))
        w.u8(UInt8(ppsList.count))
        for x in ppsList {
            w.u16(UInt16(clamping: x.count))
            w.append(x)
        }
        if let info, [100, 110, 122, 144].contains(info.profile) {
            w.u8(0xFC | UInt8(info.chromaFormat & 0x03))
            w.u8(0xF8 | UInt8(info.bitDepthLumaMinus8 & 0x07))
            w.u8(0xF8 | UInt8(info.bitDepthChromaMinus8 & 0x07))
            w.u8(0)  // numOfSequenceParameterSetExt
        }
        w.end(s)
        return w.bytes
    }

    static func hvcC(vps: [[UInt8]], sps: [[UInt8]], pps: [[UInt8]], info: HEVCSPSInfo) -> [UInt8] {
        var w = ByteWriter()
        let s = w.begin("hvcC")
        w.u8(1)
        let space = UInt8(info.profileSpace & 0x03) << 6
        let tier = UInt8(info.tier & 0x01) << 5
        let idc = UInt8(info.profileIdc & 0x1F)
        w.u8(space | tier | idc)
        w.u32(info.compatibilityFlags)
        var constraint = info.constraintFlags
        while constraint.count < 6 { constraint.append(0) }
        w.append(Array(constraint.prefix(6)))
        w.u8(UInt8(clamping: info.level))
        w.u16(0xF000)  // min_spatial_segmentation_idc = 0
        w.u8(0xFC)     // parallelismType = 0
        w.u8(0xFC | UInt8(info.chromaFormat & 0x03))
        w.u8(0xF8 | UInt8(info.bitDepthLumaMinus8 & 0x07))
        w.u8(0xF8 | UInt8(info.bitDepthChromaMinus8 & 0x07))
        w.u16(0)       // avgFrameRate
        let layers = UInt8(info.temporalLayers & 0x07) << 3
        let nested: UInt8 = info.temporalIdNested ? 0x04 : 0
        w.u8(layers | nested | 0x03)  // constantFrameRate = 0, lengthSizeMinusOne = 3
        let arrays: [(UInt8, [[UInt8]])] = [(32, vps), (33, sps), (34, pps)]
        let present = arrays.filter { !$0.1.isEmpty }
        w.u8(UInt8(present.count))
        for (type, list) in present {
            w.u8(0x80 | type)  // array_completeness = 1
            w.u16(UInt16(clamping: list.count))
            for x in list {
                w.u16(UInt16(clamping: x.count))
                w.append(x)
            }
        }
        w.end(s)
        return w.bytes
    }

    static func audioEntry(_ config: ADTSHeader, esId: UInt16) -> [UInt8] {
        var channels = config.channelConfig
        if channels == 0 { channels = 2 }
        if channels == 7 { channels = 8 }
        return audioSampleEntry("mp4a", channels: channels, sampleRate: config.sampleRate,
                                config: esds(config.audioSpecificConfig, esId: esId))
    }

    /// 通用 AudioSampleEntry（mp4a / ac-3 / ec-3 / Opus），`config` 是紧跟其后的配置盒子（esds / dac3 / dec3 / dOps）
    static func audioSampleEntry(_ type: String, channels: Int, sampleRate: Int, config: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        let s = w.begin(type)
        w.zeros(6)
        w.u16(1)  // data_reference_index
        w.zeros(8)
        w.u16(UInt16(clamping: channels))
        w.u16(16)  // samplesize
        w.u16(0)
        w.u16(0)
        w.u32(sampleRate > 0 && sampleRate <= 0xFFFF ? UInt32(sampleRate) << 16 : 0)
        w.append(config)
        w.end(s)
        return w.bytes
    }

    /// 把一段现成的负载包成盒子
    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        let s = w.begin(type)
        w.append(payload)
        w.end(s)
        return w.bytes
    }

    /// ISO 639-2 三字母代码打包成 mdhd 的 15 位语言字段，不合法时为 und
    static func packedLanguage(_ code: String) -> UInt16 {
        let c = Array(code.lowercased().utf8)
        guard c.count == 3, c.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return 0x55C4 }
        return (UInt16(c[0] - 0x60) << 10) | (UInt16(c[1] - 0x60) << 5) | UInt16(c[2] - 0x60)
    }

    /// `objectType`：0x40 = AAC（ISO/IEC 14496-3），0x6B = MP3（ISO/IEC 11172-3）；`asc` 为空时不写 DecoderSpecificInfo
    static func esds(_ asc: [UInt8], esId: UInt16, objectType: UInt8 = 0x40) -> [UInt8] {
        var w = ByteWriter()
        let s = w.beginFull("esds")
        let decoderSpecific = asc.isEmpty ? 0 : 2 + asc.count
        let decoderConfig = 13 + decoderSpecific
        let es = 3 + (2 + decoderConfig) + 3
        w.u8(0x03)  // ES_Descriptor
        w.u8(UInt8(clamping: es))
        w.u16(esId)
        w.u8(0)
        w.u8(0x04)  // DecoderConfigDescriptor
        w.u8(UInt8(clamping: decoderConfig))
        w.u8(objectType)
        w.u8(0x15)  // streamType = audio(5) << 2 | upStream 0 | reserved 1
        w.u24(0)    // bufferSizeDB
        w.u32(0)    // maxBitrate
        w.u32(0)    // avgBitrate
        if !asc.isEmpty {
            w.u8(0x05)  // DecoderSpecificInfo
            w.u8(UInt8(clamping: asc.count))
            w.append(asc)
        }
        w.u8(0x06)  // SLConfigDescriptor
        w.u8(1)
        w.u8(0x02)
        w.end(s)
        return w.bytes
    }
}
