import XCTest
@testable import CloudnKit

/// BT：编码格式、磁力解析、tracker / DHT 报文，以及用内存里的模拟 peer 跑完整下载（不联网）
final class TorrentTests: XCTestCase {
    // MARK: 编码与解析

    func testBencodeRoundTripAndSortedKeys() throws {
        let v = BValue.dict([("zeta", .int(-3)), ("alpha", .list([BValue("x"), .int(7)])), ("mid", .bytes(Data([0, 255])))])
        let encoded = Bencode.encode(v)
        XCTAssertEqual(String(decoding: encoded.prefix(10), as: UTF8.self), "d5:alphal1")
        XCTAssertEqual(try Bencode.decode(encoded), v)
        XCTAssertThrowsError(try Bencode.decode(Data("i12".utf8)))
        XCTAssertThrowsError(try Bencode.decode(Data("5:ab".utf8)))
        let (head, used) = try Bencode.decodePrefix(Data("d1:ai1eeRAW".utf8))
        XCTAssertEqual(head["a"]?.int, 1)
        XCTAssertEqual(used, 8)
    }

    func testRawInfoValueIsCapturedExactly() throws {
        let info = Data("d4:name1:xe".utf8)
        let file = Data("d8:announce3:abc4:info".utf8) + info + Data("e".utf8)
        XCTAssertEqual(try Bencode.rawValue(forKey: "info", in: file), info)
    }

    func testMagnetParsing() {
        let hex = "c12fe1c06bba254a9dc9f519b335aa7c1367a88a"
        let m = MagnetLink.find(in: "看这个 magnet:?xt=urn:btih:\(hex.uppercased())&dn=Big+Buck%20Bunny&tr=udp%3A%2F%2Ft.example%3A80&tr=udp%3A%2F%2Ft.example%3A80 好")
        XCTAssertEqual(m?.hexHash, hex)
        XCTAssertEqual(m?.displayName, "Big Buck Bunny")
        XCTAssertEqual(m?.trackers, ["udp://t.example:80"])
        XCTAssertEqual(MagnetLink.parse(m!.uri), m)
        // Base32 特征码与裸 40 位特征码
        let b32 = MagnetLink.parse("magnet:?xt=urn:btih:YEX6DQDLXISUVHOJ6UM3GNNKPQJWPKEK")
        XCTAssertEqual(b32?.hexHash, hex)
        XCTAssertEqual(MagnetLink.find(in: hex)?.hexHash, hex)
        XCTAssertNil(MagnetLink.find(in: "magnet:?dn=x"))
        XCTAssertNil(MagnetLink.find(in: "https://example.com"))
    }

    func testTorrentFileParsing() throws {
        let t = Self.fixture()
        let file = Bencode.encode(.dict([("announce", BValue("udp://a:1/announce")),
                                         ("announce-list", .list([.list([BValue("udp://b:2/announce")])])),
                                         ("info", t.infoValue)]))
        let (info, trackers) = try TorrentInfo.parse(torrentFile: file)
        XCTAssertEqual(info.infoHash, t.info.infoHash)
        XCTAssertEqual(trackers, ["udp://a:1/announce", "udp://b:2/announce"])
        XCTAssertEqual(info.name, "pack")
        XCTAssertFalse(info.isSingleFile)
        XCTAssertEqual(info.files.map(\.relativePath), ["a.bin", "empty.txt", "sub/b.bin"])
        XCTAssertEqual(info.files.map(\.offset), [0, 50_000, 50_000])
        XCTAssertEqual(info.totalLength, 120_001)
        XCTAssertEqual(info.pieceCount, 4)
        // 只选 b.bin：它从 50000 开始，覆盖第 1~3 块
        XCTAssertEqual(info.pieces(for: [2]), [false, true, true, true])
        XCTAssertThrowsError(try TorrentInfo.parse(info: t.info.rawInfo, expectedHash: [UInt8](repeating: 0, count: 20)))
    }

