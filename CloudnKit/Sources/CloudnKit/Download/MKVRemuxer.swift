// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Matroska / WebM（.mkv）→ MP4 无损转封装（不重新编码，纯 Swift，Linux / iOS / macOS 通用）。
///
/// 系统播放器不认 MKV，这里把其中一路视频和一路音频原样搬进标准 MP4，文字字幕转成 SRT 交给调用方：
/// - 流式解析 EBML（FileHandle + 1MB 缓冲，不整体读入），支持未知大小的 Segment / Cluster（直播录制的 mkv）、
///   Void / CRC-32 元素；SeekHead 只在 Tracks 出现在第一个 Cluster 之后时用来找 Tracks；Cues / Tags 等跳过；
///   数据损坏时往后找下一个 Cluster 继续，文件被截断时保留已读到的部分。
/// - 视频：V_MPEG4/ISO/AVC（CodecPrivate 即 avcC）→ avc1，V_MPEGH/ISO/HEVC（CodecPrivate 即 hvcC）→ hvc1；
///   MKV 里的帧本来就是长度前缀格式，原样写入。MKV 只记显示时间（PTS），解码顺序就是块顺序：
///   把全部 PTS 排序得到 DTS 序列，再整体前移到 DTS ≤ PTS，差值写 ctts；首帧 PTS ≠ DTS 时用 elst 跳过。
/// - 音频：A_AAC（CodecPrivate 即 AudioSpecificConfig，老式无 CodecPrivate 的按采样率 / 声道合成）、A_AC3（ac-3 + dac3）、
///   A_EAC3（ec-3 + dec3）、A_MPEG/L3（mp4a，objectTypeIndication 0x6B）、A_OPUS（Opus + dOps）。
///   每帧时长按编码规则算（AAC 1024、AC-3 1536、E-AC-3 / MP3 / Opus 解析帧头），样本连续排列。
/// - 支持 SimpleBlock 与 BlockGroup（BlockDuration、ReferenceBlock 判断关键帧），Xiph / 固定大小 / EBML 三种 lacing，
///   ContentEncoding 的头部剥离（ContentCompAlgo 3）会把剥掉的前缀补回每一帧；zlib 等压缩 / 加密的轨道跳过。
/// - 时间轴：所有时间换算到 90kHz，以视频、音频里最早的显示时间为 0 点，晚开始的轨道前面加空白编辑（同 TSRemuxer）。
/// - 字幕：S_TEXT/UTF8（及 WEBVTT）直接用文字，S_TEXT/ASS|SSA 去掉前 8 个字段和 {\...} 覆盖标签，转成 SRT；
///   图片字幕（PGS / VobSub）跳过。
/// - 内存里只保留样本表和每帧的 PTS（每帧十几字节），样本数据边读边写进 mdat。
///
/// 局限：一个视频 + 一个音频；MKV 里有视频但编码不支持（VP9 / AV1 等）时直接报错，而不是输出只有声音的 MP4；
/// E-AC-3 的从属子流（7.1）不写进 dec3；Opus 的 pre-skip 不写 elst。
public enum MKVRemuxer {
    /// 一条转成 SRT 的文字字幕轨
    public struct Subtitle: Sendable {
        /// MKV 里的语言代码（Language，没写时按规范默认为 eng；有 LanguageBCP47 时用它），可能为空
        public var language: String
        /// 轨道名（Name），可能为空
        public var name: String
        /// SRT 全文
        public var srt: String
    }

    public struct Result: Sendable {
        /// 文字字幕轨（S_TEXT/UTF8、S_TEXT/ASS|SSA 转成 SRT 文本）
        public var subtitles: [Subtitle]
        /// 被跳过的轨道说明（如「音频 DTS 不支持，已跳过」），给用户看
        public var skipped: [String]
    }

    /// 把 mkv 转封装到 output（MP4）。progress 回调 0...1（按已读字节比例，最多每 1% 一次），可为 nil。
    /// 抛出的错误用 TransferError（同 TSRemuxer）。
    public static func remux(_ input: URL, to output: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> Result {
        let reader: MKVReader
        do {
            reader = try MKVReader(url: input)
        } catch {
            throw TransferError("无法打开 MKV 文件")
        }
        defer { reader.close() }
        do {
            try reader.readHeaders()
        } catch {
            throw MKVReader.describe(error)
        }
        let selection = try MKVSelection(tracks: reader.tracks)

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
        let job = MKVRemuxJob(selection: selection, timecodeScale: reader.timecodeScale, sink: sink)
        if let progress { reader.onProgress = { progress($0) } }
        try reader.readClusters(wanted: job.wanted) { try job.handle($0) }
        let result = try job.finish()
        succeeded = true
        progress?(1)
        return result
    }

    /// 只读头部判断这个文件能否转（有可用的视频或音频轨），不能时返回原因；用于界面上决定是否显示「转换」按钮
    public static func check(_ input: URL) -> String? {
        do {
            let reader = try MKVReader(url: input)
            defer { reader.close() }
            do {
                try reader.readHeaders()
            } catch {
                throw MKVReader.describe(error)
            }
            _ = try MKVSelection(tracks: reader.tracks)
            return nil
        } catch let error as TransferError {
            return error.message
        } catch {
            return "无法打开 MKV 文件"
        }
    }
}

// MARK: - EBML 流式读取

enum EBMLError: Error {
    case endOfFile
    case invalid
    case notMatroska
    case noTracks
}

/// EBML 元素头
struct EBMLElement {
    let id: UInt32
    /// nil 表示未知大小
    let size: UInt64?
    let headerStart: UInt64
    let dataStart: UInt64

    var end: UInt64? { size.map { dataStart + $0 } }
}

/// 带缓冲的顺序读取；支持跳过和回退（缓冲区内回退不重新读盘）
final class EBMLStream {
    private let file: FileHandle
    let length: UInt64
    private var buffer: [UInt8] = []
    /// buffer[0] 的文件偏移；文件指针始终位于 start + buffer.count
    private var start: UInt64 = 0
    private var index = 0
    private static let chunk = 1 << 20

    init(url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
        length = try file.seekToEnd()
        try file.seek(toOffset: 0)
    }

    func close() { try? file.close() }

    var position: UInt64 { start + UInt64(index) }

    private var available: Int { buffer.count - index }

    /// 确保缓冲区里至少还有 n 个字节，文件不够时抛 endOfFile
    private func fill(_ n: Int) throws {
        if available >= n { return }
        if index > 0 {
            buffer.removeSubrange(0..<index)
            start += UInt64(index)
            index = 0
        }
        while buffer.count < n {
            let want = max(Self.chunk, n - buffer.count)
            guard let data = try file.read(upToCount: want), !data.isEmpty else { throw EBMLError.endOfFile }
            buffer.append(contentsOf: data)
        }
    }

    func byte() throws -> UInt8 {
        try fill(1)
        let b = buffer[index]
        index += 1
        return b
    }

    func bytes(_ n: Int) throws -> [UInt8] {
        guard n > 0 else { return [] }
        try fill(n)
        let out = Array(buffer[index..<(index + n)])
        index += n
        return out
    }

    func skip(_ n: UInt64) throws {
        if n <= UInt64(available) {
            index += Int(n)
        } else {
            try seek(to: position + n)
        }
    }

    func seek(to target: UInt64) throws {
        if target >= start && target <= start + UInt64(buffer.count) {
            index = Int(target - start)
            return
        }
        buffer.removeAll(keepingCapacity: true)
        start = target
        index = 0
        try file.seek(toOffset: min(target, length))
    }

    /// VINT 第一个字节里去掉长度标记后的掩码
    static func vintMask(_ length: Int) -> UInt8 {
        length >= 8 ? 0 : UInt8(0xFF) >> UInt8(length)
    }

    /// 元素 ID（保留长度标记位），1~4 字节
    func readID() throws -> UInt32 {
        let first = try byte()
        let length = first.leadingZeroBitCount + 1
        guard first != 0, length <= 4 else { throw EBMLError.invalid }
        var v = UInt32(first)
        for _ in 1..<length {
            let b = try byte()
            v = (v << 8) | UInt32(b)
        }
        return v
    }

