// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 下载进度的共享状态（工作线程写、引擎定时读）
final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _chunks: [DownloadChunk]
    private var _total: Int64
    private var _segmentsDone = 0
    private var _segmentsTotal = 0
    private var _hlsBytes: Int64 = 0
    private var _title: String?
    private var _peers = 0
    private var _knownPeers = 0
    private var _note: String?

    init(chunks: [DownloadChunk], total: Int64) {
        _chunks = chunks
        _total = total
    }

    var chunks: [DownloadChunk] { lock.lock(); defer { lock.unlock() }; return _chunks }
    var total: Int64 { lock.lock(); defer { lock.unlock() }; return _total }

    var received: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _chunks.reduce(0) { $0 + $1.received } + _hlsBytes
    }

    /// BT：元数据到手后的种子名（任务名随之更新）
    var title: String? { lock.lock(); defer { lock.unlock() }; return _title }
    func setTitle(_ t: String) { lock.lock(); _title = t; lock.unlock() }
    /// BT：已连接 / 已知的 peer 数
    var peers: (connected: Int, known: Int) { lock.lock(); defer { lock.unlock() }; return (_peers, _knownPeers) }
    func setPeers(_ connected: Int, known: Int) { lock.lock(); _peers = connected; _knownPeers = known; lock.unlock() }
    /// BT：找节点的诊断信息（界面展示）
    var note: String? { lock.lock(); defer { lock.unlock() }; return _note }
    func setNote(_ n: String) { lock.lock(); _note = n; lock.unlock() }

    var segments: (done: Int, total: Int) { lock.lock(); defer { lock.unlock() }; return (_segmentsDone, _segmentsTotal) }

    func reset(chunks: [DownloadChunk], total: Int64) {
        lock.lock(); _chunks = chunks; _total = total; _hlsBytes = 0; lock.unlock()
    }

    func add(_ index: Int, _ bytes: Int64) {
        lock.lock()
        _chunks[index].received += bytes
        // 被切走后半段时，正在写的这一笔可能越过新的终点：已收字节不超过分片长度，免得和新分片重复计数
        let c = _chunks[index]
        if c.end >= 0 { _chunks[index].received = min(c.received, c.end - c.start + 1) }
        lock.unlock()
    }

    /// 弹性分片：把第 index 个分片还没下的部分对半切开，后半段作为新分片追加，返回新分片序号；剩余不够切返回 nil
    func split(_ index: Int, minPiece: Int64) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let c = _chunks[index]
        guard c.end >= 0 else { return nil }
        let cur = c.start + c.received
        let remaining = c.end - cur + 1
        guard remaining >= minPiece * 2 else { return nil }
        let mid = cur + remaining / 2
        _chunks.append(DownloadChunk(start: mid, end: c.end, received: 0))
        _chunks[index].end = mid - 1
        return _chunks.count - 1
    }

    func setReceived(_ index: Int, _ value: Int64) {
        lock.lock(); if index < _chunks.count { _chunks[index].received = value }; lock.unlock()
    }

    /// 长度未知的流读完后，把实际长度回填为总大小
    func finishOpenEnded(_ index: Int) {
        lock.lock()
        if _chunks[index].end < 0 {
            _chunks[index].end = _chunks[index].start + _chunks[index].received - 1
            _total = _chunks[index].start + _chunks[index].received
        }
        lock.unlock()
    }

    func chunk(_ index: Int) -> DownloadChunk { lock.lock(); defer { lock.unlock() }; return _chunks[index] }

    func setSegments(done: Int, total: Int) { lock.lock(); _segmentsDone = done; _segmentsTotal = total; lock.unlock() }
    func segmentFinished(bytes: Int64) { lock.lock(); _segmentsDone += 1; _hlsBytes += bytes; lock.unlock() }
}

struct TransferError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// 单个文件的分片下载：探测 → 规划分片 → 多连接并发写入同一文件的不同偏移 → 断点续传
struct RangeTransfer {
    let url: String
    let headers: [String: String]
    let destination: URL
    let progress: TransferProgress
    let connections: Int
    let retryCount: Int
    let streamer: StreamingSession
    /// 同一文件的其他直链：分片按序号轮流使用各条链接，某条失败时换下一条重试
    var mirrors: [DownloadSource] = []

