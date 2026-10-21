// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 内置的公共 tracker（磁力链接自带的 tracker 往往已失效；可在设置里关掉）
public enum TorrentDefaults {
    public static let publicTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://tracker.tiny-vps.com:6969/announce",
        "https://tracker.tamersunion.org:443/announce",
        // 有的网络屏蔽 UDP：同一批 tracker 的 HTTP(S) 入口
        "http://tracker.opentrackr.org:1337/announce",
        "https://tracker.gbitt.info:443/announce"
    ]
}

/// BT 下载：DHT + tracker 找 peer，先用 ut_metadata 取元数据（磁力链接），再多 peer 并发下载、逐块 SHA1 校验。
/// 只下载不上传（不监听端口、不做种）；断点续传靠工作目录里的已校验分块位图。
struct TorrentTransfer {
    let magnet: MagnetLink
    let selection: [Int]?
    let workDir: URL
    let cacheDir: URL
    let progress: TransferProgress
    let network: TorrentNetwork
    let client: HTTPClient
    var limiter: RateLimiter?
    var extraTrackers: [String] = []
    var metadataOnly = false

    static let maxPeers = 40
    static let pipeline = 32
    /// 一直找不到任何 peer 时放弃
    static let noPeerTimeout: TimeInterval = 120
    /// 磁力链接长时间拿不到元数据时放弃
    static let metadataTimeout: TimeInterval = 600

    /// 下载完成返回产物（单文件或目录），在 workDir/bt 下
    func run() async throws -> URL {
        let swarm = try await start()
        guard let storage = await swarm.storage else { throw TransferError("种子信息不完整") }
        await swarm.flush()
        return storage.outputURL
    }

    /// 只取元数据（解析页列出文件用）
    func fetchMetadata() async throws -> TorrentInfo {
        let swarm = try await start()
        guard let info = await swarm.info else { throw TransferError("没有拿到种子信息") }
        return info
    }

