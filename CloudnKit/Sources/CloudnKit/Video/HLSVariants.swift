// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 平台只给了一个 m3u8 主列表（含多个清晰度）时，拆成可挑选的清晰度组。
/// 第一个仍是原主列表地址（下载时自动取最高码率，与以前一致），其余是各清晰度的子列表。
/// 清晰度引用独立音轨（AUDIO 组）的不拆：单独的子列表没有声音
enum HLSVariants {
    /// 一次解析里最多展开几个 m3u8，避免合集类结果发太多请求
    static let maxExpanded = 4
    static let maxOptions = 6

    static func expand(_ medias: [VideoMedia], client: HTTPClient = .shared) async -> [VideoMedia] {
        let targets = medias.indices.filter { medias[$0].isHLS && medias[$0].kind == .video && medias[$0].variantGroup.isEmpty }
        guard !targets.isEmpty, targets.count <= maxExpanded else { return medias }
        var expanded: [Int: [VideoMedia]] = [:]
        await withTaskGroup(of: (Int, [VideoMedia]?).self) { group in
            for i in targets {
                let media = medias[i]
                group.addTask {
                    guard let r = try? await client.send(HTTPRequest(url: media.url, headers: media.headers.sortedPairs, timeout: 10)),
                          r.isSuccess, r.text.contains("#EXTM3U") else { return (i, nil) }
                    return (i, options(for: media, playlist: M3U8.parse(r.text, baseURL: r.url), group: "hls\(i)"))
                }
            }
            for await (i, list) in group { if let list { expanded[i] = list } }
        }
        guard !expanded.isEmpty else { return medias }
        return medias.indices.flatMap { expanded[$0] ?? [medias[$0]] }
    }

    /// 主列表 → 清晰度组；不是主列表、只有一个清晰度或带独立音轨时返回 nil
    static func options(for media: VideoMedia, playlist: M3U8, group: String) -> [VideoMedia]? {
        guard playlist.isMaster, playlist.variants.count > 1,
              playlist.variantAudioGroups.allSatisfy({ $0 == nil }) else { return nil }
        // 每个清晰度只留码率最高的一条，按清晰度、码率从高到低
        var best: [String: (height: Int, bandwidth: Int, url: String)] = [:]
        for (i, v) in playlist.variants.enumerated() {
            let height = i < playlist.variantHeights.count ? playlist.variantHeights[i] : 0
            let key = height > 0 ? "h\(height)" : "b\(v.bandwidth)"
            if let old = best[key], old.bandwidth >= v.bandwidth { continue }
            best[key] = (height, v.bandwidth, v.url)
        }
        let sorted = best.values.sorted { ($0.height, $0.bandwidth) > ($1.height, $1.bandwidth) }
        guard sorted.count > 1 else { return nil }
        let base = (media.fileName as NSString).deletingPathExtension
        let ext = (media.fileName as NSString).pathExtension.isEmpty ? "mp4" : (media.fileName as NSString).pathExtension
        return sorted.prefix(maxOptions).enumerated().map { n, v in
            let label = label(height: v.height, bandwidth: v.bandwidth)
            return VideoMedia(url: n == 0 ? media.url : v.url, kind: media.kind,
                              fileName: n == 0 ? media.fileName : "\(base)_\(v.height > 0 ? "\(v.height)P" : "\(n)").\(ext)",
                              isHLS: true, headers: media.headers,
                              quality: n == 0 && !media.quality.isEmpty ? media.quality : label, variantGroup: group)
        }
    }

    static func label(height: Int, bandwidth: Int) -> String {
        if height > 0 { return "\(height)P" }
        return String(format: "%.1f Mbps", Double(bandwidth) / 1_000_000)
    }
}
