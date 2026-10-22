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
    @State private var quotas: [SharePlatform: DriveQuota] = [:]
    /// 上次取容量的时间与当时的账号：切回本页时 10 分钟内不重复请求
    @State private var quotaLoaded: (at: Date, key: String)?

    /// 设置里勾选显示的网盘（默认全部），按自定义顺序
    private var visibleDrives: [AccountKind] {
        allDrives.filter { !app.settings.hiddenDrives.contains($0.rawValue) }
    }

    /// 平台越来越多：默认只列登录过的（含已失效的），其余收起，展开状态记住
    @AppStorage("accounts.drivesExpanded") private var drivesExpanded = false
    @AppStorage("accounts.videosExpanded") private var videosExpanded = false
    /// 自定义顺序（逗号分隔的 rawValue；新增的平台排在末尾）
    @AppStorage("accounts.driveOrder") private var driveOrder = ""
    @AppStorage("accounts.videoOrder") private var videoOrder = ""
    /// 收起时显示哪些：自定义过就按自定义，否则显示已登录的
    @AppStorage("accounts.drivePinned") private var drivePinned = ""
    @AppStorage("accounts.videoPinned") private var videoPinned = ""
    @AppStorage("accounts.drivePinnedSet") private var drivePinnedSet = false
    @AppStorage("accounts.videoPinnedSet") private var videoPinnedSet = false

    /// 「排序与显示」编辑状态：拖动排序、点眼睛切换收起时是否显示
    @State private var editing = false
    @State private var editDrives: [AccountKind] = []
    @State private var editVideos: [AccountKind] = []
    @State private var reordering = false

    private func hasAccount(_ kind: AccountKind) -> Bool { app.accounts.accounts[kind] != nil }

    private var allDrives: [AccountKind] { Self.ordered(AccountKind.allCases.filter(\.isDrive), by: driveOrder) }
    private var videoKinds: [AccountKind] { Self.ordered(AccountKind.allCases.filter { !$0.isDrive }, by: videoOrder) }

    private var pinnedDrives: [AccountKind] {
        if drivePinnedSet { return visibleDrives.filter { Self.split(drivePinned).contains($0.rawValue) } }
        let mine = visibleDrives.filter(hasAccount)
        // 一个都没登录时给几个常用的，免得这一块空着
        return mine.isEmpty ? Array(visibleDrives.prefix(4)) : mine
    }

    private var pinnedVideos: [AccountKind] {
        videoPinnedSet ? videoKinds.filter { Self.split(videoPinned).contains($0.rawValue) } : videoKinds.filter(hasAccount)
    }

    private var shownDrives: [AccountKind] { drivesExpanded ? visibleDrives : pinnedDrives }
    private var shownVideos: [AccountKind] { videosExpanded ? videoKinds : pinnedVideos }

    private static func split(_ value: String) -> [String] { value.split(separator: ",").map(String.init) }

    /// 按保存的顺序排；没出现过的保持原有先后，排在后面
    private static func ordered(_ kinds: [AccountKind], by saved: String) -> [AccountKind] {
        var rank: [String: Int] = [:]
        for (i, raw) in split(saved).enumerated() where rank[raw] == nil { rank[raw] = i }
        return kinds.enumerated().sorted { a, b in
            (rank[a.element.rawValue] ?? 10_000 + a.offset) < (rank[b.element.rawValue] ?? 10_000 + b.offset)
        }.map(\.element)
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
                    if editing {
                        editSections
                    } else {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "网盘", trailing: loggedInSummary)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(shownDrives) { driveTile($0) }
                        }
                        let hiddenDrives = visibleDrives.count - shownDrives.count
                        if hiddenDrives > 0 || drivesExpanded {
                            expandButton(expanded: $drivesExpanded, collapsedTitle: "展开其余 \(hiddenDrives) 个网盘")
                        }
                        if drivesExpanded {
                            Text("蓝奏云、蓝奏优享、光鸭的公开分享无需登录；其余网盘未登录也能浏览分享，夸克 / UC / 115 还能直接下载部分文件。长按可管理账号；右上角绿点表示已登录，红点表示登录已失效（每 6 小时最多自动检测一次）。")
                                .font(.caption)
                                .foregroundStyle(Color.ink3)
                                .padding(.horizontal, 4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        let loggedVideos = videoKinds.filter(hasAccount).count
                        SectionLabel(title: "视频平台", trailing: loggedVideos == 0 ? "未登录" : "已登录 \(loggedVideos) 个")
                        VStack(spacing: 0) {
                            let kinds = shownVideos
                            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                                videoRow(kind)
                                RowDivider(leading: 60)
                            }
                            expandButton(expanded: $videosExpanded,
                                         collapsedTitle: kinds.isEmpty ? (videoPinnedSet ? "展开全部 \(videoKinds.count) 个平台" : "登录视频平台（\(videoKinds.count) 个）") : "展开其余 \(videoKinds.count - kinds.count) 个平台")
                                .padding(.horizontal, 14)
                        }
                        .card()
                        if videosExpanded {
                            Text("小红书、知乎需要登录；抖音登录后可获取主页全部作品；Pixiv 未登录只能解析公开作品；X、Instagram、TikTok、Reddit、Facebook 登录可选，登录后可解析受限内容并减少游客限流；其余平台无需登录。")
                                .font(.caption)
                                .foregroundStyle(Color.ink3)
                                .padding(.horizontal, 4)
                        }
                    }
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
            // 拖动排序时不让列表跟着滚
            .scrollDisabled(reordering)
            .background(Color.paper)
            .onChange(of: loggedKinds) { old, new in
                // 自定义过收起时显示哪些：新登录的平台自动加进去，免得登录完找不到
                let added = new.subtracting(old)
                guard !added.isEmpty else { return }
                if drivePinnedSet { drivePinned = (Self.split(drivePinned) + added.filter { $0.isDrive }.map(\.rawValue)).joined(separator: ",") }
                if videoPinnedSet { videoPinned = (Self.split(videoPinned) + added.filter { !$0.isDrive }.map(\.rawValue)).joined(separator: ",") }
            }
            .task(id: accountsKey) { await refreshStatus() }
            .navigationTitle("我的")
            .toolbar {
                // 平台多了列表很长：设置放到右上角，不用滑到底
                ToolbarItem(placement: .topBarLeading) {
                    Button(editing ? "完成" : "排序") { editing ? endEditing() : beginEditing() }
                        .fontWeight(editing ? .semibold : .regular)
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { SettingsView() } label: { IconView(.gear, size: 18) }
                        .accessibilityLabel("设置")
                }
            }
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
                ManualCookieView(kind: kind)
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
        let quota = platform.flatMap { quotas[$0] }
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

    private func beginEditing() {
        editDrives = visibleDrives
        editVideos = videoKinds
        // 第一次编辑：把当前收起时看到的固定下来，之后按眼睛开关
        if !drivePinnedSet { drivePinned = pinnedDrives.map(\.rawValue).joined(separator: ","); drivePinnedSet = true }
        if !videoPinnedSet { videoPinned = pinnedVideos.map(\.rawValue).joined(separator: ","); videoPinnedSet = true }
        withAnimation(.snappy) { editing = true }
    }

    private func endEditing() {
        withAnimation(.snappy) { editing = false }
    }

    /// 编辑状态：全部平台按住拖动排序，眼睛决定收起时是否显示
    private var editSections: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.draw")
                Text("按住卡片拖动调整顺序；点眼睛设置收起时是否显示，展开后仍会列出全部。")
            }
            .font(.caption)
            .foregroundStyle(Color.ink3)
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "网盘", trailing: "收起时显示 \(editDrives.filter { isPinned($0) }.count) 个")
                ReorderableGrid(items: $editDrives, columns: 2, rowHeight: 60, spacing: 10, dragging: $reordering) { kind in
                    editCell(kind, handle: false)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "视频平台", trailing: "收起时显示 \(editVideos.filter { isPinned($0) }.count) 个")
                ReorderableGrid(items: $editVideos, columns: 1, rowHeight: 56, spacing: 8, dragging: $reordering) { kind in
                    editCell(kind, handle: true)
                }
            }
        }
        .transition(.opacity)
        .onChange(of: editDrives) { _, kinds in
            // 设置里隐藏掉的网盘不参与编辑，保留在末尾
            let rest = allDrives.filter { !kinds.contains($0) }
            driveOrder = (kinds + rest).map(\.rawValue).joined(separator: ",")
        }
        .onChange(of: editVideos) { _, kinds in
            videoOrder = kinds.map(\.rawValue).joined(separator: ",")
        }
    }

    private func isPinned(_ kind: AccountKind) -> Bool {
        Self.split(kind.isDrive ? drivePinned : videoPinned).contains(kind.rawValue)
    }

    private func togglePinned(_ kind: AccountKind) {
        var list = Self.split(kind.isDrive ? drivePinned : videoPinned)
        if let i = list.firstIndex(of: kind.rawValue) { list.remove(at: i) } else { list.append(kind.rawValue) }
        withAnimation(.snappy) {
            if kind.isDrive { drivePinned = list.joined(separator: ",") } else { videoPinned = list.joined(separator: ",") }
        }
    }

    private func editCell(_ kind: AccountKind, handle: Bool) -> some View {
        let pinned = isPinned(kind)
        return HStack(spacing: 10) {
            if handle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink3)
            }
            PlatformTile(mark: .account(kind), size: 30, dimmed: !pinned)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                Text(hasAccount(kind) ? "已登录" : "未登录").font(.caption2).foregroundStyle(Color.ink3)
            }
            Spacer(minLength: 0)
            Button { togglePinned(kind) } label: {
                Image(systemName: pinned ? "eye" : "eye.slash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(pinned ? Color.ink : Color.ink3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? "收起时显示" : "收起时隐藏")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sensoryFeedback(.selection, trigger: pinned)
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
            Button { beginEditing() } label: { Label("排序与显示…", systemImage: "arrow.up.arrow.down") }
        } else {
            if let platform = kind.drivePlatform, app.resolvers.manager(for: platform) != nil {
                Button { drivePlatform = platform } label: { Label("我的网盘", glyph: .cloud) }
            }
            Button { listKind = kind } label: { Label("账号管理 / 添加账号", glyph: .user) }
            Button { beginEditing() } label: { Label("排序与显示…", systemImage: "arrow.up.arrow.down") }
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
            await loadQuotas()
            quotaLoaded = (Date(), key)
            for kind in AccountKind.allCases {
                if let platform = kind.drivePlatform, quotas[platform] != nil { app.accounts.recordHealth(kind, valid: true) }
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

    private func clearPendingAdd() {
        app.accounts.pendingAdd = nil
    }

    /// 「展开其余 N 个 / 收起」
    private func expandButton(expanded: Binding<Bool>, collapsedTitle: String) -> some View {
        Button {
            withAnimation(.snappy) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(expanded.wrappedValue ? "收起" : collapsedTitle)
                IconView(.chevronRight, size: 12)
                    .rotationEffect(.degrees(expanded.wrappedValue ? -90 : 90))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 首选方式：网页登录 → 应用内账号密码 → 手动粘贴
    private func startLogin(_ kind: AccountKind) {
        if kind.oauth != nil { loginKind = kind; return }
        if kind.prefersPasswordLogin { passwordKind = kind; return }
        if kind.supportsWebLogin { loginKind = kind } else if kind.passwordLogin != nil { passwordKind = kind } else { manualKind = kind }
    }
}

/// 按平台选首选的登录方式：网页登录 → 应用内账号密码 → 手动粘贴。供其他页面就地弹出登录，不必跳到「我的」
struct LoginSheet: View {
    let kind: AccountKind

    var body: some View {
        if let provider = kind.oauth {
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
