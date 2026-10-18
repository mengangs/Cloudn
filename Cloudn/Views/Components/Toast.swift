// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

extension View {
    /// 全局轻提示：底部胶囊，2.5 秒后自动消失
    func toastOverlay(_ toast: Binding<Toast?>) -> some View {
        overlay(alignment: .bottom) {
            if let t = toast.wrappedValue {
                HStack(spacing: 8) {
                    Image(systemName: t.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(t.isError ? .red : .green)
                    Text(t.message)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
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
