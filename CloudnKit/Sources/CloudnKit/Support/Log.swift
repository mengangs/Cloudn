// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 诊断日志：追加写入单个文本文件（超过 2MB 时保留后一半），设置页可导出给开发者排查问题。
/// 只记事件与错误，不记 Cookie / 令牌等凭据。
public enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var url: URL?
    static let maxSize = 2 * 1024 * 1024

    /// 设置日志文件位置（应用启动时调用；未设置时不写）
    public static func configure(file: URL) {
        lock.lock()
        url = file
        lock.unlock()
    }

    public static var fileURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return url
    }

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    public static func clear() {
        lock.lock(); defer { lock.unlock() }
        guard let url else { return }
        try? Data().write(to: url)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] \(redact(message))\n"
        lock.lock()
        defer { lock.unlock() }
        guard let url else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > UInt64(maxSize) {
            // 超长：只保留后一半
            try? handle.seek(toOffset: size / 2)
            let tail = (try? handle.readToEnd()) ?? Data()
            try? handle.truncate(atOffset: 0)
            try? handle.write(contentsOf: tail)
        }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// 去掉 URL 查询串里的签名 / 令牌，避免日志泄露直链凭据
    static func redact(_ message: String) -> String {
        Rx(#"(https?://[^\s?]+)\?[^\s]*"#).replacing(in: message, with: "$1?…")
    }
}
