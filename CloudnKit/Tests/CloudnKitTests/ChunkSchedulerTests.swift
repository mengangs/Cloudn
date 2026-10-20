import XCTest
@testable import CloudnKit

/// 弹性分片与慢连接抢占的纯逻辑（不联网）
final class ChunkSchedulerTests: XCTestCase {
    private let mb: Int64 = 1024 * 1024

    func testSplitHalvesRemainingRange() {
        let p = TransferProgress(chunks: [DownloadChunk(start: 0, end: 10 * mb - 1, received: 2 * mb)], total: 10 * mb)
        let new = p.split(0, minPiece: mb)
        XCTAssertEqual(new, 1)
        let c = p.chunks
        // 还剩 [2MB, 10MB)，从 6MB 处切开
        XCTAssertEqual(c[0].end, 6 * mb - 1)
        XCTAssertEqual(c[1].start, 6 * mb)
        XCTAssertEqual(c[1].end, 10 * mb - 1)
        XCTAssertEqual(c[1].received, 0)
        // 两段首尾相接，总长不变
        XCTAssertEqual((c[0].end - c[0].start + 1) + (c[1].end - c[1].start + 1), 10 * mb)
    }

    func testSplitRefusesSmallOrOpenEndedChunks() {
        let p = TransferProgress(chunks: [DownloadChunk(start: 0, end: 3 * mb - 1, received: 2 * mb),
                                          DownloadChunk(start: 0, end: -1, received: 0)], total: 0)
        XCTAssertNil(p.split(0, minPiece: mb))
        XCTAssertNil(p.split(1, minPiece: mb))
        XCTAssertEqual(p.chunks.count, 2)
    }

    func testAddClampsToShrunkenEnd() {
        let p = TransferProgress(chunks: [DownloadChunk(start: 0, end: 4 * mb - 1, received: 0)], total: 4 * mb)
        _ = p.split(0, minPiece: mb)
        // 切开前已发出的一笔越过了新终点
        p.add(0, 3 * mb)
        XCTAssertEqual(p.chunk(0).received, 2 * mb)
        XCTAssertTrue(p.chunk(0).isDone)
        p.add(1, 2 * mb)
        XCTAssertEqual(p.received, 4 * mb)
    }

    func testClaimTakesUnclaimedThenSplitsLargest() {
        let p = TransferProgress(chunks: [DownloadChunk(start: 0, end: 8 * mb - 1, received: 0),
                                          DownloadChunk(start: 8 * mb, end: 10 * mb - 1, received: 0)], total: 10 * mb)
        let s = ChunkScheduler()
        XCTAssertEqual(s.claim(progress: p, splittable: true, minPiece: mb), 0)
        XCTAssertEqual(s.claim(progress: p, splittable: true, minPiece: mb), 1)
        // 都已领走：切剩余最多的 0 号
        XCTAssertEqual(s.claim(progress: p, splittable: true, minPiece: mb), 2)
        XCTAssertEqual(p.chunk(0).end, 4 * mb - 1)
        XCTAssertEqual(p.chunk(2).start, 4 * mb)
        // 不可切分（单流）时不再领
        XCTAssertNil(s.claim(progress: p, splittable: false, minPiece: mb))
    }

    func testSampleMarksSlowConnectionOnly() {
        let p = TransferProgress(chunks: [DownloadChunk(start: 0, end: 50 * mb - 1, received: 0),
                                          DownloadChunk(start: 50 * mb, end: 100 * mb - 1, received: 0)], total: 100 * mb)
        let s = ChunkScheduler()
        let t0 = Date()
        _ = s.claim(progress: p, splittable: true, minPiece: mb, now: t0)
        _ = s.claim(progress: p, splittable: true, minPiece: mb, now: t0)
        // 20 秒内 0 号收了 20MB（约 1MB/s），1 号只收了 100KB（约 5KB/s）
        p.add(0, 20 * mb)
        p.add(1, 100 * 1024)
        s.sample(progress: p, now: t0.addingTimeInterval(20))
        XCTAssertFalse(s.shouldStop(0))
        XCTAssertTrue(s.shouldStop(1))
        // 重连后清掉标记
        s.restarted(1, received: p.chunk(1).received, now: t0.addingTimeInterval(20))
        XCTAssertFalse(s.shouldStop(1))
    }

    func testSampleWaitsBeforeJudgingNewConnections() {
        let p = TransferProgress(chunks: [DownloadChunk(start: 0, end: 50 * mb - 1, received: 0),
                                          DownloadChunk(start: 50 * mb, end: 100 * mb - 1, received: 0)], total: 100 * mb)
        let s = ChunkScheduler()
        let t0 = Date()
        _ = s.claim(progress: p, splittable: true, minPiece: mb, now: t0)
        _ = s.claim(progress: p, splittable: true, minPiece: mb, now: t0)
        p.add(0, 5 * mb)
        // 才跑 4 秒、还不是收尾阶段：不判慢
        s.sample(progress: p, now: t0.addingTimeInterval(4))
        XCTAssertFalse(s.shouldStop(1))
    }
}
