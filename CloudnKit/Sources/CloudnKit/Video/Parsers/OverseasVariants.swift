// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 海外平台共用：把同一视频的多档清晰度整理成一个 VideoMedia 清晰度组。
/// 第一档是默认选择（各解析器原本返回的那条，须是最高画质），其余档排在后面供挑选。
enum OverseasVariants {
    /// 一档清晰度（纯数据，便于离线测试）
    struct Option: Equatable, Sendable {
        var url: String
        var quality: String
        var size: Int64 = -1
        /// 分轨音频（DASH 视频轨），下载完需合轨
        var audioURL = ""
        var isHLS = false
    }

    /// 每个视频最多列出的档数
    static let maxOptions = 6

    /// 去掉空链接、重复直链与重复标签（保留先出现的），最多 limit 档；第一档原样保留
    static func dedupe(_ options: [Option], limit: Int = maxOptions) -> [Option] {
        var urls = Set<String>()
        var labels = Set<String>()
        var out: [Option] = []
        for option in options where !option.url.isEmpty {
            guard !urls.contains(option.url) else { continue }
            if !option.quality.isEmpty {
                guard labels.insert(option.quality).inserted else { continue }
            }
            urls.insert(option.url)
            out.append(option)
            if out.count >= limit { break }
        }
        return out
    }

    /// 各档 → 媒体。去重后只剩一档时不分组（与只有一种清晰度时的老行为一致）；
    /// 多档时共用 group，第一档文件名为 `stem.ext`，其余带清晰度后缀以免重名
    static func medias(_ options: [Option], stem: String, ext: String = "mp4", group: String,
                       kind: MediaKind = .video, headers: [String: String] = [:]) -> [VideoMedia] {
        let list = dedupe(options)
        guard list.count > 1 else {
            return list.map {
                VideoMedia(url: $0.url, kind: kind, fileName: "\(stem).\(ext)", size: $0.size, isHLS: $0.isHLS, headers: headers,
                           quality: $0.quality, audioURL: $0.audioURL)
            }
        }
        var names = Set<String>()
        var out: [VideoMedia] = []
        for (i, option) in list.enumerated() {
            var name = "\(stem).\(ext)"
            if i > 0 {
                let tag = fileTag(option.quality)
                name = "\(stem)_\(tag.isEmpty ? "v\(i + 1)" : tag).\(ext)"
                var n = 2
                while names.contains(name) {
                    name = "\(stem)_\(tag.isEmpty ? "v\(i + 1)" : tag)_\(n).\(ext)"
                    n += 1
                }
            }
            names.insert(name)
            out.append(VideoMedia(url: option.url, kind: kind, fileName: name, size: option.size, isHLS: option.isHLS,
                                  headers: headers, quality: option.quality, audioURL: option.audioURL, variantGroup: group))
        }
        return out
    }

    /// 清晰度标签 → 文件名后缀：`720P · H.265` → `720P_H.265`，`2.1 Mbps` → `2.1Mbps`
    static func fileTag(_ quality: String) -> String {
        let s = quality.replacingOccurrences(of: " · ", with: "_").replacingOccurrences(of: " ", with: "")
        return FileNames.sanitize(s)
    }

    /// 宽高 → `1080P`（取短边；只知道一边时用那一边）
    static func label(width: Int, height: Int) -> String {
        let side = width > 0 && height > 0 ? min(width, height) : max(width, height)
        return side > 0 ? "\(side)P" : ""
    }

    /// 码率（bit/s）→ `2.1 Mbps` / `832 kbps`
    static func label(bitrate: Int) -> String {
        guard bitrate > 0 else { return "" }
        if bitrate >= 1_000_000 { return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000) }
        return "\(max(1, bitrate / 1000)) kbps"
    }

    /// Meta（Instagram / Threads）的 video_versions：第一条是默认（原先就取它），其余按分辨率从高到低（同分辨率保持原顺序）
    static func metaVideoVersions(_ versions: [JSON]) -> [Option] {
        var all: [(index: Int, area: Int, option: Option)] = []
        for (i, v) in versions.enumerated() {
            let url = v["url"].string
            guard !url.isEmpty else { continue }
            let w = v["width"].int, h = v["height"].int
            all.append((i, w * h, Option(url: url, quality: label(width: w, height: h))))
        }
        guard let first = all.first else { return [] }
        let rest = all.dropFirst().sorted { $0.area != $1.area ? $0.area > $1.area : $0.index < $1.index }
        return [first.option] + rest.map { $0.option }
    }

    /// 直链路径里的 `1280x720` → `720P`
    static func label(fromPath url: String) -> String {
        guard let m = Rx(#"/(\d{2,5})x(\d{2,5})/"#).firstMatch(in: url), m.count >= 3 else { return "" }
        return label(width: Int(m[1]) ?? 0, height: Int(m[2]) ?? 0)
    }
}
