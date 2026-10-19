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

    var segments: (done: Int, total: Int) { lock.lock(); defer { lock.unlock() }; return (_segmentsDone, _segmentsTotal) }

    func reset(chunks: [DownloadChunk], total: Int64) {
        lock.lock(); _chunks = chunks; _total = total; _hlsBytes = 0; lock.unlock()
    }

    func add(_ index: Int, _ bytes: Int64) {
        lock.lock(); _chunks[index].received += bytes; lock.unlock()
    }

    func setReceived(_ index: Int, _ value: Int64) {
        lock.lock(); _chunks[index].received = value; lock.unlock()
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

    func run() async throws {
        let fm = FileManager.default
        if progress.chunks.isEmpty || !fm.fileExists(atPath: destination.path) {
            try await plan()
        }
        let pending = progress.chunks.indices.filter { !progress.chunk($0).isDone }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0..<max(1, min(connections, pending.count)) {
                guard let index = iterator.next() else { break }
                group.addTask { try await self.runChunk(index) }
            }
            while try await group.next() != nil {
                if let index = iterator.next() { group.addTask { try await self.runChunk(index) } }
            }
        }
        // 长度已知时校验写入总量，避免服务端提前断流留下残缺文件
        let total = progress.total
        if total > 0, progress.received < total { throw TransferError("下载不完整，请重试") }
    }

    /// 用 Range: bytes=0-0 探测总长度与是否支持分片
    private func plan() async throws {
        var request = makeRequest()
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
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
        guard (200..<300).contains(status) else { throw TransferError(Self.statusMessage(status)) }
        var total: Int64 = -1
        var ranged = false
        if status == 206, let cr = respHeaders["content-range"], let t = Int64(cr.substringAfterLast("/").trimmed) {
            total = t
            ranged = true
        } else if let len = respHeaders["content-length"].flatMap({ Int64($0.trimmed) }) {
            total = len
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
            chunks = [DownloadChunk(start: 0, end: total > 0 ? total - 1 : -1, received: 0)]
        }
        if total > 0 {
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: UInt64(total))
            try handle.close()
        }
        progress.reset(chunks: chunks, total: total)
    }

    private func runChunk(_ index: Int) async throws {
        var attempt = 0
        while true {
            do {
                try await fetchChunk(index, source: Self.sourceIndex(chunk: index, attempt: attempt, count: sources.count))
                return
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

    private func fetchChunk(_ index: Int, source: Int = 0) async throws {
        let chunk = progress.chunk(index)
        if chunk.isDone { return }
        let single = progress.chunks.count == 1
        var offset = chunk.start + chunk.received
        var request = makeRequest(source: source)
        if offset > 0 || chunk.end >= 0 {
            request.setValue("bytes=\(offset)-\(chunk.end >= 0 ? String(chunk.end) : "")", forHTTPHeaderField: "Range")
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
                var payload = data
                if chunk.end >= 0 {
                    // 不写出分片边界（个别 CDN 会多给）
                    let remaining = chunk.end - offset + 1
                    if remaining <= 0 { return }
                    if Int64(payload.count) > remaining { payload = payload.prefix(Int(remaining)) }
                }
                try handle.write(contentsOf: payload)
                offset += Int64(payload.count)
                self.progress.add(index, Int64(payload.count))
            })
        } catch {
            throw failure ?? error
        }
        if let failure { throw failure }
        if chunk.end < 0 {
            progress.finishOpenEnded(index)
        } else if !progress.chunk(index).isDone {
            throw TransferError("连接提前断开")
        }
    }

    /// source 为链接序号（0 为主链，探测总长度一律用主链）
    private func makeRequest(source: Int = 0) -> URLRequest {
        let all = sources
        let picked = all[min(max(0, source), all.count - 1)]
        var request = URLRequest(url: URL(string: picked.url) ?? URL(string: url)!)
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