    /// 元素大小，1~8 字节；值位全为 1 表示未知大小，返回 nil
    func readSize() throws -> UInt64? {
        let first = try byte()
        guard first != 0 else { throw EBMLError.invalid }
        let length = first.leadingZeroBitCount + 1
        let mask = Self.vintMask(length)
        var v = UInt64(first & mask)
        var allOnes = (first & mask) == mask
        for _ in 1..<length {
            let b = try byte()
            v = (v << 8) | UInt64(b)
            if b != 0xFF { allOnes = false }
        }
        return allOnes ? nil : v
    }

    func readElement() throws -> EBMLElement {
        let headerStart = position
        let id = try readID()
        let size = try readSize()
        return EBMLElement(id: id, size: size, headerStart: headerStart, dataStart: position)
    }

    func readUInt(_ size: UInt64) throws -> UInt64 {
        guard size <= 8 else {
            try skip(size)
            return 0
        }
        var v: UInt64 = 0
        for b in try bytes(Int(size)) { v = (v << 8) | UInt64(b) }
        return v
    }

    func readFloat(_ size: UInt64) throws -> Double {
        switch size {
        case 4:
            let v = try readUInt(4)
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: v)))
        case 8:
            let v = try readUInt(8)
            return Double(bitPattern: v)
        default:
            try skip(size)
            return 0
        }
    }

    func readBinary(_ size: UInt64) throws -> [UInt8] {
        guard size <= 16 << 20 else { throw EBMLError.invalid }
        return try bytes(Int(size))
    }

    func readString(_ size: UInt64) throws -> String {
        var b = try readBinary(size)
        if let zero = b.firstIndex(of: 0) { b.removeSubrange(zero...) }
        return String(decoding: b, as: UTF8.self)
    }

    /// 数据损坏时往后找下一个 Cluster 的 ID，找到时停在 ID 开头；到文件尾返回 false
    func resyncToCluster() throws -> Bool {
        var window: UInt32 = 0
        while true {
            let b: UInt8
            do {
                b = try byte()
            } catch EBMLError.endOfFile {
                return false
            }
            window = (window << 8) | UInt32(b)
            if window == MKVID.cluster {
                try seek(to: position - 4)
                return true
            }
        }
    }
}

/// 用到的 Matroska 元素 ID
enum MKVID {
    static let ebml: UInt32 = 0x1A45_DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x1853_8067
    static let seekHead: UInt32 = 0x114D_9B74
    static let seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549_A966
    static let timecodeScale: UInt32 = 0x2AD7B1
    static let tracks: UInt32 = 0x1654_AE6B
    static let cluster: UInt32 = 0x1F43_B675
    static let cues: UInt32 = 0x1C53_BB6B
    static let attachments: UInt32 = 0x1941_A469
    static let chapters: UInt32 = 0x1043_A770
    static let tags: UInt32 = 0x1254_C367

    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagEnabled: UInt32 = 0xB9
    static let flagDefault: UInt32 = 0x88
    static let defaultDuration: UInt32 = 0x23E383
    static let name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentEncodingType: UInt32 = 0x5033
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255

    static let timecode: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let referenceBlock: UInt32 = 0xFB

    /// Segment 的直接子元素（以及 EBML 头 / Segment 本身）：未知大小的 Cluster 遇到它们就结束
    static func isTopLevel(_ id: UInt32) -> Bool {
        switch id {
        case cluster, cues, tags, chapters, attachments, seekHead, info, tracks, ebml, segment: return true
        default: return false
        }
    }
}

/// 一条 TrackEntry
struct MKVTrack {
    var number: UInt64 = 0
    /// 1 视频、2 音频、17 字幕
    var type: UInt64 = 0
    var codecID = ""
    var codecPrivate: [UInt8] = []
    var name = ""
    var language = "eng"
    var languageBCP47 = ""
    var isEnabled = true
    var isDefault = true
    /// 纳秒，0 表示没写
    var defaultDuration: UInt64 = 0
    var pixelWidth = 0
    var pixelHeight = 0
    var sampleRate: Double = 8000
    var outputSampleRate: Double = 0
    var channels = 1
    /// 头部剥离压缩剥掉的前缀，每帧前面补回
    var framePrefix: [UInt8] = []
    /// 不支持的内容编码（zlib 压缩、加密等）说明
    var unsupportedEncoding: String?

    var displayLanguage: String { languageBCP47.isEmpty ? language : languageBCP47 }
}

/// 一个 SimpleBlock / Block（只读选中轨道的数据）
struct MKVBlock {
    var track: UInt64
    /// 绝对时间，TimecodeScale 单位
    var timecode: Int64
    var keyframe: Bool
    /// BlockDuration，TimecodeScale 单位
    var duration: UInt64?
    /// 块头之后的数据（含 lacing 头）
    var data: [UInt8]
    /// 0 无、1 Xiph、2 固定大小、3 EBML
    var lacing: UInt8
}

/// Matroska 解析：先读头部（EBML 头、Info、Tracks），再顺序读 Cluster
final class MKVReader {
    let stream: EBMLStream
    private(set) var tracks: [MKVTrack] = []
    /// 每个时间单位的纳秒数
    private(set) var timecodeScale: Int64 = 1_000_000
    /// 读 Cluster 时按字节比例回调，最多每 1% 一次
    var onProgress: ((Double) -> Void)?
    private var lastPercent = -1
    private var segmentStart: UInt64 = 0
    private var segmentEnd: UInt64 = .max
    private var tracksPosition: UInt64?
    private var hasTracks = false

    init(url: URL) throws {
        stream = try EBMLStream(url: url)
    }

    func close() { stream.close() }

    static func describe(_ error: Error) -> TransferError {
        if let e = error as? TransferError { return e }
        switch error as? EBMLError {
        case .notMatroska?: return TransferError("不是有效的 MKV 文件")
        case .endOfFile?: return TransferError("MKV 文件不完整，读不到轨道信息")
        case .noTracks?: return TransferError("MKV 里没有轨道信息")
        case .invalid?: return TransferError("MKV 文件已损坏")
        case nil: return TransferError("读取 MKV 失败：\(error.localizedDescription)")
        }
    }

    /// 读 EBML 头和 Segment 开头的元数据，停在第一个 Cluster 之前（或 Segment 结束）
    func readHeaders() throws {
        guard let header = try? stream.readElement(), header.id == MKVID.ebml, let headerSize = header.size else {
            throw EBMLError.notMatroska
        }
        let headerEnd = header.dataStart + headerSize
        var docType = "matroska"
        while stream.position < headerEnd {
            let e = try stream.readElement()
            guard let size = e.size else { throw EBMLError.notMatroska }
            if e.id == MKVID.docType {
                docType = try stream.readString(size)
            } else {
                try stream.skip(size)
            }
        }
        guard docType == "matroska" || docType == "webm" else { throw EBMLError.notMatroska }
        try stream.seek(to: headerEnd)

        while true {
            let e = try stream.readElement()
            if e.id == MKVID.segment {
                segmentStart = e.dataStart
                segmentEnd = e.end ?? .max
                break
            }
            guard let size = e.size else { throw EBMLError.invalid }
            try stream.skip(size)
        }

        while stream.position < segmentEnd {
            let e: EBMLElement
            do {
                e = try stream.readElement()
            } catch EBMLError.endOfFile {
                break
            }
            if e.id == MKVID.cluster {
                if !hasTracks, let p = tracksPosition {
                    try stream.seek(to: segmentStart + p)
                    let t = try stream.readElement()
                    if t.id == MKVID.tracks, let size = t.size { try parseTracks(end: t.dataStart + size) }
                }
                try stream.seek(to: e.headerStart)
                break
            }
            // 未知大小的其他元素当作透明容器，继续往里读
            guard let size = e.size else { continue }
            let end = e.dataStart + size
            switch e.id {
            case MKVID.info: try parseInfo(end: end)
            case MKVID.tracks: try parseTracks(end: end)
            case MKVID.seekHead: try parseSeekHead(end: end)
            default: break
            }
            try stream.seek(to: end)
        }
        guard hasTracks else { throw EBMLError.noTracks }
    }

