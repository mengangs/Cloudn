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
    /// 在账号列表里点了「添加账号」：等列表收起（onDismiss）后再弹登录页
    @State private var addAfterList: AccountKind?
    @State private var logoutKind: AccountKind?
    @State private var exporting = false
    @State private var importing = false
    @State private var importData: ImportData?
    /// 容量：先显示上次缓存的，后台取到新的再替换（取失败保留旧值），避免进页面时整块消失再出现
    @State private var quotas: [String: CachedQuota] = CachedQuota.load()
    /// 上次取容量的时间与当时的账号：切回本页时 10 分钟内不重复请求
    @State private var quotaLoaded: (at: Date, key: String)?

    /// 顺序与显示由「排序与显示」决定（PlatformLayout）；不再折叠，没显示的从末尾的「更多」进去开
    @AppStorage("accounts.driveOrder") private var driveOrder = ""
    @AppStorage("accounts.videoOrder") private var videoOrder = ""
    @AppStorage("accounts.drivePinned") private var drivePinned = ""
    @AppStorage("accounts.videoPinned") private var videoPinned = ""
    @AppStorage("accounts.drivePinnedSet") private var drivePinnedSet = false
    @AppStorage("accounts.videoPinnedSet") private var videoPinnedSet = false
    @State private var layoutGroup: PlatformLayout.Group?
    @Environment(\.dynamicTypeSize) private var typeSize

    private func hasAccount(_ kind: AccountKind) -> Bool { app.accounts.accounts[kind] != nil }

    private var allDrives: [AccountKind] { PlatformLayout.ordered(AccountKind.allCases.filter(\.isDrive), by: driveOrder) }
    private var videoKinds: [AccountKind] { PlatformLayout.ordered(AccountKind.allCases.filter { !$0.isDrive }, by: videoOrder) }

    private var shownDrives: [AccountKind] {
        drivePinnedSet ? allDrives.filter { PlatformLayout.split(drivePinned).contains($0.rawValue) }
            : PlatformLayout.defaultPinned(allDrives, drives: true, hidden: app.settings.hiddenDrives, hasAccount: hasAccount)
    }

    private var shownVideos: [AccountKind] {
        videoPinnedSet ? videoKinds.filter { PlatformLayout.split(videoPinned).contains($0.rawValue) }
            : PlatformLayout.defaultPinned(videoKinds, drives: false, hidden: [], hasAccount: hasAccount)
    }

    /// 账号有变（登录、退出、续期）时重新取容量
    private var accountsKey: String {
        app.accounts.accounts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)@\($0.value.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
    }

    private var loggedInSummary: String {
        let n = AccountKind.allCases.filter { $0.isDrive && app.accounts.accounts[$0] != nil }.count
        return n == 0 ? "未登录" : "已登录 \(n) 个"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if app.accounts.accounts.isEmpty { loginIntro }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "网盘", trailing: loggedInSummary)
                        // 辅助字号下一行一张，网盘名与容量不被截断
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2),
                                  spacing: 10) {
                            ForEach(shownDrives) { driveTile($0) }
                            moreTile(hidden: allDrives.count - shownDrives.count)
                        }
                        .animation(.snappy, value: shownDrives)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        let loggedVideos = videoKinds.filter(hasAccount).count
                        SectionLabel(title: "视频平台", trailing: loggedVideos == 0 ? "未登录" : "已登录 \(loggedVideos) 个")
                        VStack(spacing: 0) {
                            ForEach(shownVideos) { kind in
                                videoRow(kind)
                                RowDivider(leading: 60)
                            }
                            moreVideosRow(hidden: videoKinds.count - shownVideos.count)
                        }
                        .card()
                        .animation(.snappy, value: shownVideos)
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
                .readableWidth()
            }
            .background(Color.paper)
            .onChange(of: loggedKinds) { old, new in
                // 自定义过显示哪些：新登录的平台自动显示，免得登录完找不到
                let added = new.subtracting(old)
                guard !added.isEmpty else { return }
                if drivePinnedSet { drivePinned = (PlatformLayout.split(drivePinned) + added.filter(\.isDrive).map(\.rawValue)).joined(separator: ",") }
                if videoPinnedSet { videoPinned = (PlatformLayout.split(videoPinned) + added.filter { !$0.isDrive }.map(\.rawValue)).joined(separator: ",") }
            }
            .task(id: accountsKey) { await refreshStatus() }
            .navigationTitle("我的")
            .toolbar {
                // 平台多了列表很长：设置放到右上角，不用滑到底
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { SettingsView() } label: { IconView(.gear, size: 18) }
                        .accessibilityLabel("设置")
                }
            }
            .sheet(item: $layoutGroup) { PlatformLayoutView(group: $0) }
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
            // 登录页没登成就关掉：撤销「添加账号」标记，免得之后别处重新登录被当成附加账号、主账号不更新
            .sheet(item: $loginKind, onDismiss: clearPendingAdd) { kind in
                if let provider = kind.oauth {
                    OAuthLoginView(kind: kind, provider: provider)
                } else {
                    WebLoginView(kind: kind)
                }
            }
            .sheet(item: $manualKind, onDismiss: clearPendingAdd) { kind in
                if kind == .webdav { WebDAVLoginView() } else { ManualCookieView(kind: kind) }
            }
            .sheet(item: $passwordKind, onDismiss: clearPendingAdd) { kind in
                PasswordLoginView(kind: kind)
            }
            .navigationDestination(item: $drivePlatform) { MyDriveView(platform: $0) }
            // 同一时刻只能展示一个 sheet：列表完全收起后再弹登录页（固定延时在慢设备上会赶在收起之前，登录页弹不出来）
            .sheet(item: $listKind, onDismiss: {
                guard let add = addAfterList else { return }
                addAfterList = nil
                app.accounts.pendingAdd = add
                startLogin(add)
            }) { kind in
                AccountListView(kind: kind) { add in
                    addAfterList = add
                    listKind = nil
                }
            }
        }
    }

    /// 网盘卡片：点按进入我的网盘（未登录则去登录），长按管理账号
    private func driveTile(_ kind: AccountKind) -> some View {
        let account = app.accounts.accounts[kind]
        let platform = kind.drivePlatform
        let quota = platform.flatMap { quotas[$0.rawValue] }.flatMap { $0.owner == account?.nickname ? $0.quota : nil }
        let expired = app.accounts.isExpired(kind)
        return Menu {
            accountMenu(kind)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PlatformTile(mark: .account(kind), size: 34, dimmed: account == nil)
                    Spacer()
                    if account != nil {
                        statusDot(kind)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                    if account != nil, expired {
                        Text("登录已失效，点按重新登录").font(.caption).foregroundStyle(Color.clayInk).lineLimit(1)
                    } else if let account {
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
                            .contentTransition(.numericText())
                    }
                    .animation(.snappy, value: quota)
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
            if account == nil || expired {
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
                let expired = app.accounts.isExpired(kind)
                Text(account.map { expired ? "登录已失效 · \($0.nickname)" : "已登录 · \($0.nickname)" } ?? kind.benefit)
                    .font(.caption)
                    .foregroundStyle(account == nil ? Color.ink3 : (expired ? Color.clayInk : Color.success))
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

    private var loggedKinds: Set<AccountKind> { Set(app.accounts.accounts.keys) }

    /// 一个账号都没登录时：说清不登录也能用，登录了能多做什么
    private var loginIntro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("不登录也能解析大部分公开链接").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
            Text("登录网盘后可下载大文件、转存到自己的网盘；登录视频平台可获取更高清晰度和需要登录才能看的内容。凭据只保存在本机。")
                .font(.footnote)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }

    /// 网格末尾的「更多网盘」：虚线框，点开排序与显示
    private func moreTile(hidden: Int) -> some View {
        Button { layoutGroup = .drives } label: {
            VStack(spacing: 8) {
                Image(systemName: hidden > 0 ? "plus" : "arrow.up.arrow.down")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 34, height: 34)
                    .background(Color.fillMuted, in: Circle())
                Text(hidden > 0 ? "更多网盘" : "排序与显示").font(.subheadline.weight(.medium)).foregroundStyle(Color.ink2)
                if hidden > 0 {
                    Text("\(hidden) 个未显示").font(.caption).foregroundStyle(Color.ink3)
                }
            }
            .padding(14)
            // 和旁边的网盘卡片同高
            .frame(maxWidth: .infinity, minHeight: 140)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.hairline, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 视频平台卡片的最后一行：「更多视频平台」
    private func moreVideosRow(hidden: Int) -> some View {
        Button { layoutGroup = .videos } label: {
            HStack(spacing: 12) {
                Image(systemName: hidden > 0 ? "plus" : "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink2)
                    .frame(width: 32, height: 32)
                    .background(Color.fillMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(hidden > 0 ? "更多视频平台" : "排序与显示").font(.subheadline.weight(.medium)).foregroundStyle(Color.ink2)
                Spacer(minLength: 0)
                if hidden > 0 { Text("\(hidden) 个未显示").font(.caption).foregroundStyle(Color.ink3) }
                IconView(.chevronRight, size: 12).foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Divider()
            Button { layoutGroup = kind.isDrive ? .drives : .videos } label: { Label("排序与显示…", systemImage: "arrow.up.arrow.down") }
        } else {
            if let platform = kind.drivePlatform, app.resolvers.manager(for: platform) != nil {
                Button { drivePlatform = platform } label: { Label("我的网盘", glyph: .cloud) }
            }
            Button { listKind = kind } label: { Label("账号管理 / 添加账号", glyph: .user) }
            Button { layoutGroup = kind.isDrive ? .drives : .videos } label: { Label("排序与显示…", systemImage: "arrow.up.arrow.down") }
            Button { Task { await checkNow(kind) } } label: { Label("检查登录状态", glyph: .check) }
            Menu { loginOptions(kind) } label: { Label("重新登录", glyph: .refresh) }
            Button(role: .destructive) { logoutKind = kind } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
        }
    }

    /// 右上角的状态点：绿色已登录，红色登录已失效，检测中为灰色
    @ViewBuilder
    private func statusDot(_ kind: AccountKind) -> some View {
        let expired = app.accounts.isExpired(kind)
        Circle()
            .fill(app.accounts.checking.contains(kind) ? Color.ink3 : (expired ? Color.clayInk : Color.success))
            .frame(width: 7, height: 7)
            .accessibilityLabel(expired ? "登录已失效" : "已登录")
    }

    /// 进入本页时：取容量（10 分钟内不重复），取到容量的网盘即视为登录有效；
    /// 其余已登录的平台按 6 小时一次的频率检测登录态
    private func refreshStatus() async {
        let key = accountsKey
        if let loaded = quotaLoaded, loaded.key == key, Date().timeIntervalSince(loaded.at) < 600 {
            // 容量不重取
        } else {
            let fresh = await loadQuotas()
            quotaLoaded = (Date(), key)
            for kind in AccountKind.allCases {
                if let platform = kind.drivePlatform, fresh.contains(platform) { app.accounts.recordHealth(kind, valid: true) }
            }
        }
        await app.accounts.checkHealth(AccountKind.allCases, resolvers: app.resolvers)
    }

    private func checkNow(_ kind: AccountKind) async {
        let result = await app.accounts.checkHealth([kind], resolvers: app.resolvers, force: true)[kind]
        switch result {
        case .valid: app.show("\(kind.displayName)登录有效")
        case .expired: app.show("\(kind.displayName)登录已失效，请重新登录", error: true)
        case .unreachable: app.show("连不上\(kind.displayName)，请检查网络后再试", error: true)
        case nil: break
        }
    }

    /// 已登录网盘的容量（并发取）；返回这次取到的平台。取不到的保留上次的值，退出登录的去掉
    @discardableResult
    private func loadQuotas() async -> Set<SharePlatform> {
        let targets = AccountKind.allCases.compactMap { kind -> (SharePlatform, String, DriveManager)? in
            guard kind.isDrive, let account = app.accounts.accounts[kind], let platform = kind.drivePlatform,
                  let manager = app.resolvers.manager(for: platform) else { return nil }
            return (platform, account.nickname, manager)
        }
        var result = quotas.filter { key, _ in targets.contains { $0.0.rawValue == key } }
        var fresh = Set<SharePlatform>()
        await withTaskGroup(of: (SharePlatform, String, DriveQuota?).self) { group in
            for (platform, owner, manager) in targets {
                group.addTask { (platform, owner, await manager.quota()) }
            }
            for await (platform, owner, quota) in group {
                guard let quota else { continue }
                result[platform.rawValue] = CachedQuota(used: quota.used, total: quota.total, owner: owner)
                fresh.insert(platform)
            }
        }
        if result != quotas {
            quotas = result
            CachedQuota.save(result)
        }
        return fresh
    }

    @ViewBuilder
    private func loginOptions(_ kind: AccountKind) -> some View {
        if kind == .webdav {
            Button { app.accounts.pendingAdd = nil; manualKind = kind } label: { Label("连接服务器", glyph: .link) }
        } else {
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
    }

    private func clearPendingAdd() {
        app.accounts.pendingAdd = nil
    }


    /// 首选方式：网页登录 → 应用内账号密码 → 手动粘贴
    private func startLogin(_ kind: AccountKind) {
        if kind == .webdav { manualKind = kind; return }
        if kind.oauth != nil { loginKind = kind; return }
        if kind.prefersPasswordLogin { passwordKind = kind; return }
        if kind.supportsWebLogin { loginKind = kind } else if kind.passwordLogin != nil { passwordKind = kind } else { manualKind = kind }
    }
}

/// 按平台选首选的登录方式：网页登录 → 应用内账号密码 → 手动粘贴。供其他页面就地弹出登录，不必跳到「我的」
struct LoginSheet: View {
    let kind: AccountKind

    var body: some View {
        if kind == .webdav {
            WebDAVLoginView()
        } else if let provider = kind.oauth {
            OAuthLoginView(kind: kind, provider: provider)
        } else if kind.prefersPasswordLogin {
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
        // 退出会删掉该平台的全部账号（含附加账号），有多个时把数量说清楚
        let count = app.accounts.count(for: kind)
        return content.rowDialog("退出\(kind.displayName)？", isPresented: presenting($logoutKind) { $0 == kind },
                                 message: count > 1 ? "将删除本机保存的 \(count) 个\(kind.displayName)账号的登录凭据" : "将删除本机保存的登录凭据") {
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
                            guard !saving else { return }
                            saving = true
                            error = nil
                            let value = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                defer { saving = false }
                                if let name = await app.accounts.login(kind, cookie: value) {
                                    app.show("已登录：\(name)")
                                    dismiss()
                                } else {
                                    error = "凭据无效或已过期，请重新复制"
                                }
                            }
                        }
                        .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        // 校验途中不让下滑关掉（结果回来时页面已不在）
        .interactiveDismissDisabled(saving)
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

/// 网盘容量缓存（按平台，记下属于哪个账号，换账号后不显示旧的）
struct CachedQuota: Codable, Equatable {
    var used: Int64
    var total: Int64
    var owner: String

    var quota: DriveQuota { DriveQuota(used: used, total: total) }

    private static let key = "accounts.quotaCache"

    static func load() -> [String: CachedQuota] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedQuota].self, from: data)) ?? [:]
    }

    static func save(_ value: [String: CachedQuota]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
