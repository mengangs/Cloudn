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
    @State private var quota: DriveQuota?

    /// 已知大小（文件夹的大小列表里拿不到，不计入）
    private var knownSize: Int64 { files.reduce(0) { $0 + ($1.isDirectory ? 0 : max(0, $1.size)) } }
    private var notEnoughSpace: Bool {
        guard let quota, quota.total > 0 else { return false }
        return knownSize > quota.total - quota.used
    }

    private var root: String { model.saver?.rootFolderId ?? "" }
    private var current: String { path.last?.id ?? root }
    private var platformName: String { model.share.platform.displayName }

    var body: some View {
        NavigationStack {
            List {
                if let quota, quota.total > 0 {
                    Section {
                        QuotaBar(quota: quota).paperRow()
                    } footer: {
                        if notEnoughSpace {
                            Text("剩余空间不足：所选文件约 \(ByteFormat.string(knownSize))").foregroundStyle(Color.clayInk)
                        } else if knownSize > 0 {
                            Text("所选文件约 \(ByteFormat.string(knownSize))")
                        }
                    }
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button { path = [] } label: {
                                HStack(spacing: 5) { IconView(.cloud, size: 14); Text("我的网盘") }
                            }
                            .foregroundStyle(path.isEmpty ? Color.ink : Color.ink2)
                            ForEach(Array(path.enumerated()), id: \.offset) { index, crumb in
                                IconView(.chevronRight, size: 11).foregroundStyle(Color.ink3)
                                Button(crumb.name) { path = Array(path.prefix(index + 1)) }
                                    .lineLimit(1)
                                    .foregroundStyle(index == path.count - 1 ? Color.ink : Color.ink2)
                                    .disabled(index == path.count - 1)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.borderless)
                    }
                    .paperRow()
                } footer: {
                    Text("将转存 \(files.count) 项到当前文件夹")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, glyph: .warning).foregroundStyle(Color.clayInk)
                        Button("重试") { Task { await load() } }
                    }
                    .paperRow()
                } else if folders.isEmpty && !loading {
                    Section { Text("这里没有子文件夹").foregroundStyle(Color.ink3) }.paperRow()
                } else {
                    Section {
                        ForEach(folders) { folder in
                            Button {
                                path.append(Crumb(id: folder.fid, name: folder.name))
                            } label: {
                                HStack(spacing: 12) {
                                    FileIcon(name: folder.name, isDirectory: true)
                                    Text(folder.name).lineLimit(2).foregroundStyle(Color.ink)
                                    Spacer(minLength: 0)
                                    IconView(.chevronRight, size: 14).foregroundStyle(Color.ink3)
                                }
                            }
                            .paperRow()
                        }
                    }
                }
            }
            .paperList()
            .listStyle(.insetGrouped)
            .overlay { if loading && folders.isEmpty { Spinner(size: 28) } }
            .navigationTitle("转存到\(platformName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    // 先同步占住，连点只转存一次
                    guard !saving else { return }
                    saving = true
                    Task { await save() }
                } label: {
                    HStack(spacing: 8) {
                        if saving { Spinner(size: 18, usesForeground: true) } else { Image(icon: .save) }
                        Text(saving ? "正在转存…" : (notEnoughSpace ? "空间可能不足，仍要转存" : "保存到「\(path.last?.name ?? "我的网盘")」")).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(saving || errorMessage != nil)
                .floatingShadow()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .task(id: current) { await load() }
            .task { quota = await app.resolvers.manager(for: model.share.platform)?.quota() }
            .interactiveDismissDisabled(saving)
        }
    }

    private func load() async {
        guard let saver = model.saver else { return }
        let target = current
        loading = true
        errorMessage = nil
        // 进入新目录时先清掉上一层的列表，免得加载期间点到旧的文件夹
        folders = []
        // 被新目录顶掉的旧请求不收加载状态：否则新目录还在加载时会闪一下「这里没有子文件夹」
        defer { if target == current { loading = false } }
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