    private func parseInfo(end: UInt64) throws {
        while stream.position < end {
            let e = try stream.readElement()
            guard let size = e.size else { throw EBMLError.invalid }
            if e.id == MKVID.timecodeScale {
                let v = try stream.readUInt(size)
                if v > 0 && v <= 1_000_000_000 { timecodeScale = Int64(v) }
            } else {
                try stream.skip(size)
            }
        }
    }

    private func parseSeekHead(end: UInt64) throws {
        while stream.position < end {
            let e = try stream.readElement()
            guard let size = e.size else { throw EBMLError.invalid }
            guard e.id == MKVID.seek else {
                try stream.skip(size)
                continue
            }
            let seekEnd = e.dataStart + size
            var id: UInt32 = 0
            var position: UInt64?
            while stream.position < seekEnd {
                let c = try stream.readElement()
                guard let s = c.size else { throw EBMLError.invalid }
                if c.id == MKVID.seekID {
                    let v = try stream.readUInt(s)
                    id = UInt32(truncatingIfNeeded: v)
                } else if c.id == MKVID.seekPosition {
                    position = try stream.readUInt(s)
                } else {
                    try stream.skip(s)
                }
            }
            if id == MKVID.tracks, let position, tracksPosition == nil { tracksPosition = position }
        }
    }

    private func parseTracks(end: UInt64) throws {
        hasTracks = true
        while stream.position < end {
            let e = try stream.readElement()
            guard let size = e.size else { throw EBMLError.invalid }
            if e.id == MKVID.trackEntry {
                let track = try parseTrackEntry(end: e.dataStart + size)
                if track.number > 0 { tracks.append(track) }
            } else {
                try stream.skip(size)
            }
        }
    }

    private func parseTrackEntry(end: UInt64) throws -> MKVTrack {
        var t = MKVTrack()
        while stream.position < end {
            let e = try stream.readElement()
            guard let size = e.size else { throw EBMLError.invalid }
            let elementEnd = e.dataStart + size
            switch e.id {
            case MKVID.trackNumber: t.number = try stream.readUInt(size)
            case MKVID.trackType: t.type = try stream.readUInt(size)
            case MKVID.flagEnabled: t.isEnabled = try stream.readUInt(size) != 0
            case MKVID.flagDefault: t.isDefault = try stream.readUInt(size) != 0
            case MKVID.defaultDuration: t.defaultDuration = try stream.readUInt(size)
            case MKVID.name: t.name = try stream.readString(size)
            case MKVID.language: t.language = try stream.readString(size)
            case MKVID.languageBCP47: t.languageBCP47 = try stream.readString(size)
            case MKVID.codecID: t.codecID = try stream.readString(size)
            case MKVID.codecPrivate: t.codecPrivate = try stream.readBinary(size)
            case MKVID.video:
                while stream.position < elementEnd {
                    let c = try stream.readElement()
                    guard let s = c.size else { throw EBMLError.invalid }
                    switch c.id {
                    case MKVID.pixelWidth: t.pixelWidth = Int(clamping: try stream.readUInt(s))
                    case MKVID.pixelHeight: t.pixelHeight = Int(clamping: try stream.readUInt(s))
                    default: try stream.skip(s)
                    }
                }
            case MKVID.audio:
                while stream.position < elementEnd {
                    let c = try stream.readElement()
                    guard let s = c.size else { throw EBMLError.invalid }
                    switch c.id {
                    case MKVID.samplingFrequency: t.sampleRate = try stream.readFloat(s)
                    case MKVID.outputSamplingFrequency: t.outputSampleRate = try stream.readFloat(s)
                    case MKVID.channels: t.channels = Int(clamping: try stream.readUInt(s))
                    default: try stream.skip(s)
                    }
                }
            case MKVID.contentEncodings:
                try parseContentEncodings(&t, end: elementEnd)
            default:
                try stream.skip(size)
            }
            try stream.seek(to: elementEnd)
        }
        return t
    }

    private func parseContentEncodings(_ t: inout MKVTrack, end: UInt64) throws {
        while stream.position < end {
            let e = try stream.readElement()
            guard let size = e.size else { throw EBMLError.invalid }
            let encodingEnd = e.dataStart + size
            guard e.id == MKVID.contentEncoding else {
                try stream.skip(size)
                continue
            }
            var scope: UInt64 = 1
            var type: UInt64 = 0
            var algo: UInt64 = 0
            var settings: [UInt8] = []
            while stream.position < encodingEnd {
                let c = try stream.readElement()
                guard let s = c.size else { throw EBMLError.invalid }
                switch c.id {
                case MKVID.contentEncodingScope: scope = try stream.readUInt(s)
                case MKVID.contentEncodingType: type = try stream.readUInt(s)
                case MKVID.contentCompression:
                    let compressionEnd = c.dataStart + s
                    while stream.position < compressionEnd {
                        let d = try stream.readElement()
                        guard let ds = d.size else { throw EBMLError.invalid }
                        switch d.id {
                        case MKVID.contentCompAlgo: algo = try stream.readUInt(ds)
                        case MKVID.contentCompSettings: settings = try stream.readBinary(ds)
                        default: try stream.skip(ds)
                        }
                    }
                default:
                    try stream.skip(s)
                }
            }
            if type != 0 {
                t.unsupportedEncoding = "已加密"
            } else if algo == 3 {
                if scope & 1 != 0 { t.framePrefix = settings + t.framePrefix }
                if scope & 2 != 0 { t.codecPrivate = settings + t.codecPrivate }
            } else {
                let names: [UInt64: String] = [0: "zlib", 1: "bzlib", 2: "LZO"]
                t.unsupportedEncoding = "使用了 \(names[algo] ?? "未知") 压缩"
            }
        }
    }

    /// 从当前位置读到 Segment 结束，把 `wanted` 轨道的块交给 `deliver`；文件截断时保留已读部分
    func readClusters(wanted: Set<UInt64>, deliver: (MKVBlock) throws -> Void) throws {
        while stream.position < segmentEnd {
            do {
                let e = try stream.readElement()
                if e.id == MKVID.cluster {
                    try readCluster(e, wanted: wanted, deliver: deliver)
                } else if let size = e.size {
                    try stream.skip(size)
                }
                // 未知大小的其他元素：当作透明容器继续往里读
                reportProgress()
            } catch EBMLError.endOfFile {
                break
            } catch EBMLError.invalid {
                if try !stream.resyncToCluster() { break }
            }
        }
    }

    private func reportProgress() {
        guard let onProgress, stream.length > 0 else { return }
        let percent = Int(min(100, stream.position * 100 / stream.length))
        if percent > lastPercent {
            lastPercent = percent
            onProgress(Double(percent) / 100)
        }
    }

    private func readCluster(_ cluster: EBMLElement, wanted: Set<UInt64>, deliver: (MKVBlock) throws -> Void) throws {
        let end = cluster.end ?? segmentEnd
        var clusterTime: Int64 = 0
        while stream.position < end {
            let e = try stream.readElement()
            if cluster.size == nil && MKVID.isTopLevel(e.id) {
                // 未知大小的 Cluster 到此结束，把这个元素留给外层
                try stream.seek(to: e.headerStart)
                return
            }
            guard let size = e.size else { throw EBMLError.invalid }
            switch e.id {
            case MKVID.timecode:
                let v = try stream.readUInt(size)
                clusterTime = Int64(clamping: v)
            case MKVID.simpleBlock:
                if let block = try readBlock(size: size, clusterTime: clusterTime, wanted: wanted, simple: true) {
                    try deliver(block)
                }
            case MKVID.blockGroup:
                try readBlockGroup(end: e.dataStart + size, clusterTime: clusterTime, wanted: wanted, deliver: deliver)
            default:
                try stream.skip(size)
            }
            reportProgress()
        }
    }

