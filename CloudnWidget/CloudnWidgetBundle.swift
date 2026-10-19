// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CloudnWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

/// 下载进度：锁屏横幅 + 灵动岛
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding()
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.active)", systemImage: "arrow.down.circle.fill").font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(Self.speed(context.state.speed)).font(.caption).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title).font(.caption).lineLimit(1)
                        if context.state.fraction >= 0 { ProgressView(value: context.state.fraction) }
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
            } compactTrailing: {
                Text(context.state.fraction >= 0 ? "\(Int(context.state.fraction * 100))%" : "\(context.state.active)")
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "arrow.down.circle.fill")
            }
        }
    }

    static func speed(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/s" : ""
    }
}

private struct LockScreenView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.active > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.active > 0 ? Color.accentColor : .green)
                Text(state.active > 0 ? "正在下载 \(state.active) 个文件" : "下载完成")
                    .font(.headline)
                Spacer()
                Text(DownloadLiveActivity.speed(state.speed)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if !state.title.isEmpty {
                Text(state.title).font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
            }
            if state.fraction >= 0 {
                ProgressView(value: state.fraction)
            }
            if state.finished > 0 {
                Text("已完成 \(state.finished) 个").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
