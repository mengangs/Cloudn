// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

extension AppModel {
    /// 已登录、支持离线下载的网盘（按「我的」页的显示顺序）
    var offlineDrives: [SharePlatform] {
        let order = PlatformLayout.ordered(AccountKind.allCases.filter(\.isDrive),
                                           by: UserDefaults.standard.string(forKey: "accounts.driveOrder") ?? "")
        return order.compactMap { kind in
            guard accounts.accounts[kind] != nil, let platform = kind.drivePlatform, resolvers.offline(for: platform) != nil else { return nil }
            return platform
        }
    }
}

/// 离线任务列表：进行中的每几秒刷新一次，右上角添加
struct OfflineTasksView: View {
    let platform: SharePlatform
    let folderId: String
    let folderTitle: String

    @Environment(AppModel.self) private var app
    @State private var tasks: [OfflineTask] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var adding = false

    private var downloader: DriveOfflineDownloader? { app.resolvers.offline(for: platform) }
    private var hasRunning: Bool { tasks.contains { !$0.state.isFinished } }

    var body: some View {
        List {
            if let errorMessage, tasks.isEmpty {
                EmptyStateCard(icon: .warning, title: "加载失败", detail: errorMessage, actionTitle: "重试") {
                    Task { await load() }
                }
                .inList()
            } else if !loading && tasks.isEmpty {
                EmptyStateCard(icon: .magnet, title: "还没有离线任务", detail: "添加磁力或网址链接，由网盘服务器下载，不占手机流量",
                               actionTitle: "添加任务") { adding = true }
                    .inList()
            }
            if !tasks.isEmpty {
                Section {
                    ForEach(tasks) { task in
                        row(task)
                            .paperRow()
                            .swipeActions {
                                Button { remove(task) } label: { Label("删除", glyph: .trash) }.tint(Color.swipeDestructive)
                            }
                    }
                } footer: {
                    if let note = downloader?.offlineNote, !note.isEmpty { Text(note) }
                }
            }
        }
        .paperList()
        .readableWidth()
        .overlay { if loading && tasks.isEmpty { Spinner(size: 28) } }
        .refreshable { await load() }
        .navigationTitle("离线下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(icon: .plus) }
                    .accessibilityLabel("添加离线任务")
            }
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
            AddOfflineTaskView(platform: platform, folderId: folderId, folderTitle: folderTitle)
        }
        // 有进行中的任务时轮询；离开页面自动停止
        .task(id: hasRunning) {
            if tasks.isEmpty && loading { await load() }
            while hasRunning, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
    }

    private func row(_ task: OfflineTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                FileIcon(name: task.name, isDirectory: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.name).font(.subheadline).foregroundStyle(Color.ink).lineLimit(2)
                    Text(detail(task))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(stateColor(task.state))
                        .lineLimit(2)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                if case .done = task.state {
                    IconView(.checkCircle, size: 18).foregroundStyle(Color.success)
                }
            }
            if !task.state.isFinished, let progress = task.progress {
                ProgressLine(value: progress)
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: task.progress)
    }

    private func detail(_ task: OfflineTask) -> String {
        let size = task.size > 0 ? ByteFormat.string(task.size) : nil
        let state: String
        switch task.state {
        case .waiting: state = "排队中"
        case .running: state = task.progress.map { "下载中 \(Int(($0 * 100).rounded()))%" } ?? "下载中"
        case .done: state = "已完成，存在网盘里"
        case .failed(let reason): state = reason.isEmpty ? "失败" : "失败：\(reason)"
        }
        return [state, size].compactMap { $0 }.joined(separator: " · ")
    }

    private func stateColor(_ state: OfflineTaskState) -> Color {
        switch state {
        case .failed: return Color.clayInk
        case .done: return Color.success
        default: return Color.ink2
        }
    }

    private func load() async {
        guard let downloader else { return }
        defer { loading = false }
        do {
            let fresh = try await downloader.offlineTasks()
            if fresh != tasks { tasks = fresh }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ task: OfflineTask) {
        guard let downloader else { return }
        withAnimation(.snappy) { tasks.removeAll { $0.id == task.id } }
        Task {
            do {
                try await downloader.removeOfflineTasks([task.id])
            } catch {
                app.show(error.localizedDescription, error: true)
                await load()
            }
        }
    }
}