    func testPeerMessagesRoundTrip() throws {
        let messages: [PeerMessage] = [.choke, .unchoke, .interested, .have(9), .bitfield(Data([0xf0])),
                                       .request(index: 1, begin: 16384, length: 16384), .piece(index: 2, begin: 0, block: Data([1, 2, 3])),
                                       .extended(id: 3, payload: Data("d1:ai1ee".utf8))]
        for m in messages {
            let e = m.encoded()
            XCTAssertEqual(Int(PeerWire.readBE32([UInt8](e), 0)), e.count - 4)
            XCTAssertEqual(try PeerMessage.decode(e.dropFirst(4)), m)
        }
        let hash = [UInt8](repeating: 7, count: 20)
        let hs = PeerWire.handshake(infoHash: hash, peerId: PeerWire.makePeerId())
        XCTAssertEqual(hs.count, 68)
        XCTAssertTrue(try PeerWire.parseHandshake(hs, infoHash: hash))
        XCTAssertThrowsError(try PeerWire.parseHandshake(hs, infoHash: [UInt8](repeating: 8, count: 20)))
    }

    func testMetadataMessages() throws {
        XCTAssertEqual(try PeerWire.parseMetadataMessage(PeerWire.metadataRequest(piece: 2)), .request(piece: 2))
        let data = Bencode.encode(.dict([("msg_type", .int(1)), ("piece", .int(0)), ("total_size", .int(5))])) + Data("HELLO".utf8)
        XCTAssertEqual(try PeerWire.parseMetadataMessage(data), .data(piece: 0, totalSize: 5, payload: Data("HELLO".utf8)))
        XCTAssertEqual(try PeerWire.parseMetadataMessage(PeerWire.metadataReject(piece: 1)), .reject(piece: 1))
    }

    func testBitfield() {
        var b = Bitfield(data: Data([0b1010_0000, 0xff]), count: 10)
        XCTAssertTrue(b[0]); XCTAssertFalse(b[1]); XCTAssertTrue(b[2])
        XCTAssertTrue(b[9]); XCTAssertFalse(b[10])
        // 超出块数的尾部位被清掉
        XCTAssertEqual(b.setCount, 4)
        b[1] = true
        XCTAssertEqual(b.data, Data([0b1110_0000, 0b1100_0000]))
    }

    func testCompactPeersAndTrackerPackets() throws {
        XCTAssertEqual(PeerAddress.compact(Data([10, 0, 0, 1, 0x1a, 0xe1, 1, 2, 3, 4, 0, 0])), [PeerAddress(host: "10.0.0.1", port: 6881)])
        let v6 = PeerAddress.compact(Data([0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1, 0x1a, 0xe1]), ipv6: true)
        XCTAssertEqual(v6.first?.port, 6881)
        XCTAssertEqual(v6.first?.host, "2001:db8:0:0:0:0:0:1")

        let connect = [UInt8](TrackerClient.udpConnect(0xdeadbeef))
        XCTAssertEqual(connect.count, 16)
        XCTAssertEqual(PeerWire.readBE64(connect, 0), 0x41727101980)
        var resp: [UInt8] = PeerWire.be32(0)
        resp += PeerWire.be32(0xdeadbeef)
        resp += PeerWire.be64(42)
        XCTAssertEqual(try TrackerClient.parseUDPConnect(resp, transaction: 0xdeadbeef), 42)
        let a = TrackerClient.Announce(infoHash: [UInt8](repeating: 1, count: 20), peerId: [UInt8](repeating: 2, count: 20), left: 100)
        XCTAssertEqual(TrackerClient.udpAnnounce(42, 7, a).count, 98)
        var ann: [UInt8] = PeerWire.be32(1)
        for v: UInt32 in [7, 1800, 0, 1] { ann += PeerWire.be32(v) }
        ann += [127, 0, 0, 1, 0x1a, 0xe1]
        XCTAssertEqual(try TrackerClient.parseUDPAnnounce(ann, transaction: 7), [PeerAddress(host: "127.0.0.1", port: 6881)])

        let http = Bencode.encode(.dict([("interval", .int(900)), ("peers", .bytes(Data([1, 2, 3, 4, 0, 80])))]))
        XCTAssertEqual(try TrackerClient.parseHTTPResponse(http), [PeerAddress(host: "1.2.3.4", port: 80)])
        XCTAssertThrowsError(try TrackerClient.parseHTTPResponse(Bencode.encode(.dict([("failure reason", BValue("nope"))]))))
        XCTAssertEqual(TrackerClient.percent([0x41, 0x20, 0xff, 0x2e]), "A%20%FF.")
    }

