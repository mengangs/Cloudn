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

    /// 每个分片切成小段交给后台：下完的段逐段写回，某段失败退回前台时已写回的段保留
    func testSplitHandOffKeepsFinishedPieces() async throws {
        let engine = makeEngine(connections: 1)
        await engine.setHandOffPieceSize(1024 * 1024)
        let size = 6 * 1024 * 1024 + 5
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(size)?slow=1", fileName: "split.bin"))
        try await waitStarted(engine, id)
        let jobs = await engine.handOffToBackground()
        XCTAssertGreaterThanOrEqual(jobs.count, 5)
        XCTAssertTrue(jobs.allSatisfy { $0.end - $0.offset + 1 <= 1024 * 1024 })
        // 各段无缝覆盖剩下的部分
        let handed = await engine.snapshot().first { $0.id == id }!
        XCTAssertEqual(jobs.map { $0.end - $0.offset + 1 }.reduce(0, +), Int64(size) - handed.receivedBytes)

        for job in jobs.prefix(2) {
            let (status, file) = try await simulate(job)
            let ok = await engine.applyBackgroundChunk(itemId: id, chunkIndex: job.chunkIndex, offset: job.offset, end: job.end,
                                                       status: status, file: file)
            XCTAssertTrue(ok)
        }
        // 第三段失败：退回前台，前两段保留
        await engine.backgroundChunkFailed(itemId: id)
        let fallen = await engine.snapshot().first { $0.id == id }!
        XCTAssertFalse(fallen.backgrounded)
        for job in jobs.prefix(2) { XCTAssertTrue(fallen.chunks[job.chunkIndex].isDone) }
        let item = try await wait(engine, id, for: .completed, timeout: 60)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
    }

    /// 旧一轮交出的、对不上当前计划的结果作废（不算失败，也不会把没下的部分标成完成）
    func testStaleBackgroundResultIgnored() async throws {
        let engine = makeEngine(connections: 1)
        await engine.setHandOffPieceSize(1024 * 1024)
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(4 * 1024 * 1024)?slow=1", fileName: "stale.bin"))
        try await waitStarted(engine, id)
        let jobs = await engine.handOffToBackground()
        let job = try XCTUnwrap(jobs.last)
        let before = await engine.snapshot().first { $0.id == id }!
        // 起点越过了已落盘的位置（中间有一段没下）
        let bad = base.appendingPathComponent("stale")
        try Data(count: 10).write(to: bad)
        let ok = await engine.applyBackgroundChunk(itemId: id, chunkIndex: job.chunkIndex, offset: job.offset + 5, end: job.end, status: 206, file: bad)
        XCTAssertTrue(ok)
        let after = await engine.snapshot().first { $0.id == id }!
        XCTAssertEqual(after.chunks, before.chunks)
        await engine.pause(id)
    }

    /// 回到前台：后台下载收回前台继续（已写回的段保留），结果逐字节一致
    func testEnterForegroundReclaims() async throws {
        let engine = makeEngine(connections: 2)
        await engine.setHandOffPieceSize(1024 * 1024)
        let size = 5 * 1024 * 1024
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(size)?slow=1", fileName: "fg.bin"))
        try await waitStarted(engine, id)
        let jobs = await engine.enterBackground()
        XCTAssertFalse(jobs.isEmpty)
        let (status, file) = try await simulate(jobs[0])
        _ = await engine.applyBackgroundChunk(itemId: id, chunkIndex: jobs[0].chunkIndex, offset: jobs[0].offset, end: jobs[0].end,
                                              status: status, file: file)
        let reclaimed = await engine.enterForeground()
        XCTAssertEqual(reclaimed, [id])
        let back = await engine.snapshot().first { $0.id == id }!
        XCTAssertFalse(back.backgrounded)
        XCTAssertTrue(back.chunks[jobs[0].chunkIndex].isDone)
        let item = try await wait(engine, id, for: .completed, timeout: 60)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
    }

    /// 在后台时排队的单文件任务不开前台下载：探测大小后按段交给后台会话；m3u8 等留在队列里等回到前台
    func testQueuedItemsHandedOffWhileInBackground() async throws {
        let engine = makeEngine(connections: 2)
        await engine.setHandOffPieceSize(1024 * 1024)
        let collected = JobBox()
        await engine.setBackgroundSubmitter { collected.add($0) }
        _ = await engine.enterBackground()
        let size = 9 * 1024 * 1024 + 9
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(size)", fileName: "queued.bin"))
        let hls = await engine.enqueue(DownloadRequest(url: "\(server!)/hls/master.m3u8", fileName: "v.mp4", kind: .hls))
        var jobs: [BackgroundChunkJob] = []
        for _ in 0..<100 {
            jobs = collected.jobs
            if !jobs.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(jobs.count, 4)
        XCTAssertTrue(jobs.allSatisfy { $0.itemId == id })
        let handed = await engine.snapshot().first { $0.id == id }!
        XCTAssertEqual(handed.status, .running)
        XCTAssertTrue(handed.backgrounded)
        XCTAssertEqual(handed.totalBytes, Int64(size))
        let waiting = await engine.snapshot().first { $0.id == hls }!
        XCTAssertEqual(waiting.status, .queued)

        for job in jobs {
            let (status, file) = try await simulate(job)
            let ok = await engine.applyBackgroundChunk(itemId: id, chunkIndex: job.chunkIndex, offset: job.offset, end: job.end,
                                                       status: status, file: file)
            XCTAssertTrue(ok)
        }
        let item = try await wait(engine, id, for: .completed)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
        // 回到前台后 m3u8 才开始
        await engine.enterForeground()
        _ = try await wait(engine, hls, for: .completed)
    }

    /// 被系统在后台拉起时不开前台下载
    func testLaunchedInBackgroundDoesNotStartForeground() async throws {
        let engine = DownloadEngine(baseDirectory: base.appendingPathComponent("state"), downloadsDirectory: base.appendingPathComponent("dl"),
                                    launchedInBackground: true) {
            DownloadSettings(maxConcurrentTasks: 3, connectionsPerTask: 2, retryCount: 2)
        }
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/hls/master.m3u8", fileName: "v.mp4", kind: .hls))
        try await Task.sleep(nanoseconds: 800_000_000)
        let item = await engine.snapshot().first { $0.id == id }!
        XCTAssertEqual(item.status, .queued)
        await engine.enterForeground()
        _ = try await wait(engine, id, for: .completed)
    }

    /// 换链后新直链的大小和已下的对不上：丢掉已下部分，按新文件重新下载
    func testReplaceLinkWithDifferentSizeRestarts() async throws {
        let engine = makeEngine(connections: 2)
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(6 * 1024 * 1024)?slow=1", fileName: "swap.bin"))
        try await waitStarted(engine, id)
        await engine.pause(id)
        let size = 5 * 1024 * 1024 + 3
        await engine.replaceLink(id, url: "\(server!)/file/\(size)", headers: [:])
        let item = try await wait(engine, id, for: .completed)
        XCTAssertEqual(item.totalBytes, Int64(size))
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
    }

    /// 换链后大小一致：已下的分片保留，接着下
    func testReplaceLinkWithSameSizeContinues() async throws {
        let engine = makeEngine(connections: 2)
        let size = 6 * 1024 * 1024
        let id = await engine.enqueue(DownloadRequest(url: "\(server!)/file/\(size)?slow=1", fileName: "same.bin"))
        try await waitStarted(engine, id)
        await engine.pause(id)
        let paused = await engine.snapshot().first { $0.id == id }!
        await engine.replaceLink(id, url: "\(server!)/file/\(size)?slow=1&new=1", headers: [:])
        let item = try await wait(engine, id, for: .completed)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(size))
        XCTAssertGreaterThan(paused.receivedBytes, 0)
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
        // 暂停前已下完、暂停后才送达的段照样写回（暂停的任务没有连接在写），继续时不用重下
        let (status, file) = try await simulate(jobs[0])
        let ok = await engine.applyBackgroundChunk(itemId: id, chunkIndex: jobs[0].chunkIndex, offset: jobs[0].offset, end: jobs[0].end,
                                                   status: status, file: file)
        XCTAssertTrue(ok)
        let after = await engine.snapshot().first { $0.id == id }!
        XCTAssertEqual(after.status, .paused)
        XCTAssertFalse(paused.chunks[jobs[0].chunkIndex].isDone)
        XCTAssertTrue(after.chunks[jobs[0].chunkIndex].isDone)
        // 继续后结果逐字节一致
        await engine.resume(id)
        let item = try await wait(engine, id, for: .completed, timeout: 60)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(for: item)!), expected(6 * 1024 * 1024))

        // 继续（前台连接在写）之后才送达的结果作废
        let late = base.appendingPathComponent("late")
        try Data(count: 10).write(to: late)
        let ignored = await engine.applyBackgroundChunk(itemId: id, chunkIndex: 0, offset: 0, status: 206, file: late)
        XCTAssertTrue(ignored)
    }
}

/// 收集提交给「后台会话」的任务
final class JobBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _jobs: [BackgroundChunkJob] = []
    func add(_ jobs: [BackgroundChunkJob]) { lock.lock(); _jobs += jobs; lock.unlock() }
    var jobs: [BackgroundChunkJob] { lock.lock(); defer { lock.unlock() }; return _jobs }
}
