// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import ActivityKit
import CloudnKit
import Foundation
import UIKit

/// 下载进度实时活动：有任务开始时创建，进度变化节流更新，全部结束后显示「下载完成」并稍后消失
@MainActor
final class DownloadActivity {
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: DownloadActivityAttributes.ContentState?
    /// 本轮开始时已完成的任务，用来统计「本轮已完成」
    private var baselineCompleted = Set<UUID>()

    /// 上次创建失败的时间（在后台时创建必然失败，不要每次进度刷新都重试）
    private var lastStartFailure = Date.distantPast
    /// 这一轮的实时活动被用户划掉（或被系统结束）：不再重建，等任务全部结束后的下一轮再显示
    private var suppressed = false

    /// 设置页开关（默认开启）
    private var enabled: Bool { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }

    init() {
        // 上一个进程留下的实时活动（进程被杀时没来得及结束）：接管第一个，多余的结束掉
        // 已结束、已划掉的不能再更新，接管了也只会让这一轮不显示
        let existing = Activity<DownloadActivityAttributes>.activities
        let alive = existing.first { $0.activityState == .active || $0.activityState == .stale }
        activity = alive
        for extra in existing where extra.id != alive?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(with items: [DownloadItem]) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            end(final: nil)
            return
        }
        let active = items.filter { $0.status.isActive }
        if let current = activity, current.activityState == .dismissed || current.activityState == .ended {
            activity = nil
            lastState = nil
            suppressed = !active.isEmpty
        }
        if activity == nil {
            if active.isEmpty { suppressed = false }
            guard !active.isEmpty, !suppressed, Date().timeIntervalSince(lastStartFailure) > 30 else { return }
            baselineCompleted = Set(items.filter { $0.status == .completed }.map(\.id))
            start(state(items, active: active))
            return
        }
        if active.isEmpty {
            end(final: state(items, active: active))
            return
        }
        let next = state(items, active: active)
        // 实时活动更新有频率预算：任务数变了立即更新，其余（进度、速度）至少间隔 5 秒
        let countsChanged = next.active != lastState?.active || next.finished != lastState?.finished
        guard next != lastState, countsChanged || Date().timeIntervalSince(lastUpdate) >= 5 else { return }
        lastUpdate = Date()
        lastState = next
        let content = ActivityContent(state: next, staleDate: Date().addingTimeInterval(120))
        Task { await activity?.update(content) }
    }

    private func state(_ items: [DownloadItem], active: [DownloadItem]) -> DownloadActivityAttributes.ContentState {
        // 按 Double 累加：服务端报的大小不可信，几个离谱的大数相加会让 Int64 溢出崩溃
        let total = active.reduce(0.0) { $0 + Double(max(0, $1.totalBytes)) }
        let received = active.reduce(0.0) { $0 + Double(max(0, $1.receivedBytes)) }
        let unknown = active.contains { $0.totalBytes <= 0 }
        let finished = items.filter { $0.status == .completed && !baselineCompleted.contains($0.id) }.count
        let main = active.first { $0.status == .running } ?? active.first
        var note = ""
        var failedCount: Int? = nil
        if let main, case .torrent = main.request.kind, main.totalBytes <= 0 {
            note = "正在获取种子信息"
        } else if active.isEmpty {
            // 没有进行中的任务时分清：真的全部完成，还是被暂停 / 失败
            let paused = items.filter { $0.status == .paused }.count
            let failed = items.filter { $0.status == .failed }.count
            if paused > 0 {
                note = "\(paused) 个已暂停，回到应用继续"
            } else if failed > 0 {
                note = "\(failed) 个下载失败"
                failedCount = failed
            }
        }
        return .init(active: active.count, finished: finished,
                     fraction: unknown || total <= 0 ? -1 : min(1, received / total),
                     speed: Int64(saturating: active.reduce(0.0) { $0 + max(0, $1.speed) }), title: main?.displayName ?? "", note: note,
                     failed: failedCount,
                     remaining: unknown || total <= 0 ? nil : Int64(saturating: max(0, total - received)),
                     accent: Self.accentPair())
    }

    /// 当前主题色的浅色 / 深色两份（与应用里实际生效的一致）；用默认陶土色时为 nil
    private static func accentPair() -> String? {
        guard let color = AppSettings.accentUIColor(hex: UserDefaults.standard.string(forKey: "accentHex") ?? "") else { return nil }
        func hex(_ style: UIUserInterfaceStyle) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
            func byte(_ c: CGFloat) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
            return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
        }
        return hex(.light) + "," + hex(.dark)
    }

    /// 切到后台：之后应用多半拿不到运行时间、进度不会再刷新，先把说明写上，免得锁屏上停着一个过时的进度。
    /// 速度清零（不再刷新的速度只会误导），并设一个过期时间：过期后锁屏 / 灵动岛把进度显示为「未更新」
    func enterBackground(_ items: [DownloadItem]) {
        guard let activity else { return }
        let active = items.filter { $0.status.isActive }
        guard !active.isEmpty else { return }
        var next = state(items, active: active)
        let foregroundOnly = active.contains { !$0.backgrounded && !($0.request.kind == .file) }
        next.note = foregroundOnly ? "部分任务回到应用后继续" : "后台下载中，打开应用查看进度"
        next.speed = 0
        lastState = next
        lastUpdate = Date()
        Task { await activity.update(ActivityContent(state: next, staleDate: Date().addingTimeInterval(60))) }
    }

    private func start(_ state: DownloadActivityAttributes.ContentState) {
        do {
            activity = try Activity.request(attributes: DownloadActivityAttributes(),
                                            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(120)))
            lastState = state
            lastUpdate = Date()
        } catch {
            // 只能在前台创建；失败（如在后台）就隔一会儿再试
            activity = nil
            lastStartFailure = Date()
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
