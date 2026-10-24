// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 「我的」页平台的顺序与显示，存在 UserDefaults（逗号分隔的 rawValue）
enum PlatformLayout {
    enum Group: String, CaseIterable, Identifiable {
        case drives = "网盘", videos = "视频平台"
        var id: Self { self }
    }

    static func split(_ value: String) -> [String] { value.split(separator: ",").map(String.init) }
    static func join(_ kinds: some Sequence<AccountKind>) -> String { kinds.map(\.rawValue).joined(separator: ",") }

    /// 按保存的顺序排；没出现过的（新加的平台）保持原有先后，排在后面
    static func ordered(_ kinds: [AccountKind], by saved: String) -> [AccountKind] {
        var rank: [String: Int] = [:]
        for (i, raw) in split(saved).enumerated() where rank[raw] == nil { rank[raw] = i }
        return kinds.enumerated().sorted { a, b in
            (rank[a.element.rawValue] ?? 10_000 + a.offset) < (rank[b.element.rawValue] ?? 10_000 + b.offset)
        }.map(\.element)
    }

    /// 没自定义过时显示哪些：已登录的；一个都没登录时给前 4 个常用的（网盘、视频平台都是），免得空着、也看得到能登录什么
    static func defaultPinned(_ kinds: [AccountKind], drives: Bool, hidden: [String], hasAccount: (AccountKind) -> Bool) -> [AccountKind] {
        let candidates = kinds.filter { !hidden.contains($0.rawValue) }
        let mine = candidates.filter(hasAccount)
        return mine.isEmpty ? Array(candidates.prefix(4)) : mine
    }
}

/// 排序与显示：系统列表的拖动把手排序（拖到边缘会自动滚动），开关决定是否在「我的」页显示
struct PlatformLayoutView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var group: PlatformLayout.Group
    @State private var drives: [AccountKind] = []
    @State private var videos: [AccountKind] = []
    @State private var pinned: Set<AccountKind> = []
    @State private var loaded = false

    @AppStorage("accounts.driveOrder") private var driveOrder = ""
    @AppStorage("accounts.videoOrder") private var videoOrder = ""
    @AppStorage("accounts.drivePinned") private var drivePinned = ""
    @AppStorage("accounts.videoPinned") private var videoPinned = ""
    @AppStorage("accounts.drivePinnedSet") private var drivePinnedSet = false
    @AppStorage("accounts.videoPinnedSet") private var videoPinnedSet = false

    init(group: PlatformLayout.Group = .drives) {
        _group = State(initialValue: group)
    }

    private var items: Binding<[AccountKind]> { group == .drives ? $drives : $videos }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items.wrappedValue) { row($0) }
                        .onMove { from, to in items.wrappedValue.move(fromOffsets: from, toOffset: to) }
                } header: {
                    HStack {
                        Text("已显示 \(items.wrappedValue.filter(pinned.contains).count) / \(items.wrappedValue.count)")
                            .contentTransition(.numericText())
                        Spacer()
                        Text("拖动右侧把手排序")
                    }
                } footer: {
                    Text(group == .drives
                         ? "关掉的网盘不在「我的」页显示，登录状态保留，解析与下载照常。蓝奏云、蓝奏优享、光鸭的公开分享无需登录；其余网盘未登录也能浏览分享。"
                         : "小红书、知乎需要登录；抖音登录后可获取主页全部作品；X、Instagram、TikTok、Reddit、Facebook 登录可选，登录后可解析受限内容；其余平台无需登录。")
                }
                .listRowBackground(Color.surface)
            }
            .environment(\.editMode, .constant(.active))
            .paperList()
            .animation(.snappy, value: group)
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("类别", selection: $group) {
                    ForEach(PlatformLayout.Group.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.paper)
            }
            .navigationTitle("排序与显示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { setAll(true) } label: { Label("全部显示", systemImage: "eye") }
                        Button { setLoggedInOnly() } label: { Label("只显示已登录", systemImage: "person.crop.circle.badge.checkmark") }
                        Divider()
                        Button { resetOrder() } label: { Label("恢复默认顺序", systemImage: "arrow.counterclockwise") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多")
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sensoryFeedback(.selection, trigger: pinned)
            .onAppear(perform: load)
            .onChange(of: drives) { save() }
            .onChange(of: videos) { save() }
            .onChange(of: pinned) { save() }
        }
    }

    private func row(_ kind: AccountKind) -> some View {
        let on = pinned.contains(kind)
        let account = app.accounts.accounts[kind]
        return HStack(spacing: 12) {
            PlatformTile(mark: .account(kind), size: 32, dimmed: !on)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(on ? Color.ink : Color.ink2)
                Group {
                    if let account {
                        Text(app.accounts.isExpired(kind) ? "登录已失效" : "已登录 · \(account.nickname)")
                            .foregroundStyle(app.accounts.isExpired(kind) ? Color.clayInk : Color.success)
                    } else {
                        Text("未登录").foregroundStyle(Color.ink3)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("在「我的」页显示\(kind.displayName)", isOn: Binding(
                get: { on },
                set: { show in
                    withAnimation(.snappy) { if show { pinned.insert(kind) } else { pinned.remove(kind) } }
                }))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let has: (AccountKind) -> Bool = { app.accounts.accounts[$0] != nil }
        drives = PlatformLayout.ordered(AccountKind.allCases.filter(\.isDrive), by: driveOrder)
        videos = PlatformLayout.ordered(AccountKind.allCases.filter { !$0.isDrive }, by: videoOrder)
        let d = drivePinnedSet ? drives.filter { PlatformLayout.split(drivePinned).contains($0.rawValue) }
            : PlatformLayout.defaultPinned(drives, drives: true, hidden: app.settings.hiddenDrives, hasAccount: has)
        let v = videoPinnedSet ? videos.filter { PlatformLayout.split(videoPinned).contains($0.rawValue) }
            : PlatformLayout.defaultPinned(videos, drives: false, hidden: [], hasAccount: has)
        pinned = Set(d + v)
    }

    private func save() {
        guard loaded else { return }
        driveOrder = PlatformLayout.join(drives)
        videoOrder = PlatformLayout.join(videos)
        drivePinned = PlatformLayout.join(drives.filter(pinned.contains))
        videoPinned = PlatformLayout.join(videos.filter(pinned.contains))
        drivePinnedSet = true
        videoPinnedSet = true
        // 旧的「隐藏网盘」设置已并入这里
        if !app.settings.hiddenDrives.isEmpty { app.settings.hiddenDrives = [] }
    }

    private func setAll(_ show: Bool) {
        withAnimation(.snappy) {
            for kind in items.wrappedValue { if show { pinned.insert(kind) } else { pinned.remove(kind) } }
        }
    }

    private func setLoggedInOnly() {
        withAnimation(.snappy) {
            for kind in items.wrappedValue {
                if app.accounts.accounts[kind] != nil { pinned.insert(kind) } else { pinned.remove(kind) }
            }
        }
    }

    private func resetOrder() {
        withAnimation(.snappy) {
            if group == .drives { drives = AccountKind.allCases.filter(\.isDrive) } else { videos = AccountKind.allCases.filter { !$0.isDrive } }
        }
    }
}
