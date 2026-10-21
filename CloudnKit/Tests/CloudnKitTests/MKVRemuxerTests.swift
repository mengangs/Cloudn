// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// MKV → MP4 转封装：在测试里用 EBML 写出最小的 mkv（H.264 + AAC / AC-3 + 字幕），转封装后逐个盒子校验
final class MKVRemuxerTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-mkv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: 单元测试

    func testLacing() throws {
        // EBML：10、+200（2 字节有符号 VINT）、最后一帧 5
        var ebml: [UInt8] = [2, 0x8A, 0x60, 0xC7]
        ebml += [UInt8](repeating: 1, count: 225)
        XCTAssertEqual(MKVReader.frames(ebml, lacing: 3), [4..<14, 14..<224, 224..<229])
        // EBML 负差值：30、-10、+5、最后 7
        var negative: [UInt8] = [3, 0x9E, 0xB5, 0xC4]
        negative += [UInt8](repeating: 2, count: 30 + 20 + 25 + 7)
        XCTAssertEqual(MKVReader.frames(negative, lacing: 3)?.map(\.count), [30, 20, 25, 7])
        // Xiph：300 = 255 + 45，最后 30
        let xiph: [UInt8] = [1, 255, 45] + [UInt8](repeating: 3, count: 330)
        XCTAssertEqual(MKVReader.frames(xiph, lacing: 1), [3..<303, 303..<333])
        // 固定大小
        let fixed: [UInt8] = [2] + [UInt8](repeating: 4, count: 12)
        XCTAssertEqual(MKVReader.frames(fixed, lacing: 2), [1..<5, 5..<9, 9..<13])
        XCTAssertNil(MKVReader.frames([1] + [UInt8](repeating: 0, count: 3), lacing: 2))
        // 无 lacing
        XCTAssertEqual(MKVReader.frames([9, 9], lacing: 0), [0..<2])
        // 大小超出数据
        XCTAssertNil(MKVReader.frames([1, 200, 1, 2], lacing: 1))
    }

    func testDecodeTimesAndConfigs() {
        // I P B P B I（解码顺序）的显示时间 → DTS 前移一帧
        XCTAssertEqual(MKVVideoTrack.decodeTimes([0, 7200, 3600, 14400, 10800, 18000]),
                       [-3600, 0, 3600, 7200, 10800, 14400])
        XCTAssertEqual(MKVVideoTrack.decodeTimes([0, 3600, 7200]), [0, 3600, 7200])
        // 重复的 PTS 也得到严格递增的 DTS
        XCTAssertEqual(MKVVideoTrack.decodeTimes([0, 0, 3600]), [-1, 0, 3599])

        var track = MKVTrack()
        track.sampleRate = 44100
        track.channels = 2
        XCTAssertEqual(AACConfig.synthesize(codecID: "A_AAC/MPEG4/LC", track: track), [0x12, 0x10])
        track.sampleRate = 24000
        track.outputSampleRate = 48000
        XCTAssertEqual(AACConfig.synthesize(codecID: "A_AAC/MPEG4/LC/SBR", track: track), [0x13, 0x10, 0x56, 0xE5, 0x98])
        XCTAssertEqual(AACConfig.parse([0x11, 0x90])?.sampleRate, 48000)
        XCTAssertEqual(AACConfig.parse([0x11, 0x90])?.channels, 2)

        let mp3 = MPEGAudioFrame([0xFF, 0xFB, 0x90, 0xC4])  // MPEG-1 Layer III 44.1kHz 单声道
        XCTAssertEqual(mp3?.sampleRate, 44100)
        XCTAssertEqual(mp3?.samplesPerFrame, 1152)
        XCTAssertEqual(mp3?.channels, 1)
        XCTAssertEqual(OpusConfig.samples([0xFC]), 960)        // CELT 20ms，1 帧
        XCTAssertEqual(OpusConfig.samples([0x79, 0x00]), 1920)  // 混合模式 20ms（config 15），2 帧
        XCTAssertEqual(OpusConfig.samples([0x03 | (17 << 3), 0x03]), 720)  // CELT 5ms × 3

        var head = Array("OpusHead".utf8)
        head += [1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let dops = OpusConfig.dOps(head)
        XCTAssertEqual(dops?.channels, 2)
        XCTAssertEqual(dops?.box, [0, 2, 0x01, 0x38, 0, 0, 0xBB, 0x80, 0, 0, 0])

        XCTAssertEqual(MKVSubtitleTrack.assText("0,0,Default,,0,0,0,,{\\i1}Hi{\\i0}\\Nthere, friend"), "Hi\nthere, friend")
        XCTAssertEqual(MKVSubtitleTrack.plainText("a\r\n\r\nb \0"), "a\nb")
        XCTAssertEqual(MKVSubtitleTrack.timestamp(3_723_004_000_000), "01:02:03,004")
        XCTAssertEqual(MP4Builder.packedLanguage("eng"), 0x15C7)
        XCTAssertEqual(MP4Builder.packedLanguage("zh-Hans"), 0x55C4)
    }

    // MARK: 整体转封装

    func testRemuxVideoAudioSubtitles() throws {
        let input = base.appendingPathComponent("in.mkv")
        try Data(Self.makeFullMKV()).write(to: input)
        XCTAssertNil(MKVRemuxer.check(input))
        let out = base.appendingPathComponent("out.mp4")
        let result = try MKVRemuxer.remux(input, to: out)
        let file = [UInt8](try Data(contentsOf: out))
        let mp4 = MP4File(file)

        XCTAssertEqual(mp4.top.map(\.type), ["ftyp", "free", "mdat", "moov"])
        let mdat = mp4.top[2]
        let moov = mp4.top[3]
        XCTAssertEqual(mp4.children(moov).map(\.type), ["mvhd", "trak", "trak"])
        let mvhd = try XCTUnwrap(mp4.child(moov, "mvhd"))
        XCTAssertEqual(mp4.u32(mvhd.payload.lowerBound + 12), 1000)
        XCTAssertEqual(mp4.u32(mvhd.payload.lowerBound + 16), 240)
        let traks = mp4.children(moov).filter { $0.type == "trak" }
        let video = traks[0]
        let audio = traks[1]

        // —— 视频 ——
        XCTAssertEqual(mp4.children(video).map(\.type), ["tkhd", "edts", "mdia"])
        let tkhd = try XCTUnwrap(mp4.child(video, "tkhd"))
        XCTAssertEqual(mp4.u32(tkhd.payload.lowerBound + 20), 240)
        XCTAssertEqual(mp4.u32(tkhd.payload.lowerBound + 76), 320 << 16)
        XCTAssertEqual(mp4.u32(tkhd.payload.lowerBound + 80), 240 << 16)
        let elst = try XCTUnwrap(mp4.find(video, ["edts", "elst"]))
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 4), 1)
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 8), 240)
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 12), 3600)  // 跳过首帧的 CTS 偏移
        let mdhd = try XCTUnwrap(mp4.find(video, ["mdia", "mdhd"]))
        XCTAssertEqual(mp4.u32(mdhd.payload.lowerBound + 12), 90000)
        XCTAssertEqual(mp4.u32(mdhd.payload.lowerBound + 16), 21600)
        XCTAssertEqual(mp4.u16(mdhd.payload.lowerBound + 20), 0x15C7)  // MKV 没写 Language → eng

        let stbl = try XCTUnwrap(mp4.find(video, ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.children(stbl).map(\.type), ["stsd", "stts", "ctts", "stss", "stsc", "stsz", "stco"])
        let stsd = try XCTUnwrap(mp4.child(stbl, "stsd"))
        let avc1 = try XCTUnwrap(mp4.boxes(in: (stsd.payload.lowerBound + 8)..<stsd.end).first)
        XCTAssertEqual(avc1.type, "avc1")
        XCTAssertEqual(mp4.u16(avc1.payload.lowerBound + 24), 320)
        XCTAssertEqual(mp4.u16(avc1.payload.lowerBound + 26), 240)
        let avcC = try XCTUnwrap(mp4.boxes(in: (avc1.payload.lowerBound + 78)..<avc1.end).first)
        XCTAssertEqual(avcC.type, "avcC")
        XCTAssertEqual(Array(file[avcC.payload]), Self.avcC)
        XCTAssertEqual(mp4.table(stbl, "stts", columns: 2), [[6, 3600]])
        XCTAssertEqual(mp4.table(stbl, "ctts", columns: 2), [[1, 3600], [1, 7200], [1, 0], [1, 7200], [1, 0], [1, 3600]])
        XCTAssertEqual(mp4.table(stbl, "stss", columns: 1), [[1], [6]])
        let videoFrames = Self.videoFrames()
        XCTAssertEqual(mp4.sampleSizes(stbl), videoFrames.map { UInt32($0.count) })
        XCTAssertEqual(mp4.samples(stbl), videoFrames)

        // —— 音频 ——
        XCTAssertEqual(mp4.children(audio).map(\.type), ["tkhd", "mdia"])
        let atkhd = try XCTUnwrap(mp4.child(audio, "tkhd"))
        XCTAssertEqual(mp4.u32(atkhd.payload.lowerBound + 20), 170)  // 8192 / 48000 秒
        let amdhd = try XCTUnwrap(mp4.find(audio, ["mdia", "mdhd"]))
        XCTAssertEqual(mp4.u32(amdhd.payload.lowerBound + 12), 48000)
        XCTAssertEqual(mp4.u32(amdhd.payload.lowerBound + 16), 8192)
        let astbl = try XCTUnwrap(mp4.find(audio, ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.children(astbl).map(\.type), ["stsd", "stts", "stsc", "stsz", "stco"])
        let astsd = try XCTUnwrap(mp4.child(astbl, "stsd"))
        let mp4a = try XCTUnwrap(mp4.boxes(in: (astsd.payload.lowerBound + 8)..<astsd.end).first)
        XCTAssertEqual(mp4a.type, "mp4a")
        XCTAssertEqual(mp4.u16(mp4a.payload.lowerBound + 16), 2)
        XCTAssertEqual(mp4.u32(mp4a.payload.lowerBound + 24), 48000 << 16)
        let esds = try XCTUnwrap(mp4.boxes(in: (mp4a.payload.lowerBound + 28)..<mp4a.end).first)
        XCTAssertEqual(esds.type, "esds")
        XCTAssertEqual(Array(file[esds.payload]), [0, 0, 0, 0,
                                                   0x03, 25, 0, 2, 0,
                                                   0x04, 17, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                                   0x05, 2, 0x11, 0x90,
                                                   0x06, 1, 0x02])
        XCTAssertEqual(mp4.table(astbl, "stts", columns: 2), [[8, 1024]])
        let audioFrames = Self.audioFrames()
        XCTAssertEqual(mp4.samples(astbl), audioFrames)

        // mdat 恰好是所有样本
        let total = (videoFrames + audioFrames).reduce(0) { $0 + $1.count }
        XCTAssertEqual(Int(mp4.u32(mdat.start)), 8 + total)

        // —— 字幕 ——
        XCTAssertEqual(result.subtitles.count, 2)
        XCTAssertEqual(result.subtitles[0].language, "chi")
        XCTAssertEqual(result.subtitles[0].name, "中文")
        XCTAssertEqual(result.subtitles[0].srt,
                       "1\n00:00:00,000 --> 00:00:01,000\nHello\nWorld\n\n2\n00:00:01,500 --> 00:00:04,500\n<i>Bye</i>\n")
        XCTAssertEqual(result.subtitles[1].language, "ja")
        XCTAssertEqual(result.subtitles[1].name, "")
        XCTAssertEqual(result.subtitles[1].srt, "1\n00:00:00,500 --> 00:00:01,500\nHi\nthere, friend\n")
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("PGS"), result.skipped[0])
    }

    func testVP9OnlyThrows() throws {
        let tracks = EBMLW.el(0x1654AE6B, Self.trackEntry(number: 1, type: 1, codec: "V_VP9"))
        let cluster = EBMLW.el(0x1F43B675, EBMLW.uint(0xE7, 0) + Self.simpleBlock(track: 1, rel: 0, flags: 0x80, [1, 2, 3]))
        let input = base.appendingPathComponent("vp9.mkv")
        try Data(Self.mkv([tracks, cluster])).write(to: input)
        let message = try XCTUnwrap(MKVRemuxer.check(input))
        XCTAssertTrue(message.contains("VP9"), message)
        let out = base.appendingPathComponent("vp9.mp4")
        XCTAssertThrowsError(try MKVRemuxer.remux(input, to: out)) { error in
            XCTAssertTrue(error.localizedDescription.contains("VP9"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        let garbage = base.appendingPathComponent("garbage.mkv")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: garbage)
        XCTAssertNotNil(MKVRemuxer.check(garbage))
        XCTAssertThrowsError(try MKVRemuxer.remux(garbage, to: out))
    }

    func testDTSAudioSkipped() throws {
        var entries = Self.videoEntry(number: 1)
        entries += Self.trackEntry(number: 2, type: 2, codec: "A_DTS", extra: [EBMLW.str(0x22B59C, "jpn")])
        let tracks = EBMLW.el(0x1654AE6B, entries)
        var blocks = EBMLW.uint(0xE7, 0)
        blocks += Self.simpleBlock(track: 1, rel: 0, flags: 0x80, Self.nal(0x65, 40))
        blocks += Self.simpleBlock(track: 2, rel: 0, flags: 0x80, [0x7F, 0xFE, 0x80, 0x01])
        blocks += Self.simpleBlock(track: 1, rel: 40, flags: 0x00, Self.nal(0x41, 30))
        let input = base.appendingPathComponent("dts.mkv")
        try Data(Self.mkv([tracks, EBMLW.el(0x1F43B675, blocks)])).write(to: input)
        XCTAssertNil(MKVRemuxer.check(input))
        let out = base.appendingPathComponent("dts.mp4")
        let result = try MKVRemuxer.remux(input, to: out)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("DTS"), result.skipped[0])
        XCTAssertTrue(result.skipped[0].contains("jpn"), result.skipped[0])
        let mp4 = MP4File([UInt8](try Data(contentsOf: out)))
        let moov = try XCTUnwrap(mp4.top.last)
        XCTAssertEqual(mp4.children(moov).map(\.type), ["mvhd", "trak"])
        let stbl = try XCTUnwrap(mp4.find(mp4.children(moov)[1], ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.samples(stbl), [Self.nal(0x65, 40), Self.nal(0x41, 30)])
        XCTAssertNil(mp4.child(stbl, "ctts"))

        // 只有 DTS 音频：报错说明编码
        let audioOnly = EBMLW.el(0x1654AE6B, Self.trackEntry(number: 2, type: 2, codec: "A_DTS"))
        let dtsOnly = base.appendingPathComponent("dts-only.mkv")
        try Data(Self.mkv([audioOnly])).write(to: dtsOnly)
        let message = try XCTUnwrap(MKVRemuxer.check(dtsOnly))
        XCTAssertTrue(message.contains("DTS"), message)
    }

    func testUnknownSizeClustersAndSynthesizedAAC() throws {
        let audio = Self.trackEntry(number: 1, type: 2, codec: "A_AAC/MPEG4/LC", extra: [
            EBMLW.el(0xE1, EBMLW.float(0xB5, 44100) + EBMLW.uint(0x9F, 2)),
        ])
        let tracks = EBMLW.el(0x1654AE6B, audio)
        let frames = (0..<5).map { [UInt8](repeating: UInt8(0x30 + $0), count: 12 + $0) }
        var first = EBMLW.uint(0xE7, 0)
        first += Self.simpleBlock(track: 1, rel: 0, flags: 0x80, frames[0])
        first += EBMLW.el(0xEC, [0, 0, 0])  // Void
        first += Self.simpleBlock(track: 1, rel: 23, flags: 0x80, frames[1])
        first += Self.simpleBlock(track: 1, rel: 46, flags: 0x80, frames[2])
        var second = EBMLW.uint(0xE7, 70)
        second += EBMLW.el(0xBF, [1, 2, 3, 4])  // CRC-32
        second += Self.simpleBlock(track: 1, rel: 0, flags: 0x80, frames[3])
        second += Self.simpleBlock(track: 1, rel: 23, flags: 0x80, frames[4])
        let tags = EBMLW.el(0x1254C367, [0xEC, 0x81, 0x00])
        let segment = tracks + EBMLW.unknown(0x1F43B675) + first + EBMLW.unknown(0x1F43B675) + second + tags
        let input = base.appendingPathComponent("live.mkv")
        try Data(Self.ebmlHeader() + EBMLW.unknown(0x18538067) + segment).write(to: input)

        let out = base.appendingPathComponent("live.mp4")
        let recorder = ProgressRecorder()
        _ = try MKVRemuxer.remux(input, to: out, progress: { recorder.add($0) })
        let values = recorder.values
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())

        let file = [UInt8](try Data(contentsOf: out))
        let mp4 = MP4File(file)
        let moov = try XCTUnwrap(mp4.top.last)
        let trak = try XCTUnwrap(mp4.child(moov, "trak"))
        let mdhd = try XCTUnwrap(mp4.find(trak, ["mdia", "mdhd"]))
        XCTAssertEqual(mp4.u32(mdhd.payload.lowerBound + 12), 44100)
        let stbl = try XCTUnwrap(mp4.find(trak, ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.table(stbl, "stts", columns: 2), [[5, 1024]])
        XCTAssertEqual(mp4.samples(stbl), frames)
        let stsd = try XCTUnwrap(mp4.child(stbl, "stsd"))
        let mp4a = try XCTUnwrap(mp4.boxes(in: (stsd.payload.lowerBound + 8)..<stsd.end).first)
        let esds = try XCTUnwrap(mp4.boxes(in: (mp4a.payload.lowerBound + 28)..<mp4a.end).first)
        XCTAssertEqual(Array(file[(esds.payload.upperBound - 7)..<esds.payload.upperBound]), [0x05, 2, 0x12, 0x10, 0x06, 1, 0x02])
    }

    func testHeaderStrippedAC3() throws {
        let stripping = EBMLW.el(0x6D80, EBMLW.el(0x6240, EBMLW.uint(0x5031, 0) + EBMLW.uint(0x5032, 1)
            + EBMLW.uint(0x5033, 0) + EBMLW.el(0x5034, EBMLW.uint(0x4254, 3) + EBMLW.el(0x4255, [0x0B, 0x77]))))
        var entries = Self.videoEntry(number: 1)
        entries += Self.trackEntry(number: 2, type: 2, codec: "A_AC3", extra: [
            EBMLW.el(0xE1, EBMLW.float(0xB5, 48000) + EBMLW.uint(0x9F, 6)), stripping,
        ])
        // zlib 压缩的字幕（没写 ContentCompAlgo，默认 0 = zlib）：跳过
        let zlib = EBMLW.el(0x6D80, EBMLW.el(0x6240, EBMLW.el(0x5034, [])))
        entries += Self.trackEntry(number: 3, type: 17, codec: "S_TEXT/ASS", extra: [zlib])
        let tracks = EBMLW.el(0x1654AE6B, entries)

        // 48kHz、frmsizecod 28、bsid 8、3/2 声道 + LFE
        let ac3 = (0..<3).map { [0x0B, 0x77, 0x12, UInt8($0), 0x1C, 0x40, 0xE1] + [UInt8](repeating: 0x55, count: 20) }
        var blocks = EBMLW.uint(0xE7, 0)
        blocks += Self.simpleBlock(track: 1, rel: 0, flags: 0x80, Self.nal(0x65, 40))
        blocks += Self.simpleBlock(track: 2, rel: 10, flags: 0x80, Array(ac3[0].dropFirst(2)))
        blocks += Self.simpleBlock(track: 3, rel: 10, flags: 0x80, [0x78, 0x9C])
        blocks += Self.simpleBlock(track: 1, rel: 40, flags: 0x80, Self.nal(0x65, 30))
        // 后两帧固定大小 lacing：剥离的头部要补到每一帧
        blocks += Self.simpleBlock(track: 2, rel: 42, flags: 0x84, [1] + Array(ac3[1].dropFirst(2)) + Array(ac3[2].dropFirst(2)))
        let input = base.appendingPathComponent("ac3.mkv")
        try Data(Self.mkv([tracks, EBMLW.el(0x1F43B675, blocks)])).write(to: input)

        let out = base.appendingPathComponent("ac3.mp4")
        let result = try MKVRemuxer.remux(input, to: out)
        XCTAssertEqual(result.subtitles.count, 0)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("zlib"), result.skipped[0])

        let file = [UInt8](try Data(contentsOf: out))
        let mp4 = MP4File(file)
        let moov = try XCTUnwrap(mp4.top.last)
        let traks = mp4.children(moov).filter { $0.type == "trak" }
        XCTAssertEqual(traks.count, 2)
        let vstbl = try XCTUnwrap(mp4.find(traks[0], ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.table(vstbl, "stts", columns: 2), [[2, 3600]])
        XCTAssertNil(mp4.child(vstbl, "ctts"))
        XCTAssertNil(mp4.child(traks[0], "edts"))

        let audio = traks[1]
        // 音频晚 10ms 开始：前面 10ms 空白编辑
        let elst = try XCTUnwrap(mp4.find(audio, ["edts", "elst"]))
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 4), 2)
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 8), 10)
        XCTAssertEqual(Int32(bitPattern: mp4.u32(elst.payload.lowerBound + 12)), -1)
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 20), 96)
        XCTAssertEqual(mp4.u32(elst.payload.lowerBound + 24), 0)
        let mdhd = try XCTUnwrap(mp4.find(audio, ["mdia", "mdhd"]))
        XCTAssertEqual(mp4.u32(mdhd.payload.lowerBound + 12), 48000)
        let stbl = try XCTUnwrap(mp4.find(audio, ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.table(stbl, "stts", columns: 2), [[3, 1536]])
        XCTAssertEqual(mp4.samples(stbl), ac3)
        let stsd = try XCTUnwrap(mp4.child(stbl, "stsd"))
        let entry = try XCTUnwrap(mp4.boxes(in: (stsd.payload.lowerBound + 8)..<stsd.end).first)
        XCTAssertEqual(entry.type, "ac-3")
        XCTAssertEqual(mp4.u16(entry.payload.lowerBound + 16), 6)
        XCTAssertEqual(mp4.u32(entry.payload.lowerBound + 24), 48000 << 16)
        let dac3 = try XCTUnwrap(mp4.boxes(in: (entry.payload.lowerBound + 28)..<entry.end).first)
        XCTAssertEqual(dac3.type, "dac3")
        XCTAssertEqual(Array(file[dac3.payload]), [0x10, 0x3D, 0xC0])
    }

    // MARK: MKV 拼装

    static let avcC: [UInt8] = {
        let sps = TSRemuxerTests.baselineSPS
        let pps = TSRemuxerTests.baselinePPS
        return [1, 0x42, 0xC0, 0x0D, 0xFF, 0xE1, 0, UInt8(sps.count)] + sps + [1, 0, UInt8(pps.count)] + pps
    }()

    /// 4 字节长度前缀的 NAL
    static func nal(_ header: UInt8, _ length: Int) -> [UInt8] {
        [0, 0, 0, UInt8(length)] + [header] + [UInt8](repeating: header &+ 1, count: length - 1)
    }

    /// 解码顺序 I P B P B I，显示时间 0 80 40 160 120 200（毫秒）
    static func videoFrames() -> [[UInt8]] {
        (0..<6).map { nal($0 == 0 || $0 == 5 ? 0x65 : 0x41, 50 + $0 * 7) }
    }

    /// 3 帧（EBML lacing）+ 2 帧（Xiph）+ 2 帧（固定）+ 1 帧
    static func audioFrames() -> [[UInt8]] {
        [20, 25, 22, 300, 30, 10, 10, 15].enumerated().map { [UInt8](repeating: UInt8(0xA0 + $0.offset), count: $0.element) }
    }

    static func makeFullMKV() -> [UInt8] {
        var entries = videoEntry(number: 1)
        entries += trackEntry(number: 2, type: 2, codec: "A_AAC", codecPrivate: [0x11, 0x90], extra: [
            EBMLW.el(0xE1, EBMLW.float(0xB5, 48000) + EBMLW.uint(0x9F, 2)),
        ])
        entries += trackEntry(number: 3, type: 17, codec: "S_TEXT/UTF8", extra: [
            EBMLW.str(0x22B59C, "chi"), EBMLW.str(0x536E, "中文"),
        ])
        entries += trackEntry(number: 4, type: 17, codec: "S_TEXT/ASS", codecPrivate: Array("[Script Info]\n".utf8), extra: [
            EBMLW.str(0x22B59C, "jpn"), EBMLW.str(0x22B59D, "ja"), EBMLW.uint(0x88, 0),
        ])
        entries += trackEntry(number: 5, type: 17, codec: "S_HDMV/PGS")
        let tracks = EBMLW.el(0x1654AE6B, entries)
        let info = EBMLW.el(0x1549A966, EBMLW.uint(0x2AD7B1, 1_000_000) + EBMLW.float(0x4489, 240))
        let seekHead = EBMLW.el(0x114D9B74, EBMLW.el(0x4DBB, EBMLW.el(0x53AB, [0x16, 0x54, 0xAE, 0x6B]) + EBMLW.uint(0x53AC, 0)))

        let v = videoFrames()
        let a = audioFrames()
        var c1 = EBMLW.uint(0xE7, 0)
        c1 += EBMLW.el(0xEC, [0, 0, 0])
        c1 += simpleBlock(track: 1, rel: -40, flags: 0x00, nal(0x41, 9))  // 第一个关键帧之前：丢弃
        c1 += simpleBlock(track: 1, rel: 0, flags: 0x80, v[0])
        // 3 帧 EBML lacing：20、+5、最后 22
        c1 += simpleBlock(track: 2, rel: 0, flags: 0x86, [2, 0x94, 0xC4] + a[0] + a[1] + a[2])
        c1 += blockGroup(track: 3, rel: 0, Array("Hello\r\nWorld".utf8), duration: 1000)
        c1 += simpleBlock(track: 1, rel: 80, flags: 0x00, v[1])
        c1 += simpleBlock(track: 1, rel: 40, flags: 0x00, v[2])
        c1 += simpleBlock(track: 5, rel: 40, flags: 0x80, [0x16, 0, 0])
        // 2 帧 Xiph lacing：300 = 255 + 45
        c1 += simpleBlock(track: 2, rel: 64, flags: 0x82, [1, 255, 45] + a[3] + a[4])

        var c2 = EBMLW.el(0xBF, [0, 0, 0, 0])
        c2 += EBMLW.uint(0xE7, 100)
        c2 += blockGroup(track: 1, rel: 60, v[3], reference: -40)
        c2 += simpleBlock(track: 2, rel: 7, flags: 0x84, [1] + a[5] + a[6])
        c2 += simpleBlock(track: 1, rel: 20, flags: 0x00, v[4])
        c2 += blockGroup(track: 4, rel: 400, Array("0,0,Default,,0,0,0,,{\\i1}Hi{\\i0}\\Nthere, friend".utf8), duration: 1000)
        c2 += blockGroup(track: 1, rel: 100, v[5], duration: 40)
        c2 += simpleBlock(track: 2, rel: 50, flags: 0x80, a[7])
        c2 += simpleBlock(track: 3, rel: 1400, flags: 0x80, Array("<i>Bye</i>".utf8))
        let cues = EBMLW.el(0x1C53BB6B, EBMLW.el(0xBB, EBMLW.uint(0xB3, 0)))
        return mkv([seekHead, info, tracks, EBMLW.el(0x1F43B675, c1), EBMLW.el(0x1F43B675, c2), cues])
    }

    static func ebmlHeader() -> [UInt8] {
        EBMLW.el(0x1A45DFA3, EBMLW.uint(0x4286, 1) + EBMLW.uint(0x42F7, 1) + EBMLW.uint(0x42F2, 4)
            + EBMLW.uint(0x42F3, 8) + EBMLW.str(0x4282, "matroska") + EBMLW.uint(0x4287, 4) + EBMLW.uint(0x4285, 2))
    }

    static func mkv(_ children: [[UInt8]]) -> [UInt8] {
        ebmlHeader() + EBMLW.el(0x18538067, children.flatMap { $0 })
    }

    static func trackEntry(number: UInt64, type: UInt64, codec: String, codecPrivate: [UInt8]? = nil,
                           extra: [[UInt8]] = []) -> [UInt8] {
        var payload = EBMLW.uint(0xD7, number) + EBMLW.uint(0x73C5, number * 1000) + EBMLW.uint(0x83, type)
        payload += EBMLW.str(0x86, codec)
        if let codecPrivate { payload += EBMLW.el(0x63A2, codecPrivate) }
        for e in extra { payload += e }
        return EBMLW.el(0xAE, payload)
    }

    static func videoEntry(number: UInt64) -> [UInt8] {
        trackEntry(number: number, type: 1, codec: "V_MPEG4/ISO/AVC", codecPrivate: avcC, extra: [
            EBMLW.uint(0x23E383, 40_000_000),
            EBMLW.el(0xE0, EBMLW.uint(0xB0, 320) + EBMLW.uint(0xBA, 240)),
        ])
    }

    static func blockHeader(track: UInt8, rel: Int16, flags: UInt8) -> [UInt8] {
        let r = UInt16(bitPattern: rel)
        return [0x80 | track, UInt8(r >> 8), UInt8(r & 0xFF), flags]
    }

    static func simpleBlock(track: UInt8, rel: Int16, flags: UInt8, _ payload: [UInt8]) -> [UInt8] {
        EBMLW.el(0xA3, blockHeader(track: track, rel: rel, flags: flags) + payload)
    }

    static func blockGroup(track: UInt8, rel: Int16, _ payload: [UInt8], duration: UInt64? = nil,
                           reference: Int16? = nil) -> [UInt8] {
        var group = EBMLW.el(0xA1, blockHeader(track: track, rel: rel, flags: 0) + payload)
        if let duration { group += EBMLW.uint(0x9B, duration) }
        if let reference { group += EBMLW.el(0xFB, [UInt8(bitPattern: Int8(clamping: reference))]) }
        return EBMLW.el(0xA0, group)
    }
}

