// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import AuthenticationServices
import CloudnKit
import SwiftUI

/// 微软 / Google 账号登录：用系统的认证页（ASWebAuthenticationSession）走 OAuth，内嵌网页会被这两家拦下。
/// 拿到授权码后换令牌，按普通账号校验保存（令牌之后由解析器自动续期）
struct OAuthLoginView: View {
    let kind: AccountKind
    let provider: OAuthProvider
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var errorText: String?
    @State private var started = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                PlatformTile(mark: .account(kind), size: 64)
                VStack(spacing: 8) {
                    Text("登录\(kind.displayName)").font(.cardTitle).foregroundStyle(Color.ink)
                    Text("会打开\(provider.name)官方登录页，Cloudn 只拿到访问文件的授权，看不到你的密码。")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.ink2)
                }
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.clayInk)
                }
                Button {
                    Task { await start() }
                } label: {
                    HStack(spacing: 8) {
                        if working { Spinner(size: 16) }
                        Text(working ? "正在登录…" : "使用\(provider.name)账号登录")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 50))
                .disabled(working)
                Spacer()
                Text(kind.benefit).font(.footnote).foregroundStyle(Color.ink3).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .task {
                // 打开就直接弹系统登录页，少点一次
                guard !started else { return }
                started = true
                await start()
            }
        }
    }

    private func start() async {
        guard !working else { return }
        working = true
        errorText = nil
        defer { working = false }
        let request = provider.makeRequest()
        do {
            let callback = try await OAuthWebSession.authenticate(url: request.url, scheme: provider.callbackScheme)
            let code = try provider.code(from: callback, request: request)
            let credential = try await provider.exchange(code: code, request: request)
            guard let name = await app.accounts.login(kind, cookie: credential.serialized) else {
                errorText = "登录成功但账号校验失败，请重试"
                return
            }
            app.show("已登录\(kind.displayName) · \(name)")
            dismiss()
        } catch is CancellationError {
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// ASWebAuthenticationSession 的 async 封装：返回回调地址；用户关掉登录页时抛 CancellationError
@MainActor
enum OAuthWebSession {
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
                ?? ASPresentationAnchor()
        }
    }

    private static let anchor = Anchor()
    /// 会话要被持有到结束，否则一出作用域就被释放、登录页闪退
    private static var current: ASWebAuthenticationSession?

    static func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                Task { @MainActor in current = nil }
                if let callback {
                    cont.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    cont.resume(throwing: CancellationError())
                } else {
                    cont.resume(throwing: CloudnError("无法打开登录页：\(error?.localizedDescription ?? "未知错误")"))
                }
            }
            session.presentationContextProvider = anchor
            // 不共用 Safari 的登录状态：每次都能选账号，添加第二个账号也不会自动沿用第一个
            session.prefersEphemeralWebBrowserSession = true
            current = session
            if !session.start() {
                current = nil
                cont.resume(throwing: CloudnError("无法打开登录页"))
            }
        }
    }
}
