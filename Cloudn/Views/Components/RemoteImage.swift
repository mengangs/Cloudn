// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import ImageIO
import SwiftUI
import UIKit

/// 带请求头的网络图片（各平台图床校验 Referer / UA，系统 AsyncImage 带不了头）
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 200 << 20)
        return URLSession(configuration: config)
    }()

    init() {
        cache.countLimit = 300
        // 按解码后的字节数计费，图集翻多了也不会把内存吃满
        cache.totalCostLimit = 120 << 20
    }

    func clear() {
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    func cached(_ url: String) -> UIImage? { cache.object(forKey: url as NSString) }

    func load(_ url: String, headers: [String: String]) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSString) { return hit }
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        // 原图常有三四千像素（解码后四五十 MB），按最长边 1600 像素降采样解码，放在后台线程
        guard let image = await Task.detached(priority: .userInitiated, operation: { Self.downsample(data, maxPixel: 1600) }).value else {
            return nil
        }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        cache.setObject(image, forKey: url as NSString, cost: cost)
        return image
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return UIImage(data: data) }
        let thumb: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

struct RemoteImage: View {
    let url: String
    var headers: [String: String] = [:]
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                // 加载中只是一块暖灰底，不放转圈（图集里几十个转圈很吵）；失败时给个图片图标
                Rectangle()
                    .fill(Color.fillMuted)
                    .overlay {
                        if failed { IconView(.image, size: 20).foregroundStyle(Color.ink3) }
                    }
            }
        }
        .task(id: url) {
            guard !url.isEmpty else { image = nil; failed = true; return }
            // 换了地址（列表复用）：先清掉上一张的失败标记，加载中不显示「失败」图标
            failed = false
            image = ImageLoader.shared.cached(url)
            if image == nil {
                image = await ImageLoader.shared.load(url, headers: headers)
                failed = image == nil
            }
        }
    }
}