    private func readBlockGroup(end: UInt64, clusterTime: Int64, wanted: Set<UInt64>,
                                deliver: (MKVBlock) throws -> Void) throws {
        var block: MKVBlock?
        var duration: UInt64?
        var referenced = false
        while stream.position < end {
            let e = try stream.readElement()
            guard let size = e.size else { throw EBMLError.invalid }
            switch e.id {
            case MKVID.block:
                block = try readBlock(size: size, clusterTime: clusterTime, wanted: wanted, simple: false)
            case MKVID.blockDuration:
                duration = try stream.readUInt(size)
            case MKVID.referenceBlock:
                referenced = true
                try stream.skip(size)
            default:
                try stream.skip(size)
            }
        }
        guard var b = block else { return }
        b.keyframe = !referenced
        b.duration = duration
        try deliver(b)
    }

    /// 读块头；不需要的轨道直接跳过数据返回 nil
    private func readBlock(size: UInt64, clusterTime: Int64, wanted: Set<UInt64>, simple: Bool) throws -> MKVBlock? {
        let first = try stream.byte()
        let n = first.leadingZeroBitCount + 1
        guard first != 0, n <= 8, UInt64(n + 3) <= size else { throw EBMLError.invalid }
        var track = UInt64(first & EBMLStream.vintMask(n))
        for _ in 1..<n {
            let b = try stream.byte()
            track = (track << 8) | UInt64(b)
        }
        let hi = try stream.byte()
        let lo = try stream.byte()
        let relative = Int16(bitPattern: (UInt16(hi) << 8) | UInt16(lo))
        let flags = try stream.byte()
        let rest = size - UInt64(n + 3)
        guard wanted.contains(track) else {
            try stream.skip(rest)
            return nil
        }
        guard rest <= 256 << 20 else { throw EBMLError.invalid }
        let data = try stream.bytes(Int(rest))
        return MKVBlock(track: track, timecode: clusterTime + Int64(relative), keyframe: simple ? flags & 0x80 != 0 : true,
                        duration: nil, data: data, lacing: (flags >> 1) & 0x03)
    }

    /// 按 lacing 切出各帧在 `data` 里的范围；数据不对返回 nil
    static func frames(_ data: [UInt8], lacing: UInt8) -> [Range<Int>]? {
        if lacing == 0 { return [0..<data.count] }
        guard !data.isEmpty else { return nil }
        let count = Int(data[0]) + 1
        var i = 1
        var sizes: [Int] = []
        switch lacing {
        case 1:  // Xiph：每个大小是若干个 255 加一个小于 255 的字节
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard i < data.count else { return nil }
                    let b = Int(data[i])
                    i += 1
                    size += b
                    if b < 255 { break }
                }
                sizes.append(size)
            }
        case 3:  // EBML：第一个是无符号 VINT，之后是与前一个的有符号差值
            guard let (firstSize, length) = readVINT(data, at: i) else { return nil }
            i += length
            var last = Int(firstSize)
            if count > 1 { sizes.append(last) }
            if count > 2 {
                for _ in 0..<(count - 2) {
                    guard let (raw, len) = readVINT(data, at: i) else { return nil }
                    i += len
                    let bias = (Int64(1) << (7 * len - 1)) - 1
                    last += Int(Int64(raw) - bias)
                    guard last >= 0 else { return nil }
                    sizes.append(last)
                }
            }
        default:  // 固定大小
            let total = data.count - i
            guard total >= 0, total % count == 0 else { return nil }
            sizes = [Int](repeating: total / count, count: count - 1)
        }
        var ranges: [Range<Int>] = []
        var offset = i
        for size in sizes {
            guard offset + size <= data.count else { return nil }
            ranges.append(offset..<(offset + size))
            offset += size
        }
        ranges.append(offset..<data.count)
        return ranges
    }

    /// 数组里的 VINT（去掉长度标记），返回值和长度
    static func readVINT(_ d: [UInt8], at i: Int) -> (UInt64, Int)? {
        guard i < d.count, d[i] != 0 else { return nil }
        let length = d[i].leadingZeroBitCount + 1
        guard length <= 8, i + length <= d.count else { return nil }
        var v = UInt64(d[i] & EBMLStream.vintMask(length))
        for k in 1..<length { v = (v << 8) | UInt64(d[i + k]) }
        return (v, length)
    }
}

// MARK: - 轨道选择

enum MKVAudioCodec {
    case aac(config: [UInt8])
    case ac3
    case eac3
    case mp3
    case opus(head: [UInt8])
}

/// 选出要转的一路视频、一路音频和文字字幕，其余写进 skipped
struct MKVSelection {
    var video: (track: MKVTrack, codec: VideoTrackBuilder.Codec)?
    var audio: (track: MKVTrack, codec: MKVAudioCodec)?
    var subtitles: [(track: MKVTrack, ass: Bool)] = []
    var skipped: [String] = []

    init(tracks: [MKVTrack]) throws {
        let enabled = tracks.filter(\.isEnabled)

        // 视频
        var videos: [(MKVTrack, VideoTrackBuilder.Codec)] = []
        var badVideo: [(MKVTrack, String)] = []
        for t in enabled where t.type == 1 {
            switch Self.videoCodec(t) {
            case .success(let codec): videos.append((t, codec))
            case .failure(let reason): badVideo.append((t, reason.message))
            }
        }
        if let chosen = videos.first(where: { $0.0.isDefault }) ?? videos.first {
            video = (chosen.0, chosen.1)
            for (_, reason) in badVideo { skipped.append("\(reason)，已跳过") }
            let extra = videos.count - 1
            if extra > 0 { skipped.append("另有 \(extra) 条视频轨已跳过（MP4 只保留一条）") }
        } else if let reason = badVideo.first?.1 {
            throw TransferError("\(reason)，无法转为 MP4，请用 VLC 等应用打开")
        }

        // 音频
        var audios: [(MKVTrack, MKVAudioCodec)] = []
        var badAudio: [(MKVTrack, String)] = []
        for t in enabled where t.type == 2 {
            switch Self.audioCodec(t) {
            case .success(let codec): audios.append((t, codec))
            case .failure(let reason): badAudio.append((t, reason.message))
            }
        }
        if let chosen = audios.first(where: { $0.0.isDefault }) ?? audios.first {
            audio = (chosen.0, chosen.1)
            for (t, _) in audios where t.number != chosen.0.number {
                skipped.append("音轨 \(Self.codecName(t.codecID))\(Self.label(t)) 已跳过（MP4 只保留一条音轨）")
            }
        }
        for (_, reason) in badAudio { skipped.append("\(reason)，已跳过") }

        if video == nil && audio == nil {
            if let reason = badAudio.first?.1 {
                throw TransferError("\(reason)，无法转为 MP4，请用 VLC 等应用打开")
            }
            throw TransferError("MKV 里没有音视频轨")
        }

        // 字幕
        for t in enabled where t.type == 17 {
            let id = t.codecID
            let name = Self.codecName(id)
            if let encoding = t.unsupportedEncoding {
                skipped.append("字幕 \(name)\(Self.label(t)) \(encoding)，已跳过")
            } else if ["S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/WEBVTT"].contains(id) {
                subtitles.append((t, false))
            } else if ["S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA"].contains(id) {
                subtitles.append((t, true))
            } else if ["S_HDMV/PGS", "S_VOBSUB", "S_DVBSUB", "S_IMAGE/BMP"].contains(id) {
                skipped.append("字幕 \(name)\(Self.label(t)) 是图片字幕，无法转换，已跳过")
            } else {
                skipped.append("字幕格式 \(name)\(Self.label(t)) 不支持，已跳过")
            }
        }
    }

    static func videoCodec(_ t: MKVTrack) -> Swift.Result<VideoTrackBuilder.Codec, TransferError> {
        let name = codecName(t.codecID)
        if let encoding = t.unsupportedEncoding {
            return .failure(TransferError("视频 \(name)\(label(t)) \(encoding)"))
        }
        let p = t.codecPrivate
        switch t.codecID {
        case "V_MPEG4/ISO/AVC":
            guard p.count >= 7, p[0] == 1 else { return .failure(TransferError("视频 H.264 缺少 avcC 配置")) }
            return .success(.h264)
        case "V_MPEGH/ISO/HEVC":
            guard p.count >= 23, p[0] == 1 else { return .failure(TransferError("视频 HEVC 缺少 hvcC 配置")) }
            return .success(.hevc)
        default:
            return .failure(TransferError("视频编码 \(name)"))
        }
    }

