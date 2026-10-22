// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit
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
                ProgressLine(value: store.progress)
                    .opacity(store.progress < 1 ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: store.progress < 1)
                LoginWebView(kind: kind, store: store)
                    .overlay {
                        if store.loadError == nil && !store.committed {
                            VStack(spacing: 10) {
                                Spinner()
                                Text("正在打开 \(kind.loginURL.host ?? "登录页")…").font(.footnote).foregroundStyle(Color.ink3)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.surface)
                            .allowsHitTesting(false)
                        }
                        if store.blank && store.loadError == nil {
                            VStack(spacing: 12) {
                                IconView(.warning, size: 28).foregroundStyle(Color.clayInk)
                                Text("登录页没有显示内容").font(.headline).foregroundStyle(Color.ink)
                                Text(store.blankHint).font(.footnote).foregroundStyle(Color.ink2).multilineTextAlignment(.center)
                                Button("重试") { store.reload(kind.loginURL) }
                                    .buttonStyle(PillButtonStyle(kind: .primary, height: 42))
                                if !store.desktop && store.lastStatus != 429 && store.lastStatus != 403 {
                                    Button("改用电脑版页面") { store.switchToDesktop(kind.loginURL) }
                                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 42))
                                }
                                Button("复制排查信息") {
                                    Task {
                                        let info = await store.diagnostics()
                                        Clipboard.copy(info)
                                        app.show("已复制排查信息，可以粘贴发给开发者")
                                    }
                                }
                                .font(.footnote.weight(.medium))
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.surface)
                        }
                        if let error = store.loadError {
                            VStack(spacing: 12) {
                                IconView(.warning, size: 28).foregroundStyle(Color.clayInk)
                                Text("登录页打开失败").font(.headline).foregroundStyle(Color.ink)
                                Text(error).font(.footnote).foregroundStyle(Color.ink2).multilineTextAlignment(.center)
                                Button("重试") { store.reload(kind.loginURL) }
                                    .buttonStyle(PillButtonStyle(kind: .primary, height: 42))
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.surface)
                        }
                    }
                if let hint {
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.hairline).frame(height: 1)
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(Color.ink2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    }
                    .background(Color.surface)
                }
            }
            .navigationTitle("登录\(kind.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if verifying { Spinner() } else {
                        Button("完成") { Task { await finish(manual: true) } }
                    }
                }
            }
        }
        .task(id: store.attempt) {
            // 连接被静默丢弃时网页既不报错也不显示：20 秒还没收到页面就当超时
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !store.committed && store.loadError == nil { store.timedOut(kind.loginURL) }
        }
        .task {
            hint = switch kind {
            case .quark: "可用手机号验证码登录；若只显示二维码，可在页面中切换登录方式"
            case .xunlei, .pan123: "在页面中完成登录后会自动识别；如未识别，可点「完成」"
            case .aliyun: "在页面中切换到短信验证码或账号密码登录（二维码要用另一台设备扫），登录后会自动识别"
            case .pixiv: "请用 pixiv 账号密码登录，出现人机验证时在页面里完成；Google / Apple 账号登录在这里无法使用"
            case .tiktok: "选择「使用手机号 / 邮箱 / 用户名登录」；Google / Apple 账号登录在内嵌网页中无法使用"
            case .twitter, .instagram, .threads, .reddit, .facebook: "请用账号密码登录；Google / Apple 账号登录在内嵌网页中无法使用"
            default: nil
            }
            // 轮询登录态：关键凭据出现即自动校验保存；同一份凭据校验失败过就不再重复请求
            var tried = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if verifying { continue }
                let credential = await store.credential(for: kind)
                guard kind.looksLoggedIn(credential), credential != tried else { continue }
                tried = credential
                if await finish(manual: false) { return }
            }
        }
    }

    @discardableResult
    private func finish(manual: Bool) async -> Bool {
        verifying = true
        defer { verifying = false }
        let credential = await store.credential(for: kind)
        guard kind.looksLoggedIn(credential) else {
            if manual { hint = "还没有检测到登录状态，请先在页面中完成登录" }
            return false
        }
        if let name = await app.accounts.login(kind, cookie: credential) {
            app.show("已登录：\(name)")
            dismiss()
            return true
        }
        if manual { hint = "登录状态校验失败，请确认已在页面中完成登录后再点「完成」" }
        return false
    }
}

