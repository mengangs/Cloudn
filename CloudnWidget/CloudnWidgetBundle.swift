// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

@main
struct CloudnWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

/// 与主应用「纸与陶土」一致的几种颜色（小组件拿不到主应用的设计令牌，这里各写一份）
private enum Palette {
    static let clay = dynamic(0xB4532F, 0xE08A66)
    static let success = dynamic(0x3F7D52, 0x7FB38E)
    /// 灵动岛始终是黑底，用深色那一套
    static let clayOnBlack = Color(hex: 0xE08A66)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

private extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

/// 下载进度：锁屏横幅 + 灵动岛
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            // 不自定义底色：锁屏会把浅色底渲染成发黄的玻璃、浅灰字看不清。用系统底色 + 语义文字颜色
            LockScreenView(state: context.state, stale: context.isStale)
                .padding(16)
                // 点按打开下载页
                .widgetURL(DownloadLiveActivity.downloadsURL)
        } dynamicIsland: { context in
            let state = context.state
            // 过了过期时间还没收到新进度（应用在后台拿不到运行时间）：进度变淡，提示未更新
            let stale = context.isStale && state.active > 0
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Ring(fraction: state.fraction, done: state.active == 0, paused: state.isPaused, failed: state.isFailed,
                             tint: state.islandTint, size: 26)
                            .opacity(stale ? 0.5 : 1)
                        Text(state.active > 0 ? "\(state.active) 个" : (state.isFailed ? "失败" : (state.isPaused ? "已暂停" : "完成")))
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 剩余时间最有用：知道就放上面，速度在下面
                    VStack(alignment: .trailing, spacing: 2) {
                        if let eta = state.etaText, !stale {
                            Text(eta).font(.subheadline.weight(.medium)).monospacedDigit()
                        }
                        Text(Self.speed(state.speed)).font(state.etaText == nil || stale ? .subheadline : .caption)
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.title).font(.footnote).lineLimit(1).foregroundStyle(.secondary)
                        if stale {
                            Text("进度未更新，打开应用查看").font(.caption2).foregroundStyle(.secondary)
                        } else if !state.note.isEmpty {
                            Text(state.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        if state.fraction >= 0 && state.active > 0 {
                            Bar(fraction: state.fraction, tint: state.islandTint, track: .white.opacity(0.15)).opacity(stale ? 0.5 : 1)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                // 紧贴胶囊圆角的左边缘会被裁到一点：往里收一些、圆环略小
                Ring(fraction: state.fraction, done: state.active == 0, paused: state.isPaused, failed: state.isFailed,
                     tint: state.islandTint, size: 16)
                    .opacity(stale ? 0.5 : 1)
                    .padding(.leading, 4)
            } compactTrailing: {
                Text(state.compactText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(state.islandTint)
                    .opacity(stale ? 0.5 : 1)
                    .padding(.trailing, 2)
            } minimal: {
                Ring(fraction: state.fraction, done: state.active == 0, paused: state.isPaused, failed: state.isFailed,
                     tint: state.islandTint, size: 16)
                    .opacity(stale ? 0.5 : 1)
            }
            .keylineTint(state.islandTint)
            .widgetURL(Self.downloadsURL)
        }
    }

    static let downloadsURL = URL(string: "cloudn://downloads")

    static func speed(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/s" : ""
    }
}

extension DownloadActivityAttributes.ContentState {
    /// 没有进行中的任务，剩下的是失败的（没有暂停的）
    var isFailed: Bool { active == 0 && (failed ?? 0) > 0 }

    /// 没有进行中的任务、但不是全部完成（被暂停；旧版本的状态里失败也算在这里）
    var isPaused: Bool { active == 0 && !note.isEmpty && !isFailed }

    /// 剩余时间（与应用下载页的说法一致）：有速度、知道剩余大小时才有
    var etaText: String? {
        guard active > 0, speed > 0, let remaining, remaining > 0 else { return nil }
        let seconds = Double(remaining) / Double(speed)
        if seconds < 10 { return "马上就好" }
        if seconds < 60 { return "不到 1 分钟" }
        if seconds < 3600 { return "还剩约 \(Int((seconds / 60).rounded())) 分钟" }
        if seconds > 86400 * 2 { return "还要很久" }
        let h = Int(seconds / 3600)
        let m = Int((seconds - Double(h) * 3600) / 60)
        return m > 0 ? "还剩约 \(h) 小时 \(m) 分" : "还剩约 \(h) 小时"
    }

    /// 主题色的浅色 / 深色两份；没设过（默认陶土色）为 nil
    private var accentColors: (light: UIColor, dark: UIColor)? {
        let parts = (accent ?? "").split(separator: ",").compactMap { UInt32($0, radix: 16) }
        guard parts.count == 2 else { return nil }
        return (UIColor(hex: parts[0]), UIColor(hex: parts[1]))
    }

    /// 锁屏上的强调色：跟随应用的主题色
    var lockTint: Color {
        guard let colors = accentColors else { return Palette.clay }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? colors.dark : colors.light })
    }

    /// 灵动岛始终是黑底：用主题色的深色版
    var islandTint: Color {
        accentColors.map { Color(uiColor: $0.dark) } ?? Palette.clayOnBlack
    }

    /// 灵动岛右侧：知道进度显示百分比，否则显示速度，再不然显示任务数
    var compactText: String {
        if active == 0 { return isFailed ? "失败" : (isPaused ? "暂停" : "完成") }
        if fraction >= 0 { return "\(Int(fraction * 100))%" }
        if speed > 0 { return ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) }
        return "\(active) 个"
    }
}

