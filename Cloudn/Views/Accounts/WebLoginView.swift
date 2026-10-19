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
            hint = switch kind {
            case .quark: "可用手机号验证码登录；若只显示二维码，可在页面中切换登录方式"
            case .xunlei, .pan123: "在页面中完成登录后会自动识别；如未识别，可点「完成」"
            default: nil
            }
            // 轮询登录态：关键 Cookie 出现即自动校验保存
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if verifying { continue }
                let credential = await store.credential(for: kind)
                if kind.looksLoggedIn(credential) {
                    await finish(manual: false)
                    return
                }
            }
        }
    }

    private func finish(manual: Bool) async {
        verifying = true
        defer { verifying = false }
        let credential = await store.credential(for: kind)
        guard kind.looksLoggedIn(credential) else {
            if manual { hint = "还没有检测到登录状态，请先在页面中完成登录" }
            return
        }
        if let name = await app.accounts.login(kind, cookie: credential) {
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
    @ObservationIgnored weak var webView: WKWebView?

    /// 按平台的读取方式取当前登录凭据（未登录时为空串或不完整的值）
    func credential(for kind: AccountKind) async -> String {
        switch kind.capture {
        case .cookies(let domains):
            return await cookies(domains: domains)
        case .script(let script):
            guard let webView, let value = try? await webView.evaluateJavaScript(script) as? String else { return "" }
            return value
        }
    }

    /// 拼出这些域（含子域）下的全部 Cookie；同名 Cookie 以靠前的域为准
    func cookies(domains: [String]) async -> String {
        let all = await dataStore.httpCookieStore.allCookies()
        var seen = Set<String>()
        var pairs: [String] = []
        for domain in domains {
            for c in all {
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                guard d == domain || d.hasSuffix("." + domain), seen.insert(c.name).inserted else { continue }
                pairs.append("\(c.name)=\(c.value)")
            }
        }
        return pairs.joined(separator: "; ")
    }
}

struct LoginWebView: UIViewRepresentable {
    let kind: AccountKind
    let store: WebLoginStore

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store.dataStore
        if kind == .xunlei {
            // 迅雷登录页是不做响应式的桌面布局：在手机宽度下登录框会被压扁裁掉
            config.userContentController.addUserScript(WKUserScript(source: Self.xunleiRenderFix, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = kind.loginUserAgent
        store.webView = webView
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observation = webView.observe(\.estimatedProgress, options: [.new]) { view, _ in
            Task { @MainActor in store.progress = view.estimatedProgress }
        }
        webView.load(URLRequest(url: kind.loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// 固定较窄的桌面视口、隐藏宣传图、放宽 OAuth iframe（参考 YunX 的 DESKTOP_RENDER_FIX_JS）
    static let xunleiRenderFix = """
    (function(){try{
      var m=document.querySelector('meta[name="viewport"]');
      if(!m){m=document.createElement('meta');m.setAttribute('name','viewport');(document.head||document.documentElement).appendChild(m);}
      m.setAttribute('content','width=520');
      var s=document.createElement('style');
      s.textContent=['html,body{height:auto !important;overflow:visible !important;}',
        '#__nuxt,#__layout,.wrapper,.login-page{height:auto !important;overflow:visible !important;}',
        '.pan-share-web-content .banner-wrap{display:none !important;}',
        '.pan-share-web-content .login-web{width:100% !important;max-width:100% !important;}',
        '.login-web iframe,iframe{width:400px !important;max-width:100% !important;}'].join('');
      (document.head||document.documentElement).appendChild(s);
      window.dispatchEvent(new Event('resize'));
    }catch(e){}})()
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observation: NSKeyValueObservation?
    }
}
