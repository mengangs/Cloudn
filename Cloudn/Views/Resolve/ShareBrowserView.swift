// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

struct ShareBrowserView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ShareBrowserModel
    @State private var actionFile: ShareFile?
    @State private var preview: MediaPreviewItem?
    @State private var retryPwd = ""
    @State private var saveItems: SaveItems?
    @State private var textPreview: TextPreviewItem?
    @State private var query = ""

    /// 当前目录按文件名过滤（不区分大小写）
    private var visibleFiles: [ShareFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.files : model.files.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if let notice = model.guestNotice {
                Section {
                    Label {
                        HStack {
                            Text(notice).font(.footnote)
                            Spacer()
                            Button("去登录") { app.selectedTab = .me }.font(.footnote.weight(.semibold))
                        }
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            if !model.crumbs.isEmpty {
                Section { breadcrumb }
            }
            if let error = model.errorMessage {
                Section { errorView(error) }
            } else if model.files.isEmpty && !model.loading {
                Section {
                    ContentUnavailableView("空文件夹", systemImage: "folder", description: Text("这里没有文件"))
                }
            } else if visibleFiles.isEmpty && !query.isEmpty {
                Section {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                Section {
                    ForEach(visibleFiles) { file in
                        HStack(spacing: 12) {
                            if model.selecting {
                                Image(systemName: model.selection.contains(file.fid) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(model.selection.contains(file.fid) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }
                            FileRow(file: file, busy: model.busyFileIds.contains(file.fid))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { tap(file) }
                        .contextMenu { menu(for: file) }
                    }
                } footer: {
                    Text(summary)
                }
            }
        }
        .paperList()
        .listStyle(.insetGrouped)
        .overlay {
            if model.loading && model.files.isEmpty {
                ProgressView("正在加载…")
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "在当前文件夹中搜索")
        .onChange(of: model.currentDir) { query = "" }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .refreshable { await model.reloadCurrent(force: true) }
        .task { await model.open() }
        .confirmationDialog(actionFile?.name ?? "", isPresented: Binding(get: { actionFile != nil }, set: { if !$0 { actionFile = nil } }),
                            titleVisibility: .visible, presenting: actionFile) { file in
            fileActions(file)
        }
        .sheet(item: $preview) { item in
            MediaPreviewView(item: item)
        }
        .sheet(item: $textPreview) { TextPreviewView(item: $0) }
        .sheet(item: $saveItems) { items in
            SaveToDriveView(model: model, files: items.files)
        }
    }

    /// 打开「转存到我的网盘」；没登录就引导去账号页
    private func startSave(_ files: [ShareFile]) {
        guard !files.isEmpty else { return }
        if model.saveNeedsLogin {
            app.show("转存需要先登录\(model.share.platform.displayName)", error: true)
            app.selectedTab = .me
            return
        }
        saveItems = SaveItems(files: files)
    }

    private var summary: String {
        let dirs = model.files.filter(\.isDirectory).count
        let count = model.files.count - dirs
        let size = model.files.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        var parts: [String] = []
        if dirs > 0 { parts.append("\(dirs) 个文件夹") }
        if count > 0 { parts.append("\(count) 个文件") }
        if size > 0 { parts.append(ByteFormat.string(size)) }
        return parts.joined(separator: " · ")
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button { Task { await model.jump(to: nil) } } label: {
                    Image(systemName: "house")
                }
                ForEach(Array(model.crumbs.enumerated()), id: \.offset) { index, crumb in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(crumb.name) { Task { await model.jump(to: index) } }
                        .lineLimit(1)
                        .disabled(index == model.crumbs.count - 1)
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if model.needsPassword {
                TextField("输入提取码", text: $retryPwd)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await model.retry(with: retryPwd) } }
                Button("重新解析") { Task { await model.retry(with: retryPwd) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(retryPwd.isEmpty)
            } else {
                Button("重试") { Task { await model.reloadCurrent(force: true) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.selecting {
                Button(model.selection.count == model.files.count ? "全不选" : "全选") {
                    model.selection = model.selection.count == model.files.count ? [] : Set(model.files.map(\.fid))
                }
                Button("完成") { model.selecting = false; model.selection = [] }
                    .fontWeight(.semibold)
            } else {
                Button { model.toggleBookmark() } label: {
                    Image(systemName: model.isBookmarked ? "star.fill" : "star")
                }
                .disabled(model.session == nil)
                Menu {
                    Button { model.selecting = true } label: { Label("多选", systemImage: "checkmark.circle") }
                    Button { Task { await model.downloadAll() } } label: { Label("下载当前目录全部", systemImage: "arrow.down.circle") }
                    if model.saver != nil {
                        Button { startSave(model.files) } label: { Label("当前目录全部转存到我的网盘", systemImage: "tray.and.arrow.down") }
                    }
                    Button { UIPasteboard.general.string = model.sourceText; app.show("已复制分享链接") } label: {
                        Label("复制分享链接", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(model.files.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let batch = model.batch {
            HStack(spacing: 12) {
                ProgressView(value: Double(batch.done), total: Double(max(1, batch.total)))
                Text("正在获取直链 \(batch.done)/\(batch.total)").font(.footnote).monospacedDigit()
            }
            .padding()
            .background(.bar)
        } else if model.selecting {
            HStack(spacing: 12) {
                if model.saver != nil {
                    Button {
                        startSave(model.files.filter { model.selection.contains($0.fid) })
                    } label: {
                        Label("转存", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    Task { await model.downloadSelected() }
                } label: {
                    Label("下载所选（\(model.selection.count)）", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .disabled(model.selection.isEmpty)
            .padding()
            .background(.bar)
        }
    }

    private func tap(_ file: ShareFile) {
        if model.selecting {
            if model.selection.contains(file.fid) { model.selection.remove(file.fid) } else { model.selection.insert(file.fid) }
        } else if file.isDirectory {
            Task { await model.enter(file) }
        } else {
            actionFile = file
        }
    }

    @ViewBuilder
    private func menu(for file: ShareFile) -> some View {
        if file.isDirectory {
            Button { Task { await model.enter(file) } } label: { Label("打开", systemImage: "folder") }
            Button { Task { await model.downloadFolder(file) } } label: { Label("下载整个文件夹", systemImage: "arrow.down.circle") }
            if model.saver != nil {
                Button { startSave([file]) } label: { Label("转存到我的网盘", systemImage: "tray.and.arrow.down") }
            }
        } else {
            fileActions(file)
        }
    }

    @ViewBuilder
    private func fileActions(_ file: ShareFile) -> some View {
        Button { run { try await model.download(file); app.show("已添加到下载") } } label: {
            Label("下载", systemImage: "arrow.down.circle")
        }
        let kind = FileNames.kind(of: file.name)
        if kind == .video || kind == .audio || kind == .image {
            Button {
                run {
                    let link = try await model.link(for: file)
                    preview = MediaPreviewItem(url: link.url, headers: link.headers, title: file.name,
                                               kind: kind == .image ? .image : (kind == .audio ? .audio : .video))
                }
            } label: {
                Label(kind == .image ? "预览" : "在线播放", systemImage: kind == .image ? "eye" : "play.circle")
            }
        }
        if kind == .text {
            Button {
                run {
                    let link = try await model.link(for: file)
                    textPreview = TextPreviewItem(url: link.url, headers: link.headers, title: file.name)
                }
            } label: {
                Label("在线查看", systemImage: "doc.text.magnifyingglass")
            }
        }
        Button {
            run {
                let link = try await model.link(for: file)
                UIPasteboard.general.string = link.url
                app.show("已复制直链（需带请求头才能下载）")
            }
        } label: {
            Label("复制直链", systemImage: "link")
        }
        if model.saver != nil {
            Button { startSave([file]) } label: { Label("转存到我的网盘", systemImage: "tray.and.arrow.down") }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { app.show(error.localizedDescription, error: true) }
        }
    }
}

struct FileRow: View {
    let file: ShareFile
    var busy = false

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(name: file.name, isDirectory: file.isDirectory)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .lineLimit(2)
                    .font(.body)
                HStack(spacing: 8) {
                    if !file.isDirectory && file.size > 0 { Text(ByteFormat.string(file.size)) }
                    if !file.modified.isEmpty { Text(Self.dateText(file.modified)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView()
            } else if file.isDirectory {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 接口给的时间可能是毫秒时间戳，也可能已经是文本
    static func dateText(_ raw: String) -> String {
        guard let n = Double(raw) else { return raw }
        let date = Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        return date.formatted(date: .numeric, time: .shortened)
    }
}

/// 待转存的条目（sheet 用）
struct SaveItems: Identifiable {
    let id = UUID()
    let files: [ShareFile]
}