@MainActor
@Observable
final class WebLoginStore {
    var progress: Double = 0
    /// 页面加载失败的说明（内嵌网页加载失败时只会是一片空白，得自己显示出来）
    var loadError: String?
    /// 已收到页面（开始渲染）；之前显示「正在打开」
    var committed = false
    /// 每次重试加一，用来重新计时
    var attempt = 0
    /// 页面打开了却一片空白（脚本 / 资源没加载出来）
    var blank = false
    var blankHint = ""
    /// 已改用电脑版页面（桌面 UA）
    var desktop = false
    /// 最近一次主页面的 HTTP 状态码与站点（空白时据此说明原因）
    @ObservationIgnored var lastStatus = 0
    @ObservationIgnored var lastHost = ""
    /// 海外平台：连不上时提示开 VPN / 代理；国内网站只提示检查网络
    @ObservationIgnored var overseas = false
    @ObservationIgnored private var blankCheck: Task<Void, Never>?
    @ObservationIgnored let dataStore: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.nonPersistent()
        store.useAppProxy()
        return store
    }()
    @ObservationIgnored weak var webView: WKWebView?

    /// 页面空白时改用电脑版页面：有的站点手机版脚本在内嵌网页里跑不起来
    func switchToDesktop(_ url: URL) {
        desktop = true
        webView?.customUserAgent = VideoHTTP.uaChrome
        Log.info("网页登录：改用电脑版页面")
        reload(url)
    }

    /// 页面加载后隔几秒看有没有内容：空白就记下加载失败的资源，并给出提示
    func scheduleBlankCheck() {
        blankCheck?.cancel()
        blankCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, let webView = self.webView, self.loadError == nil else { return }
            let script = "(function(){var b=document.body;var t=b?(b.innerText||'').trim().length:0;"
                + "var n=document.querySelectorAll('input,button,a').length;"
                + "var e=(window.__cloudnErrors||[]).slice(0,8).join(' | ');return t+'|'+n+'|'+e;})()"
            guard let value = try? await webView.evaluateJavaScript(script) as? String else { return }
            let parts = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            let text = Int(parts.first ?? "") ?? 0
            let controls = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let errors = parts.count > 2 ? parts[2] : ""
            guard text < 5 && controls == 0 else { return }
            Log.error("网页登录：页面空白 \(webView.url?.host ?? "")（加载失败的资源：\(errors.isEmpty ? "无记录" : errors)）")
            let site = self.lastHost.replacingOccurrences(of: "www.", with: "")
            if self.lastStatus == 429 || self.lastStatus == 403 {
                // Instagram 等对它认为可疑的 IP（机房、VPN 出口）直接回 429 / 403 和空页面：换网络环境才行，换页面版本没用
                self.blankHint = "\(site) 拒绝了这次访问（HTTP \(self.lastStatus)），返回的是空页面。"
                    + "这通常是当前网络的出口 IP（VPN / 机房节点）被它限制了，与 App 无关，在 Safari 里打开也会是空白。\n\n"
                    + "请换一个节点（最好是住宅 IP），或关掉 VPN 改用其他网络后重试；稍等一段时间再试也可能恢复。"
                self.blank = true
                return
            }
            self.blankHint = self.overseas
                ? "页面打开了，但脚本或图片资源没有加载出来（常见原因：VPN 只让主站走代理，没包含它的资源域名，如 cdninstagram.com、fbcdn.net）。\n\n可以把 VPN 切到全局模式后重试，或改用电脑版页面。"
                : "页面打开了，但内容没有加载出来，可以重试或改用电脑版页面。"
            self.blank = true
        }
    }

    /// 排查信息（页面结构摘要、出错的脚本 / 资源、UA），同时写进诊断日志
    func diagnostics() async -> String {
        guard let webView else { return "没有网页" }
        let value = (try? await webView.evaluateJavaScript(LoginWebView.diagnosticsScript) as? String) ?? "读取失败"
        let text = "Cloudn 网页登录排查\n系统 iOS \(UIDevice.current.systemVersion) · 电脑版页面 \(desktop ? "是" : "否")\n\(value)"
        Log.info("网页登录：排查信息 \(value)")
        return text
    }

    func reload(_ url: URL) {
        loadError = nil
        blank = false
        lastStatus = 0
        committed = false
        attempt += 1
        Log.info("网页登录：重试打开 \(url.absoluteString)")
        webView?.load(URLRequest(url: url))
    }

    func timedOut(_ url: URL) {
        Log.error("网页登录：打开 \(url.host ?? "") 超时（20 秒没有收到页面）")
        webView?.stopLoading()
        loadError = overseas
            ? "连接 \(url.host ?? "登录页") 超时，没有收到页面。\n\n海外平台在国内网络下无法直接访问，请开启 VPN（全局或让该网站走代理），或在「设置 › 网络代理」里填写代理"
            : "网络连接超时，请检查网络后重试"
    }

    func failed(_ error: Error) {
        let e = error as NSError
        // 主动取消、被新的跳转打断都不算失败
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }
        Log.error("网页登录：页面加载失败 \(e.domain) \(e.code) \(e.localizedDescription)")
        var message = e.localizedDescription
        if e.domain == NSURLErrorDomain, [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                                          NSURLErrorCannotFindHost, NSURLErrorSecureConnectionFailed].contains(e.code), overseas {
            message += "\n\n海外平台在国内网络下无法直接访问，请开启 VPN，或在「设置 › 网络代理」里填写代理"
        }
        loadError = message
    }

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
        store.overseas = OverseasAccount.kinds.contains(kind)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store.dataStore
        let mobileSafari = kind.loginUserAgent == VideoHTTP.uaIPhone
        if mobileSafari {
            // 用 WebKit 自带的 UA（系统版本与内核一致）再补上 Safari 标识：
            // 写死的旧版本号与真实内核对不上时，部分站点（如 Instagram）会给出空白页
            config.applicationNameForUserAgent = "Version/\(Self.safariVersion) Mobile/15E148 Safari/604.1"
        }
        // 记下加载失败的脚本 / 图片等资源，页面空白时写进诊断日志
        config.userContentController.addUserScript(WKUserScript(source: Self.resourceErrorScript, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))
        if let script = kind.loginPageScript {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bouncesZoom = true
        if !mobileSafari { webView.customUserAgent = kind.loginUserAgent }
        webView.navigationDelegate = context.coordinator
        context.coordinator.store = store
        store.webView = webView
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observation = webView.observe(\.estimatedProgress, options: [.new]) { view, _ in
            Task { @MainActor in store.progress = view.estimatedProgress }
        }
        webView.load(URLRequest(url: kind.loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static let resourceErrorScript = """
    (function(){try{window.__cloudnErrors=[];var push=function(m){if(window.__cloudnErrors.length<30)window.__cloudnErrors.push(m);};
      window.addEventListener('error',function(e){var t=e.target;
      var s=t&&(t.src||t.href);if(s){push('res:'+String(s).split('?')[0]);}
      else if(e.message){push('js:'+String(e.message).slice(0,160)+' @'+String(e.filename||'').split('?')[0].slice(-60)+':'+e.lineno);}},true);
      window.addEventListener('unhandledrejection',function(e){var r=e.reason;push('promise:'+String((r&&(r.message||r))||'').slice(0,160));});
      var ce=console.error;console.error=function(){try{push('console:'+Array.prototype.slice.call(arguments).map(String).join(' ').slice(0,160));}catch(x){}
        return ce.apply(console,arguments);};}catch(x){}})()
    """

    /// 页面空白时收集的排查信息：地址、标题、加载状态、页面结构摘要、出错的资源 / 脚本、UA
    static let diagnosticsScript = """
    (function(){var b=document.body;var h=b?b.innerHTML:'';
      return JSON.stringify({url:location.href,title:document.title,ready:document.readyState,
        bodyChars:h.length,text:b?(b.innerText||'').trim().slice(0,200):'',
        html:h.replace(/\\s+/g,' ').slice(0,600),scripts:document.scripts.length,
        sw:('serviceWorker' in navigator),errors:window.__cloudnErrors||[],ua:navigator.userAgent});})()
    """

    /// 强制按桌面宽度渲染
    static func viewportScript(width: Int) -> String {
        """
        (function(){try{
          var m=document.querySelector('meta[name="viewport"]');
          if(!m){m=document.createElement('meta');m.setAttribute('name','viewport');(document.head||document.documentElement).appendChild(m);}
          m.setAttribute('content','width=\(width)');
        }catch(e){}})()
        """
    }

    /// 桌面页面缩放到一屏宽：视口宽度取页面实际内容宽度（至少 1024），打开滚动；单页应用晚渲染，隔一会儿再量两次
    static let fitToWidthScript = """
    (function(){function fit(){try{
      var d=document.documentElement,b=document.body;
      var w=Math.max(d?d.scrollWidth:0,b?b.scrollWidth:0,1024);
      var m=document.querySelector('meta[name="viewport"]');
      if(!m){m=document.createElement('meta');m.setAttribute('name','viewport');(document.head||d).appendChild(m);}
      var c='width='+w+', user-scalable=yes';
      if(m.getAttribute('content')!==c)m.setAttribute('content',c);
      if(!document.getElementById('__cloudn_fit')){var s=document.createElement('style');s.id='__cloudn_fit';
        s.textContent='html,body{overflow:auto !important;-webkit-overflow-scrolling:touch;}'+
          'input,select,textarea{font-size:16px !important;}';(document.head||d).appendChild(s);}
    }catch(e){}}
    fit();setTimeout(fit,800);setTimeout(fit,2500);})()
    """

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

    /// 「18.5」这样的系统主次版本号，对应同版本的 Safari
    static var safariVersion: String {
        UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var observation: NSKeyValueObservation?
        weak var store: WebLoginStore?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Log.info("网页登录：开始打开 \(webView.url?.absoluteString ?? "")")
            Task { @MainActor in store?.loadError = nil }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
                Log.info("网页登录：HTTP \(http.statusCode) \(http.url?.absoluteString ?? "")")
                let status = http.statusCode
                let host = http.url?.host ?? ""
                Task { @MainActor in
                    store?.lastStatus = status
                    store?.lastHost = host
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // 资源被墙时连接挂着不断，didFinish 可能迟迟不来：从开始渲染起也计时检查空白
            Task { @MainActor in
                store?.committed = true
                store?.scheduleBlankCheck()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                store?.committed = true
                store?.scheduleBlankCheck()
            }
            // 页面加载完却没有内容（脚本出错、被拦截）：记下来便于排查
            let probe = "(document.body ? document.body.innerText.length + ' 字 / ' + document.body.children.length + ' 个元素' : '没有 body') + ' · ' + navigator.userAgent"
            webView.evaluateJavaScript(probe) { value, _ in
                Log.info("网页登录：加载完成 \(webView.url?.host ?? "") 内容 \((value as? String) ?? "?")")
            }
        }

        /// 网页进程被系统回收：会白屏，自动重新加载
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Log.error("网页登录：网页进程意外退出，重新加载")
            webView.reload()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in store?.failed(error) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in store?.failed(error) }
        }
    }
}
