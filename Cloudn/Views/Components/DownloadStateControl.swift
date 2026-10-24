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
    /// 正在为直链失效的任务重新取链
    @State private var refreshing = false

    var body: some View {
        Group {
            if busy || refreshing {
                ProgressRing(value: nil, size: size - 6, glyph: false)
            } else if let item {
                switch item.status {
                case .completed:
                    IconView(.checkCircle, size: size * 0.7)
                        .foregroundStyle(Color.success)
                        .accessibilityLabel("已下载")
                case .failed:
                    Button { retry(item) } label: { IconView(.refresh, size: size * 0.55) }
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
        // 看着它下完：完成那一刻轻轻一下
        .sensoryFeedback(.success, trigger: item?.status) { old, new in old != nil && old != .completed && new == .completed }
    }

    /// 直链失效的先重新取链再继续；其他失败（网络等）照旧用原地址重试
    private func retry(_ item: DownloadItem) {
        guard item.needsFreshLink else {
            app.downloads.resume(item)
            return
        }
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                try await app.downloads.refreshLink(item)
                app.show("已重新获取直链")
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }
}

extension DownloadItem {
    /// 直链失效（HTTP 403 / 404 / 410 / 412，与 AppModel.didFail 自动换链的判断一致）且能重新取链的失败任务：
    /// 重试要换一条直链，用旧地址再试还会失败
    var needsFreshLink: Bool {
        guard status == .failed, request.canRefresh, let message = errorMessage else { return false }
        return ["HTTP 403", "HTTP 404", "HTTP 410", "HTTP 412"].contains { message.hasPrefix($0) }
    }
}

/// 多选圆点
struct SelectMark: View {
    let on: Bool
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            // 未选中的圆圈用三级墨色（对卡片约 5:1），细线色在卡片上几乎看不见
            Circle().strokeBorder(on ? Color.clear : Color.ink3, lineWidth: 1.5)
            if on {
                Circle().fill(.tint)
                Image(icon: .check).resizable().scaledToFit().frame(width: size * 0.5, height: size * 0.5)
                    .modifier(OnAccentForeground(fallback: nil))
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
        .accessibilityHidden(true)
    }
}