/// 进度回调记录（回调是 @Sendable）
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []

    func add(_ v: Double) {
        lock.lock()
        _values.append(v)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }
}

/// 测试用 EBML 写入
enum EBMLW {
    static func id(_ v: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            let b = UInt8((v >> UInt32(shift)) & 0xFF)
            if b != 0 || !out.isEmpty { out.append(b) }
        }
        return out
    }

    /// 最短的大小编码（1 / 2 字节），更大的用 8 字节
    static func size(_ n: Int) -> [UInt8] {
        if n < 127 { return [0x80 | UInt8(n)] }
        if n < 16383 { return [0x40 | UInt8(n >> 8), UInt8(n & 0xFF)] }
        var out: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) { out.append(UInt8((n >> shift) & 0xFF)) }
        return out
    }

    static func el(_ id: UInt32, _ payload: [UInt8]) -> [UInt8] {
        self.id(id) + size(payload.count) + payload
    }

    /// 未知大小的元素头
    static func unknown(_ id: UInt32) -> [UInt8] {
        self.id(id) + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    }

    static func uint(_ id: UInt32, _ v: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat {
            bytes.insert(UInt8(x & 0xFF), at: 0)
            x >>= 8
        } while x > 0
        return el(id, bytes)
    }

    static func str(_ id: UInt32, _ s: String) -> [UInt8] { el(id, Array(s.utf8)) }

    static func float(_ id: UInt32, _ d: Double) -> [UInt8] {
        let bits = d.bitPattern
        return el(id, (0..<8).map { UInt8((bits >> UInt64(56 - $0 * 8)) & 0xFF) })
    }
}
