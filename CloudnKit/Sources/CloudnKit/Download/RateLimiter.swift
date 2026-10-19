// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 全局下载限速（所有任务、所有连接共享一个额度）：每收到一段数据就预约它占用的时间，
/// 调用方等到预约的时刻再继续。限速为 0 表示不限。
final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytesPerSecond: Int64 = 0
    private var nextFree = Date.distantPast

    func setLimit(_ value: Int64) {
        lock.lock()
        if value != bytesPerSecond { nextFree = .distantPast }
        bytesPerSecond = max(0, value)
        lock.unlock()
    }

    var limit: Int64 {
        lock.lock(); defer { lock.unlock() }
        return bytesPerSecond
    }

    /// 为 bytes 字节预约额度，返回需要等待的秒数
    func reserve(_ bytes: Int, now: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard bytesPerSecond > 0, bytes > 0 else { return 0 }
        // 空闲超过 1 秒后不攒额度，避免恢复下载时瞬间冲高
        let start = max(nextFree, now.addingTimeInterval(-1))
        nextFree = start.addingTimeInterval(Double(bytes) / Double(bytesPerSecond))
        return max(0, nextFree.timeIntervalSince(now))
    }

    /// 同步等待（URLSession 代理队列里用；该队列串行，所有连接一起被放慢）
    func throttle(_ bytes: Int) {
        let wait = reserve(bytes)
        if wait > 0 { Thread.sleep(forTimeInterval: min(wait, 5)) }
    }

    func throttleAsync(_ bytes: Int) async throws {
        let wait = reserve(bytes)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000)) }
    }
}
