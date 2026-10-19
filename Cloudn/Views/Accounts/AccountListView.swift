// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 同一平台的多个账号：设为主账号、退出单个账号、添加账号
struct AccountListView: View {
    let kind: AccountKind
    let onAdd: (AccountKind) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var removing: Int?

    var body: some View {
        let list = app.accounts.list(kind)
        NavigationStack {
            List {
                Section {
                    ForEach(Array(list.enumerated()), id: \.offset) { index, account in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.nickname)
                                Text("更新于 \(account.updatedAt.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if index == 0 {
                                Text("主账号").font(.caption.weight(.medium)).foregroundStyle(.tint)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { removing = index } label: { Label("退出", systemImage: "rectangle.portrait.and.arrow.right") }
                            if index > 0 {
                                Button { Task { await app.accounts.makePrimary(index, for: kind) } } label: { Label("设为主账号", glyph: .star) }
                                    .tint(.orange)
                            }
                        }
                        .contextMenu {
                            if index > 0 {
                                Button { Task { await app.accounts.makePrimary(index, for: kind) } } label: { Label("设为主账号", glyph: .star) }
                            }
                            Button(role: .destructive) { removing = index } label: { Label("退出该账号", systemImage: "rectangle.portrait.and.arrow.right") }
                        }
                    }
                } footer: {
                    Text("解析、转存与网盘管理使用主账号。在设置中开启「多账号下载」后，批量下载会按文件轮换使用这里的全部账号。")
                }
                Section {
                    Button { onAdd(kind) } label: { Label("添加账号", glyph: .user) }
                }
            }
            .paperList()
            .navigationTitle("\(kind.displayName)账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("退出该账号？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { index in
                Button("退出", role: .destructive) { Task { await app.accounts.remove(index, for: kind) } }
            } message: { _ in
                Text("将删除本机保存的该账号登录凭据")
            }
        }
    }
}
