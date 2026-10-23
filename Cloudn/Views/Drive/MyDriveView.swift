// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「我的网盘」入口：容量 + 根目录
struct MyDriveView: View {
    let platform: SharePlatform
    @Environment(AppModel.self) private var app
    @State private var quota: DriveQuota?

    var body: some View {
        if let manager = app.resolvers.manager(for: platform) {
            DriveFolderView(platform: platform, manager: manager, folderId: manager.driveRootId, title: platform.displayName, quota: quota)
                // 从子文件夹返回时 .task 会再跑一次：取到过就不重复请求
                .task { if quota == nil { quota = await manager.quota() } }
        } else {
            ScrollView {
                EmptyStateCard(icon: .cloud, title: "暂不支持", detail: "\(platform.displayName)暂不支持文件管理").padding(16)
            }
            .background(Color.paper)
        }
    }
}

/// 网盘某个目录：浏览、下载、新建文件夹、重命名、移动、删除、分享
struct DriveFolderView: View {
    let platform: SharePlatform
    let manager: DriveManager
    let folderId: String
    let title: String
    var quota: DriveQuota?

    @Environment(AppModel.self) private var app
    @State private var items: [ShareFile] = []
    /// 一开始就算「加载中」：首次请求发出前不闪一下「空文件夹」
    @State private var loading = true
    /// 已加载过：从子文件夹返回时不重新请求（下拉可刷新；增删改、上传完成后会自动刷新）
    @State private var loaded = false
    /// 正在取下载链接的文件（防连点重复加入下载，行尾显示转圈）
    @State private var fetching = Set<String>()
    @State private var errorMessage: String?
    @State private var naming: NamingTarget?
    @State private var nameText = ""
    @State private var moving: ShareFile?
    /// 打开分享设置页的文件（平台支持细分分享设置时）
    @State private var sharing: ShareFile?
    @State private var deleting: ShareFile?
    @State private var busy = false
    @State private var query = ""
    @State private var importingFiles = false
    @State private var pickingMedia = false
    @State private var mediaItems: [PhotosPickerItem] = []
    @State private var preparingMedia = false

    private var uploader: DriveUploader? { app.resolvers.uploader(for: platform) }
    private var offline: DriveOfflineDownloader? { app.resolvers.offline(for: platform) }
    @State private var showingOffline = false
    @State private var mediaPreview: MediaPreviewItem?
    @State private var textPreview: TextPreviewItem?
    @State private var filePreview: RemoteFileItem?
    private var uploads: [UploadStore.Item] { app.uploads.items(in: platform, folder: folderId) }

