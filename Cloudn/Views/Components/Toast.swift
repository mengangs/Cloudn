// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

extension View {
    /// 全局轻提示：底部胶囊，按文字长短停留 2.5～8 秒（错误至少 4 秒）后自动消失。
    /// 所在窗口不接收触摸（见 ToastWindowPresenter），所以不提供点按关闭
    func toastOverlay(_ toast: Binding<Toast?>) -> some View {
        overlay(alignment: .bottom) {
            if let t = toast.wrappedValue {
                HStack(spacing: 10) {
                    IconView(t.isError ? .warning : .check, size: 18)
                        .foregroundStyle(Color.claySoft)
                    Text(t.message)
                        .font(.subheadline)
                        .foregroundStyle(Color.paper)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(Color.ink, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .floatingShadow()
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
                .sensoryFeedback(t.isError ? .error : .success, trigger: t.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
                .task(id: t.id) {
                    try? await Task.sleep(for: .seconds(Toast.duration(for: t)))
                    withAnimation { if toast.wrappedValue?.id == t.id { toast.wrappedValue = nil } }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: toast.wrappedValue)
    }
}

extension Toast {
    /// 停留时长：2.5 秒起，每个字加 0.06 秒，最多 8 秒；错误信息至少 4 秒，来得及读完
    static func duration(for toast: Toast) -> Double {
        let base = min(8, 2.5 + 0.06 * Double(toast.message.count))
        return toast.isError ? max(4, base) : base
    }
}
