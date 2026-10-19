// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var app
    @State private var loginKind: AccountKind?
    @State private var manualKind: AccountKind?
    @State private var logoutKind: AccountKind?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AccountKind.allCases.filter(\.isDrive)) { row($0) }
                } header: {
                    Text("网盘")
                } footer: {
                    Text("蓝奏云、蓝奏云优享版、光鸭云盘无需登录。其余网盘未登录也能浏览分享内容，夸克 / UC / 115 还可直接下载部分文件。")
                }
                Section {
                    row(.bilibili)
                } header: {
                    Text("视频平台")
                } footer: {
                    Text("抖音、快手、微博、AcFun 无需登录即可解析。")
                }
                Section {
                    Label("登录凭据仅保存在本机钥匙串，只用于向对应平台发起请求。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("账号")
            .sheet(item: $loginKind) { kind in
                WebLoginView(kind: kind)
            }
            .sheet(item: $manualKind) { kind in
                ManualCookieView(kind: kind)
            }
            .confirmationDialog("退出登录？", isPresented: Binding(get: { logoutKind != nil }, set: { if !$0 { logoutKind = nil } }),
                                titleVisibility: .visible, presenting: logoutKind) { kind in
                Button("退出 \(kind.displayName)", role: .destructive) {
                    Task { await app.accounts.logout(kind) }
                }
            } message: { _ in
                Text("将删除本机保存的登录凭证")
            }
        }
    }

    @ViewBuilder
    private func row(_ kind: AccountKind) -> some View {
        let account = app.accounts.accounts[kind]
        HStack(spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .foregroundStyle(account == nil ? Color.secondary : Color.accentColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName)
                if let account {
                    Text("已登录：\(account.nickname)").font(.caption).foregroundStyle(.green)
                } else {
                    Text(kind.benefit).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account == nil {
                Menu {
                    Button { loginKind = kind } label: { Label("网页登录", systemImage: "globe") }
                    Button { manualKind = kind } label: { Label("手动粘贴凭据", systemImage: "doc.on.clipboard") }
                } label: {
                    Text("登录")
                } primaryAction: {
                    loginKind = kind
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            } else {
                Menu {
                    Button { loginKind = kind } label: { Label("重新登录", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { logoutKind = kind } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 手动粘贴 Cookie（网页登录走不通时的兜底）
struct ManualCookieView: View {
    let kind: AccountKind
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(kind.manualPlaceholder, text: $cookie, axis: .vertical)
                        .lineLimit(4...10)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(kind.manualHint)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("\(kind.displayName) 凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("保存") {
                            saving = true
                            Task {
                                defer { saving = false }
                                if let name = await app.accounts.login(kind, cookie: cookie) {
                                    app.show("已登录：\(name)")
                                    dismiss()
                                } else {
                                    error = "凭据无效或已过期，请重新复制"
                                }
                            }
                        }
                        .disabled(cookie.isEmpty)
                    }
                }
            }
        }
    }
}
