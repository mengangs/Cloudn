// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UniformTypeIdentifiers

/// 导出：设置口令 → 生成加密备份文件 → 分享 / 存到「文件」
struct AuthExportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var file: URL?
    @State private var error: String?
    /// 正在派生密钥、加密（PBKDF2 二十万轮，放在后台算）
    @State private var generating = false

    private var canGenerate: Bool {
        passphrase.count >= 6 && passphrase == confirm && !app.accounts.accounts.isEmpty && !generating
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        SecureField("口令", text: $passphrase)
                            .submitLabel(.next)
                        SecureField("再输一次", text: $confirm)
                            .submitLabel(.done)
                            .onSubmit { if canGenerate && file == nil { generate() } }
                    } footer: {
                        Text("将导出 \(app.accounts.accounts.count + app.accounts.extras.values.reduce(0) { $0 + $1.count }) 个账号的登录凭据。导入时需要同一口令，请牢记。")
                    }
                    if let error { Section { Label(error, glyph: .warning).foregroundStyle(Color.clayInk) } }
                    if let file {
                        Section {
                            ShareLink(item: file) { Label("分享 / 保存到「文件」", glyph: .share) }
                        } footer: {
                            Text(file.lastPathComponent)
                        }
                    } else {
                        Section {
                            Button { generate() } label: {
                                HStack(spacing: 8) {
                                    Text(generating ? "正在生成…" : "生成备份文件")
                                    if generating { Spinner(size: 16) }
                                }
                            }
                            .disabled(!canGenerate)
                        } footer: {
                            // 说清楚为什么按钮不能点
                            if !confirm.isEmpty && passphrase != confirm {
                                Text("两次输入的口令不一致").foregroundStyle(Color.clayInk)
                            } else if !passphrase.isEmpty && passphrase.count < 6 {
                                Text("口令至少 6 位").foregroundStyle(Color.clayInk)
                            } else {
                                Text("口令至少 6 位")
                            }
                        }
                    }
                }
                .listRowBackground(Color.surface)
            }
            .paperList()
            .navigationTitle("导出登录凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        // 改了任一口令，之前生成的文件就不再对应当前口令：作废并删掉，要重新生成
        .onChange(of: passphrase) { discardFile() }
        .onChange(of: confirm) { discardFile() }
        // 临时目录里的备份文件不留在本机
        .onDisappear { discardFile() }
    }

    private func generate() {
        guard canGenerate else { return }
        generating = true
        let accounts = app.accounts.accounts, extras = app.accounts.extras, secret = passphrase
        Task {
            defer { generating = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try AuthBackup.writeTemporaryFile(try AuthBackup.export(accounts, extras: extras, passphrase: secret))
                }.value
                // 生成期间口令又改了：这份作废
                guard secret == passphrase, secret == confirm else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                file = url
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func discardFile() {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
        self.file = nil
    }
}

/// 导入：选文件 → 输入口令 → 解密并覆盖同平台账号
struct AuthImportView: View {
    let data: Data
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        SecureField("备份时设置的口令", text: $passphrase)
                            .submitLabel(.go)
                            .onSubmit { if !passphrase.isEmpty && !working { Task { await restore() } } }
                    } footer: {
                        Text("导入后会覆盖本机同平台的已登录账号。")
                    }
                    if let error { Section { Label(error, glyph: .warning).foregroundStyle(Color.clayInk) } }
                    Section {
                        Button { Task { await restore() } } label: {
                            HStack(spacing: 8) {
                                Text(working ? "正在导入…" : "导入")
                                if working { Spinner(size: 16) }
                            }
                        }
                        .disabled(passphrase.isEmpty || working)
                    }
                }
                .listRowBackground(Color.surface)
            }
            .paperList()
            .navigationTitle("导入登录凭据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }

    private func restore() async {
        working = true
        defer { working = false }
        do {
            // PBKDF2 二十万轮，放到后台算
            let fileData = self.data, secret = self.passphrase
            let restored = try await Task.detached { try AuthBackup.decrypt(fileData, passphrase: secret) }.value
            await app.accounts.restore(restored.accounts, extras: restored.extras)
            app.show("已导入 \(restored.count) 个账号")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
