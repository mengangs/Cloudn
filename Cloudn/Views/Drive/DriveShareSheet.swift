// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 分享设置：谁能访问、权限、有效期、密码，创建后复制链接；下面列出已有的分享链接，可复制或取消
struct DriveShareSheet: View {
    let manager: DriveManager
    let file: ShareFile
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var options = ShareOptions()
    @State private var usePassword = false
    @State private var existing: [DriveShareInfo] = []
    @State private var loadingExisting = false
    @State private var creating = false
    @State private var revoking: DriveShareInfo?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        if manager.shareAudienceOptions.count > 1 {
                            Picker("谁能访问", selection: $options.audience) {
                                ForEach(manager.shareAudienceOptions) { Text($0.label).tag($0) }
                            }
                        }
                        if manager.shareRoleOptions.count > 1 {
                            Picker("权限", selection: $options.role) {
                                ForEach(manager.shareRoleOptions) { Text($0.label).tag($0) }
                            }
                        }
                        if manager.shareExpiryOptions.count > 1 {
                            Picker("有效期", selection: $options.expiry) {
                                ForEach(manager.shareExpiryOptions) { Text($0.label).tag($0) }
                            }
                        }
                        if manager.supportsSharePassword {
                            Toggle("设置密码", isOn: $usePassword.animation())
                            if usePassword {
                                SecureField("访问密码", text: $options.password)
                                    .textContentType(.newPassword)
                            }
                        }
                    } header: {
                        Text(file.name).textCase(nil).lineLimit(1)
                    } footer: {
                        if !manager.shareOptionsNote.isEmpty { Text(manager.shareOptionsNote) }
                    }

                    Section {
                        Button(action: create) {
                            HStack {
                                Label("创建链接并复制", glyph: .link)
                                Spacer()
                                if creating { Spinner(size: 16) }
                            }
                        }
                        .disabled(creating || (usePassword && options.password.isEmpty))
                    }

                    if manager.supportsShareManagement {
                        Section {
                            if loadingExisting && existing.isEmpty {
                                HStack { Spinner(size: 16); Text("正在读取…").foregroundStyle(Color.ink3) }
                            } else if existing.isEmpty {
                                Text("还没有分享链接").foregroundStyle(Color.ink3)
                            }
                            ForEach(existing) { share in row(share) }
                        } header: {
                            Text("已有的分享")
                        } footer: {
                            Text("取消后，拿到这个链接的人就打不开了。")
                        }
                    }
                }
                .listRowBackground(Color.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .navigationTitle("分享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
            .task { await loadExisting() }
            // 用居中的提示框：确认菜单在表单页里会以气泡形式弹在顶部工具栏旁边
            .alert("取消这个分享链接？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                   presenting: revoking) { share in
                Button("取消分享", role: .destructive) { revoke(share) }
                Button("保留", role: .cancel) {}
            } message: { share in
                if let folder = share.inheritedFrom {
                    Text("这个分享来自上级文件夹「\(folder)」，取消后该文件夹及其中所有文件都不再通过链接公开。")
                } else {
                    Text("取消后，拿到这个链接的人就打不开了。")
                }
            }
            .onAppear {
                if let first = manager.shareExpiryOptions.first { options.expiry = first }
            }
        }
    }

    private func row(_ share: DriveShareInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(share.url).font(.footnote).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
            let details = [share.audience, share.role, share.expires.isEmpty ? "永久" : "\(share.expires) 到期",
                           share.hasPassword ? "有密码" : nil].compactMap { $0 }
            Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(Color.ink3)
            if let folder = share.inheritedFrom {
                Text("来自上级文件夹「\(folder)」").font(.caption).foregroundStyle(Color.clayInk)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button { Clipboard.copy(share.url); app.show("链接已复制") } label: { Label("复制链接", glyph: .link) }
            Button(role: .destructive) { revoking = share } label: { Label("取消分享", glyph: .trash) }
        }
        .swipeActions {
            Button { revoking = share } label: { Label("取消", glyph: .trash) }.tint(Color.swipeDestructive)
            Button { Clipboard.copy(share.url); app.show("链接已复制") } label: { Label("复制", glyph: .link) }.tint(Color.swipeNeutral)
        }
    }

    private func loadExisting() async {
        guard manager.supportsShareManagement else { return }
        loadingExisting = true
        defer { loadingExisting = false }
        do {
            existing = try await manager.existingShares(file)
        } catch {
            app.show(error.localizedDescription, error: true)
        }
    }

    private func create() {
        guard !creating else { return }
        creating = true
        var chosen = options
        if !usePassword { chosen.password = "" }
        Task {
            defer { creating = false }
            do {
                let link = try await manager.createShare([file], options: chosen)
                Clipboard.copy(link.text)
                app.show(chosen.password.isEmpty ? "分享链接已复制" : "分享链接和密码已复制")
                await loadExisting()
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }

    private func revoke(_ share: DriveShareInfo) {
        Task {
            do {
                try await manager.revokeShare(file, id: share.id)
                existing.removeAll { $0.id == share.id }
                app.show("已取消分享")
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }
}
