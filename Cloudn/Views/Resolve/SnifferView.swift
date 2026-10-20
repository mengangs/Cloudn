// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit
import WebKit

/// 网页里抓到的一条媒体地址
struct SniffedMedia: Identifiable, Equatable {
    enum Kind { case hls, video, audio }
    let id = UUID()
    let url: String
    let kind: Kind
    /// 发现它时所在的页面（下载时作 Referer）
    let page: String
    let title: String

    var label: String {
        switch kind {
        case .hls: return "m3u8 视频流"
        case .video: return "视频"
        case .audio: return "音频"
        }
    }

    static func classify(_ url: String) -> Kind {
        let lower = url.lowercased()
        let path = (URL(string: url)?.path ?? lower).lowercased()
        if path.hasSuffix(".m3u8") || lower.contains(".m3u8?") || lower.contains("mime_type=application/x-mpegurl") { return .hls }
        for ext in [".mp3", ".m4a", ".aac", ".wav", ".ogg", ".flac", ".opus"] where path.hasSuffix(ext) { return .audio }
        return .video
    }
}

/// 网页嗅探：在应用内打开网页，页面播放 / 请求到的音视频地址都列出来，点一下就能下载。
/// 适合没有专门适配的网站；用 MSE 分段播放（blob: 地址）的网站抓不到完整文件。
struct SnifferView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var browser: SnifferBrowser

    init(url: String) {
        _browser = State(initialValue: SnifferBrowser(url: url))
    }

    var body: some View {
        NavigationStack {
            SnifferWebView(browser: browser)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .navigationTitle(browser.title.isEmpty ? "网页嗅探" : browser.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { browser.webView.reload() } label: { Label("刷新", glyph: .refresh) }
                            Button {
                                UIPasteboard.general.string = browser.currentURL
                                app.show("已复制网页地址")
                            } label: { Label("复制网页地址", glyph: .link) }
                            if let url = URL(string: browser.currentURL) {
                                Button { UIApplication.shared.open(url) } label: { Label("在 Safari 中打开", glyph: .share) }
                            }
                        } label: {
                            IconView(.more, size: 20)
                        }
                        .accessibilityLabel("更多")
                    }
                }
                .sheet(isPresented: $browser.showingList) { mediaList.presentationDetents([.medium, .large]) }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack)
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward)
            Spacer()
            Button { browser.showingList = true } label: {
                HStack(spacing: 6) {
                    if browser.loading { Spinner(size: 14) }
                    Text(browser.medias.isEmpty ? "正在查找视频…" : "发现 \(browser.medias.count) 个媒体")
                }
            }
            .buttonStyle(PillButtonStyle(kind: browser.medias.isEmpty ? .secondary : .primary, height: 36))
            .disabled(browser.medias.isEmpty)
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var mediaList: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(browser.medias.reversed()) { media in
                        Button { download(media) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(media.label).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                                Text(media.url).font(.monoSmall).foregroundStyle(Color.ink3).lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = media.url
                                app.show("已复制地址")
                            } label: { Label("复制地址", glyph: .link) }
                        }
                    }
                } footer: {
                    Text("最新发现的在最上面。播放视频后通常会出现真正的视频地址；同一个视频可能有多条（不同清晰度或广告），优先选 m3u8 或文件较长的那条。")
                }
            }
            .navigationTitle("发现的媒体")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func download(_ media: SniffedMedia) {
        Task {
            let headers = await browser.headers(for: media)
            let base = FileNames.base(media.title, fallback: URL(string: media.page)?.host ?? "video")
            let request: DownloadRequest
            switch media.kind {
            case .hls:
                request = DownloadRequest(url: media.url, headers: headers, fileName: base + ".mp4", kind: .hls, source: "网页嗅探")
            case .video, .audio:
                let ext = URL(string: media.url)?.pathExtension.lowercased() ?? ""
                let fallback = media.kind == .audio ? "m4a" : "mp4"
                let name = base + "." + (ext.isEmpty || ext.count > 5 ? fallback : ext)
                request = DownloadRequest(url: media.url, headers: headers, fileName: name, kind: .file, source: "网页嗅探")
            }
            app.downloads.enqueue(request)
            app.show("已添加到下载")
            browser.showingList = false
        }
    }
}

