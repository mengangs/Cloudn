// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

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
            ContentUnavailableView("暂不支持", systemImage: "externaldrive.badge.xmark", description: Text("\(platform.displayName)暂不支持文件管理"))
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
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(1, Double(quota.used) / Double(quota.total)))
                        Text("已用 \(ByteFormat.string(quota.used)) / 共 \(ByteFormat.string(quota.total))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("重试") { Task { await load() } }
                }
            } else if items.isEmpty && !loading {
                ContentUnavailableView("空文件夹", systemImage: "folder").listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                row(item)
            }
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .refreshable { await load() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if busy { ProgressView() } else if caps.contains(.createFolder) {
                    Button { nameText = ""; naming = .newFolder } label: { Image(systemName: "folder.badge.plus") }
                }
            }
        }
        .task { await load() }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("名称", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("确定") { if let target = naming { commitName(target) } }
        }
        .confirmationDialog("删除「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { file in
            Button("删除", role: .destructive) { perform("已删除") { try await manager.delete([file]) } }
        } message: { _ in
            Text("删除后可在网盘的回收站中找回（以平台规则为准）")
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
                Button(role: .destructive) { deleting = item } label: { Label("删除", systemImage: "trash") }
            }
        }
        .contextMenu {
            if !item.isDirectory {
                Button { download(item) } label: { Label("下载", systemImage: "arrow.down.circle") }
            }
            if caps.contains(.share) {
                Button { share(item) } label: { Label("创建分享并复制", systemImage: "link") }
            }
            if caps.contains(.rename) {
                Button { nameText = item.name; naming = .rename(item) } label: { Label("重命名", systemImage: "pencil") }
            }
            if caps.contains(.move) {
                Button { moving = item } label: { Label("移动到…", systemImage: "folder") }
            }
            if caps.contains(.delete) {
                Button(role: .destructive) { deleting = item } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    private func label(_ item: ShareFile) -> some View {
        HStack(spacing: 12) {
            FileIcon(name: item.name, isDirectory: item.isDirectory)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(2)
                HStack(spacing: 6) {
                    if !item.isDirectory && item.size > 0 { Text(ByteFormat.string(item.size)) }
                    if !item.modified.isEmpty { Text(item.modified) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !item.isDirectory {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
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
            app.downloads.enqueue(link: link, platform: platform, folder: "", origin: nil)
            app.show("已添加到下载")
        }
    }

    private func share(_ file: ShareFile) {
        perform(nil) {
            let link = try await manager.createShare([file])
            UIPasteboard.general.string = link.text
            app.show("分享链接已复制")
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
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ForEach(folders.filter { $0.fid != excluding }) { folder in
                    NavigationLink {
                        PickerLevel(manager: manager, folderId: folder.fid, title: folder.name, excluding: excluding, onPick: onPick)
                    } label: {
                        HStack(spacing: 12) {
                            FileIcon(name: folder.name, isDirectory: true)
                            Text(folder.name).lineLimit(2)
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button { onPick(folderId) } label: { Text("移动到「\(title)」").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                    .background(.bar)
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
