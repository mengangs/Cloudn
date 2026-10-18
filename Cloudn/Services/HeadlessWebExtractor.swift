// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import UIKit
import WebKit

/// 隐藏 WKWebView：把页面真跑一遍（过 JS 挑战、触发页面自己的数据请求），再把结果取回来。
/// 必须挂到窗口上：不在视图层级里时 requestAnimationFrame 不触发，页面初始化脚本可能卡住。
struct HeadlessWebExtractor: WebPageExtractor {
    func extract(url: String, userAgent: String, documentStartScripts: [String], readyScript: String,
                 extractScript: String, timeout: TimeInterval) async -> String? {
        await Self.perform(url: url, userAgent: userAgent, scripts: documentStartScripts,
                           readyScript: readyScript, extractScript: extractScript, timeout: timeout)
    }

    @MainActor
    private static func perform(url: String, userAgent: String, scripts: [String], readyScript: String,
                                extractScript: String, timeout: TimeInterval) async -> String? {
        guard let session = HeadlessSession(url: url, userAgent: userAgent, scripts: scripts) else { return nil }
        return await session.run(readyScript: readyScript, extractScript: extractScript, timeout: timeout)
    }
}

@MainActor
final class HeadlessSession: NSObject, WKNavigationDelegate {
    private let webView: WKWebView

    init?(url: String, userAgent: String, scripts: [String]) {
        guard let target = URL(string: url),
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?.windows.first else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let controller = WKUserContentController()
        // 桌面 UA 配套的 navigator.platform，避免页面按 UA/平台不一致判成爬虫
        if userAgent.contains("Windows") {
            controller.addUserScript(WKUserScript(
                source: "try{Object.defineProperty(navigator,'platform',{get:function(){return 'Win32';}});}catch(e){}",
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        for script in scripts {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        config.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = userAgent
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        super.init()
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        holder.clipsToBounds = true
        holder.isUserInteractionEnabled = false
        holder.addSubview(webView)
        window.addSubview(holder)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: target))
    }

    func run(readyScript: String, extractScript: String, timeout: TimeInterval) async -> String? {
        defer { teardown() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return nil }
            if let ready = await evaluate(readyScript) as? Bool, ready {
                return await evaluate(extractScript) as? String
            }
        }
        return nil
    }

    /// 回调版 evaluateJavaScript（async 版本在结果为 undefined 时会抛错），带 3 秒超时
    private func evaluate(_ script: String) async -> Any? {
        await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
            var finished = false
            let finish: (Any?) -> Void = { value in
                guard !finished else { return }
                finished = true
                cont.resume(returning: value)
            }
            webView.evaluateJavaScript(script) { value, _ in finish(value) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    private func teardown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.superview?.removeFromSuperview()
    }
}
