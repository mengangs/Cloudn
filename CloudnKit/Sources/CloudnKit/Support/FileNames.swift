// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public enum FileNames {
    /// 清洗文件名：替换路径/保留字符与控制字符，过长时保留扩展名截断
    public static func sanitize(_ name: String) -> String {
        var cleaned = Rx(#"[\\/:*?"<>|\x00-\x1f]"#).replacing(in: name, with: "_").trimmed
        // 以点开头会变成隐藏文件
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let base = (cleaned as NSString).deletingPathExtension
            if !ext.isEmpty && ext.count <= 10 {
                cleaned = String(base.prefix(100)) + "." + ext
            } else {
                cleaned = String(cleaned.prefix(120))
            }
        }
        return cleaned
    }

    /// 标题 → 文件名主干（截断 80 字，为空用兜底）
    public static func base(_ title: String, fallback: String) -> String {
        let s = String(sanitize(title.replacingOccurrences(of: "\n", with: " ")).prefix(80)).trimmed
        return s.isEmpty ? fallback : s
    }

    /// 相对路径清洗：拒绝绝对路径与 `..`，逐段清洗
    public static func sanitizeRelativePath(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") { return nil }
        let parts = normalized.split(separator: "/").map(String.init)
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return nil }
        let cleaned = parts.map(sanitize).filter { !$0.isEmpty }
        return cleaned.joined(separator: "/")
    }

    public static func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    public enum Kind: Sendable { case folder, video, audio, image, archive, document, text, apk, other }

    public static func kind(of name: String, isDirectory: Bool = false) -> Kind {
        if isDirectory { return .folder }
        switch fileExtension(name) {
        case "mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8", "wmv", "rmvb", "m4v", "3gp", "m4s": return .video
        case "mp3", "flac", "wav", "aac", "m4a", "ogg", "ape", "wma", "opus": return .audio
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "avif": return .image
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz": return .archive
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub", "pages", "numbers", "key": return .document
        case "txt", "md", "json", "xml", "csv", "log", "srt", "ass", "lrc", "ini", "yaml", "yml": return .text
        case "apk", "ipa", "exe", "dmg", "msi": return .apk
        default: return .other
        }
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var i = 0
        while value >= 1024 && i < units.count - 1 { value /= 1024; i += 1 }
        return i == 0 ? "\(bytes) B" : String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[i])
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        string(Int64(bytesPerSecond)) + "/s"
    }

    /// 「1.5 M」「320 K」「2.1G」这类展示大小 → 字节（蓝奏云列表用）
    public static func parseDisplay(_ text: String) -> Int64 {
        guard let m = Rx(#"([\d.]+)\s*([KMGT]?)"#, ignoreCase: true).firstMatch(in: text.trimmed),
              let value = Double(m[1]) else { return 0 }
        let factor: Double
        switch m[2].uppercased() {
        case "K": factor = 1024
        case "M": factor = 1024 * 1024
        case "G": factor = 1024 * 1024 * 1024
        case "T": factor = 1024 * 1024 * 1024 * 1024
        default: factor = 1
        }
        return Int64(saturating: value * factor)
    }
}
