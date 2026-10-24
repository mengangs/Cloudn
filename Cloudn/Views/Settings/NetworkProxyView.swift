// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 设置页：应用内网络代理（HTTP / SOCKS5）
struct NetworkProxyView: View {
    @Environment(AppModel.self) private var app
    @State private var host = ""
    @State private var port = ""
    @State private var testing = false
    /// 测试结果：成功为毫秒数，失败为错误说明
    @State private var result: Result<Int, TestFailure>?

    struct TestFailure: Error { let message: String }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Group {
                Section {
                    Toggle("使用代理", isOn: $settings.proxyEnabled)
                    if settings.proxyEnabled {
                        Picker("类型", selection: $settings.proxyKind) {
                            ForEach(NetworkProxy.Kind.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        LabeledContent("地址") {
                            TextField("127.0.0.1", text: $host)
                                .multilineTextAlignment(.trailing)
                                .font(.mono)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .onSubmit(commit)
                        }
                        LabeledContent("端口") {
                            // 数字键盘没有回车键：停止输入片刻后自动保存（见下方 task(id: port)）
                            TextField("7890", text: $port)
                                .multilineTextAlignment(.trailing)
                                .font(.mono)
                                .keyboardType(.numberPad)
                        }
                    }
                } footer: {
                    Text("关闭时跟随系统网络（含 VPN 与系统代理）。开启后解析、下载、上传和网页登录都走此代理；已打开的网页需重开，后台下载需重新打开应用后生效。磁力（BT）不走此代理。")
                }

                if settings.proxyEnabled {
                    Section {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack {
                                Text(testing ? "正在测试…" : "测试连接")
                                Spacer()
                                if testing {
                                    Spinner(size: 18)
                                } else if let result {
                                    switch result {
                                    case .success(let ms): Text("GitHub \(ms) ms").font(.figures).foregroundStyle(Color.success)
                                    case .failure(let f): Text(f.message).font(.footnote).foregroundStyle(Color.clayInk).lineLimit(2)
                                    }
                                }
                            }
                        }
                        .disabled(testing || draft == nil)
                    } footer: {
                        if draft == nil { Text("填写地址和端口（1–65535）后可测试。") }
                    }
                }
            }
            .listRowBackground(Color.surface)
        }
        .scrollContentBackground(.hidden)
        .readableWidth()
        .background(Color.paper)
        .navigationTitle("网络代理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            host = app.settings.proxyHost
            port = String(app.settings.proxyPort)
        }
        .onDisappear(perform: commit)
        .onChange(of: app.settings.proxyKind) { result = nil }
        .onChange(of: host) { result = nil }
        .onChange(of: port) { result = nil }
        .task(id: port) {
            // 端口停止输入 0.8 秒后写入设置（逐字写入会让网络会话跟着反复重建）
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            commitPort()
        }
    }

    private var draft: NetworkProxy? {
        let p = NetworkProxy(kind: app.settings.proxyKind, host: host.trimmingCharacters(in: .whitespaces), port: Int(port) ?? 0)
        return p.isValid ? p : nil
    }

    /// 地址、端口改完再写入设置（逐字写入会让网络会话跟着反复重建）
    private func commit() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed != app.settings.proxyHost { app.settings.proxyHost = trimmed }
        commitPort()
    }

    private func commitPort() {
        if let p = Int(port), (1...65535).contains(p), p != app.settings.proxyPort { app.settings.proxyPort = p }
    }

    private func test() async {
        commit()
        testing = true
        defer { testing = false }
        let start = Date()
        do {
            let r = try await HTTPClient.shared.send(HTTPRequest(url: "https://github.com", method: "HEAD", timeout: 10))
            if r.status < 500 {
                result = .success(Int(Date().timeIntervalSince(start) * 1000))
            } else {
                result = .failure(TestFailure(message: "HTTP \(r.status)"))
            }
        } catch {
            result = .failure(TestFailure(message: "连接失败：\(error.localizedDescription)"))
        }
    }
}