    private var visibleItems: [ShareFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    enum NamingTarget: Identifiable {
        case newFolder
        case rename(ShareFile)
        var id: String {
            switch self {
            case .newFolder: return "new"
            case .rename(let f): return "rename-" + f.fid
            }
        }
    }

    private var caps: DriveCapabilities { manager.driveCapabilities }

    var body: some View {
        List {
            if let quota, quota.total > 0 {
                Section {
                    QuotaBar(quota: quota)
                        .paperRow()
                }
            }
            if !uploads.isEmpty {
                Section {
                    ForEach(uploads) { UploadRow(item: $0).paperRow() }
                }
            }
            if let errorMessage {
                EmptyStateCard(icon: .warning, title: "加载失败", detail: errorMessage, actionTitle: "重试") { Task { await load() } }.inList()
            } else if items.isEmpty && !loading && uploads.isEmpty {
                EmptyStateCard(icon: .folder, title: "空文件夹", actionTitle: uploader != nil ? "上传文件" : nil) { importingFiles = true }
                    .inList()
            } else if visibleItems.isEmpty && !query.isEmpty {
                EmptyStateCard(icon: .search, title: "没有匹配的文件", detail: "当前文件夹里没有名字包含「\(query)」的文件").inList()
            }
            ForEach(visibleItems) { item in
                row(item)
                .paperRow()
                .rowDialog("删除「\(item.name)」？", isPresented: presenting($deleting) { $0.fid == item.fid },
                           message: "通常可在网盘回收站中找回") {
                    Button("删除", role: .destructive) { perform("已删除") { try await manager.delete([item]) } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .readableWidth()
        .background(Color.paper)
        .overlay { if loading && items.isEmpty { Spinner(size: 28) } }
        .refreshable { await load() }
        .searchable(text: $query, prompt: "在当前文件夹中搜索")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy || preparingMedia {
                    Spinner()
                } else if caps.contains(.createFolder) || uploader != nil || offline != nil {
                    Menu {
                        if caps.contains(.createFolder) {
                            Button { nameText = ""; naming = .newFolder } label: { Label("新建文件夹", glyph: .folderPlus) }
                        }
                        if uploader != nil {
                            Button { importingFiles = true } label: { Label("上传文件", glyph: .arrowUp) }
                            Button { pickingMedia = true } label: { Label("上传照片或视频", glyph: .image) }
                        }
                        if offline != nil {
                            Divider()
                            Button { showingOffline = true } label: { Label("离线下载", glyph: .magnet) }
                        }
                    } label: { Image(icon: .plus) }
                    .accessibilityLabel("新建或上传")
                }
            }
        }
        .documentPicker(isPresented: $importingFiles, types: [.item], multiple: true) { urls in
            guard !urls.isEmpty else { return }
            // 选择器交回的是临时副本：上传完删除
            let files: [(url: URL, temporary: Bool, scoped: Bool)] = urls.map { (url: $0, temporary: true, scoped: false) }
            app.uploads.enqueue(files, platform: platform, folderId: folderId)
        }
        .photosPicker(isPresented: $pickingMedia, selection: $mediaItems, matching: .any(of: [.images, .videos]),
                      preferredItemEncoding: .current)
        .onChange(of: mediaItems) { _, picked in
            guard !picked.isEmpty else { return }
            mediaItems = []
            exportMedia(picked)
        }
        .onChange(of: app.uploads.finishedRevision) { _, _ in Task { await load() } }
        .task {
            guard !loaded else { return }
            await load()
        }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("名称", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("确定") { if let target = naming { commitName(target) } }
                .disabled(nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationDestination(isPresented: $showingOffline) {
            OfflineTasksView(platform: platform, folderId: folderId, folderTitle: title)
        }
        .fullScreenCover(item: $mediaPreview) { MediaPreviewView(item: $0) }
        .fullScreenCover(item: $filePreview) { RemoteFilePreview(item: $0) }
        .sheet(item: $textPreview) { TextPreviewView(item: $0) }
        .sheet(item: $sharing) { file in
            DriveShareSheet(manager: manager, file: file)
        }
        .sheet(item: $moving) { file in
            DriveFolderPicker(platform: platform, manager: manager, excluding: file.fid) { target, _ in
                perform("已移动") { try await manager.move([file], to: target) }
            }
        }
    }

    private var namingTitle: String {
        if case .rename = naming { return "重命名" }
        return "新建文件夹"
    }

    @ViewBuilder
    private func row(_ item: ShareFile) -> some View {
        Group {
            if item.isDirectory {
                NavigationLink {
                    DriveFolderView(platform: platform, manager: manager, folderId: item.fid, title: item.name)
                } label: { label(item) }
            } else {
                // 能预览的点开就看（视频 / 音频 / 图片 / 文本 / 文档），其余直接下载；右侧下载键单独下载
                Button { open(item) } label: { label(item) }
                    .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) {
            if caps.contains(.delete) {
                // 不用 destructive 角色：它会触发列表删除动画，确认框刚弹出就被收回、行又弹回来
                Button { deleting = item } label: { Label("删除", glyph: .trash) }
                    .tint(Color.swipeDestructive)
            }
        }
        .contextMenu {
            if !item.isDirectory {
                if OnlinePreview.supports(item.name) {
                    Button { preview(item) } label: { Label("预览", glyph: .eye) }
                }
                Button { download(item) } label: { Label("下载", glyph: .download) }
            }
            if caps.contains(.share) && !manager.shareAudienceOptions.isEmpty {
                Button { sharing = item } label: { Label("分享设置…", glyph: .link) }
            } else if caps.contains(.share) {
                let options = manager.shareExpiryOptions
                if options.count > 1 {
                    Menu {
                        ForEach(options) { expiry in
                            Button(expiry.label) { share(item, expiry: expiry) }
                        }
                    } label: { Label("创建分享并复制", glyph: .link) }
                } else {
                    Button { share(item, expiry: options.first ?? .forever) } label: { Label("创建分享并复制", glyph: .link) }
                }
            }
            if caps.contains(.rename) {
                Button { nameText = item.name; naming = .rename(item) } label: { Label("重命名", glyph: .pencil) }
            }
            if caps.contains(.move) {
                Button { moving = item } label: { Label("移动到…", glyph: .move) }
            }
            if caps.contains(.delete) {
                Button(role: .destructive) { deleting = item } label: { Label("删除", glyph: .trash) }
            }
        }
    }

    private func label(_ item: ShareFile) -> some View {
        HStack(spacing: 12) {
            FileIcon(name: item.name, isDirectory: item.isDirectory)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(2).truncationMode(.middle).foregroundStyle(Color.ink)
                HStack(spacing: 6) {
                    if !item.isDirectory && item.size > 0 { Text(ByteFormat.string(item.size)) }
                    if !item.modified.isEmpty { Text(FileRow.dateText(item.modified)) }
                }
                .font(.caption).foregroundStyle(Color.ink3)
            }
            Spacer(minLength: 0)
            if fetching.contains(item.fid) {
                Spinner(size: 17)
            } else if !item.isDirectory {
                Button { download(item) } label: {
                    IconView(.download, size: 17).foregroundStyle(Color.ink2).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("下载")
            }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let list = try await manager.listDrive(folderId)
            items = list.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            loaded = true
        } catch {
            // 下拉刷新途中离开页面等被取消的情况不算失败
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ file: ShareFile) {
        if OnlinePreview.supports(file.name) { preview(file) } else { download(file) }
    }

    /// 取直链后按类型预览：媒体在线播放 / 看图，文本在线看，文档下到临时目录用系统预览
    private func preview(_ file: ShareFile) {
        guard !fetching.contains(file.fid) else { return }
        let kind = FileNames.kind(of: file.name)
        if kind == .document, file.size > RemoteFileItem.limit {
            app.show("文件较大，请下载后查看", error: true)
            return
        }
        fetching.insert(file.fid)
        Task {
            defer { fetching.remove(file.fid) }
            do {
                let link = try await manager.driveDownloadLink(file)
                switch kind {
                case .video, .audio, .image:
                    mediaPreview = MediaPreviewItem(url: link.url, headers: link.headers, title: file.name,
                                                    kind: kind == .image ? .image : (kind == .audio ? .audio : .video))
                case .text:
                    textPreview = TextPreviewItem(url: link.url, headers: link.headers, title: file.name)
                default:
                    filePreview = RemoteFileItem(url: link.url, headers: link.headers, name: file.name, size: file.size)
                }
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }

    private func download(_ file: ShareFile) {
        guard !fetching.contains(file.fid) else { return }
        fetching.insert(file.fid)
        Task {
            defer { fetching.remove(file.fid) }
            do {
                let link = try await manager.driveDownloadLink(file)
                app.downloads.enqueue(link: link, platform: platform, folder: "", origin: nil,
                                      refresh: .drive(platform: platform, file: DriveFileRef(file)))
                app.show("已加入下载")
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }

    /// 相册里的照片 / 视频先导出成临时文件（保留原文件名与格式），再加入上传队列
    private func exportMedia(_ picked: [PhotosPickerItem]) {
        preparingMedia = true
        Task {
            defer { preparingMedia = false }
            var files: [(url: URL, temporary: Bool, scoped: Bool)] = []
            for item in picked {
                do {
                    if let f = try await item.loadTransferable(type: PickedMediaFile.self) { files.append((f.url, true, false)) }
                } catch {
                    app.show("读取相册文件失败：\(error.localizedDescription)", error: true)
                }
            }
            if !files.isEmpty { app.uploads.enqueue(files, platform: platform, folderId: folderId) }
        }
    }

    private func share(_ file: ShareFile, expiry: ShareExpiry) {
        perform(nil) {
            let link = try await manager.createShare([file], expiry: expiry)
            Clipboard.copy(link.text)
            app.show(expiry.isForever ? "分享链接已复制" : "分享链接已复制 · \(expiry.label)有效")
        }
    }

    private func commitName(_ target: NamingTarget) {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch target {
        case .newFolder: perform("已新建文件夹") { try await manager.createFolder(name, in: folderId) }
        case .rename(let file): perform("已重命名") { try await manager.rename(file, to: name) }
        }
    }

    /// 执行操作：成功后提示并刷新列表，失败弹错误
    private func perform(_ success: String?, _ action: @escaping () async throws -> Void) {
        // 上一个操作还没结束（连点确认、重复提交）：不再叠加
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                if let success {
                    app.show(success)
                    await load()
                }
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }
}

/// 选择目标文件夹（移动、离线下载的保存位置）；回调给出文件夹 id 与名称
struct DriveFolderPicker: View {
    let platform: SharePlatform
    let manager: DriveManager
    let excluding: String
    var actionVerb = "移动到"
    let onPick: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PickerLevel(manager: manager, folderId: manager.driveRootId, title: platform.displayName, excluding: excluding,
                        actionVerb: actionVerb) { id, title in
                onPick(id, title)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private struct PickerLevel: View {
        let manager: DriveManager
        let folderId: String
        let title: String
        let excluding: String
        let actionVerb: String
        let onPick: (String, String) -> Void
        @State private var folders: [ShareFile] = []
        @State private var loading = true
        @State private var loaded = false
        @State private var errorMessage: String?

        var body: some View {
            List {
                if let errorMessage {
                    EmptyStateCard(icon: .warning, title: "加载失败", detail: errorMessage, actionTitle: "重试") {
                        Task { await load() }
                    }
                    .inList()
                } else if !loading && folders.filter({ $0.fid != excluding }).isEmpty {
                    EmptyStateCard(icon: .folder, title: "这里没有子文件夹", detail: "可以直接\(actionVerb)当前文件夹").inList()
                }
                ForEach(folders.filter { $0.fid != excluding }) { folder in
                    NavigationLink {
                        PickerLevel(manager: manager, folderId: folder.fid, title: folder.name, excluding: excluding, actionVerb: actionVerb, onPick: onPick)
                    } label: {
                        HStack(spacing: 12) {
                            FileIcon(name: folder.name, isDirectory: true)
                            Text(folder.name).lineLimit(2).foregroundStyle(Color.ink)
                        }
                    }
                    .paperRow()
                }
            }
            .paperList()
            .overlay { if loading { Spinner(size: 28) } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button { onPick(folderId, title) } label: {
                    Label("\(actionVerb)「\(title)」", glyph: .move).lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .floatingShadow()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .task {
                // 从下一级返回时不重新请求
                guard !loaded else { return }
                await load()
            }
        }

        private func load() async {
            loading = true
            errorMessage = nil
            defer { loading = false }
            do {
                folders = try await manager.listDrive(folderId).filter(\.isDirectory)
                loaded = true
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// 容量条：已用 / 总量，超过 90% 变成陶土深色提醒
struct QuotaBar: View {
    let quota: DriveQuota
    @Environment(\.dynamicTypeSize) private var typeSize

    private var ratio: Double { quota.total > 0 ? min(1, Double(quota.used) / Double(quota.total)) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 辅助字号下「剩余」换到下一行
            AdaptiveStack(spacing: 4, rowAlignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ByteFormat.string(quota.used)).font(.serif(20, relativeTo: .title3)).foregroundStyle(Color.ink)
                    Text("/ \(ByteFormat.string(quota.total))").font(.mono).foregroundStyle(Color.ink3)
                }
                if !typeSize.isAccessibilitySize { Spacer() }
                Text("剩余 \(ByteFormat.string(max(0, quota.total - quota.used)))").font(.caption).foregroundStyle(Color.ink2)
            }
            ProgressLine(value: ratio, tint: ratio > 0.9 ? Color.clayInk : nil)
        }
        .padding(.vertical, 4)
    }
}

/// 相册导出：系统给的临时文件在回调结束后就会被删，先复制到自己的临时目录
struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMediaFile(url: target)
        }
    }
}

/// 上传中的一行：阶段 + 进度，可取消；失败的可重试
struct UploadRow: View {
    @Environment(AppModel.self) private var app
    let item: UploadStore.Item

    private var statusText: String {
        switch item.status {
        case .waiting: return "等待上传"
        case .failed(let message): return message
        case .cancelled: return "已取消"
        case .done: return "已完成"
        case .running:
            switch item.phase {
            case .hashing: return "校验中 \(Int(item.fraction * 100))%"
            case .uploading: return "上传中 \(Int(item.fraction * 100))% · \(ByteFormat.string(item.size))"
            case .finishing: return "等待网盘处理"
            }
        }
    }

    private var failed: Bool { if case .failed = item.status { return true }; return false }

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(name: item.name)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).lineLimit(1).truncationMode(.middle).font(.subheadline).foregroundStyle(Color.ink)
                if item.status == .running {
                    ProgressLine(value: item.phase == .finishing ? nil : item.fraction)
                }
                Text(statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(failed ? Color.clayInk : Color.ink3)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if failed {
                Button { app.uploads.retry(item.id) } label: { IconView(.refresh, size: 15) }
                    .buttonStyle(CircleIconButtonStyle(size: 32))
                    .accessibilityLabel("重试")
            }
            Button { app.uploads.dismiss(item.id) } label: { IconView(.close, size: 13) }
                .buttonStyle(CircleIconButtonStyle(size: 32))
                .accessibilityLabel(failed ? "移除" : "取消上传")
        }
        .padding(.vertical, 4)
    }
}
