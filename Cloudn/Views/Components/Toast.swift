// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

extension View {
    /// 全局轻提示：底部胶囊，2.5 秒后自动消失
    func toastOverlay(_ toast: Binding<Toast?>) -> some View {
        overlay(alignment: .bottom) {
            if let t = toast.wrappedValue {
                HStack(spacing: 10) {
                    IconView(t.isError ? .warning : .check, size: 18)
                        .foregroundStyle(t.isError ? Color(red: 0.94, green: 0.55, blue: 0.45) : Color(red: 0.88, green: 0.54, blue: 0.40))
                    Text(t.message)
                        .font(.subheadline)
                        .foregroundStyle(Color.paper)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(Color.ink, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
                .sensoryFeedback(t.isError ? .error : .success, trigger: t.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
                .task(id: t.id) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    withAnimation { if toast.wrappedValue?.id == t.id { toast.wrappedValue = nil } }
                }
                .onTapGesture { withAnimation { toast.wrappedValue = nil } }
            }
        }
        .animation(.spring(duration: 0.35), value: toast.wrappedValue)
    }
}
