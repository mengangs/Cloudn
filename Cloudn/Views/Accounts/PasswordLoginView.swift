// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 应用内账号密码 / 短信验证码登录（光鸭、迅雷、123、蓝奏云、蓝奏优享）
struct PasswordLoginView: View {
    let kind: AccountKind
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case password = "账号密码", sms = "短信验证码"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .password
    @State private var account = ""
    @State private var password = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var challenge: SMSChallenge?
    @State private var countdown = 0
    @State private var working = false
    @State private var error: String?
    @State private var verification: VerificationItem?
    @FocusState private var field: Field?

    enum Field: Hashable { case account, password, phone, code }

    struct VerificationItem: Identifiable {
        let id = UUID()
        let challenge: LoginVerificationRequired
    }

    private var provider: PasswordLogin? { kind.passwordLogin }

    var body: some View {
        NavigationStack {
            Form {
                if provider?.supportsSMS == true {
                    Section {
                        Picker("登录方式", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }
                }
                Group {
                    switch mode {
                    case .password:
                        Section {
                            TextField(provider?.accountHint ?? "账号", text: $account)
                                .textContentType(.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($field, equals: .account)
                                .submitLabel(.next)
                                .onSubmit { field = .password }
                            SecureField("密码", text: $password)
                                .textContentType(.password)
                                .focused($field, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { if !account.isEmpty && !password.isEmpty { submit() } }
                        } footer: {
                            Text("密码只用于本次登录，不会保存。")
                        }
                    case .sms:
                        Section {
                            TextField("手机号", text: $phone)
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                                .focused($field, equals: .phone)
                            HStack {
                                TextField("验证码", text: $code)
                                    .keyboardType(.numberPad)
                                    .textContentType(.oneTimeCode)
                                    .focused($field, equals: .code)
                                Button(countdown > 0 ? "\(countdown) 秒" : (challenge == nil ? "获取验证码" : "重新获取")) { sendCode() }
                                    .disabled(phone.isEmpty || countdown > 0 || working)
                                    .buttonStyle(.borderless)
                            }
                        } footer: {
                            if let challenge { Text(challenge.message) }
                        }
                    }
                    if let error {
                        Section { Label(error, glyph: .warning).foregroundStyle(Color.clayInk) }
                    }
                }
                .listRowBackground(Color.surface)
            }
            .paperList()
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                // 数字键盘没有回车键：给一个「完成」收起键盘
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { field = nil }
                }
            }
            .navigationTitle("登录\(kind.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { Spinner() } else {
                        Button("登录") { submit() }
                            .disabled(mode == .password ? (account.isEmpty || password.isEmpty) : (challenge == nil || code.isEmpty))
                    }
                }
            }
            .sheet(item: $verification) { item in
                LoginVerifyView(challenge: item.challenge) { ok in
                    if ok {
                        // 设备已通过验证：自动重新登录
                        submit()
                    } else {
                        error = "未完成安全验证；也可以改用短信验证码登录"
                    }
                }
            }
            // 换了登录方式，上一种方式的错误提示不再相关
            .onChange(of: mode) { error = nil }
            .task(id: countdown > 0) {
                while countdown > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    countdown -= 1
                }
            }
        }
        // 登录请求途中不让下滑关掉（结果回来时页面已不在，也不会提示）
        .interactiveDismissDisabled(working)
    }

    private func sendCode() {
        guard let provider, !working else { return }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                challenge = try await provider.sendSMS(phone: phone)
                countdown = 60
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func submit() {
        // 键盘「前往」与工具栏「登录」可能连着触发：上一次还没结束就不再提交
        guard let provider, !working else { return }
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                let credential: String
                switch mode {
                case .password: credential = try await provider.login(account: account, password: password)
                case .sms:
                    guard let challenge else { return }
                    credential = try await provider.loginSMS(challenge, code: code)
                }
                if let name = await app.accounts.login(kind, cookie: credential) {
                    app.show("已登录：\(name)")
                    dismiss()
                } else {
                    error = "登录成功，但凭据校验未通过，请稍后重试"
                }
            } catch let challenge as LoginVerificationRequired {
                verification = VerificationItem(challenge: challenge)
            } catch {
                // 天翼云盘新设备要短信二次验证：自动切到短信页，给绑定手机发验证码
                if kind == .cloud189, mode == .password, error.localizedDescription.contains("验证新设备") {
                    phone = account
                    mode = .sms
                    Task { @MainActor in sendCode() }
                    return
                }
                self.error = error.localizedDescription
            }
        }
    }
}