    static func audioCodec(_ t: MKVTrack) -> Swift.Result<MKVAudioCodec, TransferError> {
        let id = t.codecID
        let name = codecName(id)
        if let encoding = t.unsupportedEncoding {
            return .failure(TransferError("音频 \(name)\(label(t)) \(encoding)"))
        }
        if id.hasPrefix("A_AAC") {
            if !t.codecPrivate.isEmpty {
                guard t.codecPrivate.count <= 64, AACConfig.parse(t.codecPrivate) != nil else {
                    return .failure(TransferError("音频 AAC\(label(t)) 配置无法识别"))
                }
                return .success(.aac(config: t.codecPrivate))
            }
            return .success(.aac(config: AACConfig.synthesize(codecID: id, track: t)))
        }
        switch id {
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10": return .success(.ac3)
        case "A_EAC3": return .success(.eac3)
        case "A_MPEG/L3": return .success(.mp3)
        case "A_OPUS":
            guard OpusConfig.dOps(t.codecPrivate) != nil else {
                return .failure(TransferError("音频 Opus\(label(t)) 缺少 OpusHead 配置"))
            }
            return .success(.opus(head: t.codecPrivate))
        default:
            return .failure(TransferError("音频 \(name)\(label(t)) 不支持"))
        }
    }

    /// 轨道的语言 / 名称说明，如「（jpn · 评论音轨）」
    static func label(_ t: MKVTrack) -> String {
        let parts = [t.displayLanguage, t.name].filter { !$0.isEmpty && $0 != "und" }
        return parts.isEmpty ? "" : "（\(parts.joined(separator: " · "))）"
    }

    /// CodecID 的可读名称
    static func codecName(_ id: String) -> String {
        let names: [String: String] = [
            "V_MPEG4/ISO/AVC": "H.264", "V_MPEGH/ISO/HEVC": "HEVC", "V_VP9": "VP9", "V_VP8": "VP8", "V_AV1": "AV1",
            "V_MPEG1": "MPEG-1", "V_MPEG2": "MPEG-2", "V_MPEG4/ISO/ASP": "MPEG-4 Part 2", "V_MPEG4/ISO/SP": "MPEG-4 Part 2",
            "V_MPEG4/ISO/AP": "MPEG-4 Part 2", "V_MPEG4/MS/V3": "MS-MPEG4 v3", "V_MS/VFW/FOURCC": "VFW", "V_THEORA": "Theora",
            "V_PRORES": "ProRes", "V_FFV1": "FFV1", "V_UNCOMPRESSED": "未压缩视频",
            "A_AC3": "AC-3", "A_EAC3": "E-AC-3", "A_TRUEHD": "TrueHD", "A_MLP": "MLP", "A_FLAC": "FLAC",
            "A_VORBIS": "Vorbis", "A_OPUS": "Opus", "A_ALAC": "ALAC", "A_MPEG/L3": "MP3", "A_MPEG/L2": "MP2",
            "A_MPEG/L1": "MP1", "A_WAVPACK4": "WavPack", "A_TTA1": "TTA", "A_MS/ACM": "ACM",
            "S_TEXT/UTF8": "SRT", "S_TEXT/ASCII": "SRT", "S_TEXT/WEBVTT": "WebVTT", "S_TEXT/ASS": "ASS", "S_TEXT/SSA": "SSA",
            "S_ASS": "ASS", "S_SSA": "SSA", "S_HDMV/PGS": "PGS", "S_VOBSUB": "VobSub", "S_DVBSUB": "DVB",
            "S_HDMV/TEXTST": "TextST", "S_KATE": "Kate",
        ]
        if let n = names[id] { return n }
        for (prefix, n) in [("A_AAC", "AAC"), ("A_DTS", "DTS"), ("A_PCM", "PCM"), ("A_REAL", "RealAudio"),
                            ("A_QUICKTIME", "QuickTime 音频"), ("V_REAL", "RealVideo"), ("V_QUICKTIME", "QuickTime 视频")]
        where id.hasPrefix(prefix) {
            return n
        }
        for prefix in ["V_", "A_", "S_"] where id.hasPrefix(prefix) { return String(id.dropFirst(2)) }
        return id.isEmpty ? "未知" : id
    }
}

// MARK: - 转封装

/// 把选中轨道的帧写进 mdat、收集样本表和字幕，最后写 moov
final class MKVRemuxJob {
    private enum Role {
        case video
        case audio
        case subtitle(Int)
    }

    private let selection: MKVSelection
    private let scale: Int64
    private let sink: MP4SampleSink
    private var roles: [UInt64: Role] = [:]
    private let video: MKVVideoTrack?
    private let audio: MKVAudioTrack?
    private let subtitles: [MKVSubtitleTrack]

    var wanted: Set<UInt64> { Set(roles.keys) }

    init(selection: MKVSelection, timecodeScale: Int64, sink: MP4SampleSink) {
        self.selection = selection
        scale = timecodeScale
        self.sink = sink
        if let v = selection.video {
            video = MKVVideoTrack(track: v.track, codec: v.codec)
            roles[v.track.number] = .video
        } else {
            video = nil
        }
        if let a = selection.audio {
            audio = MKVAudioTrack(track: a.track, codec: a.codec)
            roles[a.track.number] = .audio
        } else {
            audio = nil
        }
        var subs: [MKVSubtitleTrack] = []
        for s in selection.subtitles where roles[s.track.number] == nil {
            roles[s.track.number] = .subtitle(subs.count)
            subs.append(MKVSubtitleTrack(track: s.track, ass: s.ass))
        }
        subtitles = subs
    }

    /// TimecodeScale 单位 → 纳秒（溢出时截断）
    private func nanoseconds(_ t: Int64) -> Int64 {
        let (p, overflow) = t.multipliedReportingOverflow(by: scale)
        if overflow { return t < 0 ? Int64.min / 4 : Int64.max / 4 }
        return p
    }

    /// 纳秒 → 90kHz
    static func ticks90k(_ ns: Int64) -> Int64 {
        ns / 100_000 * 9 + (ns % 100_000) * 9 / 100_000
    }

    func handle(_ block: MKVBlock) throws {
        guard let role = roles[block.track], let frames = MKVReader.frames(block.data, lacing: block.lacing) else { return }
        let start = nanoseconds(block.timecode)
        let duration = block.duration.map { nanoseconds(Int64(clamping: $0)) }
        switch role {
        case .video:
            guard let video else { return }
            let step = video.track.defaultDuration > 0 ? Int64(clamping: video.track.defaultDuration) : 40_000_000
            for (k, r) in frames.enumerated() {
                let pts = Self.ticks90k(start + Int64(k) * step)
                try video.add(block.data[r], pts: pts, keyframe: block.keyframe, sink: sink)
            }
            if let duration, frames.count == 1 { video.lastDuration = Self.ticks90k(duration) }
        case .audio:
            guard let audio else { return }
            var pts = Self.ticks90k(start)
            for r in frames {
                let samples = try audio.add(block.data[r], pts: pts, sink: sink)
                if audio.sampleRate > 0 { pts += Int64(samples) * 90000 / Int64(audio.sampleRate) }
            }
        case .subtitle(let i):
            for r in frames {
                subtitles[i].add(block.data[r], start: start, duration: duration)
            }
        }
    }

