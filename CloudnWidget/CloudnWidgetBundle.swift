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
    static let paper = dynamic(0xF7F5EF, 0x1C1A18)
    static let ink = dynamic(0x1F1E1B, 0xEDEAE3)
    static let ink2 = dynamic(0x66625A, 0xA8A397)
    static let track = dynamic(0xE3DED3, 0x3A3833)
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
            LockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Palette.paper)
                .activitySystemActionForegroundColor(Palette.ink)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Ring(fraction: state.fraction, done: state.active == 0, tint: Palette.clayOnBlack, size: 26)
                        Text(state.active > 0 ? "\(state.active) 个" : "完成").font(.subheadline.weight(.semibold))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(Self.speed(state.speed)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.title).font(.footnote).lineLimit(1).foregroundStyle(.secondary)
                        if state.fraction >= 0 { Bar(fraction: state.fraction, tint: Palette.clayOnBlack, track: .white.opacity(0.15)) }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Ring(fraction: state.fraction, done: state.active == 0, tint: Palette.clayOnBlack, size: 18)
            } compactTrailing: {
                Text(state.fraction >= 0 ? "\(Int(state.fraction * 100))%" : "\(state.active)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.clayOnBlack)
            } minimal: {
                Ring(fraction: state.fraction, done: state.active == 0, tint: Palette.clayOnBlack, size: 18)
            }
            .keylineTint(Palette.clayOnBlack)
        }
    }

    static func speed(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/s" : ""
    }
}

/// 圆环进度；完成后变成对勾
private struct Ring: View {
    let fraction: Double
    let done: Bool
    let tint: Color
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: size * 0.13)
            if done {
                Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(tint)
            } else {
                Circle()
                    .trim(from: 0, to: fraction >= 0 ? max(0.04, min(1, fraction)) : 0.25)
                    .stroke(tint, style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
                    .rotationEffect(.degrees(-90))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Ring(fraction: state.fraction, done: state.active == 0, tint: state.active == 0 ? Palette.success : Palette.clay, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.active > 0 ? "正在下载 \(state.active) 个文件" : "下载完成")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    if !state.title.isEmpty {
                        Text(state.title).font(.footnote).lineLimit(1).foregroundStyle(Palette.ink2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if state.fraction >= 0 && state.active > 0 {
                        Text("\(Int(state.fraction * 100))%").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                    }
                    Text(DownloadLiveActivity.speed(state.speed)).font(.caption).monospacedDigit().foregroundStyle(Palette.ink2)
                }
            }
            if state.fraction >= 0 && state.active > 0 {
                Bar(fraction: state.fraction, tint: Palette.clay, track: Palette.track)
            }
            if state.finished > 0 {
                Text("已完成 \(state.finished) 个").font(.caption2).foregroundStyle(Palette.ink2)
            }
        }
    }
}