    func testDHTResponseParsing() throws {
        let nodeId = [UInt8](repeating: 9, count: 20)
        let node = nodeId + [8, 8, 8, 8, 0x1a, 0xe1]
        let r = Bencode.encode(.dict([("t", BValue("aa")), ("y", BValue("r")),
                                      ("r", .dict([("id", .bytes(Data(nodeId))), ("nodes", .bytes(Data(node))),
                                                   ("values", .list([.bytes(Data([5, 6, 7, 8, 0, 99]))]))]))]))
        let parsed = try DHTLookup.parseResponse(r)
        XCTAssertEqual(parsed.peers, [PeerAddress(host: "5.6.7.8", port: 99)])
        XCTAssertEqual(parsed.nodes.first?.address, PeerAddress(host: "8.8.8.8", port: 6881))
        let target = [UInt8](repeating: 0, count: 20)
        XCTAssertTrue(DHTLookup.closer([0, 1] + [UInt8](repeating: 0, count: 18), than: [1] + [UInt8](repeating: 0, count: 19), to: target))
    }

    // MARK: 端到端（内存模拟 peer）

    func testMagnetDownloadFromSimulatedSwarm() async throws {
        let t = Self.fixture()
        let dir = try tempDir()
        let net = SimulatedSwarm(info: t.info, payload: t.payload, seeders: 3)
        let magnet = MagnetLink(infoHash: t.info.infoHash, displayName: "pack", trackers: [SimulatedSwarm.tracker])
        let progress = TransferProgress(chunks: [], total: -1)
        let output = try await TorrentTransfer(magnet: magnet, selection: nil, workDir: dir.appendingPathComponent("work"),
                                               cacheDir: dir.appendingPathComponent("cache"), progress: progress, network: net,
                                               client: .shared).run()
        XCTAssertEqual(output.lastPathComponent, "pack")
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("a.bin")), t.payload.prefix(50_000))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("empty.txt")), Data())
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("sub/b.bin")), t.payload.suffix(70_001))
        XCTAssertEqual(progress.title, "pack")
        XCTAssertEqual(progress.received, 120_001)
        // 元数据进了缓存
        XCTAssertEqual(TorrentMetadataCache.load(in: dir.appendingPathComponent("cache"), infoHash: t.info.infoHash)?.name, "pack")
    }

    func testSelectedFileOnly() async throws {
        let t = Self.fixture()
        let dir = try tempDir()
        let net = SimulatedSwarm(info: t.info, payload: t.payload, seeders: 2)
        let magnet = MagnetLink(infoHash: t.info.infoHash, trackers: [SimulatedSwarm.tracker])
        let info = try await TorrentMetadata.fetch(magnet, cacheDirectory: dir.appendingPathComponent("cache"), network: net)
        XCTAssertEqual(info.visibleFiles.count, 3)
        let output = try await TorrentTransfer(magnet: magnet, selection: [0], workDir: dir.appendingPathComponent("work"),
                                               cacheDir: dir.appendingPathComponent("cache"), progress: TransferProgress(chunks: [], total: -1),
                                               network: net, client: .shared).run()
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("a.bin")), t.payload.prefix(50_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("sub/b.bin").path))
    }

    func testSingleFileTorrentAndResumeSkipsNetwork() async throws {
        let payload = Data((0..<40_000).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: i * 7) })
        let info = try Self.makeInfo(name: "one.iso", pieceLength: 16_384, files: nil, payload: payload)
        let dir = try tempDir()
        let cache = dir.appendingPathComponent("cache")
        TorrentMetadataCache.save(info, in: cache)
        let work = dir.appendingPathComponent("work")
        let net = SimulatedSwarm(info: info, payload: payload, seeders: 1)
        let magnet = MagnetLink(infoHash: info.infoHash, trackers: [SimulatedSwarm.tracker])
        let output = try await TorrentTransfer(magnet: magnet, selection: nil, workDir: work, cacheDir: cache,
                                               progress: TransferProgress(chunks: [], total: -1), network: net, client: .shared).run()
        XCTAssertEqual(output.lastPathComponent, "one.iso")
        XCTAssertEqual(try Data(contentsOf: output), payload)
        // 续传状态显示全部完成：再跑一次不再连接任何 peer
        let offline = SimulatedSwarm(info: info, payload: payload, seeders: 0)
        _ = try await TorrentTransfer(magnet: magnet, selection: nil, workDir: work, cacheDir: cache,
                                      progress: TransferProgress(chunks: [], total: -1), network: offline, client: .shared).run()
        XCTAssertEqual(offline.connections, 0)
    }

    func testSwarmRejectsCorruptPieceAndRetries() async throws {
        let t = Self.fixture()
        let dir = try tempDir()
        let progress = TransferProgress(chunks: [], total: -1)
        let swarm = TorrentSwarm(infoHash: t.info.infoHash, selection: nil, trackers: [], workRoot: dir, stateURL: dir.appendingPathComponent("s.json"),
                                 cacheDir: dir, progress: progress, metadataOnly: false)
        try await swarm.begin(with: t.info)
        var all = Bitfield(count: 4)
        for i in 0..<4 { all[i] = true }
        let reqs = await swarm.assign(peer: 1, has: all, max: 2)
        XCTAssertEqual(reqs.count, 2)
        let index = reqs[0].index
        XCTAssertEqual(Set(reqs.map(\.index)).count, 1, "先把同一块的所有子块派给同一个 peer")
        let size = t.info.pieceSize(index)
        var full: Data?
        for r in reqs { full = await swarm.deliver(peer: 1, index: r.index, begin: r.begin, block: Data(count: r.length)) }
        if size > 2 * PeerWire.blockSize { XCTAssertNil(full) } else { XCTAssertNotNil(full) }
        await swarm.pieceResult(index, ok: false)
        // 校验失败的块回到待下载，换个 peer 也能领到
        let again = await swarm.assign(peer: 2, has: all, max: 64)
        XCTAssertTrue(again.contains { $0.index == index })
    }

    // MARK: 测试数据

    struct Fixture {
        let info: TorrentInfo
        let infoValue: BValue
        let payload: Data
    }

    static func fixture() -> Fixture {
        let payload = Data((0..<120_001).map { (i: Int) -> UInt8 in UInt8(truncatingIfNeeded: i * 31 + i / 7) })
        let files: [(String, Int)] = [("a.bin", 50_000), ("empty.txt", 0), ("sub/b.bin", 70_001)]
        let value = infoValue(name: "pack", pieceLength: 32_768, files: files, payload: payload)
        let info = try! TorrentInfo.parse(info: Bencode.encode(value))
        return Fixture(info: info, infoValue: value, payload: payload)
    }

    static func makeInfo(name: String, pieceLength: Int, files: [(String, Int)]?, payload: Data) throws -> TorrentInfo {
        try TorrentInfo.parse(info: Bencode.encode(infoValue(name: name, pieceLength: pieceLength, files: files, payload: payload)))
    }

    static func infoValue(name: String, pieceLength: Int, files: [(String, Int)]?, payload: Data) -> BValue {
        var pieces = Data()
        var i = 0
        while i < payload.count {
            pieces.append(TorrentInfo.sha1(payload.subdata(in: i..<min(payload.count, i + pieceLength))))
            i += pieceLength
        }
        var pairs: [(String, BValue)] = [("name", BValue(name)), ("piece length", .int(Int64(pieceLength))), ("pieces", .bytes(pieces))]
        if let files {
            pairs.append(("files", .list(files.map { f in
                .dict([("length", .int(Int64(f.1))), ("path", .list(f.0.split(separator: "/").map { BValue(String($0)) }))])
            })))
        } else {
            pairs.append(("length", .int(Int64(payload.count))))
        }
        return .dict(pairs)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("torrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}

// MARK: - 内存模拟的 swarm

/// 一个 UDP tracker（返回 seeders 个 peer）+ 若干做种 peer，全部在内存里
final class SimulatedSwarm: TorrentNetwork, @unchecked Sendable {
    static let tracker = "udp://tracker.test:80/announce"
    let info: TorrentInfo
    let payload: Data
    let seeders: Int
    private let lock = NSLock()
    private var _connections = 0
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }
    private func countConnection() { lock.lock(); _connections += 1; lock.unlock() }

    init(info: TorrentInfo, payload: Data, seeders: Int) {
        self.info = info
        self.payload = payload
        self.seeders = seeders
    }

    func udpRequest(_ address: PeerAddress, payload: Data, timeout: TimeInterval) async throws -> Data {
        guard address.host == "tracker.test" else { throw TransferError("unreachable") }
        let b = [UInt8](payload)
        let action = PeerWire.readBE32(b, 8), tid = PeerWire.readBE32(b, 12)
        if action == 0 {
            var r: [UInt8] = PeerWire.be32(0)
            r += PeerWire.be32(tid)
            r += PeerWire.be64(77)
            return Data(r)
        }
        var out: [UInt8] = PeerWire.be32(1)
        for v in [tid, 60, 0, UInt32(seeders)] { out += PeerWire.be32(v) }
        for i in 0..<seeders { out += [10, 0, 0, UInt8(i + 1), 0x1a, 0xe1] }
        return Data(out)
    }

    func connect(_ address: PeerAddress, timeout: TimeInterval) async throws -> PeerStream {
        countConnection()
        let (client, server) = PipeStream.pair()
        Task { await self.seed(server) }
        return client
    }

    /// 做种端：握手 → 扩展握手（提供元数据）→ 全量位图 → unchoke → 按请求发块
    private func seed(_ s: PipeStream) async {
        defer { s.close() }
        do {
            let hs = try await s.receive(exactly: 68, timeout: 5)
            _ = try PeerWire.parseHandshake(hs, infoHash: info.infoHash)
            try await s.send(PeerWire.handshake(infoHash: info.infoHash, peerId: PeerWire.makePeerId()))
            let ext = Bencode.encode(.dict([("m", .dict([("ut_metadata", .int(3))])), ("metadata_size", .int(Int64(info.rawInfo.count)))]))
            try await s.send(PeerMessage.extended(id: 0, payload: ext).encoded())
            var bits = Bitfield(count: info.pieceCount)
            for i in 0..<info.pieceCount { bits[i] = true }
            try await s.send(PeerMessage.bitfield(bits.data).encoded())
            try await s.send(PeerMessage.unchoke.encoded())
            var clientMetadataId: UInt8 = 0
            while true {
                let len = Int(PeerWire.readBE32([UInt8](try await s.receive(exactly: 4, timeout: 10)), 0))
                if len == 0 { continue }
                switch try PeerMessage.decode(try await s.receive(exactly: len, timeout: 10)) {
                case .extended(0, let p):
                    clientMetadataId = UInt8(try Bencode.decodePrefix(p).0["m"]?["ut_metadata"]?.int ?? 0)
                case .extended(3, let p):
                    if case .request(let piece) = try PeerWire.parseMetadataMessage(p) {
                        let start = piece * PeerWire.metadataPieceSize
                        let chunk = info.rawInfo.subdata(in: start..<min(info.rawInfo.count, start + PeerWire.metadataPieceSize))
                        let head = Bencode.encode(.dict([("msg_type", .int(1)), ("piece", .int(Int64(piece))), ("total_size", .int(Int64(info.rawInfo.count)))]))
                        try await s.send(PeerMessage.extended(id: clientMetadataId, payload: head + chunk).encoded())
                    }
                case .request(let index, let begin, let length):
                    let start = Int(info.pieceLength) * index + begin
                    try await s.send(PeerMessage.piece(index: index, begin: begin, block: payload.subdata(in: start..<start + length)).encoded())
                default:
                    break
                }
            }
        } catch {}
    }
}

/// 一对互通的内存字节流
final class PipeStream: PeerStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox = Data()
    private var closed = false
    private var other: PipeStream?

    static func pair() -> (PipeStream, PipeStream) {
        let a = PipeStream(), b = PipeStream()
        a.other = b
        b.other = a
        return (a, b)
    }

    private func push(_ d: Data) { lock.lock(); inbox.append(d); lock.unlock() }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func target() -> PipeStream? {
        lock.lock(); defer { lock.unlock() }
        return closed ? nil : other
    }

    /// 取出 n 字节；不够时返回 nil，已关闭时抛错
    private func take(_ n: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if inbox.count >= n {
            let out = Data(inbox.prefix(n))
            inbox.removeFirst(n)
            return out
        }
        if closed { throw TransferError("closed") }
        return nil
    }

    func send(_ data: Data) async throws {
        guard let peer = target(), !peer.isClosed else { throw TransferError("closed") }
        peer.push(data)
    }

    func receive(exactly n: Int, timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let out = try take(n) { return out }
            if Date() > deadline { throw TransferError("timeout") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func close() {
        lock.lock(); closed = true; let peer = other; other = nil; lock.unlock()
        peer?.markClosed()
    }

    private func markClosed() { lock.lock(); closed = true; other = nil; lock.unlock() }
}