    func finish() throws -> MKVRemuxer.Result {
        var skipped = selection.skipped
        let hasVideo = (video?.sampleCount ?? 0) > 0
        let hasAudio = (audio?.sampleCount ?? 0) > 0
        if let audio, !hasAudio {
            skipped.append("音频 \(MKVSelection.codecName(audio.track.codecID)) 数据无法识别，已跳过")
        }
        guard hasVideo || hasAudio else { throw TransferError("MKV 里没有可转封装的音视频数据") }

        var starts: [Int64] = []
        if hasVideo, let v = video?.minPTS { starts.append(v) }
        if hasAudio, let a = audio?.firstPTS { starts.append(a) }
        let origin = starts.min() ?? 0

        var plans: [MP4Builder.TrackPlan] = []
        if hasVideo, let video, let plan = video.plan(id: UInt32(plans.count + 1), origin: origin) { plans.append(plan) }
        if hasAudio, let audio, let plan = audio.plan(id: UInt32(plans.count + 1), origin: origin) { plans.append(plan) }
        guard !plans.isEmpty else { throw TransferError("MKV 里没有可转封装的音视频数据") }

        try sink.finishMdat()
        try sink.handle.write(contentsOf: Data(MP4Builder.moov(plans: plans)))

        // 90kHz → 纳秒
        let originNs = origin / 9 * 100_000 + (origin % 9) * 100_000 / 9
        var subs: [MKVRemuxer.Subtitle] = []
        for s in subtitles {
            let srt = s.srt(origin: originNs)
            guard !srt.isEmpty else { continue }
            subs.append(MKVRemuxer.Subtitle(language: s.track.displayLanguage, name: s.track.name, srt: srt))
        }
        return MKVRemuxer.Result(subtitles: subs, skipped: skipped)
    }
}

/// 视频轨：长度前缀的帧原样写入，记 PTS（90kHz），最后推算 DTS
final class MKVVideoTrack {
    let track: MKVTrack
    let codec: VideoTrackBuilder.Codec
    private(set) var table = MP4SampleTable()
    private(set) var pts: [Int64] = []
    private(set) var syncSamples: [UInt32] = []
    private(set) var minPTS: Int64?
    /// 最后一个带 BlockDuration 的块的时长（90kHz）
    var lastDuration: Int64?
    private var started = false

    var sampleCount: Int { table.count }

    init(track: MKVTrack, codec: VideoTrackBuilder.Codec) {
        self.track = track
        self.codec = codec
    }

    func add(_ frame: ArraySlice<UInt8>, pts value: Int64, keyframe: Bool, sink: MP4SampleSink) throws {
        let prefix = track.framePrefix
        guard prefix.count + frame.count > 0 else { return }
        if !started {
            // 第一个关键帧之前的帧无法解码，丢掉
            guard keyframe else { return }
            started = true
        }
        let offset = sink.offset
        if !prefix.isEmpty { try sink.write(prefix) }
        try sink.write(frame)
        table.add(offset: offset, size: prefix.count + frame.count)
        pts.append(value)
        if keyframe { syncSamples.append(UInt32(table.count)) }
        if let m = minPTS {
            if value < m { minPTS = value }
        } else {
            minPTS = value
        }
    }

    /// 由显示时间推算解码时间：排序后的 PTS 序列（严格递增）整体前移到每帧 DTS ≤ PTS
    static func decodeTimes(_ pts: [Int64]) -> [Int64] {
        guard !pts.isEmpty else { return [] }
        var dts = pts.sorted()
        for i in 1..<dts.count where dts[i] <= dts[i - 1] { dts[i] = dts[i - 1] + 1 }
        var shift: Int64 = 0
        for i in dts.indices { shift = max(shift, dts[i] - pts[i]) }
        if shift > 0 { for i in dts.indices { dts[i] -= shift } }
        return dts
    }

    func plan(id: UInt32, origin: Int64) -> MP4Builder.TrackPlan? {
        guard !pts.isEmpty, let minPTS else { return nil }
        let dts = Self.decodeTimes(pts)
        var offsets: [Int64] = []
        offsets.reserveCapacity(pts.count)
        for i in pts.indices { offsets.append(pts[i] - dts[i]) }
        var deltas: [UInt32] = []
        deltas.reserveCapacity(pts.count)
        for i in 1..<max(1, dts.count) { deltas.append(UInt32(clamping: dts[i] - dts[i - 1])) }
        var last: Int64 = 3000
        if track.defaultDuration > 0 {
            last = MKVRemuxJob.ticks90k(Int64(clamping: track.defaultDuration))
        } else if let lastDuration {
            last = lastDuration
        } else if let d = deltas.last {
            last = Int64(d)
        }
        deltas.append(UInt32(clamping: max(1, last)))
        var mediaDuration: Int64 = 0
        for d in deltas { mediaDuration += Int64(d) }

        let firstDTS = dts[0]
        let mediaTime = max(0, minPTS - firstDTS)
        var presentationEnd: Int64 = 0
        for i in dts.indices {
            let end = dts[i] - firstDTS + offsets[i] + Int64(deltas[i])
            if end > presentationEnd { presentationEnd = end }
        }
        let (edits, trackDuration) = MP4Builder.makeEdits(startOffset: minPTS - origin, mediaTime: mediaTime,
                                                          mediaEnd: presentationEnd, timescale: MP4Builder.videoTimescale)

        let config = track.codecPrivate
        var width = track.pixelWidth
        var height = track.pixelHeight
        let entry: [UInt8]
        switch codec {
        case .h264:
            if width <= 0 || height <= 0, let sps = Self.parameterSet(avcC: config), let info = H264SPSInfo.parse(sps) {
                width = info.width
                height = info.height
            }
            entry = MP4Builder.visualEntry("avc1", width: width, height: height, config: MP4Builder.box("avcC", config))
        case .hevc:
            if width <= 0 || height <= 0, let sps = Self.parameterSet(hvcC: config), let info = HEVCSPSInfo.parse(sps) {
                width = info.width
                height = info.height
            }
            entry = MP4Builder.visualEntry("hvc1", width: width, height: height, config: MP4Builder.box("hvcC", config))
        }
        return MP4Builder.TrackPlan(id: id, isVideo: true, timescale: MP4Builder.videoTimescale, mediaDuration: mediaDuration,
                                    edits: edits, trackDuration: trackDuration, width: width, height: height,
                                    sampleEntry: entry, deltas: deltas, compositionOffsets: offsets,
                                    syncSamples: syncSamples, table: table, language: track.language)
    }

    /// avcC 里的第一个 SPS
    static func parameterSet(avcC c: [UInt8]) -> [UInt8]? {
        guard c.count > 8, c[5] & 0x1F > 0 else { return nil }
        let length = (Int(c[6]) << 8) | Int(c[7])
        guard 8 + length <= c.count else { return nil }
        return Array(c[8..<(8 + length)])
    }

    /// hvcC 里的第一个 SPS（NAL 类型 33）
    static func parameterSet(hvcC c: [UInt8]) -> [UInt8]? {
        guard c.count > 23 else { return nil }
        var i = 23
        for _ in 0..<Int(c[22]) {
            guard i + 3 <= c.count else { return nil }
            let type = c[i] & 0x3F
            let count = (Int(c[i + 1]) << 8) | Int(c[i + 2])
            i += 3
            for _ in 0..<count {
                guard i + 2 <= c.count else { return nil }
                let length = (Int(c[i]) << 8) | Int(c[i + 1])
                i += 2
                guard i + length <= c.count else { return nil }
                if type == 33 { return Array(c[i..<(i + length)]) }
                i += length
            }
        }
        return nil
    }
}

/// 音频轨：帧原样写入，每帧时长（采样数）按编码规则算
final class MKVAudioTrack {
    let track: MKVTrack
    let codec: MKVAudioCodec
    private(set) var table = MP4SampleTable()
    private(set) var durations: [UInt32] = []
    private(set) var firstPTS: Int64?
    /// 媒体时间刻度（采样率）；AC-3 / E-AC-3 / MP3 由第一帧决定
    private(set) var sampleRate: Int
    private(set) var channels: Int
    /// AC-3 / E-AC-3 的 dac3 / dec3 内容，由第一帧生成
    private var specific: [UInt8]?

    var sampleCount: Int { table.count }

    init(track: MKVTrack, codec: MKVAudioCodec) {
        self.track = track
        self.codec = codec
        sampleRate = Int(track.sampleRate.rounded())
        channels = track.channels
        switch codec {
        case .aac(let config):
            if let info = AACConfig.parse(config) {
                sampleRate = info.sampleRate
                if info.channels > 0 { channels = info.channels == 7 ? 8 : info.channels }
            }
        case .opus(let head):
            sampleRate = 48000
            if let info = OpusConfig.dOps(head) { channels = info.channels }
        default:
            break
        }
    }

