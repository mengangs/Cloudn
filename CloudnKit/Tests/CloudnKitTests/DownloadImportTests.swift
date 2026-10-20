import XCTest
@testable import CloudnKit

/// 本地文件登记为已完成下载（网页录制保存用），不需要网络
final class DownloadImportTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    func makeEngine() -> DownloadEngine {
        DownloadEngine(baseDirectory: base.appendingPathComponent("state"), downloadsDirectory: base.appendingPathComponent("dl")) {
            DownloadSettings(maxConcurrentTasks: 3, connectionsPerTask: 4, retryCount: 1)
        }
    }

    func testImportFinishedFileMovesIntoDownloads() async throws {
        let engine = makeEngine()
        let payload = Data("hello".utf8)
        let source = base.appendingPathComponent("rec.mp4")
        try payload.write(to: source)
        let item = try await engine.importFinishedFile(source, request: DownloadRequest(url: "https://example.com/page", fileName: "录制.mp4", source: "网页录制"))
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.outputPath, "录制.mp4")
        XCTAssertEqual(item.totalBytes, Int64(payload.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let saved = try XCTUnwrap(engine.fileURL(for: item))
        XCTAssertEqual(try Data(contentsOf: saved), payload)

        // 重名自动编号
        try payload.write(to: source)
        let second = try await engine.importFinishedFile(source, request: DownloadRequest(url: "", fileName: "录制.mp4"))
        XCTAssertEqual(second.outputPath, "录制 (1).mp4")
        let all = await engine.snapshot()
        XCTAssertEqual(all.count, 2)
    }

    func testImportMissingFileThrowsAndLeavesNoItem() async throws {
        let engine = makeEngine()
        let missing = base.appendingPathComponent("nope.mp4")
        do {
            _ = try await engine.importFinishedFile(missing, request: DownloadRequest(url: "", fileName: "x.mp4"))
            XCTFail("应当抛错")
        } catch {}
        let all = await engine.snapshot()
        XCTAssertTrue(all.isEmpty)
    }
}
