// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// 可按住拖动排序的等高网格（列数为 1 时就是列表）。
/// 每格按下标算出绝对位置：拖着的那格跟手走，其余格子在顺序变化时用弹簧动画让位。
struct ReorderableGrid<Item: Hashable, Cell: View>: View {
    @Binding var items: [Item]
    var columns = 2
    var rowHeight: CGFloat
    var spacing: CGFloat = 10
    /// 正在拖动（外层据此暂停滚动）
    @Binding var dragging: Bool
    @ViewBuilder var cell: (Item) -> Cell

    @State private var lifted: Item?
    /// 拖起时那一格的中心点，拖动位置 = 起点 + 手指位移
    @State private var origin: CGPoint = .zero
    @State private var translation: CGSize = .zero
    @GestureState private var pressing = false

    private static var spring: Animation { .spring(response: 0.32, dampingFraction: 0.82) }

    var body: some View {
        let rows = max(1, (items.count + columns - 1) / columns)
        GeometryReader { proxy in
            let width = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.self) { item in
                    let isLifted = lifted == item
                    cell(item)
                        .frame(width: width, height: rowHeight)
                        .scaleEffect(isLifted ? 1.04 : 1)
                        .shadow(color: .black.opacity(isLifted ? 0.16 : 0), radius: isLifted ? 14 : 0, y: isLifted ? 6 : 0)
                        .position(isLifted ? CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
                                           : center(of: item, width: width))
                        .zIndex(isLifted ? 1 : 0)
                        .gesture(dragGesture(item, width: width, rows: rows))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(name: "reorder")
        }
        .frame(height: CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing)
        // 手势被打断（例如来电、系统手势）也要把拖着的格子放回去
        .onChange(of: pressing) { _, active in
            if !active { drop() }
        }
    }

    private func center(of item: Item, width: CGFloat) -> CGPoint {
        let index = items.firstIndex(of: item) ?? 0
        return center(at: index, width: width)
    }

    private func center(at index: Int, width: CGFloat) -> CGPoint {
        let col = index % columns, row = index / columns
        return CGPoint(x: CGFloat(col) * (width + spacing) + width / 2,
                       y: CGFloat(row) * (rowHeight + spacing) + rowHeight / 2)
    }

    private func dragGesture(_ item: Item, width: CGFloat, rows: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("reorder")))
            .updating($pressing) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if lifted == nil {
                    origin = center(of: item, width: width)
                    translation = .zero
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        lifted = item
                        dragging = true
                    }
                }
                guard lifted == item, let drag else { return }
                translation = drag.translation
                moveIfNeeded(item, width: width, rows: rows)
            }
    }

    /// 手指所在的格子不是自己时，把自己挪过去，其余格子随动画让位
    private func moveIfNeeded(_ item: Item, width: CGFloat, rows: Int) {
        guard let from = items.firstIndex(of: item) else { return }
        let x = origin.x + translation.width, y = origin.y + translation.height
        let col = min(columns - 1, max(0, Int(x / (width + spacing))))
        let row = min(rows - 1, max(0, Int(y / (rowHeight + spacing))))
        let to = min(items.count - 1, row * columns + col)
        guard to != from else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(Self.spring) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    private func drop() {
        guard lifted != nil else { return }
        withAnimation(Self.spring) {
            lifted = nil
            translation = .zero
            dragging = false
        }
    }
}