    /// 写一帧，返回它的采样数
    @discardableResult
    func add(_ frame: ArraySlice<UInt8>, pts: Int64, sink: MP4SampleSink) throws -> Int {
        var data = track.framePrefix
        data.append(contentsOf: frame)
        guard !data.isEmpty else { return 0 }
        if table.count == 0 {
            // 第一帧：AC-3 / E-AC-3 / MP3 从帧头取采样率、声道和配置，取不到就丢掉这帧
            switch codec {
            case .ac3:
                guard let info = AC3Frame.ac3(data) else { return 0 }
                sampleRate = info.sampleRate
                channels = info.channels
                specific = info.specific
            case .eac3:
                guard let info = AC3Frame.eac3(data) else { return 0 }
                sampleRate = info.sampleRate
                channels = info.channels
                specific = info.specific
            case .mp3:
                guard let info = MPEGAudioFrame(data) else { return 0 }
                sampleRate = info.sampleRate
                channels = info.channels
            default:
                break
            }
        }
        var samples: Int?
        switch codec {
        case .aac: samples = 1024
        case .ac3: samples = 1536
        case .eac3: samples = AC3Frame.eac3Samples(data)
        case .mp3: samples = MPEGAudioFrame(data)?.samplesPerFrame
        case .opus: samples = OpusConfig.samples(data)
        }
        if samples == nil {
            if track.defaultDuration > 0 && sampleRate > 0 {
                samples = Int(Int64(clamping: track.defaultDuration) * Int64(sampleRate) / 1_000_000_000)
            } else {
                samples = durations.last.map { Int($0) } ?? 1024
            }
        }
        let count = max(1, samples ?? 1024)
        let offset = sink.offset
        try sink.write(data)
        table.add(offset: offset, size: data.count)
        durations.append(UInt32(clamping: count))
        if firstPTS == nil { firstPTS = pts }
        return count
    }

    func plan(id: UInt32, origin: Int64) -> MP4Builder.TrackPlan? {
        guard table.count > 0, sampleRate > 0 else { return nil }
        let entry: [UInt8]
        let esId = UInt16(clamping: Int(id))
        switch codec {
        case .aac(let config):
            entry = MP4Builder.audioSampleEntry("mp4a", channels: channels, sampleRate: sampleRate,
                                                config: MP4Builder.esds(config, esId: esId))
        case .mp3:
            entry = MP4Builder.audioSampleEntry("mp4a", channels: channels, sampleRate: sampleRate,
                                                config: MP4Builder.esds([], esId: esId, objectType: 0x6B))
        case .ac3:
            guard let specific else { return nil }
            entry = MP4Builder.audioSampleEntry("ac-3", channels: channels, sampleRate: sampleRate,
                                                config: MP4Builder.box("dac3", specific))
        case .eac3:
            guard let specific else { return nil }
            entry = MP4Builder.audioSampleEntry("ec-3", channels: channels, sampleRate: sampleRate,
                                                config: MP4Builder.box("dec3", specific))
        case .opus(let head):
            guard let info = OpusConfig.dOps(head) else { return nil }
            entry = MP4Builder.audioSampleEntry("Opus", channels: channels, sampleRate: 48000,
                                                config: MP4Builder.box("dOps", info.box))
        }
        let rate = Int64(sampleRate)
        var mediaDuration: Int64 = 0
        for d in durations { mediaDuration += Int64(d) }
        let start = firstPTS ?? origin
        let (edits, trackDuration) = MP4Builder.makeEdits(startOffset: start - origin, mediaTime: 0,
                                                          mediaEnd: mediaDuration, timescale: rate)
        return MP4Builder.TrackPlan(id: id, isVideo: false, timescale: rate, mediaDuration: mediaDuration, edits: edits,
                                    trackDuration: trackDuration, width: 0, height: 0, sampleEntry: entry,
                                    deltas: durations, compositionOffsets: [], syncSamples: nil, table: table,
                                    language: track.language)
    }
}

/// 文字字幕轨 → SRT
final class MKVSubtitleTrack {
    let track: MKVTrack
    let ass: Bool
    /// 纳秒
    private var cues: [(start: Int64, end: Int64?, text: String)] = []

    init(track: MKVTrack, ass: Bool) {
        self.track = track
        self.ass = ass
    }

    func add(_ frame: ArraySlice<UInt8>, start: Int64, duration: Int64?) {
        var data = track.framePrefix
        data.append(contentsOf: frame)
        let raw = String(decoding: data, as: UTF8.self)
        let text = ass ? Self.assText(raw) : Self.plainText(raw)
        guard !text.isEmpty else { return }
        var length = duration
        if (length ?? 0) <= 0, track.defaultDuration > 0 { length = Int64(clamping: track.defaultDuration) }
        let end = length.flatMap { $0 > 0 ? start + $0 : nil }
        cues.append((start, end, text))
    }

    /// 去掉空行、首尾空白和 \0
    static func plainText(_ s: String) -> String {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0"))) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    /// MKV 里的 ASS 事件：ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text；
    /// 取 Text，去掉 {...} 覆盖标签，\N / \n 换行，\h 空格
    static func assText(_ s: String) -> String {
        var commas = 0
        var textStart = s.endIndex
        for i in s.indices where s[i] == "," {
            commas += 1
            if commas == 8 {
                textStart = s.index(after: i)
                break
            }
        }
        let text = commas == 8 ? s[textStart...] : Substring(s)
        var out = ""
        var depth = 0
        for ch in text {
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                if depth > 0 { depth -= 1 } else { out.append(ch) }
            } else if depth == 0 {
                out.append(ch)
            }
        }
        out = out.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        return plainText(out)
    }

    /// 时间以 `origin`（纳秒）为 0 点；没有时长的条目显示到下一条开始（最多 5 秒），最后一条 3 秒
    func srt(origin: Int64) -> String {
        let sorted = cues.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map(\.element)
        var out: [String] = []
        for (i, cue) in sorted.enumerated() {
            var end = cue.end ?? 0
            if cue.end == nil {
                if i + 1 < sorted.count, sorted[i + 1].start > cue.start {
                    end = min(sorted[i + 1].start, cue.start + 5_000_000_000)
                } else {
                    end = cue.start + 3_000_000_000
                }
            }
            let start = cue.start - origin
            let stop = end - origin
            guard stop > 0 else { continue }
            out.append("\(out.count + 1)\n\(Self.timestamp(max(0, start))) --> \(Self.timestamp(stop))\n\(cue.text)\n")
        }
        return out.joined(separator: "\n")
    }

    /// 纳秒 → HH:MM:SS,mmm
    static func timestamp(_ ns: Int64) -> String {
        let ms = ns / 1_000_000
        func pad(_ v: Int64, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(pad(ms / 3_600_000, 2)):\(pad(ms / 60000 % 60, 2)):\(pad(ms / 1000 % 60, 2)),\(pad(ms % 1000, 3))"
    }
}

// MARK: - 编码配置

/// AAC AudioSpecificConfig
enum AACConfig {
    /// 取核心采样率（SBR 显式信令时也是核心采样率，每帧 1024 个采样对应它）和声道配置
    static func parse(_ asc: [UInt8]) -> (sampleRate: Int, channels: Int)? {
        var r = BitReader(asc)
        do {
            let objectType = try r.bits(5)
            if objectType == 31 { try r.skip(6) }
            let index = try r.bits(4)
            let rate: Int
            if index == 15 {
                rate = try r.bits(24)
            } else {
                guard index < ADTSHeader.sampleRates.count else { return nil }
                rate = ADTSHeader.sampleRates[index]
            }
            let channels = try r.bits(4)
            guard rate > 0 else { return nil }
            return (rate, channels)
        } catch {
            return nil
        }
    }

