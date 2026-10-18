// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

struct BookmarksView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onOpen: (Bookmark) -> Void
    @State private var renaming: Bookmark?
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                if app.bookmarks.bookmarks.isEmpty {
                    ContentUnavailableView("还没有收藏", systemImage: "star",
                                           description: Text("在分享页右上角点星标即可收藏，下次一键打开"))
                }
                ForEach(app.bookmarks.bookmarks) { b in
                    Button { onOpen(b) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(b.title).foregroundStyle(.primary)
                            Text("\(b.source) · \(b.createdAt.formatted(date: .numeric, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { app.bookmarks.remove([b.id]) } label: { Label("删除", systemImage: "trash") }
                        Button { newTitle = b.title; renaming = b } label: { Label("重命名", systemImage: "pencil") }
                            .tint(.orange)
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = b.text; app.show("已复制") } label: { Label("复制链接", systemImage: "doc.on.doc") }
                        Button { newTitle = b.title; renaming = b } label: { Label("重命名", systemImage: "pencil") }
                        Button(role: .destructive) { app.bookmarks.remove([b.id]) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("收藏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("名称", text: $newTitle)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if let r = renaming, !newTitle.isEmpty { app.bookmarks.rename(r.id, title: newTitle) }
                }
            }
        }
    }
}
