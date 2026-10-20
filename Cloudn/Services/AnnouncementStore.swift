// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

/// 应用内公告：列表、已读记录（只存在本机）、启动弹窗
@MainActor
@Observable
final class AnnouncementStore {
    private(set) var items: [Announcement] = []
    private(set) var loading = false
    private(set) var errorMessage: String?
    /// 待弹出的公告（启动检查得出，关掉后清空）
    var popup: Announcement?
    private(set) var readIds: Set<String>

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private var mirror: () -> String

    init(mirror: @escaping () -> String) {
        self.mirror = mirror
        readIds = Set(UserDefaults.standard.stringArray(forKey: "announcementsRead") ?? [])
    }

    var unreadCount: Int { items.filter { !readIds.contains($0.id) }.count }

    func isRead(_ a: Announcement) -> Bool { readIds.contains(a.id) }

    /// 启动 / 回到前台：最多每 6 小时拉一次，失败静默；有未读的就挑一条弹出
    func checkOnLaunch() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 6 * 3600 { return }
        Task {
            await refresh()
            if popup == nil, errorMessage == nil { popup = Announcements.popupCandidate(items, read: readIds) }
        }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await Announcements.fetch(mirror: mirror(), currentVersion: AppModel.currentVersion)
            errorMessage = nil
            lastFetch = Date()
        } catch {
            errorMessage = error.localizedDescription
            Log.error("公告：\(error.localizedDescription)")
        }
    }

    func markRead(_ id: String) {
        guard !readIds.contains(id) else { return }
        readIds.insert(id)
        // 只留最近 500 条，按当前列表优先保留
        var list = items.map(\.id).filter(readIds.contains)
        list += readIds.subtracting(list).prefix(max(0, 500 - list.count))
        defaults.set(list, forKey: "announcementsRead")
    }

    func markAllRead() {
        for a in items { markRead(a.id) }
    }
}
