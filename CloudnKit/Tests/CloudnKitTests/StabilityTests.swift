// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 不可信输入（网络 / 文件 / 服务端数据）里的极端值不能让进程崩溃：
/// Double → 整数转换、整数溢出、负下标、递归过深
final class StabilityTests: XCTestCase {

    // MARK: Double → 整数

    func testSaturatingConversions() {
        XCTAssertEqual(Int64(saturating: 1e30), .max)
        XCTAssertEqual(Int64(saturating: -1e30), .min)
        XCTAssertEqual(Int64(saturating: .infinity), .max)
        XCTAssertEqual(Int64(saturating: -.infinity), .min)
        XCTAssertEqual(Int64(saturating: .nan), 0)
        XCTAssertEqual(Int64(saturating: 9.223372036854775807e18), .max)
        XCTAssertEqual(Int64(saturating: 12.9), 12)
        XCTAssertEqual(Int64(saturating: -12.9), -12)
        XCTAssertEqual(Int(saturating: .nan), 0)
        XCTAssertEqual(Int(saturating: 1e300), .max)
    }

    func testJSONNumbersOutOfRange() {
        let json = JSON(data: Data(#"{"big":1e30,"neg":-1e30,"s":"1e30","inf":"inf","nan":"nan","n":"42","f":"3.9"}"#.utf8))!
        XCTAssertEqual(json["big"].int64, .max)
        XCTAssertEqual(json["neg"].int64, .min)
        XCTAssertEqual(json["s"].int64, .max)
        XCTAssertEqual(json["inf"].int64, .max)
        XCTAssertEqual(json["nan"].int64, 0)
        XCTAssertEqual(json["n"].int, 42)
        XCTAssertEqual(json["f"].int64, 3)
        XCTAssertEqual(json["inf"].double, 0)
        XCTAssertEqual(json["nan"].double, 0)
        XCTAssertEqual(json["f"].double, 3.9)
        // 宽松 JS 字面量里的 Infinity
        let lit = JSLiteral.parse("{d: Infinity, e: -Infinity}")!.json
        XCTAssertEqual(lit["d"].double, 0)
        XCTAssertEqual(lit["e"].double, 0)
        XCTAssertEqual(lit["d"].int64, .max)
    }

    func testParseDisplayHugeNumber() {
        XCTAssertEqual(ByteFormat.parseDisplay("999999999999999999999999 T"), .max)
        XCTAssertEqual(ByteFormat.parseDisplay("1.5 K"), 1536)
    }

    // MARK: HLS

    func testM3U8HostileValues() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:9223372036854775807
        #EXTINF:inf,
        a.ts
        #EXTINF:nan,
        b.ts
        #EXTINF:1e400,
        c.ts
        #EXTINF:4.5,
        #EXT-X-BYTERANGE:9223372036854775807@9223372036854775807
        d.ts
        """
        let list = M3U8.parse(text, baseURL: "https://example.com/x/index.m3u8")
        XCTAssertEqual(list.segments.count, 4)
        XCTAssertEqual(list.totalDuration, 4.5)
        XCTAssertNil(list.segments[3].range)
        // 序号溢出时回绕，不崩溃
        XCTAssertEqual(list.segments[0].sequence, .max)
        XCTAssertEqual(list.segments[1].sequence, .min)

        let negative = M3U8.parse("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:-5\n#EXTINF:1,\na.ts\n", baseURL: "https://example.com/")
        XCTAssertEqual(negative.segments.first?.sequence, 0)
        XCTAssertEqual(HLSTransfer.sequenceIV(-1).count, 16)
        XCTAssertEqual(Array(HLSTransfer.sequenceIV(-1).suffix(8)), [UInt8](repeating: 0xFF, count: 8))
    }

    func testByteRangeOverflow() {
        XCTAssertNil(M3U8.ByteRange.parse("10@9223372036854775800", previousEnd: 0))
        XCTAssertNil(M3U8.ByteRange.parse("9223372036854775807", previousEnd: 1))
        XCTAssertEqual(M3U8.ByteRange.parse("100@50", previousEnd: 0), M3U8.ByteRange(offset: 50, length: 100))
    }

    // MARK: 字幕

    func testSubtitleHostileTimes() throws {
        let vtt = "WEBVTT\n\n99999999999999999999:00:00.000 --> inf:00:00.000\nHi\n\n00:00:01.000 --> 00:00:02.000\nThere\n"
        let cues = SubtitleConverter.vttCues(vtt)
        XCTAssertEqual(cues.last?.text, "There")
        let srt = try XCTUnwrap(SubtitleConverter.toSRT(Data(vtt.utf8), format: .vtt))
        XCTAssertTrue(String(decoding: srt, as: UTF8.self).contains("There"))

        let json3 = #"{"events":[{"tStartMs":9223372036854775807,"dDurationMs":9223372036854775807,"segs":[{"utf8":"a"}]},"# +
            #"{"tStartMs":-9223372036854775807,"segs":[{"utf8":"b"}]},{"tStartMs":1e300,"segs":[{"utf8":"c"}]}]}"#
        let yt = SubtitleConverter.json3Cues(try XCTUnwrap(JSON(data: Data(json3.utf8))))
        XCTAssertEqual(yt.count, 3)
        XCTAssertTrue(yt.allSatisfy { $0.start >= 0 && $0.end >= $0.start })
        XCTAssertNotNil(SubtitleConverter.toSRT(Data(json3.utf8), format: .youtubeJSON3))

        let bili = #"{"body":[{"from":1e300,"to":-1e300,"content":"x"},{"from":"inf","to":"nan","content":"y"}]}"#
        let b = SubtitleConverter.biliCues(try XCTUnwrap(JSON(data: Data(bili.utf8))))
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[1].start, 0)
    }

    // MARK: 递归深度

    func testDeeplyNestedLiteralsDoNotOverflowStack() {
        let depth = 100_000
        let deep = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        XCTAssertNil(JSLiteral.parse(deep))
        XCTAssertNil(OrderedValue.parse(deep))
        let deepObject = String(repeating: "{a:", count: depth) + "1" + String(repeating: "}", count: depth)
        XCTAssertNil(JSLiteral.parse(deepObject))
        // 正常深度照常解析
        let ok = String(repeating: "[", count: 50) + "1" + String(repeating: "]", count: 50)
        XCTAssertNotNil(JSLiteral.parse(ok))
        XCTAssertNotNil(OrderedValue.parse(ok))
    }

    // MARK: 尺寸 / 偏移

    func testEstimatedSpaceDoesNotOverflow() {
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .hls, expected: .max, total: -1, received: 0), .max)
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .dash(audioURL: "a"), expected: .max / 2 + 1, total: -1, received: 10), .max - 10)
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .hls, expected: 100, total: -1, received: 50), 150)
    }

    func testBackgroundTaskDescriptionRejectsNegatives() {
        let id = UUID()
        XCTAssertNil(BackgroundChunkJob.parse(taskDescription: "\(id.uuidString)|-1|0|10"))
        XCTAssertNil(BackgroundChunkJob.parse(taskDescription: "\(id.uuidString)|0|-5|10"))
        XCTAssertEqual(BackgroundChunkJob.parse(taskDescription: "\(id.uuidString)|2|0|-1")?.chunkIndex, 2)
    }

    func testSignCheckRejectsOverflowingRange() {
        XCTAssertNil(Pan115Resolver.parseSignCheck("0-9223372036854775807"))
        XCTAssertEqual(Pan115Resolver.parseSignCheck("0-9223372036854775806")?.end, 9_223_372_036_854_775_806)
    }

    // MARK: MKV

    func testMKVHostileTrackValues() throws {
        XCTAssertFalse(MKVTrack.isPlausibleSampleRate(.nan))
        XCTAssertFalse(MKVTrack.isPlausibleSampleRate(.infinity))
        XCTAssertFalse(MKVTrack.isPlausibleSampleRate(1e30))
        XCTAssertTrue(MKVTrack.isPlausibleSampleRate(44100))

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-stability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // 采样率 NaN、输出采样率 inf、每帧时长离谱、簇时间戳全 1：以前分别会在 Int(Double) / 整数相加时崩溃
        let audio = MKVRemuxerTests.trackEntry(number: 1, type: 2, codec: "A_AAC/MPEG4/LC/SBR", extra: [
            EBMLW.uint(0x23E383, UInt64.max),
            EBMLW.el(0xE1, EBMLW.float(0xB5, .nan) + EBMLW.float(0x78B5, .infinity) + EBMLW.uint(0x9F, 2)),
        ])
        let tracks = EBMLW.el(0x1654AE6B, audio)
        var cluster = EBMLW.uint(0xE7, UInt64.max)
        cluster += MKVRemuxerTests.simpleBlock(track: 1, rel: 0, flags: 0x80, [UInt8](repeating: 0x21, count: 12))
        cluster += MKVRemuxerTests.simpleBlock(track: 1, rel: 32767, flags: 0x80, [UInt8](repeating: 0x22, count: 12))
        let input = base.appendingPathComponent("hostile.mkv")
        try Data(MKVRemuxerTests.mkv([tracks, EBMLW.el(0x1F43B675, cluster)])).write(to: input)
        let out = base.appendingPathComponent("hostile.mp4")
        _ = try MKVRemuxer.remux(input, to: out)
        let mp4 = MP4File([UInt8](try Data(contentsOf: out)))
        let moov = try XCTUnwrap(mp4.top.last)
        let trak = try XCTUnwrap(mp4.child(moov, "trak"))
        let stbl = try XCTUnwrap(mp4.find(trak, ["mdia", "minf", "stbl"]))
        XCTAssertEqual(mp4.samples(stbl).count, 2)
    }

    // MARK: 并发

    func testTaskBoxConcurrentAccess() {
        let box = TaskBox()
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            if i % 2 == 0 { box.task = nil } else { _ = box.task }
        }
        XCTAssertNil(box.task)
    }
}