/// 添加离线任务：粘贴链接（每行一个）→ 选网盘与保存位置 → 提交
struct AddOfflineTaskView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var platform: SharePlatform?
    @State private var folderId: String
    @State private var folderTitle: String
    @State private var links: String
    @State private var picking = false
    @State private var submitting = false
    @FocusState private var editing: Bool
    /// 从某个网盘目录进来时固定网盘，不显示网盘选择
    private let fixedPlatform: Bool

    init(platform: SharePlatform? = nil, folderId: String? = nil, folderTitle: String? = nil, links: String = "") {
        _platform = State(initialValue: platform)
        _folderId = State(initialValue: folderId ?? "")
        _folderTitle = State(initialValue: folderTitle ?? "")
        _links = State(initialValue: links)
        fixedPlatform = platform != nil
    }

    private var downloader: DriveOfflineDownloader? { platform.flatMap { app.resolvers.offline(for: $0) } }
    private var manager: DriveManager? { platform.flatMap { app.resolvers.manager(for: $0) } }

    private var lines: [String] {
        links.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var unsupported: [String] {
        guard let downloader else { return [] }
        return lines.filter { !downloader.acceptsOffline($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("磁力链接或网址，每行一个", text: $links, axis: .vertical)
                            .lineLimit(3...8)
                            .font(.mono)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($editing)
                    } footer: {
                        if !unsupported.isEmpty {
                            Text("有 \(unsupported.count) 个链接\(platform?.displayName ?? "")不支持离线，将跳过")
                                .foregroundStyle(Color.clayInk)
                        }
                    }

                    Section {
                        if !fixedPlatform {
                            Picker("网盘", selection: $platform) {
                                ForEach(app.offlineDrives) { p in
                                    Text(p.displayName).tag(Optional(p))
                                }
                            }
                        }
                        Button { picking = true } label: {
                            LabeledContent("保存到") {
                                HStack(spacing: 4) {
                                    Text(folderTitle.isEmpty ? "根目录" : folderTitle).lineLimit(1)
                                    IconView(.chevronRight, size: 12)
                                }
                                .foregroundStyle(Color.ink2)
                            }
                        }
                        .foregroundStyle(Color.ink)
                        .disabled(manager == nil)
                    } footer: {
                        if let note = downloader?.offlineNote, !note.isEmpty { Text(note) }
                    }
                }
                .listRowBackground(Color.surface)
            }
            .paperList()
            .navigationTitle("离线下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting { Spinner() } else {
                        Button("添加") { submit() }
                            .disabled(downloader == nil || lines.count == unsupported.count)
                    }
                }
            }
            .sheet(isPresented: $picking) {
                if let platform, let manager {
                    DriveFolderPicker(platform: platform, manager: manager, excluding: "", actionVerb: "保存到") { id, title in
                        folderId = id
                        folderTitle = title
                    }
                }
            }
            .onAppear {
                if platform == nil { platform = app.offlineDrives.first }
                if links.isEmpty { editing = true }
            }
            .onChange(of: platform) { _, _ in
                // 换了网盘：保存位置回到根目录
                guard !fixedPlatform else { return }
                folderId = ""
                folderTitle = ""
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .interactiveDismissDisabled(submitting)
    }

    private func submit() {
        guard let downloader, let platform, !submitting else { return }
        let targets = lines.filter(downloader.acceptsOffline)
        guard !targets.isEmpty else { return }
        let folder = folderId.isEmpty ? (manager?.driveRootId ?? "") : folderId
        submitting = true
        Task {
            defer { submitting = false }
            var added: [String] = []
            var failure: String?
            for link in targets {
                do {
                    let name = try await downloader.addOfflineTask(link, to: folder)
                    added.append(name ?? link)
                } catch {
                    failure = error.localizedDescription
                }
            }
            if added.isEmpty {
                app.show(failure ?? "添加失败", error: true)
                return
            }
            let summary = added.count == 1 ? "已添加离线任务：\(added[0])" : "已添加 \(added.count) 个离线任务"
            app.show(failure.map { "\(summary)，\(targets.count - added.count) 个失败：\($0)" } ?? "\(summary)，可在\(platform.displayName)「离线下载」里查看",
                     error: failure != nil)
            dismiss()
        }
    }
}
