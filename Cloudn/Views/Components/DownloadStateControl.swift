// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 行尾的下载键：没下载时是下载键，取链中转圈，下载中变成进度环（点按暂停 / 继续），完成打勾，失败给重试
struct DownloadStateControl: View {
    @Environment(AppModel.self) private var app
    let item: DownloadItem?
    var busy = false
    var size: CGFloat = 32
    let start: () -> Void

    var body: some View {
        Group {
            if busy {
                ProgressRing(value: nil, size: size - 6, glyph: false)
            } else if let item {
                switch item.status {
                case .completed:
                    IconView(.checkCircle, size: size * 0.7)
                        .foregroundStyle(Color.success)
                        .accessibilityLabel("已下载")
                case .failed:
                    Button { app.downloads.resume(item) } label: { IconView(.refresh, size: size * 0.55) }
                        .buttonStyle(CircleIconButtonStyle(size: size, foreground: Color.clayInk))
                        .accessibilityLabel("下载失败，重试")
                default:
                    Button {
                        if item.status == .paused { app.downloads.resume(item) } else { app.downloads.pause(item) }
                    } label: {
                        ProgressRing(value: item.fraction, size: size - 4, paused: item.status == .paused)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.status == .paused ? "继续下载" : "暂停下载")
                }
            } else {
                Button(action: start) { IconView(.download, size: size * 0.53) }
                    .buttonStyle(CircleIconButtonStyle(size: size))
                    .accessibilityLabel("下载")
            }
        }
        .frame(width: max(size, 44), height: max(size, 44))
        .animation(.snappy(duration: 0.25), value: item?.status)
        .animation(.snappy(duration: 0.25), value: busy)
    }
}

/// 多选圆点
struct SelectMark: View {
    let on: Bool
    var size: CGFloat = 22
    @Environment(\.onAccent) private var onAccent

    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? Color.clear : Color.hairline, lineWidth: 1.5)
            if on {
                Circle().fill(.tint)
                Image(icon: .check).resizable().scaledToFit().frame(width: size * 0.5, height: size * 0.5).foregroundStyle(onAccent)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
        .accessibilityHidden(true)
    }
}
