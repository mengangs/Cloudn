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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("筛选", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if items.isEmpty {
                    ContentUnavailableView("没有下载任务", systemImage: "arrow.down.circle",
                                           description: Text("在「解析」页粘贴链接，选择文件即可下载"))
                        .listRowBackground(Color.clear)
                }
                ForEach(items) { item in
                    DownloadRow(item: item, refreshing: refreshing.contains(item.id))
                        .contentShape(Rectangle())
                        .onTapGesture { primaryAction(item) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = item } label: { Label("删除", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            if item.status.isActive {
                                Button { app.downloads.pause(item) } label: { Label("暂停", systemImage: "pause") }.tint(.orange)
                            } else if item.status == .paused || item.status == .failed {
                                Button { app.downloads.resume(item) } label: { Label("继续", systemImage: "play") }.tint(.green)
                            }
                        }
                        .contextMenu { menu(item) }
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { app.downloads.resumeAll() } label: { Label("全部继续", systemImage: "play") }
                        Button { app.downloads.pauseAll() } label: { Label("全部暂停", systemImage: "pause") }
                        Button(role: .destructive) { app.downloads.clearFinished() } label: {
                            Label("清除已完成记录", systemImage: "checkmark.circle.badge.xmark")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
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
            Button { previewURL = url } label: { Label("打开", systemImage: "eye") }
            ShareLink(item: url) { Label("分享 / 存储到文件", systemImage: "square.and.arrow.up") }
            if MediaTools.canSaveToPhotos(url) {
                Button {
                    Task {
                        do { try await MediaTools.saveToPhotos(url); app.show("已保存到相册") } catch { app.show(error.localizedDescription, error: true) }
                    }
                } label: { Label("保存到相册", systemImage: "photo.on.rectangle") }
            }
        } else {
            if item.status.isActive {
                Button { app.downloads.pause(item) } label: { Label("暂停", systemImage: "pause") }
            } else {
                Button { app.downloads.resume(item) } label: { Label("继续", systemImage: "play") }
            }
            if item.request.origin != nil {
                Button { refresh(item) } label: { Label("重新获取直链并继续", systemImage: "arrow.clockwise") }
            }
        }
        Button { UIPasteboard.general.string = item.request.url; app.show("已复制下载地址") } label: {
            Label("复制下载地址", systemImage: "link")
        }
        Button(role: .destructive) { deleting = item } label: { Label("删除", systemImage: "trash") }
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

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct DownloadRow: View {
    let item: DownloadItem
    var refreshing = false

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(name: item.displayName, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayName)
                    .lineLimit(2)
                    .font(.subheadline.weight(.medium))
                if item.status != .completed {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction).tint(tint)
                    } else if item.status == .running || item.status == .merging {
                        ProgressView().progressViewStyle(.linear).tint(tint)
                    }
                }
                HStack(spacing: 6) {
                    Text(statusText).foregroundStyle(statusColor)
                    if !item.request.source.isEmpty { Text("· \(item.request.source)") }
                    Spacer(minLength: 0)
                    Text(sizeText).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if item.status == .failed, let message = item.errorMessage {
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(3)
                }
            }
            statusIcon
        }
        .padding(.vertical, 4)
    }

    private var tint: Color { item.status == .paused ? .orange : .accentColor }

    @ViewBuilder
    private var statusIcon: some View {
        if refreshing {
            ProgressView()
        } else {
            switch item.status {
            case .running, .queued: Image(systemName: "pause.circle").font(.title2).foregroundStyle(.secondary)
            case .paused: Image(systemName: "play.circle").font(.title2).foregroundStyle(.tint)
            case .failed: Image(systemName: "arrow.clockwise.circle").font(.title2).foregroundStyle(.red)
            case .merging: ProgressView()
            case .completed: Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            }
        }
    }

    private var statusText: String {
        switch item.status {
        case .queued: return "排队中"
        case .running:
            if item.backgrounded { return "后台下载中 " + ByteFormat.speed(item.speed) }
            if item.segmentsTotal > 0 { return "分片 \(item.segmentsDone)/\(item.segmentsTotal)" }
            if case .dash = item.request.kind { return (item.phase == 0 ? "视频轨 " : "音轨 ") + ByteFormat.speed(item.speed) }
            return ByteFormat.speed(item.speed)
        case .paused: return "已暂停"
        case .merging: return "合并中"
        case .failed: return "失败"
        case .completed: return item.finishedAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? "已完成"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .failed: return .red
        case .paused: return .orange
        default: return .secondary
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