    private func start() async throws -> TorrentSwarm {
        let root = workDir.appendingPathComponent("bt", isDirectory: true)
        if !metadataOnly { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let cached = TorrentMetadataCache.load(in: cacheDir, infoHash: magnet.infoHash)
        let swarm = TorrentSwarm(infoHash: magnet.infoHash, selection: selection, trackers: Self.unique(magnet.trackers + extraTrackers),
                                 workRoot: root, stateURL: workDir.appendingPathComponent("bt-state.json"), cacheDir: cacheDir,
                                 progress: progress, metadataOnly: metadataOnly)
        try await swarm.begin(with: cached)
        if await swarm.isComplete { return swarm }
        let peerId = PeerWire.makePeerId()
        let began = Date()
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { await discover(swarm, peerId: peerId) }
            while !(await swarm.isComplete) {
                try Task.checkCancellation()
                // 写盘失败（空间满了等）重下也没用：整个下载失败，提示原因
                if let failure = await swarm.failure { throw TransferError(failure, permanent: true) }
                for address in await swarm.takeConnectable(limit: Self.maxPeers) {
                    group.addTask { await runPeer(address, swarm: swarm, peerId: peerId) }
                }
                let elapsed = Date().timeIntervalSince(began)
                if await swarm.knownCount == 0, elapsed > Self.noPeerTimeout {
                    throw TransferError("没有找到可用的节点（可能已无人做种，或网络屏蔽了 BT）")
                }
                if await swarm.info == nil, elapsed > Self.metadataTimeout {
                    throw TransferError("长时间没有拿到种子信息，请稍后再试")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            group.cancelAll()
        }
        return swarm
    }

    // MARK: 找 peer

    private func discover(_ swarm: TorrentSwarm, peerId: [UInt8]) async {
        let dht = DHTLookup(network: network, infoHash: magnet.infoHash)
        var lastTracker = Date.distantPast
        var lastDHT = Date.distantPast
        while !Task.isCancelled {
            let now = Date()
            let connected = await swarm.connectedCount
            let trackerDue = now.timeIntervalSince(lastTracker) > (connected < 5 ? 90 : 300)
            let dhtDue = now.timeIntervalSince(lastDHT) > (connected < 10 ? 45 : 300)
            if trackerDue || dhtDue {
                var trackers: [String] = []
                if trackerDue { trackers = await swarm.trackers }
                if trackerDue { lastTracker = now }
                if dhtDue { lastDHT = now }
                let announce = TrackerClient.Announce(infoHash: magnet.infoHash, peerId: peerId, downloaded: await swarm.downloadedBytes,
                                                      left: await swarm.leftBytes)
                await withDiscardingTaskGroup { group in
                    for t in trackers {
                        group.addTask { [network, client] in
                            do {
                                let peers = try await TrackerClient.announce(t, announce, network: network, client: client)
                                await swarm.recordTracker(ok: true)
                                await swarm.addPeers(peers)
                                Log.info("tracker 返回 \(peers.count) 个节点：\(t)")
                            } catch {
                                await swarm.recordTracker(ok: false)
                                Log.info("tracker 无响应：\(t)（\(error.localizedDescription)）")
                            }
                        }
                    }
                    if dhtDue {
                        group.addTask {
                            let responded = await dht.findPeers { await swarm.addPeers($0) }
                            await swarm.recordDHT(responded)
                            Log.info("DHT 查找：\(responded) 个节点回应")
                        }
                    }
                }
                let note = await swarm.statusNote
                Log.info("BT 找节点：\(note)")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: 单个 peer

    private func runPeer(_ address: PeerAddress, swarm: TorrentSwarm, peerId: [UInt8]) async {
        let pid = await swarm.registerPeer()
        var useful = false
        var outstanding: [TorrentSwarm.BlockRequest] = []
        var metadataPiece: Int?
        do {
            let stream = try await network.connect(address, timeout: 10)
            defer { stream.close() }
            try await stream.send(PeerWire.handshake(infoHash: magnet.infoHash, peerId: peerId))
            let supportsExtensions = try PeerWire.parseHandshake(try await stream.receive(exactly: 68, timeout: 15), infoHash: magnet.infoHash)
            await swarm.recordHandshake()
            if supportsExtensions {
                let size = await swarm.metadataSizeIfKnown
                try await stream.send(PeerMessage.extended(id: 0, payload: PeerWire.extendedHandshake(metadataSize: size)).encoded())
            }
            try await stream.send(PeerMessage.interested.encoded())
            var choked = true
            var rawBits: Data?
            var haves: [Int] = []
            var bits: Bitfield?
            var metadataId: UInt8?
            var info: TorrentInfo?
            var lastUseful = Date()
            var lastSent = Date()
            while !Task.isCancelled {
                if await swarm.isComplete { break }
                if info == nil, let ready = await swarm.info {
                    info = ready
                    var b = Bitfield(data: rawBits ?? Data(), count: ready.pieceCount)
                    for h in haves { b[h] = true }
                    bits = b
                    haves = []
                }
                if let current = bits, info != nil {
                    if !choked, outstanding.count <= Self.pipeline / 2 {
                        let more = await swarm.assign(peer: pid, has: current, max: Self.pipeline - outstanding.count)
                        if !more.isEmpty {
                            var batch = Data()
                            for r in more { batch.append(PeerMessage.request(index: r.index, begin: r.begin, length: r.length).encoded()) }
                            try await stream.send(batch)
                            outstanding += more
                            lastSent = Date()
                        }
                    }
                } else if let id = metadataId, metadataPiece == nil, let piece = await swarm.nextMetadataPiece() {
                    metadataPiece = piece
                    try await stream.send(PeerMessage.extended(id: id, payload: PeerWire.metadataRequest(piece: piece)).encoded())
                    lastSent = Date()
                }
                // 一直不给数据（choke 着、没有我们要的块、不支持取元数据）的连接让给别人
                if Date().timeIntervalSince(lastUseful) > (info == nil ? 45 : 75) { break }
                if Date().timeIntervalSince(lastSent) > 90 {
                    try await stream.send(PeerMessage.keepAlive.encoded())
                    lastSent = Date()
                }
                let length = Int(PeerWire.readBE32([UInt8](try await stream.receive(exactly: 4, timeout: 60)), 0))
                if length == 0 { continue }
                guard length <= PeerMessage.maxLength else { break }
                let message = try PeerMessage.decode(try await stream.receive(exactly: length, timeout: 60))
                switch message {
                case .choke:
                    choked = true
                    await swarm.release(peer: pid, outstanding)
                    outstanding = []
                case .unchoke:
                    choked = false
                case .have(let i):
                    if bits != nil { bits![i] = true } else { haves.append(i) }
                case .bitfield(let d):
                    if let count = bits?.count { bits = Bitfield(data: d, count: count) } else { rawBits = d }
                case .piece(let index, let begin, let block):
                    if let k = outstanding.firstIndex(where: { $0.index == index && $0.begin == begin }) { outstanding.remove(at: k) }
                    try await limiter?.throttleAsync(block.count)
                    lastUseful = Date()
                    useful = true
                    if let full = await swarm.deliver(peer: pid, index: index, begin: begin, block: block) {
                        guard await swarm.pieceHash(index) == TorrentInfo.sha1(full) else {
                            // 校验失败：数据有问题，这块重新下载
                            await swarm.pieceResult(index, ok: false)
                            continue
                        }
                        if let storage = await swarm.storage {
                            do {
                                try storage.write(piece: index, data: full)
                            } catch {
                                // 写盘失败不是数据的问题，重下只会反复失败：记下错误，整个下载停下
                                Log.error("BT 写入失败：\(error.localizedDescription)")
                                await swarm.pieceWriteFailed(index, message: TorrentStorage.writeFailureMessage(error))
                                throw error
                            }
                        }
                        await swarm.pieceResult(index, ok: true)
                    }
                case .extended(0, let payload):
                    if let (head, _) = try? Bencode.decodePrefix(payload) {
                        if let id = head["m"]?["ut_metadata"]?.int, id > 0, id < 256 { metadataId = UInt8(id) }
                        if let size = head["metadata_size"]?.int { await swarm.setMetadataSize(Int(size)) }
                        if info == nil {
                            Log.info("BT peer \(address)：\(head["v"]?.string ?? "未知客户端")，ut_metadata=\(metadataId.map { "\($0)" } ?? "无")，" +
                                     "metadata_size=\(head["metadata_size"]?.int ?? 0)")
                        }
                    }
                case .extended(PeerWire.localPexId, let payload):
                    let found = PeerWire.parsePex(payload)
                    if !found.isEmpty { await swarm.addPeers(found) }
                case .extended(PeerWire.localMetadataId, let payload):
                    switch try PeerWire.parseMetadataMessage(payload) {
                    case .data(let piece, let total, let data):
                        if total > 0 { await swarm.setMetadataSize(total) }
                        await swarm.metadataReceived(piece, data)
                        metadataPiece = nil
                        lastUseful = Date()
                        useful = true
                    case .reject(let piece):
                        Log.info("BT peer \(address) 拒绝提供种子信息（第 \(piece) 块）")
                        await swarm.metadataRejected(piece)
                        metadataPiece = nil
                        metadataId = nil
                    case .request(let piece):
                        // 不对外提供元数据
                        if let id = metadataId { try await stream.send(PeerMessage.extended(id: id, payload: PeerWire.metadataReject(piece: piece)).encoded()) }
                    }
                default:
                    break
                }
            }
        } catch {
            // 连接失败 / 断开 / 超时：换别的 peer
        }
        await swarm.release(peer: pid, outstanding)
        if let metadataPiece { await swarm.metadataRejected(metadataPiece) }
        await swarm.peerEnded(address, useful: useful)
    }

    static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}

/// 解析页用：拿种子信息、列出文件
public enum TorrentMetadata {
    /// onStatus 回报已连接 / 已知的 peer 数，以及找节点的诊断信息
    public static func fetch(_ magnet: MagnetLink, cacheDirectory: URL, extraTrackers: [String] = [],
                             network: TorrentNetwork = TorrentNetworks.system, client: HTTPClient = .shared,
                             onStatus: (@Sendable (Int, Int, String) -> Void)? = nil) async throws -> TorrentInfo {
        if let cached = TorrentMetadataCache.load(in: cacheDirectory, infoHash: magnet.infoHash) { return cached }
        let progress = TransferProgress(chunks: [], total: -1)
        let transfer = TorrentTransfer(magnet: magnet, selection: nil, workDir: cacheDirectory, cacheDir: cacheDirectory, progress: progress,
                                       network: network, client: client, extraTrackers: extraTrackers, metadataOnly: true)
        let reporter = Task {
            while !Task.isCancelled {
                let p = progress.peers
                onStatus?(p.connected, p.known, progress.note ?? "")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { reporter.cancel() }
        return try await transfer.fetchMetadata()
    }
}
