// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation

/// 解析页最近结果的短时缓存（只在内存里）：从「最近」重新点开、返回后再解析同一链接时直接用上次的结果，不再等网络。
/// 直链有有效期，只留 10 分钟；失败不缓存；登录 / 换账号后键变了会重新解析。
/// 批量解析和下载失败后重新取链（DownloadStore）不走这里，总是重新解析
@MainActor
final class ParseCache {
    static let shared = ParseCache()
    static let lifetime: TimeInterval = 600
    static let capacity = 30

    private var entries: [String: (result: VideoParseResult, time: Date)] = [:]

    /// 链接 + 该平台当前账号：登录、退出、切换账号后不会拿到旧账号的结果
    static func key(for link: DetectedVideoLink, accounts: AccountStore) -> String {
        let cookie = link.platform.accountKind.flatMap { accounts.accounts[$0]?.cookie } ?? ""
        return "\(link.url)|\(cookie.hashValue)"
    }

    func result(for key: String, now: Date = Date()) -> VideoParseResult? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.time) < Self.lifetime else {
            entries[key] = nil
            return nil
        }
        return entry.result
    }

    func store(_ result: VideoParseResult, for key: String, now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.time) < Self.lifetime }
        if entries.count >= Self.capacity, let oldest = entries.min(by: { $0.value.time < $1.value.time })?.key {
            entries[oldest] = nil
        }
        entries[key] = (result, now)
    }
}
