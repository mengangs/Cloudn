// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// 空状态 / 出错状态卡片：线性图标 + 衬线标题 + 说明，可带一个下一步按钮
struct EmptyStateCard: View {
    let icon: Icon
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            IconView(icon, size: 26).foregroundStyle(Color.ink3)
            Text(title).font(.cardTitle).foregroundStyle(Color.ink)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                    .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .card()
    }

    /// 放进 List / Form 时去掉行底色与内边距
    func inList() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
    }
}

/// 转圈：工具栏、行内与整页加载用。按时间算角度，不依赖 repeatForever，放在列表里也不会漂移
struct Spinner: View {
    var size: CGFloat = 20
    /// 用当前前景色（放在实心按钮里时）而不是强调色
    var usesForeground = false

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(usesForeground ? AnyShapeStyle(.foreground) : AnyShapeStyle(.tint),
                        style: StrokeStyle(lineWidth: max(1.6, size * 0.1), lineCap: .round))
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("加载中")
    }
}
