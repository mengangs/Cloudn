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
                            // 每个账号自成一张圆角卡片：左滑时整张卡一起移动，右边不会露出直角的行底
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            // 不用 destructive 角色：它会触发列表删除动画，确认框刚弹出就被收回
                            .swipeActions(allowsFullSwipe: false) {
                                Button { removing = index } label: { Label("退出", systemImage: "rectangle.portrait.and.arrow.right") }
                                    .tint(Color.clayInk)
                                if index > 0 {
                                    Button { Task { await app.accounts.makePrimary(index, for: kind) } } label: { Label("设为主账号", glyph: .star) }
                                        .tint(Color.ink2)
                                }
                            }
                            .contextMenu {
                                if index > 0 {
                                    Button { Task { await app.accounts.makePrimary(index, for: kind) } } label: { Label("设为主账号", glyph: .star) }
                                }
                                Button(role: .destructive) { removing = index } label: { Label("退出该账号", systemImage: "rectangle.portrait.and.arrow.right") }
                            }
                            .rowDialog("退出该账号？", isPresented: presenting($removing) { $0 == index }, message: "将删除本机保存的该账号登录凭据") {
                                Button("退出", role: .destructive) { Task { await app.accounts.remove(index, for: kind) } }
                            }
                        }
                    } footer: {
                        Text("解析、转存与网盘管理使用主账号。在设置中开启「多账号下载」后，批量下载会按文件轮换使用这里的全部账号。")
                    }
                Section {
                    Button { onAdd(kind) } label: { Label("添加账号", glyph: .user) }
                        .listRowBackground(Color.surface)
                }
            }
            .paperList()
            .navigationTitle("\(kind.displayName)账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
