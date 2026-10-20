// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 一次 BT 下载的共享状态：元数据拼装、分块分配、peer 地址池。各 peer 连接各跑一个任务，只在这里协调
actor TorrentSwarm {
    struct BlockRequest: Hashable, Sendable {
        let index: Int
        let begin: Int
        let length: Int
    }

    private struct ActivePiece {
        /// 0 未请求 / 1 已请求 / 2 已收到
        var state: [UInt8]
        var requesters: [[Int]]
        var blocks: [Int: Data] = [:]
        var received = 0
        let size: Int
    }

    /// 同时在拼的分块上限（控制内存：每个分块在校验前整块留在内存里）
    static let maxActivePieces = 48
    static let maxMetadataSize = 64 * 1024 * 1024

    let infoHash: [UInt8]
    private let selection: [Int]?
    private let workRoot: URL
    private let stateURL: URL
    private let cacheDir: URL
    private let progress: TransferProgress
    private let metadataOnly: Bool

    private(set) var info: TorrentInfo?
    private(set) var storage: TorrentStorage?
    private var have = Bitfield(count: 0)
    private var needed: [Bool] = []
    private var remaining = 0
    private var order: [Int] = []
    private var orderPos = 0
    private var retry: [Int] = []
    private var active: [Int: ActivePiece] = [:]
    private var verifying = Set<Int>()
    private var verifiedBytes: Int64 = 0
    private var inflightBytes: Int64 = 0
    private(set) var neededBytes: Int64 = 0
    private var lastStateSave = Date.distantPast

    private var metadataSize = 0
    private var metadataPieces: [Int: Data] = [:]
    private var metadataRequested: [Int: Date] = [:]

    private var queue: [PeerAddress] = []
    private var seen = Set<PeerAddress>()
    private var connected = Set<PeerAddress>()
    private var failures: [PeerAddress: Int] = [:]
    private var nextPeer = 0
    private(set) var trackers: [String]

    init(infoHash: [UInt8], selection: [Int]?, trackers: [String], workRoot: URL, stateURL: URL,
         cacheDir: URL, progress: TransferProgress, metadataOnly: Bool) {
        self.infoHash = infoHash
        self.selection = selection
        self.trackers = trackers
        self.workRoot = workRoot
        self.stateURL = stateURL
        self.cacheDir = cacheDir
        self.progress = progress
        self.metadataOnly = metadataOnly
    }

    /// 已有元数据（缓存 / 种子文件）时直接建立下载计划
    func begin(with info: TorrentInfo?) throws {
        if let info, self.info == nil { try setupDownload(info) }
    }

    var isComplete: Bool {
        guard info != nil else { return false }
        return metadataOnly || remaining == 0
    }

    var pieceCount: Int? { info?.pieceCount }
    var connectedCount: Int { connected.count }
    var knownCount: Int { seen.count }
    var leftBytes: Int64 { info == nil ? 1 << 30 : max(0, neededBytes - verifiedBytes) }
    var downloadedBytes: Int64 { verifiedBytes }
    var metadataSizeIfKnown: Int? { info.map { $0.rawInfo.count } ?? (metadataSize > 0 ? metadataSize : nil) }

    // MARK: 元数据就绪后建立下载计划

    private func setupDownload(_ info: TorrentInfo) throws {
        self.info = info
        progress.setTitle(info.name)
        guard !metadataOnly else { return }
        let all = Set(info.files.map(\.id))
        let chosen = selection.map { Set($0).intersection(all) } ?? all
        needed = info.pieces(for: chosen)
        have = Bitfield(count: info.pieceCount)
        if let saved = TorrentResumeState.load(stateURL), Set(saved.selected) == chosen {
            have = Bitfield(data: saved.have, count: info.pieceCount)
        }
        neededBytes = 0
        verifiedBytes = 0
        remaining = 0
        var pending: [Int] = []
        for i in 0..<info.pieceCount where needed[i] {
            let size = Int64(info.pieceSize(i))
            neededBytes += size
            if have[i] { verifiedBytes += size } else { remaining += 1; pending.append(i) }
        }
        // 随机顺序：不同客户端各下各的，整个种子的分块更均匀，也不会全挤在稀缺块上
        order = pending.shuffled()
        orderPos = 0
        let storage = TorrentStorage(info: info, root: workRoot, selected: chosen)
        try storage.prepare()
        self.storage = storage
        progress.reset(chunks: [DownloadChunk(start: 0, end: max(0, neededBytes) - 1, received: verifiedBytes)], total: neededBytes)
        saveState(force: true)
    }

    // MARK: 元数据（BEP 9）

    func setMetadataSize(_ size: Int) {
        guard info == nil, metadataSize == 0, size > 0, size <= Self.maxMetadataSize else { return }
        metadataSize = size
    }

    /// 还没拿到、且最近 15 秒没向别人要过的元数据块
    func nextMetadataPiece(now: Date = Date()) -> Int? {
        guard info == nil, metadataSize > 0 else { return nil }
        let count = (metadataSize + PeerWire.metadataPieceSize - 1) / PeerWire.metadataPieceSize
        for i in 0..<count where metadataPieces[i] == nil {
            if let at = metadataRequested[i], now.timeIntervalSince(at) < 15 { continue }
            metadataRequested[i] = now
            return i
        }
        return nil
    }

    func metadataRejected(_ piece: Int) { metadataRequested[piece] = nil }

    func metadataReceived(_ piece: Int, _ data: Data) {
        guard info == nil, metadataSize > 0 else { return }
        let count = (metadataSize + PeerWire.metadataPieceSize - 1) / PeerWire.metadataPieceSize
        guard piece >= 0, piece < count else { return }
        let expected = piece == count - 1 ? metadataSize - piece * PeerWire.metadataPieceSize : PeerWire.metadataPieceSize
        guard data.count == expected else { metadataRequested[piece] = nil; return }
        metadataPieces[piece] = data
        guard metadataPieces.count == count else { return }
        let raw = (0..<count).reduce(into: Data()) { $0.append(metadataPieces[$1]!) }
        metadataPieces = [:]
        metadataRequested = [:]
        do {
            let parsed = try TorrentInfo.parse(info: raw, expectedHash: infoHash)
            TorrentMetadataCache.save(parsed, in: cacheDir)
            Log.info("BT 元数据就绪：\(parsed.name)，\(parsed.pieceCount) 块，\(parsed.files.count) 个文件")
            try setupDownload(parsed)
        } catch {
            // 校验不过（有人发了错的数据）：整份重新要
            Log.error("BT 元数据无效：\(error.localizedDescription)")
            metadataSize = 0
        }
    }

    // MARK: 分块分配

    func assign(peer: Int, has: Bitfield, max limit: Int) -> [BlockRequest] {
        guard let info, limit > 0 else { return [] }
        var out: [BlockRequest] = []
        // 先补齐正在拼的分块，尽快凑满整块去校验
        for index in active.keys.sorted() where has[index] {
            take(index, peer: peer, into: &out, limit: limit, info: info)
            if out.count >= limit { return out }
        }
        while out.count < limit, active.count < Self.maxActivePieces, let index = nextNewPiece(has) {
            let size = info.pieceSize(index)
            let blocks = (size + PeerWire.blockSize - 1) / PeerWire.blockSize
            active[index] = ActivePiece(state: [UInt8](repeating: 0, count: blocks), requesters: Array(repeating: [], count: blocks), size: size)
            take(index, peer: peer, into: &out, limit: limit, info: info)
        }
        if out.isEmpty {
            // 收尾阶段：剩下的块都已有人在下，允许同一块再向另一个 peer 要一份，谁先到用谁的
            for index in active.keys.sorted() where has[index] {
                guard var p = active[index] else { continue }
                for b in p.state.indices where p.state[b] == 1 && !p.requesters[b].contains(peer) && p.requesters[b].count < 2 {
                    p.requesters[b].append(peer)
                    out.append(block(index, b, size: p.size))
                    if out.count >= limit { break }
                }
                active[index] = p
                if out.count >= limit { break }
            }
        }
        return out
    }

    private func take(_ index: Int, peer: Int, into out: inout [BlockRequest], limit: Int, info: TorrentInfo) {
        guard var p = active[index] else { return }
        for b in p.state.indices where p.state[b] == 0 {
            p.state[b] = 1
            p.requesters[b] = [peer]
            out.append(block(index, b, size: p.size))
            if out.count >= limit { break }
        }
        active[index] = p
    }

    private func block(_ index: Int, _ b: Int, size: Int) -> BlockRequest {
        let begin = b * PeerWire.blockSize
        return BlockRequest(index: index, begin: begin, length: min(PeerWire.blockSize, size - begin))
    }

    private func isFree(_ i: Int) -> Bool { !have[i] && active[i] == nil && !verifying.contains(i) }

    private func nextNewPiece(_ has: Bitfield) -> Int? {
        if let k = retry.firstIndex(where: { has[$0] && isFree($0) }) { return retry.remove(at: k) }
        while orderPos < order.count, !isFree(order[orderPos]) { orderPos += 1 }
        var j = orderPos
        while j < order.count {
            let i = order[j]
            if has[i] && isFree(i) { return i }
            j += 1
        }
        return nil
    }

    /// 连接断开 / 被 choke：没收到的块退回待分配
    func release(peer: Int, _ blocks: [BlockRequest]) {
        for r in blocks {
            guard var p = active[r.index] else { continue }
            let b = r.begin / PeerWire.blockSize
            guard b < p.state.count, p.state[b] == 1 else { continue }
            p.requesters[b].removeAll { $0 == peer }
            if p.requesters[b].isEmpty { p.state[b] = 0 }
            active[r.index] = p
        }
    }

    /// 收到一块数据；凑满整个分块时返回完整数据（调用方在 actor 外校验、落盘，再报 pieceResult）
    func deliver(peer: Int, index: Int, begin: Int, block data: Data) -> Data? {
        guard var p = active[index], begin % PeerWire.blockSize == 0 else { return nil }
        let b = begin / PeerWire.blockSize
        guard b < p.state.count, p.state[b] != 2, data.count == min(PeerWire.blockSize, p.size - begin) else { return nil }
        p.state[b] = 2
        p.requesters[b] = []
        p.blocks[b] = data
        p.received += 1
        inflightBytes += Int64(data.count)
        if p.received < p.state.count {
            active[index] = p
            reportProgress()
            return nil
        }
        active[index] = nil
        verifying.insert(index)
        var full = Data(capacity: p.size)
        for i in 0..<p.state.count { full.append(p.blocks[i]!) }
        inflightBytes -= Int64(p.size)
        return full
    }

    func pieceHash(_ index: Int) -> Data? { info?.pieceHashes[index] }

    func pieceResult(_ index: Int, ok: Bool) {
        verifying.remove(index)
        guard let info else { return }
        if ok {
            if !have[index] {
                have[index] = true
                remaining -= 1
                verifiedBytes += Int64(info.pieceSize(index))
            }
            saveState(force: remaining == 0)
        } else {
            Log.error("BT 分块 \(index) 校验失败，重新下载")
            retry.append(index)
        }
        reportProgress()
    }

    private func reportProgress() {
        progress.setReceived(0, min(neededBytes, verifiedBytes + inflightBytes))
    }

    private func saveState(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStateSave) > 1 else { return }
        lastStateSave = now
        guard let info else { return }
        let all = Set(info.files.map(\.id))
        let chosen = selection.map { Set($0).intersection(all) } ?? all
        TorrentResumeState(have: have.data, selected: chosen.sorted()).save(stateURL)
    }

    func flush() { saveState(force: true) }

    // MARK: peer 地址池

    func addPeers(_ peers: [PeerAddress]) {
        for p in peers where !seen.contains(p) && seen.count < 5000 {
            seen.insert(p)
            queue.append(p)
        }
        progress.setPeers(connected.count, known: seen.count)
    }

    func addTrackers(_ list: [String]) {
        for t in list where !trackers.contains(t) { trackers.append(t) }
    }

    func takeConnectable(limit: Int) -> [PeerAddress] {
        var out: [PeerAddress] = []
        while connected.count < limit, !queue.isEmpty {
            let p = queue.removeFirst()
            guard !connected.contains(p) else { continue }
            connected.insert(p)
            out.append(p)
        }
        if !out.isEmpty { progress.setPeers(connected.count, known: seen.count) }
        return out
    }

    func registerPeer() -> Int {
        nextPeer += 1
        return nextPeer
    }

    /// 连接结束：出过力的 peer 排回队尾稍后再连；连不上的最多再试一次
    func peerEnded(_ address: PeerAddress, useful: Bool) {
        connected.remove(address)
        if useful {
            failures[address] = 0
            queue.append(address)
        } else {
            let n = (failures[address] ?? 0) + 1
            failures[address] = n
            if n < 2 { queue.append(address) }
        }
        progress.setPeers(connected.count, known: seen.count)
    }
}
