// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .all
    @State private var previewURL: URL?
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var deleting: DownloadItem?
    @State private var confirmClear = false
    @State private var refreshing = Set<UUID>()
    @State private var samples: [Double] = []
    /// 展开的分组
    @State private var expanded = Set<UUID>()
    /// 正在看调试信息的任务
    @State private var debugging: DownloadItem?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", done = "已完成"
        var id: String { rawValue }
    }

    private var items: [DownloadItem] {
        let all = app.downloads.items
        switch filter {
        case .all: return all
        case .active: return all.filter { $0.status != .completed }
        case .done: return all.filter { $0.status == .completed }
        }
    }

    /// 同一批次的任务收成一组（按首次出现的位置排列），其余单独成行
    private var entries: [DownloadEntry] {
        var result: [DownloadEntry] = []
        var grouped: [UUID: [DownloadItem]] = [:]
        var order: [DownloadGroup] = []
        for item in items {
            if let group = item.request.group {
                if grouped[group.id] == nil {
                    order.append(group)
                    result.append(.group(group, []))
                }
                grouped[group.id, default: []].append(item)
            } else {
                result.append(.single(item))
            }
        }
        return result.map { entry in
            guard case .group(let g, _) = entry else { return entry }
            let members = grouped[g.id] ?? []
            // 只剩一个任务的批次不必折叠
            return members.count == 1 ? .single(members[0]) : .group(g, members)
        }
    }

    /// 一个任务一张卡片：点按打开文件 / 暂停 / 继续，左滑删除，右滑暂停 / 继续，长按是全部操作；多选模式下点按勾选。
    /// 卡片底色画在行内容上（不是列表的行背景），左右滑时整张卡片带着圆角一起移动
    private func row(_ item: DownloadItem, inset: CGFloat = 0) -> some View {
        let on = selection.contains(item.id)
        return HStack(spacing: 12) {
            if selecting {
                SelectMark(on: on).transition(.move(edge: .leading).combined(with: .opacity))
            }
            DownloadRow(item: item, refreshing: refreshing.contains(item.id), showsControl: !selecting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(on ? Color.claySoft.opacity(0.5) : Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.hairline), lineWidth: on ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { selecting ? toggle([item.id]) : primaryAction(item) }
        .contextMenu { menu(item) }
        .rowDialog(item.displayName, isPresented: presenting($deleting) { $0.id == item.id }) {
            if item.status == .completed {
                Button("删除任务和文件", role: .destructive) { app.downloads.remove(item, deleteFile: true) }
                Button("仅删除记录") { app.downloads.remove(item, deleteFile: false) }
            } else {
                Button("删除任务", role: .destructive) { app.downloads.remove(item, deleteFile: true) }
            }
        }
        // 不用 destructive 角色：那会让列表立刻播放「删除这一行」的动画，确认框随行一起消失、行又弹回来和别的卡片重叠
        .modifier(SwipeAction(edge: .trailing, action: selecting ? nil : SwipeAction.Item(title: "删除", glyph: .trash, tint: Color.clayInk) {
            deleting = item
        }))
        .modifier(SwipeAction(edge: .leading, action: selecting ? nil : leadingAction(item)))
        .listRowInsets(EdgeInsets(top: 4, leading: 16 + inset, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// 右滑：下载中给「暂停」，暂停 / 失败给「继续」，已完成没有（不注册空的右滑，免得出现错位的按钮）
    private func leadingAction(_ item: DownloadItem) -> SwipeAction.Item? {
        if item.status.isActive {
            return SwipeAction.Item(title: "暂停", glyph: .pause, tint: Color.ink2) { app.downloads.pause(item) }
        }
        if item.status == .paused || item.status == .failed {
            return SwipeAction.Item(title: "继续", glyph: .play, tint: Color.success) { app.downloads.resume(item) }
        }
        return nil
    }

    /// 一组任务的标题卡片：点按展开 / 收起，展开后成员卡片略向内缩进；多选模式下点标题勾选整组
    private func groupHeader(_ group: DownloadGroup, _ members: [DownloadItem]) -> some View {
        let open = expanded.contains(group.id)
        let ids = Set(members.map(\.id))
        let allOn = ids.isSubset(of: selection)
        return HStack(spacing: 12) {
            if selecting { SelectMark(on: allOn) }
            GroupHeader(title: group.title, items: members)
            Spacer(minLength: 0)
            IconView(.chevronRight, size: 14)
                .foregroundStyle(Color.ink3)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            if selecting {
                if allOn { selection.subtract(ids) } else { selection.formUnion(ids) }
            } else {
                withAnimation(.snappy(duration: 0.25)) {
                    if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                }
            }
        }
        .contextMenu { groupMenu(members) }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(open ? "收起" : "展开")
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func groupMenu(_ members: [DownloadItem]) -> some View {
        Button { app.downloads.resume(members.filter { $0.status == .paused || $0.status == .failed }) } label: {
            Label("全部继续", glyph: .play)
        }
        Button { app.downloads.pause(members.filter(\.status.isActive)) } label: { Label("全部暂停", glyph: .pause) }
        Menu {
            Button("删除任务和文件", role: .destructive) { app.downloads.remove(members, deleteFile: true) }
            Button("仅删除记录") { app.downloads.remove(members, deleteFile: false) }
        } label: { Label("删除这一组", glyph: .trash) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !app.downloads.items.isEmpty {
                    SummaryCard(items: app.downloads.items, samples: samples)
                        .plainListRow(top: 4, bottom: 6)
                    filterChips
                        .plainListRow(top: 4, bottom: 8)
                }
                if items.isEmpty { emptyState.plainListRow(top: 0, bottom: 0) }
                ForEach(entries) { entry in
                    switch entry {
                    case .single(let item):
                        row(item)
                    case .group(let group, let members):
                        groupHeader(group, members)
                        if expanded.contains(group.id) {
                            ForEach(members) { row($0, inset: 14) }
                        }
                    }
                }
                Color.clear.frame(height: selecting ? 96 : 16).plainListRow(top: 0, bottom: 0)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background(Color.paper)
            .navigationTitle("下载")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selecting {
                        Button(selection.count == items.count ? "全不选" : "全选") {
                            selection = selection.count == items.count ? [] : Set(items.map(\.id))
                        }
                        Button("完成") { withAnimation(.snappy(duration: 0.25)) { selecting = false; selection = [] } }.fontWeight(.semibold)
                    } else {
                        Menu {
                            Button { withAnimation(.snappy(duration: 0.25)) { selecting = true } } label: { Label("选择", glyph: .checkCircle) }
                            Button { app.downloads.resumeAll() } label: { Label("全部继续", glyph: .play) }
                            Button { app.downloads.pauseAll() } label: { Label("全部暂停", glyph: .pause) }
                            Button(role: .destructive) { confirmClear = true } label: {
                                Label("清除已完成记录", glyph: .trash)
                            }
                            .disabled(!app.downloads.items.contains { $0.status == .completed })
                        } label: { Image(icon: .more).foregroundStyle(Color.ink) }
                        .accessibilityLabel("更多")
                        .disabled(app.downloads.items.isEmpty)
                        .rowDialog("清除已完成的记录？", isPresented: $confirmClear, message: "只清除列表里的记录，已下载的文件保留") {
                            Button("清除记录", role: .destructive) { app.downloads.clearFinished() }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { selectionBar.padding(.horizontal, 16).padding(.bottom, 8) }
            }
            .sensoryFeedback(.selection, trigger: selection)
            .task { await sampleSpeed() }
            .fullScreenCover(item: Binding(get: { previewURL.map(IdentifiedURL.init) }, set: { previewURL = $0?.url })) { item in
                FilePreviewView(url: item.url)
            }
            .sheet(item: $debugging) { item in
                DownloadDebugView(itemId: item.id)
            }
        }
    }

    /// 多选时底部的浮动操作条
    private var selectionBar: some View {
        let chosen = app.downloads.items.filter { selection.contains($0.id) }
        let canPause = chosen.contains { $0.status.isActive }
        let canResume = chosen.contains { $0.status == .paused || $0.status == .failed }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chosen.isEmpty ? "未选择" : "已选 \(chosen.count) 项").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
                let size = chosen.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
                if size > 0 { Text(ByteFormat.string(size)).font(.monoSmall).foregroundStyle(Color.ink3) }
            }
            Spacer(minLength: 0)
            if canResume {
                Button { app.downloads.resume(chosen.filter { $0.status == .paused || $0.status == .failed }) } label: {
                    IconView(.play, size: 16)
                }
                .buttonStyle(CircleIconButtonStyle(size: 40))
                .accessibilityLabel("继续所选")
            }
            if canPause {
                Button { app.downloads.pause(chosen.filter(\.status.isActive)) } label: { IconView(.pause, size: 16) }
                    .buttonStyle(CircleIconButtonStyle(size: 40))
                    .accessibilityLabel("暂停所选")
            }
            Menu {
                Button("删除任务和文件", role: .destructive) { removeSelected(deleteFiles: true) }
                Button("仅删除记录") { removeSelected(deleteFiles: false) }
            } label: {
                HStack(spacing: 6) { Image(icon: .trash); Text("删除") }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.surface)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Color.clayInk, in: Capsule())
            }
            .disabled(chosen.isEmpty)
            .opacity(chosen.isEmpty ? 0.5 : 1)
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.hairline, lineWidth: 1) }
        .floatingShadow()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func toggle(_ ids: [UUID]) {
        for id in ids {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
    }

    private func removeSelected(deleteFiles: Bool) {
        let chosen = app.downloads.items.filter { selection.contains($0.id) }
        app.downloads.remove(chosen, deleteFile: deleteFiles)
        app.show("已删除 \(chosen.count) 个任务")
        selection = []
        selecting = false
    }

    private var filterChips: some View {
        let all = app.downloads.items
        let active = all.filter { $0.status != .completed }.count
        return HStack(spacing: 8) {
            FilterChip(title: "全部 \(all.count)", selected: filter == .all) { filter = .all }
            FilterChip(title: "进行中 \(active)", selected: filter == .active) { filter = .active }
            FilterChip(title: "已完成 \(all.count - active)", selected: filter == .done) { filter = .done }
            Spacer(minLength: 0)
        }
        .sensoryFeedback(.selection, trigger: filter)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            IconView(.download, size: 28).foregroundStyle(Color.ink3)
            Text(filter == .all ? "还没有下载" : (filter == .active ? "没有进行中的任务" : "还没有完成的任务"))
                .font(.cardTitle)
                .foregroundStyle(Color.ink)
            if filter == .all {
                Text("在「解析」页打开链接，点文件右侧的下载键即可").font(.footnote).foregroundStyle(Color.ink2)
                Button("去解析") { app.selectedTab = .resolve }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    /// 每秒记一次总速度，给速度曲线用；没有任务在下时清空
    private func sampleSpeed() async {
        while !Task.isCancelled {
            let running = app.downloads.items.filter { $0.status == .running }
            if running.isEmpty {
                if !samples.isEmpty { samples = [] }
            } else {
                samples.append(running.reduce(0) { $0 + $1.speed })
                if samples.count > 48 { samples.removeFirst(samples.count - 48) }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func primaryAction(_ item: DownloadItem) {
        switch item.status {
        case .completed:
            guard let url = app.downloads.fileURL(item) else { return }
            if url.hasDirectoryPath || Self.isDirectory(url) { Self.revealInFiles(url) } else { previewURL = url }
        case .running, .queued: app.downloads.pause(item)
        case .paused, .failed: app.downloads.resume(item)
        case .merging: break
        }
    }

    @ViewBuilder
    private func menu(_ item: DownloadItem) -> some View {
        if item.status == .completed, let url = app.downloads.fileURL(item) {
            if Self.isDirectory(url) {
                Button { Self.revealInFiles(url) } label: { Label("在「文件」中查看", glyph: .folder) }
            } else {
                Button { previewURL = url } label: { Label("打开", glyph: .eye) }
            }
            ShareLink(item: url) { Label("分享 / 存储到文件", glyph: .share) }
            if MediaTools.canSaveToPhotos(url) {
                Button {
                    Task {
                        do { try await MediaTools.saveToPhotos(url); app.show("已保存到相册") } catch { app.show(error.localizedDescription, error: true) }
                    }
                } label: { Label("保存到相册", glyph: .image) }
            }
        } else {
            if item.status.isActive {
                Button { app.downloads.pause(item) } label: { Label("暂停", glyph: .pause) }
            } else {
                Button { app.downloads.resume(item) } label: { Label("继续", glyph: .play) }
            }
            if item.request.canRefresh {
                Button { refresh(item) } label: { Label("重新获取直链并继续", glyph: .refresh) }
            }
        }
        Button { UIPasteboard.general.string = item.request.url; app.show("已复制下载地址") } label: {
            Label("复制下载地址", glyph: .link)
        }
        Button { debugging = item } label: { Label("调试信息", glyph: .doc) }
        // 删除放在二级菜单里：选中具体方式就是确认，不再额外弹确认框
        Menu {
            if item.status == .completed {
                Button("删除任务和文件", role: .destructive) { app.downloads.remove(item, deleteFile: true) }
                Button("仅删除记录") { app.downloads.remove(item, deleteFile: false) }
            } else {
                Button("删除任务", role: .destructive) { app.downloads.remove(item, deleteFile: true) }
            }
        } label: { Label("删除", glyph: .trash) }
    }

    /// 多文件种子下完是一个目录：QuickLook 打不开，交给「文件」App 打开那个位置
    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func revealInFiles(_ url: URL) {
        guard let target = URL(string: "shareddocuments://" + url.path) else { return }
        UIApplication.shared.open(target)
    }

    private func refresh(_ item: DownloadItem) {
        refreshing.insert(item.id)
        Task {
            defer { refreshing.remove(item.id) }
            do {
                try await app.downloads.refreshLink(item)
                app.show("已重新获取直链")
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }
}

/// 条件化的左右滑操作：没有操作时不注册该方向的滑动
private struct SwipeAction: ViewModifier {
    struct Item {
        let title: String
        let glyph: Glyph
        let tint: Color
        let run: () -> Void
    }

    let edge: HorizontalEdge
    let action: Item?

    func body(content: Content) -> some View {
        if let action {
            content.swipeActions(edge: edge, allowsFullSwipe: false) {
                Button(action: action.run) { Label(action.title, glyph: action.glyph) }
                    .tint(action.tint)
            }
        } else {
            content
        }
    }
}

private extension View {
    /// plain 列表里不带行底色、分隔线的一行，左右与卡片对齐
    func plainListRow(top: CGFloat, bottom: CGFloat) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

enum DownloadEntry: Identifiable {
    case single(DownloadItem)
    case group(DownloadGroup, [DownloadItem])

    var id: String {
        switch self {
        case .single(let item): return item.id.uuidString
        case .group(let g, _): return "g-" + g.id.uuidString
        }
    }
}

/// 顶部汇总：总速度、预计剩余时间、速度曲线、总进度
private struct SummaryCard: View {
    let items: [DownloadItem]
    let samples: [Double]

    var body: some View {
        let active = items.filter { $0.status.isActive }
        let speed = items.filter { $0.status == .running }.reduce(0) { $0 + $1.speed }
        let total = active.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        let received = active.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let done = items.filter { $0.status == .completed }
        VStack(alignment: .leading, spacing: 12) {
            if active.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(items.contains { $0.status == .failed } ? "有任务未完成" : "全部完成")
                        .font(.cardTitle)
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Text("\(done.count) 个 · \(ByteFormat.string(done.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }))")
                        .font(.mono)
                        .foregroundStyle(Color.ink2)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(ByteFormat.speed(speed))
                        .font(.serif(26, relativeTo: .title))
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: speed)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        let eta = speed > 0 && total > received ? Humanize.eta(Double(total - received) / speed) : ""
                        Text(eta.isEmpty ? "\(active.count) 个进行中" : eta).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
                        if !eta.isEmpty { Text("\(active.count) 个进行中").font(.caption).foregroundStyle(Color.ink3) }
                    }
                }
                Sparkline(values: samples)
                    .frame(height: 40)
                if total > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressLine(value: Double(received) / Double(total))
                        Text("\(ByteFormat.string(received)) / \(ByteFormat.string(total))").font(.monoSmall).foregroundStyle(Color.ink3)
                    }
                }
            }
        }
        .padding(16)
        .card()
    }
}

/// 速度曲线：最近几十秒的总速度，填充一层淡色
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 0, 1)
            let points = values.enumerated().map { index, v in
                CGPoint(x: values.count > 1 ? geo.size.width * CGFloat(index) / CGFloat(values.count - 1) : geo.size.width,
                        y: geo.size.height * (1 - CGFloat(v / peak) * 0.9))
            }
            ZStack {
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(.tint.opacity(0.10))
                    Path { p in p.addLines(points) }
                        .stroke(.tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                } else {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height - 1))
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height - 1))
                    }
                    .stroke(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }
            .animation(.easeOut(duration: 0.6), value: values)
        }
        .accessibilityHidden(true)
    }
}

