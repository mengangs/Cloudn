// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 连接 WebDAV 服务器（坚果云、NAS、OpenList 等）：地址 + 用户名 + 密码，校验能列出根目录后保存
struct WebDAVLoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var field: Field?

    enum Field: Hashable { case url, username, password }

    /// 常见服务的地址，点一下填入
    private let presets: [(String, String)] = [
        ("坚果云", "https://dav.jianguoyun.com/dav/"),
        ("OpenList / Alist", "http://192.168.1.2:5244/dav/"),
    ]

    private var canSubmit: Bool {
        !working && URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true && !username.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("服务器地址，如 https://dav.example.com/dav/", text: $url)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($field, equals: .url)
                            .submitLabel(.next)
                            .onSubmit { field = .username }
                        TextField("用户名", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($field, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { field = .password }
                        SecureField("密码 / 应用密码", text: $password)
                            .textContentType(.password)
                            .focused($field, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { if canSubmit { submit() } }
                    } footer: {
                        Text("坚果云需在网页版「账户信息 › 安全选项」里生成应用密码。地址、用户名和密码只保存在本机钥匙串。")
                    }
                    Section("常用地址") {
                        ForEach(presets, id: \.1) { name, address in
                            Button {
                                url = address
                                field = .username
                            } label: {
                                LabeledContent(name) {
                                    Text(address).font(.footnote).foregroundStyle(Color.ink3).lineLimit(1)
                                }
                            }
                            .foregroundStyle(Color.ink)
                        }
                    }
                    if let error {
                        Section { Text(error).foregroundStyle(Color.clayInk) }
                    }
                }
                .listRowBackground(Color.surface)
            }
            .paperList()
            .navigationTitle("连接 WebDAV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { Spinner() } else {
                        Button("连接") { submit() }.disabled(!canSubmit)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { field = .url }
        }
        .interactiveDismissDisabled(working)
    }

    private func submit() {
        guard canSubmit else { return }
        working = true
        error = nil
        let credential = WebDAVResolver.makeCredential(url: url.trimmingCharacters(in: .whitespaces), username: username, password: password)
        Task {
            defer { working = false }
            if let name = await app.accounts.login(.webdav, cookie: credential) {
                app.show("已连接：\(name)")
                dismiss()
            } else {
                error = "连接失败：请检查地址、用户名和密码"
            }
        }
    }
}
