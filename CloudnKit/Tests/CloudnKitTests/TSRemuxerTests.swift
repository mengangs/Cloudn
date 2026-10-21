// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// TS → MP4 转封装：在测试里拼出最小的 TS（PAT / PMT / PES，假 H.264 + AAC ADTS），转封装后逐个盒子校验
final class TSRemuxerTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: 已知向量（ffmpeg / x264 / x265 生成，宽高由 ffprobe 确认）

    /// x264 Constrained Baseline 320x240
    static let baselineSPS = hex("6742c00dd90141fb011000000300100000030320f142a480")
    static let baselinePPS = hex("68cb83cb20")
    /// x264 High 318x180（宽高都需要裁剪）
    static let highSPS = hex("6764000dacd941419ea7c044000003000400000300f03c50a658")
    /// x265 Main 640x360
    static let hevcSPS = hex("42010101600000030090000003000003003fa00502016965959a4932bc05a02000000300200000030301")

    // MARK: 单元测试

    func testExpGolomb() throws {
        // 1 | 010 | 011 | 00100 | 00111 → ue: 0, 1, 2, 3, 6
        var r = BitReader([0xA6, 0x43, 0x80])
        XCTAssertEqual(try r.ue(), 0)
        XCTAssertEqual(try r.ue(), 1)
        XCTAssertEqual(try r.ue(), 2)
        XCTAssertEqual(try r.ue(), 3)
        XCTAssertEqual(try r.ue(), 6)
        var s = BitReader([0xA6, 0x43, 0x80])
        XCTAssertEqual(try s.se(), 0)
        XCTAssertEqual(try s.se(), 1)
        XCTAssertEqual(try s.se(), -1)
        XCTAssertEqual(try s.se(), 2)
        XCTAssertEqual(try s.se(), -3)
        var empty = BitReader([0x00])
        XCTAssertThrowsError(try empty.ue())
        var bits = BitReader([0b1011_0000])
        XCTAssertEqual(try bits.bits(4), 0b1011)
    }

    func testH264SPS() throws {
        let baseline = try XCTUnwrap(H264SPSInfo.parse(Self.baselineSPS))
        XCTAssertEqual(baseline.profile, 66)
        XCTAssertEqual(baseline.compatibility, 0xC0)
        XCTAssertEqual(baseline.level, 13)
        XCTAssertEqual(baseline.width, 320)
        XCTAssertEqual(baseline.height, 240)

        let high = try XCTUnwrap(H264SPSInfo.parse(Self.highSPS))
        XCTAssertEqual(high.profile, 100)
        XCTAssertEqual(high.chromaFormat, 1)
        XCTAssertEqual(high.bitDepthLumaMinus8, 0)
        XCTAssertEqual(high.width, 318)
        XCTAssertEqual(high.height, 180)

        XCTAssertNil(H264SPSInfo.parse([0x67, 0x42]))
    }

    func testHEVCSPS() throws {
        let info = try XCTUnwrap(HEVCSPSInfo.parse(Self.hevcSPS))
        XCTAssertEqual(info.profileSpace, 0)
        XCTAssertEqual(info.tier, 0)
        XCTAssertEqual(info.profileIdc, 1)
        XCTAssertEqual(info.compatibilityFlags, 0x6000_0000)
        XCTAssertEqual(info.constraintFlags, [0x90, 0, 0, 0, 0, 0])
        XCTAssertEqual(info.level, 63)
        XCTAssertEqual(info.chromaFormat, 1)
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertEqual(info.temporalLayers, 1)
        XCTAssertTrue(info.temporalIdNested)
        // 截断到 profile_tier_level 之后：仍返回档次信息，宽高为 0
        let truncated = HEVCSPSInfo.parse(Array(Self.hevcSPS.prefix(20)))
        XCTAssertEqual(truncated?.profileIdc, 1)
        XCTAssertEqual(truncated?.width, 0)
    }

    func testTimestampWraparound() {
        let period: Int64 = 1 << 33
        XCTAssertEqual(TSClock.unwrap(1000, near: 500), 1000)
        // 回绕后的小值展开到下一圈
        XCTAssertEqual(TSClock.unwrap(3000, near: period - 9000), period + 3000)
        // 下一圈里出现回绕前的值（B 帧 PTS）展开回上一圈
        XCTAssertEqual(TSClock.unwrap(period - 3000, near: period + 3000), period - 3000)
        XCTAssertEqual(TSClock.unwrap(10, near: 2 * period + 5), 2 * period + 10)
        // 33 位时间戳编码 / 解码
        let raw: Int64 = period - 1
        XCTAssertEqual(TSDemuxer.timestamp(Self.encodeTimestamp(raw, prefix: 2), 0), raw)
        XCTAssertEqual(TSDemuxer.timestamp(Self.encodeTimestamp(123_456_789, prefix: 3), 0), 123_456_789)

        let clock = TSClock()
        XCTAssertEqual(clock.reference(for: 42), 42)
        XCTAssertEqual(clock.reference(for: 99), 42)
    }

    func testAnnexBAndADTS() throws {
        let stream: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 0, 1, 0x65, 0x88, 0, 0]
        let ranges = AnnexB.nalRanges(stream)
        XCTAssertEqual(ranges.map { Array(stream[$0]) }, [[0x09, 0xF0], [0x67, 0x42], [0x65, 0x88]])
        XCTAssertEqual(AnnexB.unescape([0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03]), [0x00, 0x00, 0x01, 0x00, 0x00])

        let frame = Self.adtsFrame(payload: [UInt8](repeating: 0x21, count: 10))
        let header = try XCTUnwrap(ADTSHeader(frame, at: 0))
        XCTAssertEqual(header.headerLength, 7)
        XCTAssertEqual(header.frameLength, 17)
        XCTAssertEqual(header.objectType, 2)
        XCTAssertEqual(header.sampleRate, 44100)
        XCTAssertEqual(header.channelConfig, 2)
        XCTAssertEqual(header.audioSpecificConfig, [0x12, 0x10])
        XCTAssertNil(ADTSHeader([0xFF, 0xF1, 0x50], at: 0))
    }

    // MARK: 整体转封装

    func testRemuxVideoAndAudio() throws {
        let ts = base.appendingPathComponent("in.ts")
        try Data(Self.makeTS(video: true, audio: true)).write(to: ts)
        let out = base.appendingPathComponent("out.mp4")
        try TSRemuxer.remux(video: ts, to: out)
        let file = [UInt8](try Data(contentsOf: out))
        let mp4 = MP4File(file)

        XCTAssertEqual(mp4.top.map(\.type), ["ftyp", "free", "mdat", "moov"])
        let ftyp = try XCTUnwrap(mp4.top.first)
        XCTAssertEqual(Array(file[ftyp.payload]).fourccs(), ["isom", "\0\0\u{2}\0", "isom", "iso2", "avc1", "mp41"])
        let mdat = mp4.top[2]
        XCTAssertEqual(mdat.start, 40)
        let moov = mp4.top[3]
        XCTAssertEqual(mp4.children(moov).map(\.type), ["mvhd", "trak", "trak"])
        let mvhd = try XCTUnwrap(mp4.child(moov, "mvhd"))
        XCTAssertEqual(mp4.u32(mvhd.payload.lowerBound + 12), 1000)  // timescale
        XCTAssertEqual(mp4.u32(mvhd.payload.lowerBound + 16), 266)   // 33（空白）+ 233
        XCTAssertEqual(mp4.u32(mvhd.payload.lowerBound + 96), 3)     // next_track_ID

        let traks = mp4.children(moov).filter { $0.type == "trak" }
        let video = traks[0]
        let audio = traks[1]

        // —— 视频 ——
        XCTAssertEqual(mp4.children(video).map(\.type), ["tkhd", "edts", "mdia"])
        let tkhd = try XCTUnwrap(mp4.child(video, "tkhd"))
        XCTAssertEqual(mp4.u32(tkhd.payload.lowerBound + 12), 1)            // track_ID
        XCTAssertEqual(mp4.u32(tkhd.payload.lowerBound + 20), 266)          // duration
        XCTAssertEqual(mp4.u32(tkhd.payload.lowerBound + 76), 320 << 16)    // width
        XCTAssertEqual(mp4.u32(tkhd.payload.lowerBound + 80), 240 << 16)    // height
        let elst = try XCTUnwrap(mp4.find(video, ["edts", "elst"]))
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 4), 2)
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 8), 33)
        XCTAssertEqual(Int32(bitPattern: mp4.u32(elst.payload.lowerBound + 12)), -1)
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 20), 233)
        XCTAssertEqual(Int32(bitPattern: mp4.u32(elst.payload.lowerBound + 24)), 3000)

        let mdhd = try XCTUnwrap(mp4.find(video, ["mdia", "mdhd"]))
        XCTAssertEqual(mp4.u32(mdhd.payload.lowerBound + 12), 90000)
        XCTAssertEqual(mp4.u32(mdhd.payload.lowerBound + 16), 21000)
        let hdlr = try XCTUnwrap(mp4.find(video, ["mdia", "hdlr"]))
        XCTAssertEqual(Array(file[(hdlr.payload.lowerBound + 8)..<(hdlr.payload.lowerBound + 12)]).fourccs(), ["vide"])
        XCTAssertNotNil(mp4.find(video, ["mdia", "minf", "vmhd"]))
        XCTAssertNotNil(mp4.find(video, ["mdia", "minf", "dinf", "dref"]))
        let stbl = try XCTUnwrap(mp4.find(video, ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.children(stbl).map(\.type), ["stsd", "stts", "ctts", "stss", "stsc", "stsz", "stco"])

        // stsd → avc1 → avcC
        let stsd = try XCTUnwrap(mp4.child(stbl, "stsd"))
        let avc1 = try XCTUnwrap(mp4.boxes(in: (stsd.payload.lowerBound + 8)..<stsd.end).first)
        XCTAssertEqual(avc1.type, "avc1")
        XCTAssertEqual(mp4.u16(avc1.payload.lowerBound + 24), 320)
        XCTAssertEqual(mp4.u16(avc1.payload.lowerBound + 26), 240)
        let avcC = try XCTUnwrap(mp4.boxes(in: (avc1.payload.lowerBound + 78)..<avc1.end).first)
        XCTAssertEqual(avcC.type, "avcC")
        var expectedAvcC: [UInt8] = [1, 0x42, 0xC0, 0x0D, 0xFF, 0xE1, 0, UInt8(Self.baselineSPS.count)]
        expectedAvcC += Self.baselineSPS
        expectedAvcC += [1, 0, UInt8(Self.baselinePPS.count)]
        expectedAvcC += Self.baselinePPS
        XCTAssertEqual(Array(file[avcC.payload]), expectedAvcC)

        XCTAssertEqual(mp4.table(stbl, "stts", columns: 2), [[7, 3000]])
        XCTAssertEqual(mp4.table(stbl, "ctts", columns: 2), [[1, 3000], [1, 6000], [1, 0], [1, 6000], [1, 0], [2, 3000]])
        XCTAssertEqual(mp4.table(stbl, "stss", columns: 1), [[1], [6]])
        // 视频 PES 不带长度，下一个 PES 开头才交付、再下一个才凑成访问单元：
        // 写入顺序 A0-2 V0-4 A3-4 A5 V5-6，视频两块（5 + 2）
        XCTAssertEqual(mp4.table(stbl, "stsc", columns: 3), [[1, 5, 1], [2, 2, 1]])
        let videoSamples = Self.videoAUs().map(\.expectedSample)
        XCTAssertEqual(mp4.sampleSizes(stbl), videoSamples.map { UInt32($0.count) })
        XCTAssertEqual(mp4.samples(stbl), videoSamples)

        // —— 音频 ——
        XCTAssertEqual(mp4.children(audio).map(\.type), ["tkhd", "mdia"])  // 从 0 点开始，无 elst
        let atkhd = try XCTUnwrap(mp4.child(audio, "tkhd"))
        XCTAssertEqual(mp4.u32(atkhd.payload.lowerBound + 12), 2)
        XCTAssertEqual(mp4.u32(atkhd.payload.lowerBound + 20), 139)         // 6144 / 44100 秒
        XCTAssertEqual(mp4.u16(atkhd.payload.lowerBound + 36), 0x0100)      // volume
        let amdhd = try XCTUnwrap(mp4.find(audio, ["mdia", "mdhd"]))
        XCTAssertEqual(mp4.u32(amdhd.payload.lowerBound + 12), 44100)
        XCTAssertEqual(mp4.u32(amdhd.payload.lowerBound + 16), 6144)
        XCTAssertNotNil(mp4.find(audio, ["mdia", "minf", "smhd"]))
        let astbl = try XCTUnwrap(mp4.find(audio, ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.children(astbl).map(\.type), ["stsd", "stts", "stsc", "stsz", "stco"])
        let astsd = try XCTUnwrap(mp4.child(astbl, "stsd"))
        let mp4a = try XCTUnwrap(mp4.boxes(in: (astsd.payload.lowerBound + 8)..<astsd.end).first)
        XCTAssertEqual(mp4a.type, "mp4a")
        XCTAssertEqual(mp4.u16(mp4a.payload.lowerBound + 16), 2)             // channelcount
        XCTAssertEqual(mp4.u32(mp4a.payload.lowerBound + 24), 44100 << 16)   // samplerate
        let esds = try XCTUnwrap(mp4.boxes(in: (mp4a.payload.lowerBound + 28)..<mp4a.end).first)
        XCTAssertEqual(esds.type, "esds")
        let expectedEsds: [UInt8] = [0, 0, 0, 0,
                                     0x03, 25, 0, 2, 0,
                                     0x04, 17, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0x05, 2, 0x12, 0x10,
                                     0x06, 1, 0x02]
        XCTAssertEqual(Array(file[esds.payload]), expectedEsds)
        XCTAssertEqual(mp4.table(astbl, "stts", columns: 2), [[6, 1024]])
        XCTAssertEqual(mp4.table(astbl, "stsc", columns: 3), [[1, 3, 1]])
        let audioFrames = Self.audioPayloads()
        XCTAssertEqual(mp4.sampleSizes(astbl), audioFrames.map { UInt32($0.count) })
        XCTAssertEqual(mp4.samples(astbl), audioFrames)
        XCTAssertEqual(mp4.u32(mdat.start), UInt32(file.count - 40 - moov.size))
    }

    func testRemuxSeparateAudioAcrossWrap() throws {
        let videoTS = base.appendingPathComponent("v.ts")
        let audioTS = base.appendingPathComponent("a.ts")
        try Data(Self.makeTS(video: true, audio: false)).write(to: videoTS)
        // 独立音轨从 startPTS + 9000 开始，正好回绕到 0
        try Data(Self.makeTS(video: false, audio: true, audioStart: Self.startPTS + 9000)).write(to: audioTS)
        let out = base.appendingPathComponent("merged.mp4")
        try TSRemuxer.remux(video: videoTS, audio: audioTS, to: out)
        let mp4 = MP4File([UInt8](try Data(contentsOf: out)))
        let moov = try XCTUnwrap(mp4.top.last)
        let traks = mp4.children(moov).filter { $0.type == "trak" }
        XCTAssertEqual(traks.count, 2)

        // 0 点 = 视频首帧显示时刻（startPTS + 3000）：视频只有 media_time 偏移，音频前面空白 6000/90000 秒
        let velst = try XCTUnwrap(mp4.find(traks[0], ["edts", "elst"]))
        XCTAssertEqual(mp4.u32(velst.payload.lowerBound + 4), 1)
        XCTAssertEqual(mp4.u32(velst.payload.lowerBound + 8), 233)
        XCTAssertEqual(mp4.u32(velst.payload.lowerBound + 12), 3000)
        let aelst = try XCTUnwrap(mp4.find(traks[1], ["edts", "elst"]))
        XCTAssertEqual(mp4.u32(aelst.payload.lowerBound + 4), 2)
        XCTAssertEqual(mp4.u32(aelst.payload.lowerBound + 8), 66)
        XCTAssertEqual(Int32(bitPattern: mp4.u32(aelst.payload.lowerBound + 12)), -1)
        XCTAssertEqual(mp4.u32(aelst.payload.lowerBound + 20), 139)
        XCTAssertEqual(mp4.u32(aelst.payload.lowerBound + 24), 0)

        // 先写完视频再写音频：各一块
        let vstbl = try XCTUnwrap(mp4.find(traks[0], ["mdia", "minf", "stbl"]))
        let astbl = try XCTUnwrap(mp4.find(traks[1], ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.table(vstbl, "stsc", columns: 3), [[1, 7, 1]])
        XCTAssertEqual(mp4.table(astbl, "stsc", columns: 3), [[1, 6, 1]])
        XCTAssertEqual(mp4.samples(vstbl), Self.videoAUs().map(\.expectedSample))
        XCTAssertEqual(mp4.samples(astbl), Self.audioPayloads())
    }

    /// 任务被暂停：转封装中途停下，抛出 CancellationError，不留半成品
    func testRemuxStopsWhenCancelled() throws {
        let ts = base.appendingPathComponent("in.ts")
        try Data(Self.makeTS(video: true, audio: true)).write(to: ts)
        let out = base.appendingPathComponent("out.mp4")
        XCTAssertThrowsError(try TSRemuxer.remux(video: ts, to: out, shouldCancel: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testRemuxWithoutSupportedStreamsThrows() throws {
        let ts = base.appendingPathComponent("id3.ts")
        try Data(Self.makeTS(video: false, audio: false)).write(to: ts)
        let out = base.appendingPathComponent("none.mp4")
        XCTAssertThrowsError(try TSRemuxer.remux(video: ts, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: TS 拼装

    static let startPTS: Int64 = (1 << 33) - 9000
    static let videoPID = 0x100
    static let audioPID = 0x101
    static let id3PID = 0x102
    static let pmtPID = 0x1000

    struct AU {
        let dts: Int64
        let pts: Int64
        let keyframe: Bool
        let slice: [UInt8]

        /// 送进 TS 的 Annex-B 字节：AUD +（关键帧时）SPS / PPS + 切片
        var annexB: [UInt8] {
            var out: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
            if keyframe {
                out += [0, 0, 0, 1] + TSRemuxerTests.baselineSPS
                out += [0, 0, 0, 1] + TSRemuxerTests.baselinePPS
            }
            out += [0, 0, 1] + slice
            return out
        }

        /// MP4 样本：只剩 4 字节长度前缀 + 切片
        var expectedSample: [UInt8] {
            let n = UInt32(slice.count)
            return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + slice
        }
    }

    /// I P B P B I P（解码顺序），显示顺序帧号 1 3 2 5 4 6 7，帧间隔 3000；DTS 从 startPTS 开始跨过 33 位回绕
    static func videoAUs() -> [AU] {
        let order: [Int64] = [1, 3, 2, 5, 4, 6, 7]
        var list: [AU] = []
        for (i, p) in order.enumerated() {
            let key = i == 0 || i == 5
            var slice: [UInt8] = key ? [0x65, 0x88, 0x84] : [0x41, 0x9A, 0x02]
            slice += [UInt8](repeating: 0xAB, count: 300 + i * 50)
            list.append(AU(dts: startPTS + Int64(i) * 3000, pts: startPTS + p * 3000, keyframe: key, slice: slice))
        }
        return list
    }

    static func audioPayloads() -> [[UInt8]] {
        (0..<6).map { [UInt8](repeating: 0x21, count: 20 + $0) }
    }

    static func adtsFrame(payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 7
        let channels = 2
        var h: [UInt8] = [0xFF, 0xF1]
        h.append(0x40 | (4 << 2) | UInt8(channels >> 2))  // LC，44100
        h.append(UInt8((channels & 3) << 6) | UInt8((length >> 11) & 0x03))
        h.append(UInt8((length >> 3) & 0xFF))
        h.append(UInt8((length & 0x07) << 5) | 0x1F)
        h.append(0xFC)
        return h + payload
    }

    static func encodeTimestamp(_ value: Int64, prefix: UInt8) -> [UInt8] {
        let v = value & ((1 << 33) - 1)
        let b0 = (prefix << 4) | (UInt8((v >> 30) & 0x07) << 1) | 1
        let b1 = UInt8((v >> 22) & 0xFF)
        let b2 = (UInt8((v >> 15) & 0x7F) << 1) | 1
        let b3 = UInt8((v >> 7) & 0xFF)
        let b4 = (UInt8(v & 0x7F) << 1) | 1
        return [b0, b1, b2, b3, b4]
    }

    static func pes(streamID: UInt8, pts: Int64, dts: Int64?, payload: [UInt8], bounded: Bool) -> [UInt8] {
        var header: [UInt8] = [0x80]
        if let dts {
            header += [0xC0, 10]
            header += encodeTimestamp(pts, prefix: 3)
            header += encodeTimestamp(dts, prefix: 1)
        } else {
            header += [0x80, 5]
            header += encodeTimestamp(pts, prefix: 2)
        }
        let length = bounded ? header.count + payload.count : 0
        var out: [UInt8] = [0, 0, 1, streamID, UInt8(length >> 8), UInt8(length & 0xFF)]
        out += header
        out += payload
        return out
    }

    /// 把一段数据切成 TS 包，最后一包用适配域填充补满 188 字节
    static func packetize(pid: Int, _ data: [UInt8], counter: inout Int) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        var first = true
        while i < data.count {
            let n = min(184, data.count - i)
            var p: [UInt8] = [0x47, UInt8((first ? 0x40 : 0) | ((pid >> 8) & 0x1F)), UInt8(pid & 0xFF)]
            if n == 184 {
                p.append(UInt8(0x10 | (counter & 0x0F)))
            } else {
                p.append(UInt8(0x30 | (counter & 0x0F)))
                let adaptation = 183 - n
                p.append(UInt8(adaptation))
                if adaptation > 0 {
                    p.append(0x00)
                    p += [UInt8](repeating: 0xFF, count: adaptation - 1)
                }
            }
            p += data[i..<(i + n)]
            out += p
            counter += 1
            i += n
            first = false
        }
        return out
    }

    static func psi(_ section: [UInt8]) -> [UInt8] {
        // pointer_field + 表 + CRC（解析器不校验 CRC）
        [0] + section + [0, 0, 0, 0]
    }

    static func makeTS(video: Bool, audio: Bool, audioStart: Int64 = startPTS) -> [UInt8] {
        var out: [UInt8] = []
        var counters: [Int: Int] = [:]
        func emit(_ pid: Int, _ data: [UInt8]) {
            var c = counters[pid] ?? 0
            out += packetize(pid: pid, data, counter: &c)
            counters[pid] = c
        }
        // PAT
        let pat: [UInt8] = [0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00,
                            0x00, 0x01, UInt8(0xE0 | (pmtPID >> 8)), UInt8(pmtPID & 0xFF)]
        emit(0, psi(pat))
        // PMT：ID3（0x15，应忽略）+ 视频 + 音频
        var streams: [UInt8] = [0x15, UInt8(0xE0 | (id3PID >> 8)), UInt8(id3PID & 0xFF), 0xF0, 0x00]
        if video { streams += [0x1B, UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF), 0xF0, 0x00] }
        if audio { streams += [0x0F, UInt8(0xE0 | (audioPID >> 8)), UInt8(audioPID & 0xFF), 0xF0, 0x00] }
        var pmt: [UInt8] = [0x02, 0xB0, UInt8(9 + streams.count + 4), 0x00, 0x01, 0xC1, 0x00, 0x00,
                            UInt8(0xE0 | (videoPID >> 8)), UInt8(videoPID & 0xFF), 0xF0, 0x00]
        pmt += streams
        emit(pmtPID, psi(pmt))
        emit(id3PID, pes(streamID: 0xBD, pts: startPTS, dts: nil, payload: [UInt8](repeating: 0x49, count: 40), bounded: true))

        let frames = audioPayloads().map { adtsFrame(payload: $0) }
        let step: Int64 = 1024 * 90000 / 44100
        if audio {
            let first = frames[0] + frames[1] + frames[2]
            emit(audioPID, pes(streamID: 0xC0, pts: audioStart, dts: nil, payload: first, bounded: true))
        }
        if video {
            // 第一个 IDR 之前的非关键帧：应被丢弃
            let leading = AU(dts: startPTS - 3000, pts: startPTS - 3000, keyframe: false, slice: [0x41, 0x9A, 0x07, 0x11])
            emit(videoPID, pes(streamID: 0xE0, pts: leading.pts, dts: leading.dts, payload: leading.annexB, bounded: false))
            for au in videoAUs() {
                let dts: Int64? = au.pts == au.dts ? nil : au.dts
                emit(videoPID, pes(streamID: 0xE0, pts: au.pts, dts: dts, payload: au.annexB, bounded: false))
            }
        }
        if audio {
            // 第 6 帧跨两个 PES
            let second = frames[3] + frames[4] + Array(frames[5].prefix(5))
            emit(audioPID, pes(streamID: 0xC0, pts: audioStart + 3 * step, dts: nil, payload: second, bounded: true))
            let third = Array(frames[5].dropFirst(5))
            emit(audioPID, pes(streamID: 0xC0, pts: audioStart + 5 * step, dts: nil, payload: third, bounded: true))
        }
        return out
    }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var chars = Array(s)
        while chars.count >= 2 {
            out.append(UInt8(String(chars[0..<2]), radix: 16)!)
            chars.removeFirst(2)
        }
        return out
    }
}

// MARK: - 测试用 MP4 盒子解析

struct MP4Box {
    let type: String
    let start: Int
    let end: Int
    let payload: Range<Int>
    var size: Int { end - start }
}

struct MP4File {
    let d: [UInt8]
    init(_ d: [UInt8]) { self.d = d }

    var top: [MP4Box] { boxes(in: 0..<d.count) }

    func u16(_ i: Int) -> UInt16 { UInt16(d[i]) << 8 | UInt16(d[i + 1]) }

    func u32(_ i: Int) -> UInt32 {
        let a = UInt32(d[i]) << 24
        let b = UInt32(d[i + 1]) << 16
        let c = UInt32(d[i + 2]) << 8
        return a | b | c | UInt32(d[i + 3])
    }

    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) << 32 | UInt64(u32(i + 4)) }

    func boxes(in range: Range<Int>) -> [MP4Box] {
        var out: [MP4Box] = []
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            var size = Int(u32(i))
            var header = 8
            if size == 1 {
                size = Int(u64(i + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - i
            }
            guard size >= header, i + size <= range.upperBound else { break }
            let type = String(decoding: d[(i + 4)..<(i + 8)], as: UTF8.self)
            out.append(MP4Box(type: type, start: i, end: i + size, payload: (i + header)..<(i + size)))
            i += size
        }
        return out
    }

    func children(_ box: MP4Box) -> [MP4Box] { boxes(in: box.payload) }

    func child(_ box: MP4Box, _ type: String) -> MP4Box? { children(box).first { $0.type == type } }

    func find(_ box: MP4Box, _ path: [String]) -> MP4Box? {
        var current = box
        for type in path {
            guard let next = child(current, type) else { return nil }
            current = next
        }
        return current
    }

    /// FullBox 表：version/flags + entry_count + 每条 `columns` 个 u32
    func table(_ stbl: MP4Box, _ type: String, columns: Int) -> [[UInt32]] {
        guard let box = child(stbl, type) else { return [] }
        let count = Int(u32(box.payload.lowerBound + 4))
        var rows: [[UInt32]] = []
        var i = box.payload.lowerBound + 8
        for _ in 0..<count {
            var row: [UInt32] = []
            for _ in 0..<columns {
                row.append(u32(i))
                i += 4
            }
            rows.append(row)
        }
        return rows
    }

    func sampleSizes(_ stbl: MP4Box) -> [UInt32] {
        guard let stsz = child(stbl, "stsz") else { return [] }
        let count = Int(u32(stsz.payload.lowerBound + 8))
        return (0..<count).map { u32(stsz.payload.lowerBound + 12 + $0 * 4) }
    }

    /// 按 stsc / stco / stsz 取出每个样本的字节
    func samples(_ stbl: MP4Box) -> [[UInt8]] {
        let sizes = sampleSizes(stbl)
        let offsets = table(stbl, "stco", columns: 1).map { Int($0[0]) }
        let stsc = table(stbl, "stsc", columns: 3)
        var out: [[UInt8]] = []
        var sample = 0
        for (chunk, offset) in offsets.enumerated() {
            var perChunk = 0
            for entry in stsc where Int(entry[0]) <= chunk + 1 { perChunk = Int(entry[1]) }
            var position = offset
            for _ in 0..<perChunk where sample < sizes.count {
                let size = Int(sizes[sample])
                out.append(Array(d[position..<(position + size)]))
                position += size
                sample += 1
            }
        }
        return out
    }
}

private extension Array where Element == UInt8 {
    /// 每 4 字节转成一个字符串
    func fourccs() -> [String] {
        stride(from: 0, to: count - count % 4, by: 4).map { String(decoding: self[$0..<($0 + 4)], as: UTF8.self) }
    }
}
