// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: Filter = .all
    @State private var previewURL: URL?
    @State private var deleting: DownloadItem?
    @State private var refreshing = Set<UUID>()
    @State private var samples: [Double] = []

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

    private func row(_ item: DownloadItem) -> some View {
        DownloadRow(item: item, refreshing: refreshing.contains(item.id))
            .contentShape(Rectangle())
            .onTapGesture { primaryAction(item) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleting = item } label: { Label("删除", glyph: .trash) }
            }
            .swipeActions(edge: .leading) {
                if item.status.isActive {
                    Button { app.downloads.pause(item) } label: { Label("暂停", glyph: .pause) }.tint(Color.ink2)
                } else if item.status == .paused || item.status == .failed {
                    Button { app.downloads.resume(item) } label: { Label("继续", glyph: .play) }.tint(Color.success)
                }
            }
            .contextMenu { menu(item) }
            .paperRow()
    }

    @ViewBuilder
    private func groupMenu(_ members: [DownloadItem]) -> some View {
        Button { members.filter { $0.status == .paused || $0.status == .failed }.forEach(app.downloads.resume) } label: {
            Label("全部继续", glyph: .play)
        }
        Button { members.filter(\.status.isActive).forEach(app.downloads.pause) } label: { Label("全部暂停", glyph: .pause) }
        Button(role: .destructive) { members.forEach { app.downloads.remove($0, deleteFile: false) } } label: {
            Label("删除这一组记录（保留已下载文件）", glyph: .trash)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !app.downloads.items.isEmpty {
                    Section {
                        SummaryCard(items: app.downloads.items, samples: samples)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                        filterChips
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                    .listRowSeparator(.hidden)
                }
                if items.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(entries) { entry in
                        switch entry {
                        case .single(let item):
                            row(item)
                        case .group(let group, let members):
                            DisclosureGroup {
                                ForEach(members) { row($0) }
                            } label: {
                                GroupHeader(title: group.title, items: members)
                            }
                            .contextMenu { groupMenu(members) }
                            .paperRow()
                        }
                    }
                }
            }
            .paperList()
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { app.downloads.resumeAll() } label: { Label("全部继续", glyph: .play) }
                        Button { app.downloads.pauseAll() } label: { Label("全部暂停", glyph: .pause) }
                        Button(role: .destructive) { app.downloads.clearFinished() } label: {
                            Label("清除已完成记录", glyph: .trash)
                        }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(Color.ink) }
                    .disabled(app.downloads.items.isEmpty)
                }
            }
            .task { await sampleSpeed() }
            .sheet(item: Binding(get: { previewURL.map(IdentifiedURL.init) }, set: { previewURL = $0?.url })) { item in
                QuickLookPreview(url: item.url).ignoresSafeArea()
            }
            .confirmationDialog("删除任务", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { item in
                if item.status == .completed {
                    Button("删除任务和文件", role: .destructive) { app.downloads.remove(item, deleteFile: true) }
                    Button("仅删除记录") { app.downloads.remove(item, deleteFile: false) }
                } else {
                    Button("删除任务", role: .destructive) { app.downloads.remove(item, deleteFile: true) }
                }
            }
        }
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
        case .completed: previewURL = app.downloads.fileURL(item)
        case .running, .queued: app.downloads.pause(item)
        case .paused, .failed: app.downloads.resume(item)
        case .merging: break
        }
    }

    @ViewBuilder
    private func menu(_ item: DownloadItem) -> some View {
        if item.status == .completed, let url = app.downloads.fileURL(item) {
            Button { previewURL = url } label: { Label("打开", glyph: .eye) }
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
            if item.request.origin != nil {
                Button { refresh(item) } label: { Label("重新获取直链并继续", glyph: .refresh) }
            }
        }
        Button { UIPasteboard.general.string = item.request.url; app.show("已复制下载地址") } label: {
            Label("复制下载地址", glyph: .link)
        }
        Button(role: .destructive) { deleting = item } label: { Label("删除", glyph: .trash) }
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
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0)], startPoint: .top, endPoint: .bottom))
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

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(name: item.displayName)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayName)
                    .lineLimit(2)
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
            DownloadStateControl(item: item, busy: refreshing || item.status == .merging) {}
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
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