enum Humanize {
    /// 剩余时间说成人话
    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 10 { return "马上就好" }
        if seconds < 60 { return "不到 1 分钟" }
        if seconds < 3600 { return "还剩约 \(Int((seconds / 60).rounded())) 分钟" }
        if seconds > 86400 * 2 { return "还要很久" }
        let h = Int(seconds / 3600)
        let m = Int((seconds - Double(h) * 3600) / 60)
        return m > 0 ? "还剩约 \(h) 小时 \(m) 分" : "还剩约 \(h) 小时"
    }
}

/// 分组标题：名称 + 完成数 + 合计进度
private struct GroupHeader: View {
    let title: String
    let items: [DownloadItem]

    var body: some View {
        let done = items.filter { $0.status == .completed }.count
        let failed = items.filter { $0.status == .failed }.count
        let total = items.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        let received = items.reduce(Int64(0)) { $0 + ($1.status == .completed ? max(0, $1.totalBytes) : $1.receivedBytes) }
        HStack(spacing: 12) {
            FileIcon(name: title, isDirectory: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                if done < items.count {
                    ProgressLine(value: total > 0 ? min(1, Double(received) / Double(total)) : Double(done) / Double(max(1, items.count)))
                }
                HStack(spacing: 8) {
                    Text("\(done)/\(items.count) 已完成")
                    if failed > 0 { Text("\(failed) 个失败").foregroundStyle(Color.clayInk) }
                    if total > 0 { Text(ByteFormat.string(total)) }
                }
                .font(.monoSmall)
                .foregroundStyle(Color.ink3)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct DownloadRow: View {
    let item: DownloadItem
    var refreshing = false
    var showsControl = true

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(name: item.displayName, isDirectory: isFolder)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayName)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                if item.status != .completed {
                    if let fraction = item.fraction {
                        ProgressLine(value: fraction, tint: item.status == .paused ? Color.ink3 : (item.status == .failed ? Color.clayInk : nil))
                    } else if item.status == .running || item.status == .merging {
                        ProgressLine(value: nil)
                    }
                }
                HStack(spacing: 6) {
                    Text(statusText).foregroundStyle(statusColor)
                    if !item.request.source.isEmpty { Text("· \(item.request.source)") }
                    Spacer(minLength: 0)
                    Text(sizeText).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(Color.ink3)
                if item.status == .failed, let message = item.errorMessage {
                    Text(message).font(.caption2).foregroundStyle(Color.clayInk).lineLimit(3)
                }
                if let exported = item.exportedTo {
                    Label("已移到：\(exported)", glyph: .folder).font(.caption2).foregroundStyle(Color.ink3).lineLimit(2)
                }
            }
            if showsControl {
                DownloadStateControl(item: item, busy: refreshing || item.status == .merging) {}
            }
        }
        .padding(.vertical, 4)
    }

    /// 多文件种子：产物是目录
    private var isFolder: Bool {
        item.outputPath?.hasSuffix("/") == true
    }

    private var statusText: String {
        if case .torrent = item.request.kind, item.status == .running {
            if item.totalBytes <= 0 { return "获取种子信息 · " + (item.note ?? "已连接 \(item.peers) 个节点") }
            let eta = item.totalBytes > item.receivedBytes && item.speed > 0
                ? " · " + Humanize.eta(Double(item.totalBytes - item.receivedBytes) / item.speed) : ""
            return ByteFormat.speed(item.speed) + " · \(item.peers) 个节点" + eta
        }
        switch item.status {
        case .queued: return "排队中"
        case .running:
            let eta = item.totalBytes > item.receivedBytes && item.speed > 0
                ? " · " + Humanize.eta(Double(item.totalBytes - item.receivedBytes) / item.speed) : ""
            if item.backgrounded { return "后台下载中 " + ByteFormat.speed(item.speed) }
            if item.segmentsTotal > 0 { return "分片 \(item.segmentsDone)/\(item.segmentsTotal)" }
            if case .dash = item.request.kind { return (item.phase == 0 ? "视频轨 " : "音轨 ") + ByteFormat.speed(item.speed) }
            return ByteFormat.speed(item.speed) + eta
        case .paused: return "已暂停"
        case .merging: return "合并中"
        case .failed: return "失败"
        case .completed: return item.finishedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "已完成"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .failed: return Color.clayInk
        case .paused: return Color.ink2
        case .completed: return Color.ink3
        default: return Color.ink2
        }
    }

    private var sizeText: String {
        if item.status == .completed || item.totalBytes <= 0 {
            return item.receivedBytes > 0 ? ByteFormat.string(item.receivedBytes) : ""
        }
        if case .dash = item.request.kind { return ByteFormat.string(item.receivedBytes) }
        return "\(ByteFormat.string(item.receivedBytes)) / \(ByteFormat.string(item.totalBytes))"
    }
}
