import XCTest
@testable import CloudnKit

/// 需要本地测试服务器：python3 Tests/Server/test_server.py 8765，并设置 CLOUDN_TEST_SERVER=http://127.0.0.1:8765
final class DownloadEngineTests: XCTestCase {
    var server: String!
    var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["CLOUDN_TEST_SERVER"] else {
            throw XCTSkip("未设置 CLOUDN_TEST_SERVER")
        }
        server = s
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    func makeEngine(connections: Int = 8) -> DownloadEngine {
        DownloadEngine(baseDirectory: base.appendingPathComponent("state"), downloadsDirectory: base.appendingPathComponent("dl")) {
            DownloadSettings(maxConcurrentTasks: 3, connectionsPerTask: connections, retryCount: 2)
        }
    }

    func expected(_ size: Int) -> Data {
        Data((0..<size).map { UInt8(($0 * 7 + 3) % 251) })
    }

    func wait(_ engine: DownloadEngine, _ id: UUID, for status: DownloadStatus, timeout: TimeInterval = 30) async throws -> DownloadItem {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let item = await engine.snapshot().first(where: { $0.id == id }) {
                if item.status == status { return item }
                if item.status == .failed && status != .failed { XCTFail("下载失败：\(item.errorMessage ?? "")"); return item }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("等待 \(status) 超时")
        throw CancellationError()
    }

    func testMultiConnectionDownload() async throws {
        let engine = makeEngine()
        let size = 20 * 1024 * 1024 + 123
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(size)", fileName: "big.bin", folder: "a/b"))
        let item = try await wait(engine, id, for: .completed)
        XCTAssertEqual(item.outputPath, "a/b/big.bin")
        let data = try Data(contentsOf: engine.fileURL(for: item)!)
        XCTAssertEqual(data, expected(size))
    }

    /// 多源分片：一条正常链接 + 一条被拒绝的链接，分片应自动换用可用的链接并完整下载
    func testMultiSourceFallsBackFromRejectedMirror() async throws {
        let engine = makeEngine()
        let size = 12 * 1024 * 1024 + 7
        let mirrors = [DownloadSource(url: "\(server!)/file/\(size)?m=1", headers: [:]),
                       DownloadSource(url: "\(server!)/forbidden", headers: [:])]
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(size)", fileName: "multi.bin", mirrors: mirrors))
        let item = try await wait(engine, id, for: .completed)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
        XCTAssertEqual(RangeTransfer.sourceIndex(chunk: 2, attempt: 0, count: 3), 2)
        XCTAssertEqual(RangeTransfer.sourceIndex(chunk: 2, attempt: 1, count: 3), 0)
        XCTAssertEqual(RangeTransfer.sourceIndex(chunk: 5, attempt: 0, count: 1), 0)
    }

    func testNoRangeServer() async throws {
        let engine = makeEngine()
        let size = 3 * 1024 * 1024
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/norange/\(size)", fileName: "n.bin"))
        let item = try await wait(engine, id, for: .completed)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
    }

    func testPauseResumeAndPersistence() async throws {
        var engine: DownloadEngine? = makeEngine(connections: 4)
        let size = 8 * 1024 * 1024
        let id = await engine!.enqueue(DownloadRequest(url: "\(server!)/file/\(size)?slow=1", fileName: "slow.bin"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        await engine!.pause(id)
        let paused = await engine!.snapshot().first { $0.id == id }!
        XCTAssertEqual(paused.status, .paused)
        XCTAssertGreaterThan(paused.receivedBytes, 0)
        XCTAssertLessThan(paused.receivedBytes, Int64(size))
        // 模拟重启：新引擎从磁盘恢复任务表与分片进度
        engine = nil
        let engine2 = makeEngine(connections: 4)
        let restored = await engine2.snapshot().first { $0.id == id }!
        XCTAssertEqual(restored.status, .paused)
        XCTAssertFalse(restored.chunks.isEmpty)
        await engine2.resume(id)
        let item = try await wait(engine2, id, for: .completed, timeout: 60)
        XCTAssertEqual(try Data(contentsOf: engine2.fileURL(for: item)!), expected(size))
    }

    func testHLS() async throws {
        let engine = makeEngine()
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/hls/master.m3u8", fileName: "v.mp4", kind: .hls))
        let item = try await wait(engine, id, for: .completed)
        XCTAssertEqual(item.outputPath, "v.ts")
        let data = try Data(contentsOf: engine.fileURL(for: item)!)
        XCTAssertEqual(data.count, 5000)
        XCTAssertEqual(data[0], 0)
        XCTAssertEqual(data[4999], 4)
        XCTAssertEqual(item.segmentsTotal, 5)
    }

    func testForbiddenFailsWithMessage() async throws {
        let engine = makeEngine()
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/forbidden", fileName: "x"))
        let item = try await wait(engine, id, for: .failed)
        XCTAssertTrue(item.errorMessage?.contains("403") ?? false)
    }

    func testUniqueNames() async throws {
        let engine = makeEngine()
        let a = await engine.enqueue(DownloadRequest(url: "\(server!)/file/1000", fileName: "same.bin"))
        _ = try await wait(engine, a, for: .completed)
        let b = await engine.enqueue(DownloadRequest(url: "\(server!)/file/1000", fileName: "same.bin"))
        let item = try await wait(engine, b, for: .completed)
        XCTAssertEqual(item.outputPath, "same (1).bin")
    }

    func testM3U8AudioRendition() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="a1",DEFAULT=NO,URI="audio_lo.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="a2",DEFAULT=YES,URI="audio_hi.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud"
        v720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aud"
        v1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=300000
        v360.m3u8
        """
        let p = M3U8.parse(text, baseURL: "https://h/p/master.m3u8")
        XCTAssertEqual(p.bestVariant?.url, "https://h/p/v1080.m3u8")
        XCTAssertEqual(p.bestVariant?.audio, "https://h/p/audio_hi.m3u8")
        let plain = M3U8.parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n", baseURL: "https://h/p/m.m3u8")
        XCTAssertNil(plain.bestVariant?.audio)
    }

    func testM3U8Parse() {
        let p = M3U8.parse("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.bin\",IV=0x000102030405060708090a0b0c0d0e0f\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\nhttps://cdn/a.m4s\n", baseURL: "https://h/p/list.m3u8")
        XCTAssertEqual(p.mapURL, "https://h/p/init.mp4")
        XCTAssertEqual(p.segments.first?.key?.uri, "https://h/p/k.bin")
        XCTAssertEqual(p.segments.first?.key?.iv?.count, 16)
        XCTAssertEqual(HLSTransfer.sequenceIV(1).last, 1)
    }
}
