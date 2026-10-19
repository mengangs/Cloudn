// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

/// 下载引擎的界面侧镜像
@MainActor
@Observable
final class DownloadStore {
    private(set) var items: [DownloadItem] = []
    @ObservationIgnored let engine: DownloadEngine
    @ObservationIgnored private let resolvers: ShareResolvers

    init(engine: DownloadEngine, resolvers: ShareResolvers) {
        self.engine = engine
        self.resolvers = resolvers
        Task { [weak self] in
            for await list in await engine.updates() {
                self?.items = list
            }
        }
    }

    var activeCount: Int { items.filter { $0.status.isActive }.count }

    func enqueue(_ request: DownloadRequest) {
        Task { await engine.enqueue(request) }
    }

    func enqueue(link: DownloadLink, platform: SharePlatform, folder: String, origin: ShareOrigin?) {
        let kind: DownloadKind = link.url.contains(".m3u8") ? .hls : .file
        enqueue(DownloadRequest(
            url: link.url, headers: link.headers, fileName: link.fileName, folder: folder, kind: kind,
            expectedSize: link.size, source: platform.displayName,
            cleanup: link.cleanupToken.map { CleanupToken(platform: platform.rawValue, token: $0) },
            origin: origin))
    }

    func enqueue(media: VideoMedia, result: VideoParseResult, folder: String = "") {
        let kind: DownloadKind = !media.audioURL.isEmpty ? .dash(audioURL: media.audioURL) : (media.isHLS ? .hls : .file)
        enqueue(DownloadRequest(url: media.url, headers: media.headers, fileName: media.fileName, folder: folder, kind: kind,
                                expectedSize: media.size, source: result.platform.displayName))
    }

    func pause(_ item: DownloadItem) { Task { await engine.pause(item.id) } }
    func resume(_ item: DownloadItem) { Task { await engine.resume(item.id) } }
    func remove(_ item: DownloadItem, deleteFile: Bool) { Task { await engine.remove(item.id, deleteFile: deleteFile) } }
    func pauseAll() { Task { await engine.pauseAll() } }
    func resumeAll() { Task { await engine.resumeAll() } }
    func clearFinished() { Task { await engine.clearFinished() } }
    func fileURL(_ item: DownloadItem) -> URL? { engine.fileURL(for: item) }

    /// 直链过期：按来源信息重新解析取链，保留已下载部分继续
    func refreshLink(_ item: DownloadItem) async throws {
        guard let origin = item.request.origin, let resolver = resolvers.resolver(for: origin.platform),
              let share = ShareLinkParser.parse(origin.shareURL) else {
            throw CloudnError("该任务没有可重新解析的来源，请回到解析页重新下载")
        }
        let session = try await resolver.openSession(share, pwd: origin.pwd)
        let link = try await resolver.downloadLink(session, file: origin.file)
        await engine.replaceLink(item.id, url: link.url, headers: link.headers)
    }
}
