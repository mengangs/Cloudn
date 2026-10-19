// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import ActivityKit
import CloudnKit
import Foundation

/// 下载进度实时活动：有任务开始时创建，进度变化节流更新，全部结束后显示「下载完成」并稍后消失
@MainActor
final class DownloadActivity {
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: DownloadActivityAttributes.ContentState?
    /// 本轮开始时已完成的任务，用来统计「本轮已完成」
    private var baselineCompleted = Set<UUID>()

    /// 设置页开关（默认开启）
    private var enabled: Bool { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }

    func update(with items: [DownloadItem]) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            end(final: nil)
            return
        }
        let active = items.filter { $0.status.isActive }
        if activity == nil {
            guard !active.isEmpty else { return }
            baselineCompleted = Set(items.filter { $0.status == .completed }.map(\.id))
            start(state(items, active: active))
            return
        }
        if active.isEmpty {
            end(final: state(items, active: active))
            return
        }
        let next = state(items, active: active)
        // 实时活动更新有频率预算：至少间隔 2 秒，内容没变化不发
        guard next != lastState, Date().timeIntervalSince(lastUpdate) >= 2 else { return }
        lastUpdate = Date()
        lastState = next
        let content = ActivityContent(state: next, staleDate: Date().addingTimeInterval(120))
        Task { await activity?.update(content) }
    }

    private func state(_ items: [DownloadItem], active: [DownloadItem]) -> DownloadActivityAttributes.ContentState {
        let total = active.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        let received = active.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let unknown = active.contains { $0.totalBytes <= 0 }
        let finished = items.filter { $0.status == .completed && !baselineCompleted.contains($0.id) }.count
        let main = active.first { $0.status == .running } ?? active.first
        return .init(active: active.count, finished: finished,
                     fraction: unknown || total <= 0 ? -1 : min(1, Double(received) / Double(total)),
                     speed: active.reduce(Int64(0)) { $0 + Int64($1.speed) }, title: main?.displayName ?? "")
    }

    private func start(_ state: DownloadActivityAttributes.ContentState) {
        do {
            activity = try Activity.request(attributes: DownloadActivityAttributes(),
                                            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(120)))
            lastState = state
            lastUpdate = Date()
        } catch {
            // 只能在前台创建；失败（如在后台）就等下次有变化再试
            activity = nil
        }
    }

    private func end(final: DownloadActivityAttributes.ContentState?) {
        guard let current = activity else { return }
        activity = nil
        lastState = nil
        let content = final.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await current.end(content, dismissalPolicy: .after(Date().addingTimeInterval(8))) }
    }
}
