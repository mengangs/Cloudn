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
    /// 下载前探测到的大小 / 时长 / 清晰度
    var info: MediaProbeResult?
    var probing = true

    /// 列表里显示的一行说明：清晰度 · 大小 · 时长
    var detail: String {
        guard let info else { return probing ? "正在获取大小…" : "大小未知" }
        var parts: [String] = []
        if info.height > 0 { parts.append("\(info.height)p") }
        if let size = info.size { parts.append((info.estimated ? "约 " : "") + ByteFormat.string(size)) }
        if let d = info.duration { parts.append(Self.clock(d)) }
        return parts.isEmpty ? "大小未知" : parts.joined(separator: " · ")
    }

    var isPreview: Bool { info?.looksLikePreview ?? false }

    /// 排序用：时长优先，其次大小
    var weight: Double { (info?.duration ?? 0) * 1_000_000_000 + Double(info?.size ?? 0) }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

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
        let sorted = browser.medias.sorted { $0.weight > $1.weight }
        let main = sorted.filter { !$0.isPreview }
        let previews = sorted.filter { $0.isPreview }
        return NavigationStack {
            List {
                Section {
                    ForEach(main) { mediaRow($0) }
                } footer: {
                    Text("时长最长的排在最前面，一般就是正片。没找到正片？先在网页里点播放，真正的视频地址通常在开始播放后才出现。")
                }
                if !previews.isEmpty {
                    Section {
                        ForEach(previews) { mediaRow($0) }
                    } header: {
                        Text("可能是预览片段或广告")
                    } footer: {
                        Text("不到 30 秒或很小的视频，多半是网页上的预览图、广告。")
                    }
                }
            }
            .navigationTitle("发现的媒体")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func mediaRow(_ media: SniffedMedia) -> some View {
        Button { download(media) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(media.label).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text(media.detail).font(.monoSmall).foregroundStyle(media.isPreview ? Color.ink3 : Color.clayInk)
                }
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
        let media = SniffedMedia(url: url, kind: SniffedMedia.classify(url), page: page.isEmpty ? currentURL : page,
                                 title: title.isEmpty ? self.title : title)
        medias.append(media)
        Task { await probe(media) }
    }

    /// 后台探测大小 / 时长，结果回填到列表
    private func probe(_ media: SniffedMedia) async {
        let headers = await headers(for: media)
        let info = await MediaProbe.probe(media.url, headers: headers, isHLS: media.kind == .hls)
        guard let i = medias.firstIndex(where: { $0.id == media.id }) else { return }
        medias[i].info = info
        medias[i].probing = false
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
      // 正片地址常写在页面源码 / 内嵌数据里（含 JSON 转义的斜杠），定时扫一遍
      var scans = 0;
      function scanPage(){
        try {
          var html = document.documentElement ? document.documentElement.outerHTML : '';
          if (html.length > 6000000) return;
          var re = /https?:(?:\\\\?\\/){2}[^"'\\s<>]+?\\.(?:m3u8|mp4|m4v)(?:\\?[^"'\\s<>]*)?/gi, m;
          while ((m = re.exec(html)) !== null) {
            report(m[0].replace(/\\\\\\//g, '/').replace(/\\\\u0026/gi, '&').replace(/&amp;/g, '&'), false);
          }
        } catch (e) {}
      }
      var scanTimer = setInterval(function(){ scanPage(); if (++scans >= 10) clearInterval(scanTimer); }, 3000);
      // 很多网站要点播放才去加载正片：页面加载完后把最大的那个视频静音播放一下
      window.addEventListener('load', function(){
        setTimeout(function(){
          try {
            if (window.top !== window) return;
            var best = null, area = 0;
            document.querySelectorAll('video').forEach(function(v){
              var r = v.getBoundingClientRect(); var a = r.width * r.height;
              if (a > area) { area = a; best = v; }
            });
            if (best && best.paused && area > 40000) {
              best.muted = true;
              var p = best.play(); if (p && p.catch) p.catch(function(){});
            }
          } catch (e) {}
          scanPage();
        }, 1500);
      });
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
