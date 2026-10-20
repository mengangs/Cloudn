// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

/// 磁力链接的种子信息获取放在应用层：离开种子页不会中断，回来时接着看同一次查找的进度与结果
@MainActor
@Observable
final class TorrentFetchStore {
    struct Status: Equatable {
        var connected = 0
        var known = 0
        var note = ""
        var info: TorrentInfo?
        var error: String?

        static func == (a: Status, b: Status) -> Bool {
            a.connected == b.connected && a.known == b.known && a.note == b.note && a.error == b.error
                && a.info?.infoHash == b.info?.infoHash
        }
    }

    private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let extraTrackers: () -> [String]

    init(cacheDirectory: URL, extraTrackers: @escaping () -> [String]) {
        self.cacheDirectory = cacheDirectory
        self.extraTrackers = extraTrackers
    }

    func status(_ magnet: MagnetLink) -> Status { statuses[magnet.hexHash] ?? Status() }

    /// 没在查、也没有结果时才开始；失败后再调用即重试
    func start(_ magnet: MagnetLink) {
        let key = magnet.hexHash
        if tasks[key] != nil || statuses[key]?.info != nil { return }
        statuses[key] = Status()
        let cache = cacheDirectory
        let trackers = extraTrackers()
        tasks[key] = Task { [weak self] in
            do {
                let info = try await TorrentMetadata.fetch(magnet, cacheDirectory: cache, extraTrackers: trackers) { connected, known, note in
                    Task { @MainActor in self?.update(key) { $0.connected = connected; $0.known = known; $0.note = note } }
                }
                self?.update(key) { $0.info = info; $0.error = nil }
            } catch is CancellationError {
                self?.update(key) { $0.error = nil }
            } catch {
                self?.update(key) { $0.error = error.localizedDescription }
            }
            self?.tasks[key] = nil
        }
    }

    /// 已交给下载任务自己去取：停掉这边的查找，免得两份一起连节点
    func cancel(_ magnet: MagnetLink) {
        tasks[magnet.hexHash]?.cancel()
        tasks[magnet.hexHash] = nil
    }

    private func update(_ key: String, _ change: (inout Status) -> Void) {
        var s = statuses[key] ?? Status()
        change(&s)
        statuses[key] = s
    }
}
