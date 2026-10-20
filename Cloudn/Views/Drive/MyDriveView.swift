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
                .task { quota = await manager.quota() }
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
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var naming: NamingTarget?
    @State private var nameText = ""
    @State private var moving: ShareFile?
    @State private var deleting: ShareFile?
    @State private var busy = false
    @State private var query = ""
    @State private var importingFiles = false
    @State private var pickingMedia = false
    @State private var mediaItems: [PhotosPickerItem] = []
    @State private var preparingMedia = false

    private var uploader: DriveUploader? { app.resolvers.uploader(for: platform) }
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
                EmptyStateCard(icon: .folder, title: "空文件夹").inList()
            } else if visibleItems.isEmpty && !query.isEmpty {
                EmptyStateCard(icon: .search, title: "没有匹配的文件", detail: "当前文件夹里没有名字包含「\(query)」的文件").inList()
            }
            ForEach(visibleItems) { item in
                row(item)
                .paperRow()
                .rowDialog("删除「\(item.name)」？", isPresented: presenting($deleting) { $0.fid == item.fid },
                           message: "删除后可在网盘的回收站中找回（以平台规则为准）") {
                    Button("删除", role: .destructive) { perform("已删除") { try await manager.delete([item]) } }
                }
            }
        }
        .paperList()
        .overlay { if loading && items.isEmpty { Spinner(size: 28) } }
        .refreshable { await load() }
        .searchable(text: $query, prompt: "在当前文件夹中搜索")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy || preparingMedia {
                    Spinner()
                } else if caps.contains(.createFolder) || uploader != nil {
                    Menu {
                        if caps.contains(.createFolder) {
                            Button { nameText = ""; naming = .newFolder } label: { Label("新建文件夹", glyph: .folderPlus) }
                        }
                        if uploader != nil {
                            Button { importingFiles = true } label: { Label("上传文件", glyph: .arrowUp) }
                            Button { pickingMedia = true } label: { Label("上传照片或视频", glyph: .image) }
                        }
                    } label: { Image(icon: .plus) }
                    .accessibilityLabel("新建或上传")
                }
            }
        }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            let files: [(url: URL, temporary: Bool, scoped: Bool)] = urls.map { (url: $0, temporary: false, scoped: true) }
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
        .task { await load() }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("名称", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("确定") { if let target = naming { commitName(target) } }
        }
        .sheet(item: $moving) { file in
            DriveFolderPicker(platform: platform, manager: manager, excluding: file.fid) { target in
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
                Button { download(item) } label: { label(item) }
                    .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) {
            if caps.contains(.delete) {
                Button(role: .destructive) { deleting = item } label: { Label("删除", glyph: .trash) }
                    .tint(Color.clayInk)
            }
        }
        .contextMenu {
            if !item.isDirectory {
                Button { download(item) } label: { Label("下载", glyph: .download) }
            }
            if caps.contains(.share) {
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
            if !item.isDirectory {
                IconView(.download, size: 17).foregroundStyle(Color.ink2)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func download(_ file: ShareFile) {
        perform(nil) {
            let link = try await manager.driveDownloadLink(file)
            app.downloads.enqueue(link: link, platform: platform, folder: "", origin: nil,
                                  refresh: .drive(platform: platform, file: DriveFileRef(file)))
            app.show("已添加到下载")
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
            UIPasteboard.general.string = link.text
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

/// 选择移动目标文件夹
struct DriveFolderPicker: View {
    let platform: SharePlatform
    let manager: DriveManager
    let excluding: String
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PickerLevel(manager: manager, folderId: manager.driveRootId, title: platform.displayName, excluding: excluding) { id in
                onPick(id)
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
        let onPick: (String) -> Void
        @State private var folders: [ShareFile] = []
        @State private var loading = true
        @State private var errorMessage: String?

        var body: some View {
            List {
                if let errorMessage {
                    EmptyStateCard(icon: .warning, title: "加载失败", detail: errorMessage).inList()
                } else if !loading && folders.filter({ $0.fid != excluding }).isEmpty {
                    EmptyStateCard(icon: .folder, title: "这里没有子文件夹", detail: "可以直接移动到当前文件夹").inList()
                }
                ForEach(folders.filter { $0.fid != excluding }) { folder in
                    NavigationLink {
                        PickerLevel(manager: manager, folderId: folder.fid, title: folder.name, excluding: excluding, onPick: onPick)
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
                Button { onPick(folderId) } label: {
                    Label("移动到「\(title)」", glyph: .move).lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .floatingShadow()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .task {
                defer { loading = false }
                do {
                    folders = try await manager.listDrive(folderId).filter(\.isDirectory)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// 容量条：已用 / 总量，超过 90% 变成陶土深色提醒
struct QuotaBar: View {
    let quota: DriveQuota

    private var ratio: Double { quota.total > 0 ? min(1, Double(quota.used) / Double(quota.total)) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(ByteFormat.string(quota.used)).font(.serif(20, relativeTo: .title3)).foregroundStyle(Color.ink)
                Text("/ \(ByteFormat.string(quota.total))").font(.mono).foregroundStyle(Color.ink3)
                Spacer()
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