/// 浏览器状态 + WKWebView（页面脚本把发现的媒体地址发回来）
@MainActor
@Observable
final class SnifferBrowser: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    @ObservationIgnored let webView: WKWebView
    private(set) var medias: [SniffedMedia] = []
    private(set) var title = ""
    private(set) var currentURL: String
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var loading = false
    var showingList = false
    @ObservationIgnored private var seen = Set<String>()

    init(url: String) {
        currentURL = url
        let config = WKWebViewConfiguration()
        // 用默认数据存储：在这里登录过的网站下次还在，下载时也能带上它的 Cookie
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.sniffScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        controller.add(WeakMessageHandler(self), name: "cloudnSniff")
        webView.navigationDelegate = self
        if let target = URL(string: url) { webView.load(URLRequest(url: target)) }
    }

    /// 下载时的请求头：页面 UA、页面地址作 Referer、该站点的 Cookie
    func headers(for media: SniffedMedia) async -> [String: String] {
        var headers = ["Referer": media.page]
        if let ua = try? await webView.evaluateJavaScript("navigator.userAgent") as? String { headers["User-Agent"] = ua }
        if let host = URL(string: media.url)?.host?.lowercased() {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let matched = cookies.filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            if !matched.isEmpty { headers["Cookie"] = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
        }
        return headers
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let url = body["url"] as? String else { return }
        add(url: url, page: body["page"] as? String ?? "", title: body["title"] as? String ?? "")
    }

    private func add(url: String, page: String, title: String) {
        guard url.hasPrefix("http"), !seen.contains(url) else { return }
        seen.insert(url)
        medias.append(SniffedMedia(url: url, kind: SniffedMedia.classify(url), page: page.isEmpty ? currentURL : page,
                                   title: title.isEmpty ? self.title : title))
    }

    private func refreshState() {
        title = webView.title ?? ""
        currentURL = webView.url?.absoluteString ?? currentURL
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        refreshState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        refreshState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        refreshState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        refreshState()
    }

    /// 在每个页面（含 iframe）里：监听资源加载、fetch / XHR 请求和 video / audio 元素，
    /// 地址像音视频（扩展名或 m3u8）就发回来；blob: / data: 地址无法下载，跳过
    static let sniffScript = """
    (function(){
      if (window.__cloudnSniff) return; window.__cloudnSniff = true;
      var seen = {};
      var rx = /\\.(m3u8|mp4|m4v|mov|webm|flv|mkv|mp3|m4a|aac|wav|ogg|flac|opus)(\\?|#|$)/i;
      function report(u, fromMedia){
        try {
          if (!u || typeof u !== 'string') return;
          if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
          u = new URL(u, location.href).href;
          if (seen[u]) return;
          if (!fromMedia && !rx.test(u) && !/mime_type=video|mime_type=application\\/x-mpegurl/i.test(u)) return;
          seen[u] = 1;
          window.webkit.messageHandlers.cloudnSniff.postMessage({url: u, page: location.href, title: document.title || ''});
        } catch (e) {}
      }
      try { new PerformanceObserver(function(list){ list.getEntries().forEach(function(e){ report(e.name, false); }); })
              .observe({entryTypes: ['resource']}); } catch (e) {}
      try { (performance.getEntriesByType('resource') || []).forEach(function(e){ report(e.name, false); }); } catch (e) {}
      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function(input){
          try { report(typeof input === 'string' ? input : (input && input.url), false); } catch (e) {}
          return originalFetch.apply(this, arguments);
        };
      }
      var originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url){
        try { report(String(url), false); } catch (e) {}
        return originalOpen.apply(this, arguments);
      };
      setInterval(function(){
        try {
          document.querySelectorAll('video, audio, source').forEach(function(el){ report(el.currentSrc || el.src, true); });
        } catch (e) {}
      }, 1500);
    })();
    """
}

/// WKUserContentController 强引用消息处理者：中间隔一层弱引用，避免浏览器状态永远释放不掉
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private struct SnifferWebView: UIViewRepresentable {
    let browser: SnifferBrowser

    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
