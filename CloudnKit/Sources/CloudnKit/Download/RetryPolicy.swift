// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 下载重试策略：哪些状态码值得重试、每次重试前等多久
enum RetryPolicy {
    /// 指数退避的起点与上限（秒）
    static let baseDelay: TimeInterval = 0.8
    static let maxDelay: TimeInterval = 30
    /// Retry-After 最多照办这么久（个别服务器给几小时，没必要真等）
    static let maxRetryAfter: TimeInterval = 120

    /// 408 请求超时、429 请求太频繁、5xx 服务器错误：过一会儿再试多半能好。
    /// 403 / 404 / 410 / 412 等是直链失效，重试没用，走重新取链
    static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    /// 第 attempt 次重试（从 1 起）前等待的秒数：0.8、1.6、3.2 … 封顶 30 秒；服务器给了 Retry-After 时按它来
    static func delay(attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, maxRetryAfter) }
        let n = max(1, attempt)
        // 2 的幂次封顶，避免溢出
        let factor = pow(2.0, Double(min(n - 1, 16)))
        return min(maxDelay, baseDelay * factor)
    }

    /// 解析 Retry-After：秒数，或 HTTP 日期（如 `Wed, 21 Oct 2026 07:28:00 GMT`）；解析不了返回 nil
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw) { return seconds >= 0 ? seconds : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// 退避等待（可被取消）
    static func sleep(attempt: Int, retryAfter: TimeInterval? = nil) async throws {
        let seconds = delay(attempt: attempt, retryAfter: retryAfter)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// 存储空间检查：开始下载前比较需要的空间与剩余空间，不够就提前失败，免得下到一半才写满
public enum DiskSpace {
    /// url 所在卷的可用空间（iOS 用「重要用途可用空间」，系统会为它清理可清除的缓存）；拿不到返回 nil
    public static func available(at url: URL) -> Int64? {
        var probe = url
        let fm = FileManager.default
        // 目录可能还没建：往上找到存在的那一级
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        #if canImport(Darwin)
        if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        #endif
        if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]), let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        if let attrs = try? fm.attributesOfFileSystem(forPath: probe.path), let free = attrs[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    /// 需要的空间超过剩余空间时返回错误说明；任一方未知（≤ 0 / nil）时不拦
    public static func shortage(needed: Int64, available: Int64?) -> String? {
        guard needed > 0, let available, available >= 0, needed > available else { return nil }
        return "存储空间不足：需要约 \(ByteFormat.string(needed))，剩余 \(ByteFormat.string(available))"
    }

    /// 不够时抛出 TransferError
    static func ensure(needed: Int64, at url: URL) throws {
        guard needed > 0 else { return }
        if let message = shortage(needed: needed, available: available(at: url)) { throw TransferError(message, permanent: true) }
    }

    /// 下载途中写满时的说明
    public static let writeFailedMessage = "存储空间不足，写入失败：请清理空间后继续"

    /// 写盘出错是否因为空间不足（ENOSPC / 配额用完 / Cocoa 的空间不足错误，包括包在 underlying 里的）
    public static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 4 {
            if e.domain == NSPOSIXErrorDomain && (e.code == Int(ENOSPC) || e.code == Int(EDQUOT)) { return true }
            if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
