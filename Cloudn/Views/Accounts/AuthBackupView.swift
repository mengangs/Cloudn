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

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        SecureField("口令", text: $passphrase)
                        SecureField("再输一次", text: $confirm)
                    } footer: {
                        Text("将导出 \(app.accounts.accounts.count + app.accounts.extras.values.reduce(0) { $0 + $1.count }) 个账号的登录凭据。口令不会被保存，导入时需要同一个口令，请妥善记住。")
                    }
                    if let error { Section { Text(error).foregroundStyle(Color.clayInk) } }
                    if let file {
                        Section {
                            ShareLink(item: file) { Label("分享 / 存储到文件", glyph: .share) }
                        } footer: {
                            Text(file.lastPathComponent)
                        }
                    } else {
                        Section {
                            Button("生成备份文件") { generate() }
                                .disabled(passphrase.count < 6 || passphrase != confirm || app.accounts.accounts.isEmpty)
                        } footer: {
                            Text("口令至少 6 位")
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
    }

    private func generate() {
        do {
            let data = try AuthBackup.export(app.accounts.accounts, extras: app.accounts.extras, passphrase: passphrase)
            file = try AuthBackup.writeTemporaryFile(data)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
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
                    } footer: {
                        Text("导入后会覆盖本机同平台的已登录账号。")
                    }
                    if let error { Section { Text(error).foregroundStyle(Color.clayInk) } }
                    Section {
                        Button(working ? "正在导入…" : "导入") { Task { await restore() } }
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
