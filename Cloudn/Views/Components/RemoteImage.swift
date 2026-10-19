// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
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

    init() { cache.countLimit = 300 }

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
        guard let (data, _) = try? await session.data(for: request), let image = UIImage(data: data) else { return nil }
        let prepared = await image.byPreparingForDisplay() ?? image
        cache.setObject(prepared, forKey: url as NSString)
        return prepared
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
            guard !url.isEmpty else { failed = true; return }
            image = ImageLoader.shared.cached(url)
            if image == nil {
                image = await ImageLoader.shared.load(url, headers: headers)
                failed = image == nil
            }
        }
    }
}
