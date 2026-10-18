// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import WebKit

/// 网页登录：独立的非持久化 WKWebView 会话，登录完成后读取该平台域下的 Cookie，校验后存入钥匙串
struct WebLoginView: View {
    let kind: AccountKind
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var store = WebLoginStore()
    @State private var verifying = false
    @State private var hint: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.progress < 1 {
                    ProgressView(value: store.progress).progressViewStyle(.linear)
                }
                LoginWebView(kind: kind, store: store)
                if let hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .navigationTitle("登录\(kind.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if verifying { ProgressView() } else {
                        Button("完成") { Task { await finish(manual: true) } }
                    }
                }
            }
        }
        .task {
            hint = kind == .quark ? "可用手机号验证码登录；若只显示二维码，可在页面中切换登录方式" : nil
            // 轮询登录态：关键 Cookie 出现即自动校验保存
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if verifying { continue }
                let cookie = await store.cookies(domain: kind.cookieDomain)
                if kind.looksLoggedIn(cookie) {
                    await finish(manual: false)
                    return
                }
            }
        }
    }

    private func finish(manual: Bool) async {
        verifying = true
        defer { verifying = false }
        let cookie = await store.cookies(domain: kind.cookieDomain)
        guard kind.looksLoggedIn(cookie) else {
            if manual { hint = "还没有检测到登录状态，请先在页面中完成登录" }
            return
        }
        if let name = await app.accounts.login(kind, cookie: cookie) {
            app.show("已登录：\(name)")
            dismiss()
        } else if manual {
            hint = "登录状态校验失败，请稍后再点「完成」"
        }
    }
}

@MainActor
@Observable
final class WebLoginStore {
    var progress: Double = 0
    @ObservationIgnored let dataStore = WKWebsiteDataStore.nonPersistent()

    /// 拼出该域（含子域）下的全部 Cookie
    func cookies(domain: String) async -> String {
        let all = await dataStore.httpCookieStore.allCookies()
        return all
            .filter { c in
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                return d == domain || d.hasSuffix("." + domain)
            }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }
}

struct LoginWebView: UIViewRepresentable {
    let kind: AccountKind
    let store: WebLoginStore

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store.dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = kind.loginUserAgent
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observation = webView.observe(\.estimatedProgress, options: [.new]) { view, _ in
            Task { @MainActor in store.progress = view.estimatedProgress }
        }
        webView.load(URLRequest(url: kind.loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observation: NSKeyValueObservation?
    }
}