/// 圆环进度；完成后变成对勾、暂停显示暂停符号、失败显示叹号；进度未知时只画底环（不画假的进度）
private struct Ring: View {
    let fraction: Double
    let done: Bool
    var paused = false
    var failed = false
    let tint: Color
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: size * 0.13)
            if failed {
                Image(systemName: "exclamationmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(tint)
            } else if paused {
                Image(systemName: "pause.fill").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(tint)
            } else if done {
                Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(tint)
            } else {
                if fraction >= 0 {
                    Circle()
                        .trim(from: 0, to: max(0.04, min(1, fraction)))
                        .stroke(tint, style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Image(systemName: "arrow.down").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 细进度条
private struct Bar: View {
    let fraction: Double
    let tint: Color
    let track: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

private struct LockScreenView: View {
    let state: DownloadActivityAttributes.ContentState
    /// 过了过期时间还没收到新进度（应用在后台）
    var stale = false

    private var dimmed: Bool { stale && state.active > 0 }

    private var headline: String {
        if state.active > 0 { return "正在下载 \(state.active) 个文件" }
        if state.isFailed { return "下载失败" }
        return state.isPaused ? "下载已暂停" : "下载完成"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Ring(fraction: state.fraction, done: state.active == 0, paused: state.isPaused, failed: state.isFailed,
                     tint: state.active == 0 && !state.isPaused && !state.isFailed ? Palette.success : state.lockTint, size: 34)
                    .opacity(dimmed ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if !state.title.isEmpty {
                        Text(state.title).font(.footnote).lineLimit(1).foregroundStyle(.secondary)
                    }
                    if dimmed {
                        Text("进度未更新，打开应用查看").font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    } else if !state.note.isEmpty {
                        Text(state.note).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if state.fraction >= 0 && state.active > 0 {
                        Text("\(Int(state.fraction * 100))%").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                    }
                    if let eta = state.etaText, !dimmed {
                        Text(eta).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(DownloadLiveActivity.speed(state.speed)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if state.fraction >= 0 && state.active > 0 {
                Bar(fraction: state.fraction, tint: state.lockTint, track: Color.secondary.opacity(0.25))
                    .opacity(dimmed ? 0.5 : 1)
            }
            if state.finished > 0 {
                Text("已完成 \(state.finished) 个").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