    /// 老式 A_AAC/MPEG4/LC 等没有 CodecPrivate：按 CodecID、采样率、声道合成（同 FFmpeg）
    static func synthesize(codecID: String, track: MKVTrack) -> [UInt8] {
        var objectType = 2
        if codecID.contains("MAIN") {
            objectType = 1
        } else if codecID.contains("SSR") {
            objectType = 3
        } else if codecID.contains("LTP") {
            objectType = 4
        }
        let index = frequencyIndex(Int(track.sampleRate.rounded()))
        let channels = track.channels <= 6 ? max(0, track.channels) : (track.channels == 8 ? 7 : 0)
        var asc: [UInt8] = [UInt8(objectType << 3) | UInt8(index >> 1),
                            UInt8((index & 1) << 7) | UInt8(channels << 3)]
        if codecID.contains("SBR") {
            let output = track.outputSampleRate > 0 ? track.outputSampleRate : track.sampleRate * 2
            let extensionIndex = frequencyIndex(Int(output.rounded()))
            asc += [0x56, 0xE5, 0x80 | UInt8(extensionIndex << 3)]
        }
        return asc
    }

    /// 最接近的采样率序号
    static func frequencyIndex(_ rate: Int) -> Int {
        let rates = ADTSHeader.sampleRates
        var best = 0
        for i in rates.indices where abs(rates[i] - rate) < abs(rates[best] - rate) { best = i }
        return best
    }
}

/// AC-3 / E-AC-3 帧头
enum AC3Frame {
    struct Info {
        var sampleRate: Int
        var channels: Int
        /// dac3 / dec3 盒子的内容
        var specific: [UInt8]
    }

    private static let channelCounts = [2, 1, 2, 3, 3, 4, 4, 5]
    private static let rates = [48000, 44100, 32000]

    static func ac3(_ s: [UInt8]) -> Info? {
        guard s.count >= 8, s[0] == 0x0B, s[1] == 0x77 else { return nil }
        let fscod = Int(s[4] >> 6)
        let frmsizecod = Int(s[4] & 0x3F)
        let bsid = Int(s[5] >> 3)
        let bsmod = Int(s[5] & 0x07)
        guard fscod < 3, bsid <= 10 else { return nil }
        var r = BitReader(Array(s[6...]))
        do {
            let acmod = try r.bits(3)
            if acmod & 1 != 0 && acmod != 1 { try r.skip(2) }  // cmixlev
            if acmod & 4 != 0 { try r.skip(2) }                // surmixlev
            if acmod == 2 { try r.skip(2) }                    // dsurmod
            let lfeon = try r.bit()
            // fscod(2) bsid(5) bsmod(3) acmod(3) lfeon(1) bit_rate_code(5) reserved(5)
            var v = UInt32(fscod) << 22
            v |= UInt32(bsid) << 17
            v |= UInt32(bsmod) << 14
            v |= UInt32(acmod) << 11
            v |= UInt32(lfeon) << 10
            v |= UInt32(frmsizecod >> 1) << 5
            var w = ByteWriter()
            w.u24(v)
            return Info(sampleRate: rates[fscod], channels: channelCounts[acmod] + lfeon, specific: w.bytes)
        } catch {
            return nil
        }
    }

    static func eac3(_ s: [UInt8]) -> Info? {
        guard s.count >= 6, s[0] == 0x0B, s[1] == 0x77 else { return nil }
        var r = BitReader(Array(s[2...]))
        do {
            _ = try r.bits(2)  // strmtyp
            _ = try r.bits(3)  // substreamid
            let frmsiz = try r.bits(11)
            let fscod = try r.bits(2)
            let rate: Int
            let blocks: Int
            if fscod == 3 {
                let fscod2 = try r.bits(2)
                guard fscod2 < 3 else { return nil }
                rate = rates[fscod2] / 2
                blocks = 6
            } else {
                rate = rates[fscod]
                let numblkscod = try r.bits(2)
                blocks = [1, 2, 3, 6][numblkscod]
            }
            let acmod = try r.bits(3)
            let lfeon = try r.bit()
            let bsid = try r.bits(5)
            guard bsid > 10 && bsid <= 16 else { return nil }
            let frameBytes = (frmsiz + 1) * 2
            let dataRate = min(8191, frameBytes * 8 * rate / (blocks * 256) / 1000)
            var w = ByteWriter()
            w.u16(UInt16(dataRate << 3))  // data_rate(13) num_ind_sub(3) = 0
            // fscod(2) bsid(5) reserved(1) | asvc(1) bsmod(3) acmod(3) lfeon(1) | reserved(3) num_dep_sub(4) reserved(1)
            w.u8(UInt8(fscod << 6) | UInt8(bsid << 1))
            w.u8(UInt8(acmod << 1) | UInt8(lfeon))
            w.u8(0)
            return Info(sampleRate: rate, channels: channelCounts[acmod] + lfeon, specific: w.bytes)
        } catch {
            return nil
        }
    }

    /// 一个块里所有独立子流（substream 0）同步帧的采样数之和
    static func eac3Samples(_ s: [UInt8]) -> Int? {
        var i = 0
        var total = 0
        while i + 5 <= s.count, s[i] == 0x0B, s[i + 1] == 0x77 {
            let strmtyp = s[i + 2] >> 6
            let substream = (s[i + 2] >> 3) & 0x07
            let frmsiz = (Int(s[i + 2] & 0x07) << 8) | Int(s[i + 3])
            let fscod = s[i + 4] >> 6
            let numblkscod = fscod == 3 ? 3 : Int((s[i + 4] >> 4) & 0x03)
            if strmtyp != 1 && substream == 0 { total += [1, 2, 3, 6][numblkscod] * 256 }
            i += (frmsiz + 1) * 2
        }
        return total > 0 ? total : nil
    }
}

/// MPEG 音频（MP3）帧头
struct MPEGAudioFrame {
    let sampleRate: Int
    let channels: Int
    let samplesPerFrame: Int

    init?(_ s: [UInt8]) {
        guard s.count >= 4, s[0] == 0xFF, s[1] & 0xE0 == 0xE0 else { return nil }
        let version = (s[1] >> 3) & 0x03  // 3 = MPEG-1，2 = MPEG-2，0 = MPEG-2.5
        let layer = (s[1] >> 1) & 0x03    // 1 = Layer III，2 = Layer II，3 = Layer I
        let index = Int((s[2] >> 2) & 0x03)
        guard version != 1, layer != 0, index != 3 else { return nil }
        let base = [44100, 48000, 32000][index]
        sampleRate = version == 3 ? base : (version == 2 ? base / 2 : base / 4)
        channels = s[3] >> 6 == 3 ? 1 : 2
        if layer == 3 {
            samplesPerFrame = 384
        } else if layer == 2 || version == 3 {
            samplesPerFrame = 1152
        } else {
            samplesPerFrame = 576
        }
    }
}

/// Opus：OpusHead → dOps，按 TOC 算每包采样数（48kHz）
enum OpusConfig {
    static func dOps(_ h: [UInt8]) -> (box: [UInt8], channels: Int)? {
        guard h.count >= 19, Array(h[0..<8]) == Array("OpusHead".utf8) else { return nil }
        let channels = Int(h[9])
        guard channels > 0 else { return nil }
        let family = h[18]
        var w = ByteWriter()
        w.u8(0)  // Version
        w.u8(h[9])
        w.u16(UInt16(h[10]) | (UInt16(h[11]) << 8))  // PreSkip（OpusHead 是小端）
        w.u32(UInt32(h[12]) | (UInt32(h[13]) << 8) | (UInt32(h[14]) << 16) | (UInt32(h[15]) << 24))
        w.u16(UInt16(h[16]) | (UInt16(h[17]) << 8))  // OutputGain
        w.u8(family)
        if family != 0 {
            guard h.count >= 21 + channels else { return nil }
            w.append(Array(h[19..<(21 + channels)]))  // StreamCount、CoupledCount、ChannelMapping
        }
        return (w.bytes, channels)
    }

    static func samples(_ p: [UInt8]) -> Int? {
        guard let toc = p.first else { return nil }
        let config = Int(toc >> 3)
        let frame: Int
        if config < 12 {
            frame = [480, 960, 1920, 2880][config & 3]
        } else if config < 16 {
            frame = config & 1 == 0 ? 480 : 960
        } else {
            frame = [120, 240, 480, 960][config & 3]
        }
        let count: Int
        switch toc & 0x03 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard p.count >= 2 else { return nil }
            count = Int(p[1] & 0x3F)
        }
        return count > 0 ? frame * count : nil
    }
}
