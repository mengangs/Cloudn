// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 下载前探测媒体地址：文件取大小；m3u8 取时长、清晰度并按码率估算大小（网页嗅探列表用）
public struct MediaProbeResult: Equatable, Sendable {
    /// 字节数；未知为 nil
    public var size: Int64?
    /// 大小是按码率 × 时长估出来的
    public var estimated = false
    /// 秒；未知为 nil
    public var duration: Double?
    /// 清晰度短边（720 表示 720p）；未知为 0
    public var height = 0

    public init(size: Int64? = nil, estimated: Bool = false, duration: Double? = nil, height: Int = 0) {
        self.size = size
        self.estimated = estimated
        self.duration = duration
        self.height = height
    }

    /// 很短或很小的多半是页面的预览片段 / 广告
    public var looksLikePreview: Bool {
        if let duration { return duration < 30 }
        if let size, !estimated { return size < 2 * 1024 * 1024 }
        return false
    }
}

public enum MediaProbe {
    public static func probe(_ url: String, headers: [String: String], isHLS: Bool, client: HTTPClient = .shared) async -> MediaProbeResult? {
        isHLS ? await probeHLS(url, headers: headers, client: client) : await probeFile(url, headers: headers, client: client)
    }

    /// 先 HEAD；拿不到长度（或服务器不支持 HEAD）再带 Range 只取开头 1 字节读 Content-Range。
    /// 取开头用流式请求：服务端忽略 Range 回整个文件时，收到第一块数据就断开，不会把文件读进内存
    static func probeFile(_ url: String, headers: [String: String], client: HTTPClient) async -> MediaProbeResult? {
        let pairs = headers.sortedPairs
        if let r = try? await client.send(HTTPRequest(url: url, method: "HEAD", headers: pairs, timeout: 12)), r.isSuccess,
           let length = Int64(r.header("Content-Length") ?? ""), length > 0 {
            return MediaProbeResult(size: length)
        }
        guard let r = try? await HTTPClient.fetchPrefixResponse(url, headers: pairs, limit: 1, timeout: 12) else { return nil }
        return sizeFromRangeProbe(status: r.status, headers: r.headers).map { MediaProbeResult(size: $0) }
    }

    /// Range 探测的响应 → 文件总大小：优先 Content-Range 的总长；服务端忽略 Range 回 200 时取 Content-Length。
    /// headers 的键为小写
    static func sizeFromRangeProbe(status: Int, headers: [String: String]) -> Int64? {
        guard (200..<300).contains(status) else { return nil }
        if let total = headers["content-range"].flatMap({ totalFromContentRange($0) }) { return total }
        if status == 200, let length = Int64(headers["content-length"] ?? ""), length > 0 { return length }
        return nil
    }

    static func probeHLS(_ url: String, headers: [String: String], client: HTTPClient) async -> MediaProbeResult? {
        guard var playlist = await load(url, headers: headers, client: client) else { return nil }
        var bandwidth = 0
        var height = 0
        if playlist.isMaster {
            guard let i = playlist.variants.indices.max(by: { playlist.variants[$0].bandwidth < playlist.variants[$1].bandwidth }),
                  let media = await load(playlist.variants[i].url, headers: headers, client: client) else { return nil }
            bandwidth = playlist.variants[i].bandwidth
            height = i < playlist.variantHeights.count ? playlist.variantHeights[i] : 0
            playlist = media
        }
        let duration = playlist.totalDuration
        var result = MediaProbeResult(duration: duration > 0 ? duration : nil, height: height)
        if bandwidth > 0 && duration > 0 {
            result.size = Int64(saturating: Double(bandwidth) * duration / 8)
            result.estimated = true
        } else if let first = playlist.segments.first,
                  let probed = await probeFile(first.url, headers: headers, client: client), let size = probed.size {
            // 没写码率：按第一个分片的大小 × 分片数估算
            // 服务端给的大小不可信：相乘溢出时不估
            let (estimate, overflow) = size.multipliedReportingOverflow(by: Int64(playlist.segments.count))
            result.size = overflow ? nil : estimate
            result.estimated = true
        }
        return result
    }

    private static func load(_ url: String, headers: [String: String], client: HTTPClient) async -> M3U8? {
        guard let r = try? await client.send(.get(url, headers: headers.sortedPairs)), r.isSuccess, r.text.contains("#EXTM3U") else { return nil }
        return M3U8.parse(r.text, baseURL: r.url)
    }

    /// `bytes 0-0/12345` → 12345
    static func totalFromContentRange(_ value: String) -> Int64? {
        guard let total = value.split(separator: "/").last, let n = Int64(total.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }
}
