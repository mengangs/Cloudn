import XCTest
@testable import CloudnKit

/// 前台下了一部分 → 交给「后台会话」（这里用 HTTPClient 模拟）→ 分片写回 → 文件逐字节一致。
/// 需要本地测试服务器（同 DownloadEngineTests）。
final class BackgroundHandoffTests: XCTestCase {
    var server: String!
    var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["CLOUDN_TEST_SERVER"] else {
            throw XCTSkip("未设置 CLOUDN_TEST_SERVER")
        }
        server = s
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    func makeEngine(connections: Int) -> DownloadEngine {
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

    /// 等到分片计划已生成、且前台已经写下了一些数据
    func waitStarted(_ engine: DownloadEngine, _ id: UUID) async throws {
        for _ in 0..<100 {
            if let item = await engine.snapshot().first(where: { $0.id == id }), !item.chunks.isEmpty, item.receivedBytes > 0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("前台下载没有开始")
    }

    /// 模拟系统后台会话下载一个分片，返回 (状态码, 临时文件)
    func simulate(_ job: BackgroundChunkJob) async throws -> (Int, URL) {
        var headers = job.headers.map { ($0.key, $0.value) }
        if let range = job.rangeHeader { headers.append(("Range", range)) }
        let r = try await HTTPClient.shared.send(.get(job.url, headers: headers))
        let file = base.appendingPathComponent("bg-\(UUID().uuidString)")
        try r.body.write(to: file)
        return (r.status, file)
    }

    func testHandOffAndApply() async throws {
        let engine = makeEngine(connections: 4)
        let size = 8 * 1024 * 1024 + 77
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(size)?slow=1", fileName: "bg.bin"))
        try await waitStarted(engine, id)

        let jobs = await engine.handOffToBackground()
        XCTAssertFalse(jobs.isEmpty)
        XCTAssertTrue(jobs.allSatisfy { $0.itemId == id && $0.end >= 0 })
        let handed = await engine.snapshot().first { $0.id == id }!
        XCTAssertTrue(handed.backgrounded)
        XCTAssertEqual(handed.status, .running)
        // 交出后再调用不会重复交出
        let again = await engine.handOffToBackground()
        XCTAssertTrue(again.isEmpty)

        for job in jobs {
            XCTAssertEqual(BackgroundChunkJob.parse(taskDescription: job.taskDescription)?.chunkIndex, job.chunkIndex)
            let (status, file) = try await simulate(job)
            await engine.backgroundProgress(itemId: id, chunkIndex: job.chunkIndex, offset: job.offset, written: 1024)
            let ok = await engine.applyBackgroundChunk(itemId: id, chunkIndex: job.chunkIndex, offset: job.offset, status: status, file: file)
            XCTAssertTrue(ok)
        }
        let item = try await wait(engine, id, for: .completed)
        XCTAssertFalse(item.backgrounded)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
    }

    func testFailedChunkFallsBackToForeground() async throws {
        let engine = makeEngine(connections: 4)
        let size = 8 * 1024 * 1024
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(size)?slow=1", fileName: "fb.bin"))
        try await waitStarted(engine, id)
        let jobs = await engine.handOffToBackground()
        XCTAssertGreaterThan(jobs.count, 1)

        // 第一个分片在后台完成，第二个返回了错误的状态码（被判为不可用）
        let (status, file) = try await simulate(jobs[0])
        let applied = await engine.applyBackgroundChunk(itemId: id, chunkIndex: jobs[0].chunkIndex, offset: jobs[0].offset, status: status, file: file)
        XCTAssertTrue(applied)
        let bad = base.appendingPathComponent("bad")
        try Data("x".utf8).write(to: bad)
        let rejected = await engine.applyBackgroundChunk(itemId: id, chunkIndex: jobs[1].chunkIndex, offset: jobs[1].offset, status: 403, file: bad)
        XCTAssertFalse(rejected)
        await engine.backgroundChunkFailed(itemId: id)

        // 退回前台后从已落盘的位置续传，结果仍逐字节一致
        let item = try await wait(engine, id, for: .completed, timeout: 60)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
    }

    func testRelaunchKeepsBackgroundedAndReconciles() async throws {
        var engine: DownloadEngine? = makeEngine(connections: 4)
        let size = 6 * 1024 * 1024
        let id = await engine!.enqueue(DownloadRequest(url: "\(server!)/file/\(size)?slow=1", fileName: "re.bin"))
        try await waitStarted(engine!, id)
        _ = await engine!.handOffToBackground()
        engine = nil

        // 进程被系统回收后重新启动：后台任务保持运行，不被改成暂停
        let engine2 = makeEngine(connections: 4)
        let restored = await engine2.snapshot().first { $0.id == id }!
        XCTAssertEqual(restored.status, .running)
        XCTAssertTrue(restored.backgrounded)
        let ids = await engine2.backgroundedItemIds()
        XCTAssertEqual(ids, [id])

        // 会话里已没有对应任务（例如用户强制退出）：退回前台继续
        await engine2.reconcileBackground(activeItemIds: [])
        let item = try await wait(engine2, id, for: .completed, timeout: 60)
        XCTAssertEqual(try Data(contentsOf: engine2.fileURL(for: item)!), expected(size))
    }

    func testPauseLeavesBackground() async throws {
        let engine = makeEngine(connections: 2)
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(6 * 1024 * 1024)?slow=1", fileName: "p.bin"))
        try await waitStarted(engine, id)
        let jobs = await engine.handOffToBackground()
        await engine.pause(id)
        let paused = await engine.snapshot().first { $0.id == id }!
        XCTAssertEqual(paused.status, .paused)
        XCTAssertFalse(paused.backgrounded)
        // 暂停后才送达的后台结果直接作废
        let (status, file) = try await simulate(jobs[0])
        let ok = await engine.applyBackgroundChunk(itemId: id, chunkIndex: jobs[0].chunkIndex, offset: jobs[0].offset, status: status, file: file)
        XCTAssertTrue(ok)
        let after = await engine.snapshot().first { $0.id == id }!
        XCTAssertEqual(after.chunks, paused.chunks)
    }
}
