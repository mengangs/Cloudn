// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 选择「我的网盘」里的目标文件夹并转存
struct SaveToDriveView: View {
    let model: ShareBrowserModel
    let files: [ShareFile]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Crumb] = []
    @State private var folders: [ShareFile] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var saving = false

    private var root: String { model.saver?.rootFolderId ?? "" }
    private var current: String { path.last?.id ?? root }
    private var platformName: String { model.share.platform.displayName }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Button { path = [] } label: { Label("我的网盘", systemImage: "externaldrive") }
                            ForEach(Array(path.enumerated()), id: \.offset) { index, crumb in
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                Button(crumb.name) { path = Array(path.prefix(index + 1)) }
                                    .lineLimit(1)
                                    .disabled(index == path.count - 1)
                            }
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    Text("将转存 \(files.count) 项到当前文件夹")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("重试") { Task { await load() } }
                    }
                } else if folders.isEmpty && !loading {
                    Section { Text("这里没有子文件夹").foregroundStyle(.secondary) }
                } else {
                    Section {
                        ForEach(folders) { folder in
                            Button {
                                path.append(Crumb(id: folder.fid, name: folder.name))
                            } label: {
                                HStack(spacing: 12) {
                                    FileIcon(name: folder.name, isDirectory: true)
                                    Text(folder.name).lineLimit(2).foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .paperList()
            .listStyle(.insetGrouped)
            .overlay { if loading && folders.isEmpty { ProgressView() } }
            .navigationTitle("转存到\(platformName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("保存到「\(path.last?.name ?? "我的网盘")」").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saving || errorMessage != nil)
                .padding()
                .background(.bar)
            }
            .task(id: current) { await load() }
            .interactiveDismissDisabled(saving)
        }
    }

    private func load() async {
        guard let saver = model.saver else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        let target = current
        do {
            let list = try await saver.listFolders(target)
            guard target == current else { return }
            folders = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            guard target == current else { return }
            folders = []
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.save(files, to: current)
            app.show("已转存 \(files.count) 项到\(platformName)「\(path.last?.name ?? "我的网盘")」")
            dismiss()
        } catch {
            app.show("转存失败：\(error.localizedDescription)", error: true)
        }
    }
}
