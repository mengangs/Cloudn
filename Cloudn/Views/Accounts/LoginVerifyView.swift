// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 迅雷新设备安全验证页的应用内承载，参考 YunX（AGPL-3.0）的 XunleiVerifyWebViewScreen。
import CloudnKit
import SwiftUI
import WebKit

/// 在应用内完成平台要求的网页安全验证；成功后回调，由登录页自动重试
struct LoginVerifyView: View {
    let challenge: LoginVerificationRequired
    let onFinish: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VerifyWebView(challenge: challenge, loading: $loading) { ok in
                onFinish(ok)
                dismiss()
            }
            .overlay(alignment: .top) { if loading { ProgressLine(value: nil) } }
            .navigationTitle("迅雷安全验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onFinish(false); dismiss() }
                }
            }
        }
    }
}

private struct VerifyWebView: UIViewRepresentable {
    let challenge: LoginVerificationRequired
    @Binding var loading: Bool
    let onResult: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // 验证页通过 XLJSWebViewBridge 回传结果：用消息通道接住
        let bridge = """
        window.XLJSWebViewBridge = {
          onVerifyResult: function(s){ window.webkit.messageHandlers.xlverify.postMessage(String(s || '')); },
          close: function(){ window.webkit.messageHandlers.xlverify.postMessage('__close__'); }
        };
        """
        config.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "xlverify")
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = challenge.userAgent
        web.navigationDelegate = context.coordinator
        if let url = URL(string: challenge.url) { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "xlverify")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: VerifyWebView
        private var done = false

        init(_ parent: VerifyWebView) { self.parent = parent }

        private func finish(_ ok: Bool) {
            guard !done else { return }
            done = true
            parent.onResult(ok)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // 只接受可信页面发来的消息
            guard LoginVerificationPolicy.isTrustedPage(message.frameInfo.request.url?.absoluteString) else { return }
            finish((message.body as? String) != "__close__")
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url?.absoluteString
            if LoginVerificationPolicy.isCallback(url) {
                decisionHandler(.cancel)
                finish(true)
                return
            }
            // 只允许留在迅雷的 https 页面里
            decisionHandler(LoginVerificationPolicy.isTrustedPage(url) || url == "about:blank" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            guard LoginVerificationPolicy.isTrustedPage(webView.url?.absoluteString) else { return }
            webView.evaluateJavaScript(parent.challenge.script)
        }
    }
}
