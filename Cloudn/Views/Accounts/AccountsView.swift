// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var app
    @State private var loginKind: AccountKind?
    @State private var manualKind: AccountKind?
    @State private var passwordKind: AccountKind?
    @State private var drivePlatform: SharePlatform?
    @State private var listKind: AccountKind?
    @State private var logoutKind: AccountKind?
    @State private var exporting = false
    @State private var importing = false
    @State private var importData: ImportData?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AccountKind.allCases.filter(\.isDrive)) { row($0) }
                } header: {
                    Text("网盘")
                } footer: {
                    Text("蓝奏云、蓝奏云优享版、光鸭云盘的公开分享无需登录。其余网盘未登录也能浏览分享内容，夸克 / UC / 115 还可直接下载部分文件。")
                }
                Section {
                    ForEach(AccountKind.allCases.filter { !$0.isDrive }) { row($0) }
                } header: {
                    Text("视频平台")
                } footer: {
                    Text("抖音、快手、微博、AcFun 无需登录即可解析；小红书需要登录；Pixiv 未登录只能解析公开作品。")
                }
                Section {
                    Button { exporting = true } label: { Label("导出登录凭据（加密备份）", systemImage: "square.and.arrow.up") }
                        .disabled(app.accounts.accounts.isEmpty)
                    Button { importing = true } label: { Label("从备份导入", systemImage: "square.and.arrow.down") }
                } header: {
                    Text("备份与恢复")
                }
                Section {
                    Label("登录凭据仅保存在本机钥匙串，只用于向对应平台发起请求。", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("账号")
            .sheet(isPresented: $exporting) { AuthExportView() }
            .sheet(item: $importData) { AuthImportView(data: $0.data) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
                guard case .success(let url) = result else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    importData = ImportData(data: data)
                } else {
                    app.show("无法读取所选文件", error: true)
                }
            }
            .sheet(item: $loginKind) { kind in
                WebLoginView(kind: kind)
            }
            .sheet(item: $manualKind) { kind in
                ManualCookieView(kind: kind)
            }
            .sheet(item: $passwordKind) { kind in
                PasswordLoginView(kind: kind)
            }
            .navigationDestination(item: $drivePlatform) { MyDriveView(platform: $0) }
            .sheet(item: $listKind) { kind in
                AccountListView(kind: kind) { add in
                    listKind = nil
                    // 等账号列表收起后再弹登录页（同一时刻只能展示一个 sheet）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        app.accounts.pendingAdd = add
                        startLogin(add)
                    }
                }
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
                .foregroundStyle(account == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName)
                if let account {
                    let count = app.accounts.count(for: kind)
                    Text("已登录：\(account.nickname)" + (count > 1 ? "（共 \(count) 个账号）" : "")).font(.caption).foregroundStyle(.green)
                } else {
                    Text(kind.benefit).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account == nil {
                Menu {
                    loginOptions(kind)
                } label: {
                    Text("登录")
                } primaryAction: {
                    app.accounts.pendingAdd = nil
                    startLogin(kind)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            } else {
                Menu {
                    if let platform = kind.drivePlatform, app.resolvers.manager(for: platform) != nil {
                        Button { drivePlatform = platform } label: { Label("我的网盘", systemImage: "externaldrive") }
                    }
                    Button { listKind = kind } label: { Label("账号管理 / 添加账号", systemImage: "person.2") }
                    Menu { loginOptions(kind) } label: { Label("重新登录", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { logoutKind = kind } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func loginOptions(_ kind: AccountKind) -> some View {
        if let provider = kind.passwordLogin {
            Button { app.accounts.pendingAdd = nil; passwordKind = kind } label: {
                Label(provider.supportsSMS ? "账号密码 / 短信登录" : "账号密码登录", systemImage: "person.badge.key")
            }
        }
        if kind.supportsWebLogin {
            Button { app.accounts.pendingAdd = nil; loginKind = kind } label: { Label("网页登录", systemImage: "globe") }
        }
        Button { app.accounts.pendingAdd = nil; manualKind = kind } label: { Label("手动粘贴凭据", systemImage: "doc.on.clipboard") }
    }

    /// 首选方式：网页登录 → 应用内账号密码 → 手动粘贴
    private func startLogin(_ kind: AccountKind) {
        if kind.supportsWebLogin { loginKind = kind } else if kind.passwordLogin != nil { passwordKind = kind } else { manualKind = kind }
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

struct ImportData: Identifiable {
    let id = UUID()
    let data: Data
}

extension AccountKind {
    /// 对应的网盘平台（视频账号为 nil）
    var drivePlatform: SharePlatform? { SharePlatform.allCases.first { $0.accountKind == self } }
}
