// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 下载可靠性的纯逻辑：后台分段、重试策略、空间检查、任务表容错、m3u8 BYTERANGE / DRM / 直播、BT 写盘错误分类
final class DownloadResilienceTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: 交给后台会话时的分段

    func testSplitForHandOff() {
        let mb: Int64 = 1024 * 1024
        let chunks = [
            DownloadChunk(start: 0, end: 100 * mb - 1, received: 10 * mb),       // 剩 90MB → 32 + 32 + 26
            DownloadChunk(start: 100 * mb, end: 120 * mb - 1, received: 0),      // 20MB 不切
            DownloadChunk(start: 120 * mb, end: 130 * mb - 1, received: 10 * mb), // 已完成
            DownloadChunk(start: 130 * mb, end: -1, received: 0)                 // 长度未知不切
        ]
        let split = DownloadEngine.splitForHandOff(chunks, maxPiece: 32 * mb)
        XCTAssertEqual(split.count, 6)
        // 原分片序号不变：第一个缩短为第一段，已收字节保留
        XCTAssertEqual(split[0], DownloadChunk(start: 0, end: 42 * mb - 1, received: 10 * mb))
        XCTAssertEqual(split[1], chunks[1])
        XCTAssertEqual(split[2], chunks[2])
        XCTAssertEqual(split[3], chunks[3])
        XCTAssertEqual(split[4], DownloadChunk(start: 42 * mb, end: 74 * mb - 1, received: 0))
        XCTAssertEqual(split[5], DownloadChunk(start: 74 * mb, end: 100 * mb - 1, received: 0))
        // 各段无缝覆盖原来没下完的范围
        let pieces = [split[0], split[4], split[5]]
        XCTAssertEqual(pieces.map { $0.end - ($0.start + $0.received) + 1 }.reduce(0, +), 90 * mb)
        XCTAssertTrue(pieces.allSatisfy { $0.end - ($0.start + $0.received) + 1 <= 32 * mb })

        // 不限大小：原样返回
        XCTAssertEqual(DownloadEngine.splitForHandOff(chunks, maxPiece: .max), chunks)

        let id = UUID()
        let jobs = DownloadEngine.backgroundJobs(itemId: id, chunks: split, url: "https://x/f", headers: ["A": "b"])
        XCTAssertEqual(jobs.map(\.chunkIndex), [0, 1, 3, 4, 5])
        XCTAssertEqual(jobs[0].offset, 10 * mb)
        XCTAssertEqual(jobs[0].rangeHeader, "bytes=\(10 * mb)-\(42 * mb - 1)")
        XCTAssertEqual(jobs[2].offset, 0)
        XCTAssertNil(jobs[2].rangeHeader)
    }

    // MARK: 重试策略

    func testRetryPolicy() {
        for status in [408, 429, 500, 502, 503, 504, 599] { XCTAssertTrue(RetryPolicy.isRetryable(status: status), "\(status)") }
        for status in [400, 401, 403, 404, 410, 412, 416, 200, 206] { XCTAssertFalse(RetryPolicy.isRetryable(status: status), "\(status)") }

        XCTAssertEqual(RetryPolicy.delay(attempt: 1), 0.8, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.delay(attempt: 2), 1.6, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.delay(attempt: 3), 3.2, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.delay(attempt: 6), 25.6, accuracy: 0.001)
        XCTAssertEqual(RetryPolicy.delay(attempt: 7), 30)
        XCTAssertEqual(RetryPolicy.delay(attempt: 1000), 30)
        // Retry-After 优先，但不会无限等
        XCTAssertEqual(RetryPolicy.delay(attempt: 1, retryAfter: 7), 7)
        XCTAssertEqual(RetryPolicy.delay(attempt: 1, retryAfter: 9999), RetryPolicy.maxRetryAfter)

        let now = Date(timeIntervalSince1970: 1_792_560_000)
        XCTAssertEqual(RetryPolicy.parseRetryAfter("120", now: now), 120)
        XCTAssertEqual(RetryPolicy.parseRetryAfter(" 5 ", now: now), 5)
        XCTAssertNil(RetryPolicy.parseRetryAfter(nil, now: now))
        XCTAssertNil(RetryPolicy.parseRetryAfter("soon", now: now))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: now.addingTimeInterval(42))
        XCTAssertEqual(RetryPolicy.parseRetryAfter(date, now: now) ?? -1, 42, accuracy: 1)

        let e = TransferError(status: 429, retryAfter: 3)
        XCTAssertTrue(e.isRetryableStatus)
        XCTAssertTrue(e.message.hasPrefix("HTTP 429"))
        // 直链过期类的说明不变（应用按前缀判断要不要重新取链）
        XCTAssertTrue(TransferError(status: 403).message.hasPrefix("HTTP 403"))
        XCTAssertFalse(TransferError(status: 403).isRetryableStatus)
        XCTAssertTrue(TransferError(status: 503).isRetryableStatus)
    }

    func testPlanStillValid() {
        XCTAssertTrue(RangeTransfer.planStillValid(knownTotal: 1000, probedTotal: 1000))
        XCTAssertFalse(RangeTransfer.planStillValid(knownTotal: 1000, probedTotal: 999))
        XCTAssertTrue(RangeTransfer.planStillValid(knownTotal: -1, probedTotal: 999))
        XCTAssertTrue(RangeTransfer.planStillValid(knownTotal: 1000, probedTotal: -1))
    }

    // MARK: 存储空间

    func testSpaceShortage() {
        let gb: Int64 = 1024 * 1024 * 1024
        let message = DiskSpace.shortage(needed: 3 * gb, available: gb)
        XCTAssertEqual(message, "存储空间不足：需要约 3.0 GB，剩余 1.0 GB")
        XCTAssertNil(DiskSpace.shortage(needed: gb, available: 3 * gb))
        XCTAssertNil(DiskSpace.shortage(needed: gb, available: nil))
        XCTAssertNil(DiskSpace.shortage(needed: 0, available: 0))
        XCTAssertNil(DiskSpace.shortage(needed: -1, available: 10))
        XCTAssertNotNil(DiskSpace.available(at: base.appendingPathComponent("not/yet/created")))

        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .file, expected: 1000, total: -1, received: 100), 900)
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .file, expected: -1, total: 2000, received: 500), 1500)
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .file, expected: -1, total: -1, received: 0), 0)
        // m3u8 拼接后还要转封装：按两倍估
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .hls, expected: 1000, total: -1, received: 0), 2000)
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .hls, expected: -1, total: -1, received: 0), 0)
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .dash(audioURL: "a"), expected: 1000, total: 1000, received: 0), 2000)
        XCTAssertEqual(DownloadEngine.estimatedSpace(kind: .dash(audioURL: "a"), expected: 1000, total: -1, received: 0, phase: 1), 0)

        XCTAssertTrue(DiskSpace.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(DiskSpace.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(DiskSpace.isOutOfSpace(wrapped))
        XCTAssertFalse(DiskSpace.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    /// 剩余空间明显不够时下载直接失败并说明原因（不用测试服务器：检查在发请求之前）
    func testEngineFailsEarlyWhenSpaceIsShort() async throws {
        let engine = DownloadEngine(baseDirectory: base.appendingPathComponent("state"), downloadsDirectory: base.appendingPathComponent("dl")) {
            DownloadSettings(maxConcurrentTasks: 1, connectionsPerTask: 1, retryCount: 0)
        }
        let huge: Int64 = 1 << 60
        let id = await engine.enqueue(DownloadRequest(url: "http://127.0.0.1:1/never", fileName: "huge.bin", expectedSize: huge))
        var item: DownloadItem?
        for _ in 0..<100 {
            item = await engine.snapshot().first { $0.id == id }
            if item?.status == .failed { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(item?.status, .failed)
        XCTAssertTrue(item?.errorMessage?.hasPrefix("存储空间不足：需要约") ?? false, item?.errorMessage ?? "")
    }

    // MARK: 任务表容错

    func testDecodeItemsSkipsBadRecords() throws {
        let good = DownloadItem(request: DownloadRequest(url: "https://a/1", fileName: "a.bin"))
        var other = DownloadItem(request: DownloadRequest(url: "https://a/2", fileName: "b.bin", kind: .hls))
        other.status = .paused
        let encoded = try JSONEncoder().encode([good, other])
        var array = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [Any])
        // 中间插一条缺字段的、一条类型不对的、一个 null
        array.insert(["id": UUID().uuidString, "status": "running"], at: 1)
        array.insert("garbage", at: 2)
        array.append(NSNull())
        let data = try JSONSerialization.data(withJSONObject: array)

        let result = try XCTUnwrap(DownloadEngine.decodeItems(data))
        XCTAssertEqual(result.items.map(\.id), [good.id, other.id])
        XCTAssertEqual(result.skipped, 3)
        XCTAssertNil(DownloadEngine.decodeItems(Data("{not json".utf8)))
        XCTAssertNil(DownloadEngine.decodeItems(Data("{\"a\":1}".utf8)))
    }

    func testEngineRestoresFromBackupAndCleansOrphans() async throws {
        let stateDir = base.appendingPathComponent("state")
        let work = stateDir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var kept = DownloadItem(request: DownloadRequest(url: "https://a/1", fileName: "a.bin"))
        kept.status = .paused
        var done = DownloadItem(request: DownloadRequest(url: "https://a/2", fileName: "b.bin"))
        done.status = .completed
        // 主文件写坏了，备份是好的
        try Data("[{\"broken\":".utf8).write(to: stateDir.appendingPathComponent("downloads.json"))
        try JSONEncoder().encode([kept, done]).write(to: stateDir.appendingPathComponent("downloads.json.bak"))
        // 工作目录：一个属于暂停的任务，一个属于已完成的任务，一个谁都不认识，一个不是任务目录
        for name in [kept.id.uuidString, done.id.uuidString, UUID().uuidString, "keep-me"] {
            try FileManager.default.createDirectory(at: work.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let engine = DownloadEngine(baseDirectory: stateDir, downloadsDirectory: base.appendingPathComponent("dl")) { DownloadSettings() }
        let items = await engine.snapshot()
        XCTAssertEqual(items.map(\.id), [kept.id, done.id])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: work.path))
        XCTAssertEqual(left, [kept.id.uuidString, "keep-me"])

        // 保存时上一版留作备份
        await engine.pause(kept.id)
        await engine.remove(done.id, deleteFile: false)
        let backup = try XCTUnwrap(DownloadEngine.decodeItems(Data(contentsOf: stateDir.appendingPathComponent("downloads.json.bak"))))
        XCTAssertEqual(backup.items.map(\.id), [kept.id, done.id])
        let current = try XCTUnwrap(DownloadEngine.decodeItems(Data(contentsOf: stateDir.appendingPathComponent("downloads.json"))))
        XCTAssertEqual(current.items.map(\.id), [kept.id])
    }

    func testUnreadableStateKeepsWorkData() throws {
        let stateDir = base.appendingPathComponent("state")
        let work = stateDir.appendingPathComponent("work")
        let orphan = work.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: stateDir.appendingPathComponent("downloads.json"))
        _ = DownloadEngine(baseDirectory: stateDir, downloadsDirectory: base.appendingPathComponent("dl")) { DownloadSettings() }
        // 任务表完全读不出来时不清理，数据也许还能找回
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    // MARK: m3u8

    func testByteRangeParsing() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:10
        #EXT-X-MAP:URI="main.mp4",BYTERANGE="720@0"
        #EXTINF:10,
        #EXT-X-BYTERANGE:1000@720
        main.mp4
        #EXTINF:10,
        #EXT-X-BYTERANGE:2000
        main.mp4
        #EXTINF:10,
        #EXT-X-BYTERANGE:500
        other.mp4
        #EXTINF:10,
        plain.ts
        #EXT-X-ENDLIST
        """
        let list = M3U8.parse(text, baseURL: "https://cdn.example.com/v/index.m3u8")
        XCTAssertEqual(list.mapURL, "https://cdn.example.com/v/main.mp4")
        XCTAssertEqual(list.mapRange, M3U8.ByteRange(offset: 0, length: 720))
        XCTAssertEqual(list.segments.count, 4)
        XCTAssertEqual(list.segments[0].range, M3U8.ByteRange(offset: 720, length: 1000))
        // 没写起点：接着同一资源上一段之后
        XCTAssertEqual(list.segments[1].range, M3U8.ByteRange(offset: 1720, length: 2000))
        // 换了资源：从 0 开始
        XCTAssertEqual(list.segments[2].range, M3U8.ByteRange(offset: 0, length: 500))
        XCTAssertEqual(list.segments[2].url, "https://cdn.example.com/v/other.mp4")
        XCTAssertNil(list.segments[3].range)
        XCTAssertEqual(list.segments[0].range?.header, "bytes=720-1719")
        XCTAssertTrue(list.hasEndList)
        XCTAssertFalse(list.isLive)
        XCTAssertFalse(list.isDRMProtected)

        XCTAssertNil(M3U8.ByteRange.parse("abc", previousEnd: 0))
        XCTAssertNil(M3U8.ByteRange.parse("0@5", previousEnd: 0))
        XCTAssertEqual(M3U8.ByteRange.parse(" 10@3 ", previousEnd: 99), M3U8.ByteRange(offset: 3, length: 10))
    }

    func testByteRangeSlice() throws {
        let body = Data((0..<100).map { UInt8($0) })
        let range = M3U8.ByteRange(offset: 10, length: 20)
        // 206：服务器按 Range 回的就是这一段
        XCTAssertEqual(try HLSTransfer.slice(body.prefix(20), status: 206, range: range), body.prefix(20))
        // 200：服务器忽略 Range 回了整个资源，从中截出
        XCTAssertEqual(try HLSTransfer.slice(body, status: 200, range: range), body.subdata(in: 10..<30))
        XCTAssertThrowsError(try HLSTransfer.slice(body.prefix(25), status: 200, range: range))
        XCTAssertThrowsError(try HLSTransfer.slice(body.prefix(5), status: 206, range: range))
        XCTAssertEqual(try HLSTransfer.slice(body, status: 200, range: nil), body)
    }

    func testDRMAndLiveDetection() {
        let fairplay = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://abc",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
        #EXTINF:6,
        a.ts
        #EXT-X-ENDLIST
        """
        XCTAssertTrue(M3U8.parse(fairplay, baseURL: "https://x/").isDRMProtected)
        let master = """
        #EXTM3U
        #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://k"
        #EXT-X-STREAM-INF:BANDWIDTH=100
        v.m3u8
        """
        XCTAssertTrue(M3U8.parse(master, baseURL: "https://x/").isDRMProtected)
        let aes = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:6,
        a.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:6,
        b.ts
        #EXT-X-ENDLIST
        """
        let plain = M3U8.parse(aes, baseURL: "https://x/")
        XCTAssertFalse(plain.isDRMProtected)
        XCTAssertEqual(plain.segments[0].key?.method, "AES-128")
        XCTAssertNil(plain.segments[1].key)

        let live = M3U8.parse("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:6,\na.ts\n#EXTINF:6,\nb.ts\n", baseURL: "https://x/")
        XCTAssertTrue(live.isLive)
        let vod = M3U8.parse("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:6,\na.ts\n", baseURL: "https://x/")
        XCTAssertFalse(vod.isLive)
        XCTAssertEqual(M3U8.drmMessage, "该视频使用 DRM 加密，无法下载")
    }

    func testHLSAppendState() throws {
        XCTAssertEqual(HLSTransfer.AppendState.load(in: base, name: "output"), HLSTransfer.AppendState())
        try HLSTransfer.AppendState(count: 12, length: 34_567).save(in: base, name: "output")
        XCTAssertEqual(HLSTransfer.AppendState.load(in: base, name: "output"), HLSTransfer.AppendState(count: 12, length: 34_567))
        try Data("bad".utf8).write(to: HLSTransfer.AppendState.url(in: base, name: "audio"))
        XCTAssertEqual(HLSTransfer.AppendState.load(in: base, name: "audio"), HLSTransfer.AppendState())
    }

    // MARK: BT 写盘错误

    func testTorrentWriteFailureMessage() {
        let full = TorrentStorage.writeFailureMessage(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        XCTAssertTrue(full.hasPrefix("存储空间不足"), full)
        let cocoa = TorrentStorage.writeFailureMessage(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        XCTAssertTrue(cocoa.hasPrefix("存储空间不足"), cocoa)
        let other = TorrentStorage.writeFailureMessage(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        XCTAssertTrue(other.hasPrefix("写入文件失败"), other)
    }

    /// 校验失败的块重新下载；写盘失败的块记下错误、整个下载停下（不会无限重下）
    func testSwarmDistinguishesWriteFailureFromHashFailure() async throws {
        let t = TorrentTests.fixture()
        let progress = TransferProgress(chunks: [], total: -1)
        let swarm = TorrentSwarm(infoHash: t.info.infoHash, selection: nil, trackers: [], workRoot: base,
                                 stateURL: base.appendingPathComponent("s.json"), cacheDir: base, progress: progress, metadataOnly: false)
        try await swarm.begin(with: t.info)
        await swarm.pieceResult(0, ok: false)
        let afterHash = await swarm.failure
        XCTAssertNil(afterHash)
        await swarm.pieceWriteFailed(1, message: "存储空间不足，BT 下载已停止")
        let afterWrite = await swarm.failure
        XCTAssertEqual(afterWrite, "存储空间不足，BT 下载已停止")
    }

    /// 端到端：数据文件位置被目录占着、写不进去 → 任务失败并说明原因，而不是反复重下
    func testTorrentWriteFailureStopsTransfer() async throws {
        let payload = Data((0..<40_000).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: i * 7) })
        let info = try TorrentTests.makeInfo(name: "one.iso", pieceLength: 16_384, files: nil, payload: payload)
        let cache = base.appendingPathComponent("cache")
        TorrentMetadataCache.save(info, in: cache)
        let work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("bt/one.iso"), withIntermediateDirectories: true)
        let net = SimulatedSwarm(info: info, payload: payload, seeders: 1)
        let magnet = MagnetLink(infoHash: info.infoHash, trackers: [SimulatedSwarm.tracker])
        let transfer = TorrentTransfer(magnet: magnet, selection: nil, workDir: work, cacheDir: cache,
                                       progress: TransferProgress(chunks: [], total: -1), network: net, client: .shared)
        let started = Date()
        do {
            _ = try await transfer.run()
            XCTFail("写不进去时应当失败")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.hasPrefix("写入文件失败") || message.hasPrefix("存储空间不足"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }
}
