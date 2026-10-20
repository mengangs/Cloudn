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
    @State private var quotas: [SharePlatform: DriveQuota] = [:]

    /// 设置里勾选显示的网盘（默认全部）
    private var visibleDrives: [AccountKind] {
        AccountKind.allCases.filter { $0.isDrive && !app.settings.hiddenDrives.contains($0.rawValue) }
    }

    private var loggedInSummary: String {
        let n = AccountKind.allCases.filter { $0.isDrive && app.accounts.accounts[$0] != nil }.count
        return n == 0 ? "未登录" : "已登录 \(n) 个"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "网盘", trailing: loggedInSummary)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(visibleDrives) { driveTile($0) }
                        }
                        Text("蓝奏云、蓝奏优享、光鸭的公开分享无需登录；其余网盘未登录也能浏览分享，夸克 / UC / 115 还能直接下载部分文件。长按可管理账号。")
                            .font(.caption)
                            .foregroundStyle(Color.ink3)
                            .padding(.horizontal, 4)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "视频平台")
                        VStack(spacing: 0) {
                            let kinds = AccountKind.allCases.filter { !$0.isDrive }
                            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                                videoRow(kind)
                                if index < kinds.count - 1 { RowDivider(leading: 60) }
                            }
                        }
                        .card()
                        Text("抖音、快手、微博、AcFun 无需登录；小红书需要登录；Pixiv 未登录只能解析公开作品。")
                            .font(.caption)
                            .foregroundStyle(Color.ink3)
                            .padding(.horizontal, 4)
                    }
                    VStack(spacing: 0) {
                        NavigationLink { SettingsView() } label: { linkRow(.gear, "设置") }
                        RowDivider(leading: 52)
                        Button { exporting = true } label: { linkRow(.share, "导出登录凭据（加密备份）") }
                            .disabled(app.accounts.accounts.isEmpty)
                            .opacity(app.accounts.accounts.isEmpty ? 0.4 : 1)
                        RowDivider(leading: 52)
                        Button { importing = true } label: { linkRow(.save, "从备份导入") }
                    }
                    .buttonStyle(.plain)
                    .card()
                    HStack(alignment: .top, spacing: 8) {
                        IconView(.lock, size: 14)
                        Text("登录凭据只保存在本机钥匙串，只用于向对应平台发起请求。")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.ink3)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.paper)
            .task(id: app.accounts.accounts.keys.map(\.rawValue).sorted()) { await loadQuotas() }
            .navigationTitle("我的")
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
        }
    }

    /// 网盘卡片：点按进入我的网盘（未登录则去登录），长按管理账号
    private func driveTile(_ kind: AccountKind) -> some View {
        let account = app.accounts.accounts[kind]
        let platform = kind.drivePlatform
        let quota = platform.flatMap { quotas[$0] }
        return Menu {
            accountMenu(kind)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PlatformTile(mark: .account(kind), size: 34, dimmed: account == nil)
                    Spacer()
                    if account != nil {
                        Circle().fill(Color.success).frame(width: 7, height: 7)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                    if let account {
                        let count = app.accounts.count(for: kind)
                        Text(account.nickname + (count > 1 ? " 等 \(count) 个" : ""))
                            .font(.caption).foregroundStyle(Color.ink2).lineLimit(1)
                    } else {
                        Text("未登录").font(.caption).foregroundStyle(Color.ink3)
                    }
                }
                if let quota, quota.total > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressLine(value: min(1, Double(quota.used) / Double(quota.total)))
                        Text("\(ByteFormat.string(quota.used)) / \(ByteFormat.string(quota.total))")
                            .font(.monoSmall).foregroundStyle(Color.ink3).lineLimit(1).minimumScaleFactor(0.8)
                    }
                } else {
                    Text(account == nil ? "点按登录" : " ").font(.monoSmall).foregroundStyle(Color.ink3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        } primaryAction: {
            if account == nil {
                app.accounts.pendingAdd = nil
                startLogin(kind)
            } else if let platform, app.resolvers.manager(for: platform) != nil {
                drivePlatform = platform
            } else {
                listKind = kind
            }
        }
        .buttonStyle(.plain)
        .modifier(LogoutDialog(kind: kind, logoutKind: $logoutKind))
    }

    /// 视频平台：一行一个，右侧是登录状态 / 登录键
    private func videoRow(_ kind: AccountKind) -> some View {
        let account = app.accounts.accounts[kind]
        return HStack(spacing: 12) {
            PlatformTile(mark: .account(kind), size: 32, dimmed: account == nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
                Text(account.map { "已登录 · \($0.nickname)" } ?? kind.benefit)
                    .font(.caption)
                    .foregroundStyle(account == nil ? Color.ink3 : Color.success)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if account == nil {
                Menu { loginOptions(kind) } label: {
                    Text("登录")
                } primaryAction: {
                    app.accounts.pendingAdd = nil
                    startLogin(kind)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 30))
                .font(.footnote)
            } else {
                Menu { accountMenu(kind) } label: {
                    IconView(.more, size: 20).foregroundStyle(Color.ink2).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("\(kind.displayName)账号操作")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(LogoutDialog(kind: kind, logoutKind: $logoutKind))
    }

    private func linkRow(_ icon: Icon, _ title: String) -> some View {
        HStack(spacing: 12) {
            IconView(icon, size: 19).foregroundStyle(Color.ink).frame(width: 26)
            Text(title).foregroundStyle(Color.ink)
            Spacer()
            IconView(.chevronRight, size: 13).foregroundStyle(Color.ink3)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func accountMenu(_ kind: AccountKind) -> some View {
        if app.accounts.accounts[kind] == nil {
            loginOptions(kind)
        } else {
            if let platform = kind.drivePlatform, app.resolvers.manager(for: platform) != nil {
                Button { drivePlatform = platform } label: { Label("我的网盘", glyph: .cloud) }
            }
            Button { listKind = kind } label: { Label("账号管理 / 添加账号", glyph: .user) }
            Menu { loginOptions(kind) } label: { Label("重新登录", glyph: .refresh) }
            Button(role: .destructive) { logoutKind = kind } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
        }
    }

    /// 已登录网盘的容量（并发取，取不到就不显示）
    private func loadQuotas() async {
        let targets = AccountKind.allCases.compactMap { kind -> (SharePlatform, DriveManager)? in
            guard kind.isDrive, app.accounts.accounts[kind] != nil, let platform = kind.drivePlatform,
                  let manager = app.resolvers.manager(for: platform) else { return nil }
            return (platform, manager)
        }
        var result: [SharePlatform: DriveQuota] = [:]
        await withTaskGroup(of: (SharePlatform, DriveQuota?).self) { group in
            for (platform, manager) in targets {
                group.addTask { (platform, await manager.quota()) }
            }
            for await (platform, quota) in group {
                if let quota { result[platform] = quota }
            }
        }
        quotas = result
    }

    @ViewBuilder
    private func loginOptions(_ kind: AccountKind) -> some View {
        if let provider = kind.passwordLogin {
            Button { app.accounts.pendingAdd = nil; passwordKind = kind } label: {
                Label(provider.supportsSMS ? "账号密码 / 短信登录" : "账号密码登录", glyph: .user)
            }
        }
        if kind.supportsWebLogin {
            Button { app.accounts.pendingAdd = nil; loginKind = kind } label: { Label("网页登录", glyph: .link) }
        }
        Button { app.accounts.pendingAdd = nil; manualKind = kind } label: { Label("手动粘贴凭据", glyph: .paste) }
    }

    /// 首选方式：网页登录 → 应用内账号密码 → 手动粘贴
    private func startLogin(_ kind: AccountKind) {
        if kind.prefersPasswordLogin { passwordKind = kind; return }
        if kind.supportsWebLogin { loginKind = kind } else if kind.passwordLogin != nil { passwordKind = kind } else { manualKind = kind }
    }
}

/// 按平台选首选的登录方式：网页登录 → 应用内账号密码 → 手动粘贴。供其他页面就地弹出登录，不必跳到「我的」
struct LoginSheet: View {
    let kind: AccountKind

    var body: some View {
        if kind.prefersPasswordLogin {
            PasswordLoginView(kind: kind)
        } else if kind.supportsWebLogin {
            WebLoginView(kind: kind)
        } else if kind.passwordLogin != nil {
            PasswordLoginView(kind: kind)
        } else {
            ManualCookieView(kind: kind)
        }
    }
}

/// 退出登录确认，挂在对应平台的卡片 / 行上
private struct LogoutDialog: ViewModifier {
    let kind: AccountKind
    @Binding var logoutKind: AccountKind?
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.rowDialog("退出\(kind.displayName)？", isPresented: presenting($logoutKind) { $0 == kind },
                          message: "将删除本机保存的登录凭据") {
            Button("退出登录", role: .destructive) { Task { await app.accounts.logout(kind) } }
        }
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
                Group {
                    Section {
                        TextField(kind.manualPlaceholder, text: $cookie, axis: .vertical)
                            .lineLimit(4...10)
                            .font(.mono)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text(kind.manualHint)
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(Color.clayInk) }
                    }
                }
                .listRowBackground(Color.surface)
            }
            .paperList()
            .navigationTitle("\(kind.displayName)凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { Spinner() } else {
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