    /// 主链在前
    var sources: [DownloadSource] { [DownloadSource(url: url, headers: headers)] + mirrors }

    /// 第 index 个分片第 attempt 次尝试用哪条链接
    static func sourceIndex(chunk index: Int, attempt: Int, count: Int) -> Int {
        count <= 1 ? 0 : (index + attempt) % count
    }

    static let minChunkSize: Int64 = 2 * 1024 * 1024
    /// 弹性分片切出来的每一半至少这么大（太碎了建连开销比省下的时间还多）
    static let minStealPiece: Int64 = 1024 * 1024

    func run() async throws {
        let fm = FileManager.default
        if progress.chunks.isEmpty || !fm.fileExists(atPath: destination.path) {
            try await plan()
        }
        // 只有按 Range 规划成多段的任务才能切分片、换连接（单流可能是服务端不支持 Range）
        let splittable = progress.chunks.count > 1
        let scheduler = ChunkScheduler()
        let workers = max(1, connections)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                scheduler.workerStarted()
                group.addTask {
                    defer { scheduler.workerFinished() }
                    // 空闲连接先领没开始的分片，领完了就把剩余最多的分片切一半接着下：不会出现别的连接都闲着、只剩一条慢连接在磨尾巴
                    while let index = scheduler.claim(progress: self.progress, splittable: splittable, minPiece: Self.minStealPiece) {
                        defer { scheduler.release(index) }
                        try await self.runChunk(index, scheduler: scheduler)
                    }
                }
            }
            if splittable {
                group.addTask {
                    // 看门狗：每 2 秒采样各连接速度，明显慢的连接断开重连（已写入的字节保留，从断点续传）
                    while scheduler.hasWorkers, !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        scheduler.sample(progress: self.progress, now: Date())
                    }
                }
            }
            try await group.waitForAll()
        }
        // 长度已知时校验写入总量，避免服务端提前断流留下残缺文件
        let total = progress.total
        if total > 0, progress.received < total { throw TransferError("下载不完整，请重试") }
    }

    /// 分段探测（Range: bytes=0-0）的响应 → (总长度, 是否支持分片)；nil 表示这次回应不可信，要不带 Range 再问一次。
    /// 只认 206 + `Content-Range: bytes 0-0/总长`（参考 YunX 的 ChunkDownloader）：
    /// 206 的 Content-Length 是这一段（1 字节）的长度；有的服务器（光鸭云盘）对分段请求回 200 / 不规范的头，
    /// 拿 Content-Length 当总长会把整个文件当成 1 字节。网页（text/html）多半是防盗链 / 过期页，不可信
    static func planTotal(status: Int, headers: [String: String]) -> (total: Int64, ranged: Bool)? {
        if (headers["content-type"] ?? "").lowercased().contains("text/html") { return nil }
        guard status == 206, let cr = headers["content-range"] else { return nil }
        let spec = cr.lowercased().replacingOccurrences(of: "bytes", with: "").trimmed
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, String(parts[0]).trimmed == "0-0", let total = Int64(String(parts[1]).trimmed), total > 1 else { return nil }
        return (total, true)
    }

    /// 不带 Range 的探测：只认 200 + Content-Length（不是网页）；拿不到时长度未知、整体下载
    static func plainTotal(status: Int, headers: [String: String]) -> Int64 {
        if (headers["content-type"] ?? "").lowercased().contains("text/html") { return -1 }
        guard status == 200, let len = headers["content-length"].flatMap({ Int64($0.trimmed) }), len > 0 else { return -1 }
        return len
    }

    /// 只取响应头（拿到即断开）
    private func head(range: Bool) async throws -> (status: Int, headers: [String: String]) {
        var request = makeRequest()
        if range { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
        var status = 0
        var respHeaders: [String: String] = [:]
        do {
            try await streamer.run(request, onResponse: { r in
                status = r.status
                respHeaders = r.headers
                return false
            }, onData: { _ in })
        } catch is StreamingSession.Rejected {
            // 拿到响应头即主动取消，属预期
        }
        return (status, respHeaders)
    }

    /// 探测总长度与是否支持分片
    private func plan() async throws {
        let probe = try await head(range: true)
        Log.info("下载探测（Range 0-0）：HTTP \(probe.status) Content-Range=\(probe.headers["content-range"] ?? "无") "
                 + "Content-Length=\(probe.headers["content-length"] ?? "无") Content-Type=\(probe.headers["content-type"] ?? "无")")
        guard (200..<300).contains(probe.status) else { throw TransferError(Self.statusMessage(probe.status)) }
        var total: Int64 = -1
        var ranged = false
        if let planned = Self.planTotal(status: probe.status, headers: probe.headers) {
            (total, ranged) = planned
        } else {
            // 分段回应不可信：不带 Range 再问一次总长度（拿不到就整体下载、长度未知）
            let plain = try await head(range: false)
            total = Self.plainTotal(status: plain.status, headers: plain.headers)
            Log.info("下载探测（不带 Range）：HTTP \(plain.status) Content-Length=\(plain.headers["content-length"] ?? "无") → 总长 \(total)")
        }
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        var chunks: [DownloadChunk]
        if ranged && total > Self.minChunkSize * 2 {
            let count = Int(min(Int64(max(1, connections)), max(1, total / Self.minChunkSize)))
            let size = total / Int64(count)
            chunks = (0..<count).map { i in
                let start = Int64(i) * size
                let end = i == count - 1 ? total - 1 : start + size - 1
                return DownloadChunk(start: start, end: end, received: 0)
            }
        } else {
            // 不支持分段（或分段回应不规范）：单流、不带 Range 从头读到尾，总长只用来显示进度和校验
            chunks = [DownloadChunk(start: 0, end: -1, received: 0)]
        }
        if total > 0 {
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: UInt64(total))
            try handle.close()
        }
        progress.reset(chunks: chunks, total: total)
    }

    private func runChunk(_ index: Int, scheduler: ChunkScheduler? = nil) async throws {
        var attempt = 0
        while true {
            do {
                try await fetchChunk(index, source: Self.sourceIndex(chunk: index, attempt: attempt, count: sources.count), scheduler: scheduler)
                return
            } catch is ChunkScheduler.Preempted {
                // 慢连接被换掉：已写入的保留，立即从断点重连，不算失败、不退避
                scheduler?.restarted(index, received: progress.chunk(index).received)
            } catch let e as TransferError where e.message.hasPrefix("HTTP 4") {
                // 多源时某条链接被拒绝，换下一条；每条都试过仍被拒绝才放弃
                attempt += 1
                if sources.count <= 1 || attempt >= sources.count { throw e }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                attempt += 1
                if attempt > retryCount { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
            }
        }
    }

    /// 单次请求的范围上限：YouTube（googlevideo.com）对一次拉取超过约 10MB 的请求限速，按 10MB 一段分多次请求
    static func requestCap(for url: String) -> Int64? {
        guard let host = URL(string: url)?.host?.lowercased(), host.hasSuffix("googlevideo.com") else { return nil }
        return 10 * 1024 * 1024
    }

    private func fetchChunk(_ index: Int, source: Int = 0, scheduler: ChunkScheduler? = nil) async throws {
        let picked = sources[min(max(0, source), sources.count - 1)].url
        guard let cap = Self.requestCap(for: picked), progress.chunk(index).end >= 0 else {
            return try await fetchPart(index, source: source, scheduler: scheduler, cap: nil)
        }
        while !progress.chunk(index).isDone {
            let before = progress.chunk(index).received
            try await fetchPart(index, source: source, scheduler: scheduler, cap: cap)
            if progress.chunk(index).received == before { throw TransferError("连接提前断开") }
        }
    }

    /// 下载分片（cap 不为空时只取从当前位置起至多 cap 字节，由 fetchChunk 循环取完）
    private func fetchPart(_ index: Int, source: Int, scheduler: ChunkScheduler?, cap: Int64?) async throws {
        let chunk = progress.chunk(index)
        if chunk.isDone { return }
        let single = progress.chunks.count == 1
        var offset = chunk.start + chunk.received
        var request = makeRequest(source: source)
        let partEnd: Int64 = cap.map { min(chunk.end, offset + $0 - 1) } ?? chunk.end
        if offset > 0 || chunk.end >= 0 {
            request.setValue("bytes=\(offset)-\(partEnd >= 0 ? String(partEnd) : "")", forHTTPHeaderField: "Range")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var failure: Error?
        do {
            try await streamer.run(request, onResponse: { r in
                if r.status == 200 && offset > 0 {
                    // 服务端忽略了 Range：单流可以从头重来，多分片无法继续
                    guard single else {
                        failure = TransferError("服务器不支持断点续传")
                        return false
                    }
                    offset = 0
                    self.progress.setReceived(index, 0)
                    try? handle.seek(toOffset: 0)
                    return true
                }
                guard r.status == 200 || r.status == 206 else {
                    failure = TransferError(Self.statusMessage(r.status))
                    return false
                }
                return true
            }, onData: { data in
                if let scheduler, scheduler.shouldStop(index) { throw ChunkScheduler.Preempted() }
                var payload = data
                // 终点每次现读：下载途中后半段可能被空闲连接切走
                let end = chunk.end >= 0 ? self.progress.chunk(index).end : -1
                if end >= 0 {
                    // 不写出分片边界（个别 CDN 会多给、或后半段已被切走）
                    let remaining = end - offset + 1
                    if remaining <= 0 { throw ChunkScheduler.Reached() }
                    if Int64(payload.count) > remaining { payload = payload.prefix(Int(remaining)) }
                }
                try handle.write(contentsOf: payload)
                offset += Int64(payload.count)
                self.progress.add(index, Int64(payload.count))
                // 写到（可能变短了的）终点就主动断开，不再白收后面的数据
                if end >= 0 && offset > end { throw ChunkScheduler.Reached() }
            })
        } catch is ChunkScheduler.Reached {
            // 到达终点主动断开，属正常结束
        } catch {
            throw failure ?? error
        }
        if let failure { throw failure }
        if chunk.end < 0 {
            progress.finishOpenEnded(index)
        } else if cap != nil {
            // 分段请求：这一段没取完（且分片也没被切短到已完成）才算断开
            let current = progress.chunk(index)
            if !current.isDone && current.start + current.received <= min(partEnd, current.end) {
                throw TransferError("连接提前断开")
            }
        } else if !progress.chunk(index).isDone {
            throw TransferError("连接提前断开")
        }
    }

    /// source 为链接序号（0 为主链，探测总长度一律用主链）
    private func makeRequest(source: Int = 0) -> URLRequest {
        let all = sources
        let picked = all[min(max(0, source), all.count - 1)]
        // 链接解析不出来时用一个必然失败的地址，让这次请求按普通失败处理，而不是崩溃
        var request = URLRequest(url: URL(string: picked.url) ?? URL(string: url) ?? URL(fileURLWithPath: "/dev/null/invalid"))
        request.httpShouldHandleCookies = false
        for (k, v) in picked.headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    static func statusMessage(_ status: Int) -> String {
        switch status {
        case 403: return "HTTP 403：直链已失效或被拒绝，请重新解析后下载"
        case 404, 410: return "HTTP \(status)：文件不存在或直链已过期"
        case 412: return "HTTP 412：直链校验失败，请重新解析后下载"
        case 416: return "HTTP 416：请求范围无效"
        case 0: return "网络连接失败"
        default: return "HTTP \(status)"
        }
    }
}

/// 弹性分片调度与慢连接抢占（参考 YunX 的任务池 + 弹性区与慢连接抢占）
final class ChunkScheduler: @unchecked Sendable {
    /// 慢连接被换掉
    struct Preempted: Error {}
    /// 分片写到终点，主动断开
    struct Reached: Error {}

    private struct Active {
        var startedAt: Date
        var lastBytes: Int64
        var lastAt: Date
        var speed: Double = -1
        var stop = false
    }

    /// 绝对下限：低于 12KB/s 才可能算慢（正常连接几十到几百 KB/s 以上）
    static let minBytesPerSecond: Double = 12 * 1024
    /// 每个分片最多换 3 次连接（整站都慢时防止反复重连）
    static let maxPreempts = 3

    private let lock = NSLock()
    private var claimed = Set<Int>()
    private var active: [Int: Active] = [:]
    private var preempts: [Int: Int] = [:]
    private var lastPreemptAt: [Int: Date] = [:]
    private var workers = 0
    private var peakWorkers = 0

    func workerStarted() { lock.lock(); workers += 1; peakWorkers = max(peakWorkers, workers); lock.unlock() }
    func workerFinished() { lock.lock(); workers -= 1; lock.unlock() }
    var hasWorkers: Bool { lock.lock(); defer { lock.unlock() }; return workers > 0 }

    /// 领一个分片：先领没开始的；都在下了就把剩余最多的切一半
    func claim(progress: TransferProgress, splittable: Bool, minPiece: Int64, now: Date = Date()) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let chunks = progress.chunks
        if let i = chunks.indices.first(where: { !claimed.contains($0) && !chunks[$0].isDone }) {
            begin(i, received: chunks[i].received, now: now)
            return i
        }
        guard splittable else { return nil }
        let candidates = claimed.sorted { remaining(chunks[$0]) > remaining(chunks[$1]) }
        for i in candidates {
            if let new = progress.split(i, minPiece: minPiece) {
                begin(new, received: 0, now: now)
                return new
            }
        }
        return nil
    }

    func release(_ index: Int) {
        lock.lock(); claimed.remove(index); active[index] = nil; lock.unlock()
    }

    func shouldStop(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return active[index]?.stop ?? false
    }

    func restarted(_ index: Int, received: Int64, now: Date = Date()) {
        lock.lock(); begin(index, received: received, now: now); lock.unlock()
    }

    /// 采样各连接速度；比「本任务单连接平均速度的一半」与绝对下限都慢的，标记换连接。
    /// 平时要跑满 15 秒、剩余 ≥128KB 才判；已有连接领不到活退出（真正收尾）时放宽到 3 秒、剩余 ≥16KB
    func sample(progress: TransferProgress, now: Date) {
        lock.lock(); defer { lock.unlock() }
        let chunks = progress.chunks
        for (i, a) in active where i < chunks.count {
            let received = chunks[i].received
            let dt = now.timeIntervalSince(a.lastAt)
            guard dt > 0.5 else { continue }
            active[i]?.speed = Double(max(0, received - a.lastBytes)) / dt
            active[i]?.lastBytes = received
            active[i]?.lastAt = now
        }
        let known = active.values.filter { $0.speed >= 0 }.map(\.speed)
        guard !known.isEmpty else { return }
        let average = known.reduce(0, +) / Double(known.count)
        let threshold = max(Self.minBytesPerSecond, average / 2)
        let pendingUnclaimed = chunks.indices.contains { !claimed.contains($0) && !chunks[$0].isDone }
        let endgame = !pendingUnclaimed && workers < peakWorkers
        var marked = 0
        for (i, a) in active.sorted(by: { $0.value.speed < $1.value.speed }) where marked < 2 && i < chunks.count {
            guard a.speed >= 0, a.speed < threshold, !a.stop, (preempts[i] ?? 0) < Self.maxPreempts,
                  now.timeIntervalSince(lastPreemptAt[i] ?? .distantPast) > 10 else { continue }
            let age = now.timeIntervalSince(a.startedAt)
            let left = remaining(chunks[i])
            guard endgame ? (age >= 3 && left >= 16 * 1024) : (age >= 15 && left >= 128 * 1024) else { continue }
            active[i]?.stop = true
            preempts[i, default: 0] += 1
            lastPreemptAt[i] = now
            marked += 1
            Log.info("换掉慢连接：分片 \(i) \(Int(a.speed / 1024))KB/s（阈值 \(Int(threshold / 1024))KB/s），剩余 \(left / 1024)KB")
        }
    }

    private func begin(_ index: Int, received: Int64, now: Date) {
        claimed.insert(index)
        active[index] = Active(startedAt: now, lastBytes: received, lastAt: now)
    }

    private func remaining(_ c: DownloadChunk) -> Int64 {
        c.end < 0 ? 0 : max(0, c.end - (c.start + c.received) + 1)
    }
}
