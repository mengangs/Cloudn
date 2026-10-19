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
                switch mode {
                case .password:
                    Section {
                        TextField(provider?.accountHint ?? "账号", text: $account)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $password)
                            .textContentType(.password)
                    } footer: {
                        Text("账号密码只用于本次向\(kind.displayName)发起登录，不会保存；保存的是登录后得到的令牌。")
                    }
                case .sms:
                    Section {
                        TextField("手机号", text: $phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                        HStack {
                            TextField("验证码", text: $code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                            Button(countdown > 0 ? "\(countdown) 秒" : (challenge == nil ? "获取验证码" : "重新获取")) { sendCode() }
                                .disabled(phone.isEmpty || countdown > 0 || working)
                                .buttonStyle(.borderless)
                        }
                    } footer: {
                        if let challenge { Text(challenge.message) }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .paperList()
            .navigationTitle("登录\(kind.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
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
            .task(id: countdown > 0) {
                while countdown > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    countdown -= 1
                }
            }
        }
    }

    private func sendCode() {
        guard let provider else { return }
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
        guard let provider else { return }
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
                self.error = error.localizedDescription
            }
        }
    }
}
