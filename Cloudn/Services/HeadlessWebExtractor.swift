// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import UIKit
import WebKit

/// 隐藏 WKWebView：把页面真跑一遍（过 JS 挑战、触发页面自己的数据请求），再把结果取回来。
/// 必须挂到窗口上：不在视图层级里时 requestAnimationFrame 不触发，页面初始化脚本可能卡住。
struct HeadlessWebExtractor: WebPageExtractor {
    func extract(url: String, userAgent: String, cookie: String, documentStartScripts: [String],
                 readyScript: String, extractScript: String, timeout: TimeInterval) async -> String? {
        await Self.perform(url: url, userAgent: userAgent, cookie: cookie, scripts: documentStartScripts,
                           readyScript: readyScript, progressScript: nil, extractScript: extractScript, timeout: timeout)
    }

    /// 批量翻页：轮询时顺带报进度；用户要求提前停止时直接取回已收集的部分
    func extract(url: String, userAgent: String, cookie: String, documentStartScripts: [String],
                 readyScript: String, progressScript: String, extractScript: String, timeout: TimeInterval) async -> String? {
        await Self.perform(url: url, userAgent: userAgent, cookie: cookie, scripts: documentStartScripts,
                           readyScript: readyScript, progressScript: progressScript, extractScript: extractScript, timeout: timeout)
    }

    @MainActor
    private static func perform(url: String, userAgent: String, cookie: String, scripts: [String], readyScript: String,
                                progressScript: String?, extractScript: String, timeout: TimeInterval) async -> String? {
        guard let session = HeadlessSession(url: url, userAgent: userAgent, scripts: scripts) else { return nil }
        await session.start(cookie: cookie)
        return await session.run(readyScript: readyScript, progressScript: progressScript, extractScript: extractScript, timeout: timeout)
    }
}

@MainActor
final class HeadlessSession: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let target: URL
    /// 页面已加载失败（打不开 / 网页进程崩溃）：不再空等到超时，让解析器尽快换别的办法
    private var failed = false
    /// 主框架至少提交过一次导航（页面已有内容）
    private var committed = false

    init?(url: String, userAgent: String, scripts: [String]) {
        guard let target = URL(string: url),
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first?.windows.first else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.websiteDataStore.useAppProxy()
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
        self.target = target
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
    }

    /// 先把登录 Cookie 写进这个临时数据仓库（只在本次会话有效），再开始加载页面
    func start(cookie: String) async {
        if let host = target.host {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            for cookie in Self.cookies(cookie, host: host) {
                await store.setCookie(cookie)
            }
        }
        webView.load(URLRequest(url: target))
    }

    /// `a=1; b=2` → 挂在站点主域（`.facebook.com`）上的 Cookie，子域名页面也带得上
    static func cookies(_ header: String, host: String) -> [HTTPCookie] {
        let labels = host.split(separator: ".")
        let domain = "." + (labels.count > 2 ? labels.suffix(2).joined(separator: ".") : host)
        return header.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return HTTPCookie(properties: [
                .name: name, .value: parts[1].trimmingCharacters(in: .whitespaces),
                .domain: domain, .path: "/", .secure: "TRUE",
            ])
        }
    }

    func run(readyScript: String, progressScript: String? = nil, extractScript: String, timeout: TimeInterval) async -> String? {
        defer { teardown() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return nil }
            if failed {
                // 失败前页面可能已经把数据带回来了：最后看一眼，没有就立即结束
                guard committed, let ready = await evaluate(readyScript) as? Bool, ready else { return nil }
                return await evaluate(extractScript) as? String
            }
            if let ready = await evaluate(readyScript) as? Bool, ready {
                return await evaluate(extractScript) as? String
            }
            if let progressScript {
                CollectionProgress.report(scriptValue: await evaluate(progressScript))
                // 用户点了「停止」：不再等加载完，取回已经收集到的
                if CollectionProgress.isStopRequested { return await evaluate(extractScript) as? String }
            }
        }
        return nil
    }

    // MARK: 导航失败

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committed = true
    }

    /// 还没提交就失败：页面根本没打开（断网、被墙、证书错误）。已有页面后的跳转失败（如页面尝试唤起 App 的自定义协议）不算
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard Self.isFatal(error) else { return }
        if !committed {
            Log.info("隐藏浏览器：页面打开失败 \(error.localizedDescription)")
            failed = true
        }
    }

    /// 主框架加载中途失败
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard Self.isFatal(error) else { return }
        Log.info("隐藏浏览器：页面加载失败 \(error.localizedDescription)")
        failed = true
    }

    /// 网页进程崩溃（内存不足等）：页面已经没了，等下去也不会好
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.info("隐藏浏览器：网页进程已终止")
        committed = false
        failed = true
    }

    /// 被新导航顶掉（-999）、交给下载 / 外部 App（WebKit 102）、不支持的协议都不是真正的失败
    private static func isFatal(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && (ns.code == NSURLErrorCancelled || ns.code == NSURLErrorUnsupportedURL) { return false }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 101 || ns.code == 204) { return false }
        return true
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
