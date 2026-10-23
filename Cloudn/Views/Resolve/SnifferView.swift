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
        guard seconds.isFinite, seconds >= 0, seconds < 1e9 else { return "--:--" }
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
/// 适合没有专门适配的网站；用 MSE 分段播放（blob: 地址）的网站抓不到完整文件，
/// 但可以「录制视频流」：边播放边把页面喂给播放器的数据存下来。
struct SnifferView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var browser: SnifferBrowser
    /// 正在准备下载的地址（取 Cookie 要等一下）：连点不重复入队
    @State private var enqueuing = Set<String>()
    @Environment(\.dynamicTypeSize) private var typeSize

    init(url: String) {
        _browser = State(initialValue: SnifferBrowser(url: url))
    }

    #if DEBUG
    /// 截图模式：用预先放好演示结果的浏览器
    init(browser: SnifferBrowser) {
        _browser = State(initialValue: browser)
    }
    #endif

    var body: some View {
        NavigationStack {
            SnifferWebView(browser: browser)
                .ignoresSafeArea(edges: .bottom)
                .overlay { if let error = browser.loadError { loadErrorCard(error) } }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if browser.mseDetected || browser.recording { recordBar }
                        bottomBar
                    }
                }
                .navigationTitle(browser.title.isEmpty ? "网页嗅探" : browser.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { browser.retry() } label: { Label("刷新", glyph: .refresh) }
                            Button {
                                Clipboard.copy(browser.currentURL)
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
                .sheet(isPresented: $browser.showingRecorder) { recorderSheet.presentationDetents([.medium, .large]) }
        }
        // 第一次发现媒体时轻提示一下（底部按钮由灰变亮）
        .sensoryFeedback(.success, trigger: browser.medias.isEmpty) { wasEmpty, isEmpty in wasEmpty && !isEmpty }
        // 关掉嗅探页时还在录制：丢弃（正在保存的不受影响）
        .onDisappear { browser.cancelRecording() }
    }

    /// 网页没打开（断网、地址错误、证书问题）：说明原因并给重试，免得只看到一片空白
    private func loadErrorCard(_ message: String) -> some View {
        ZStack {
            Color.paper.ignoresSafeArea()
            EmptyStateCard(icon: .warning, title: "网页打开失败", detail: message, actionTitle: "重试") { browser.retry() }
                .padding(.horizontal, 24)
        }
    }

    // MARK: 录制 MSE 视频流

    private var recordBar: some View {
        Button { browser.showingRecorder = true } label: {
            HStack(spacing: 8) {
                Image(systemName: browser.recording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(browser.recording ? Color.red : Color.clayInk)
                if browser.recording {
                    Text("正在录制 · " + ByteFormat.string(browser.recordedBytes))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                } else {
                    Text("检测到 MSE 视频流（可录制）")
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                }
                Spacer(minLength: 8)
                Text(browser.recording ? "停止录制" : "录制视频流")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.clayInk)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
    }

    private var recorderSheet: some View {
        NavigationStack {
            List {
                Section {
                    recorderStatus
                }
                Section {
                    tip("1", "点「开始录制」后回到网页，从头播放到结尾。已播过一段的，先刷新网页，否则开头录不到。")
                    tip("2", "只录网页实际加载的内容，拖动跳过的部分录不到。")
                    tip("3", "可用播放器倍速加快录制，中途尽量别切清晰度。")
                    tip("4", "播完点「停止并保存」，视频会出现在下载列表。单次最多 2 GB。")
                } header: {
                    Text("怎么录")
                } footer: {
                    Text("该网站分段播放（MSE），没有可直接下载的地址，只能边播边录。录制时可关闭此面板。")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { recorderButtons }
            .navigationTitle("录制视频流")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var recorderStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if browser.savingRecording {
                HStack(spacing: 8) {
                    Spinner(size: 14)
                    Text("正在保存…").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                }
            } else if browser.recording {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill").foregroundStyle(Color.red)
                    Text("已录制 " + ByteFormat.string(browser.recordedBytes))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                    if browser.recordedTracks > 0 {
                        Text("· \(browser.recordedTracks) 条轨道").font(.subheadline).foregroundStyle(Color.ink2)
                    }
                }
                if browser.recordCapped {
                    Text("已达到 2 GB 上限，后面的内容不再录制，请停止并保存。")
                        .font(.footnote)
                        .foregroundStyle(Color.clayInk)
                } else if browser.recordedBytes == 0 {
                    Text("还没有数据：请在网页里播放视频。")
                        .font(.footnote)
                        .foregroundStyle(Color.ink2)
                }
            } else {
                Text("检测到 MSE 视频流").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                if !browser.mseSummary.isEmpty {
                    Text(browser.mseSummary).font(.monoSmall).foregroundStyle(Color.ink3).lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func tip(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).font(.monoSmall).foregroundStyle(Color.clayInk)
            Text(text).font(.subheadline).foregroundStyle(Color.ink)
        }
    }

    private var recorderButtons: some View {
        HStack(spacing: 12) {
            if browser.recording {
                Button("放弃") {
                    browser.cancelRecording()
                    app.show("已放弃录制")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 44))
                Button("停止并保存") { saveRecording() }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 44))
                    .frame(maxWidth: .infinity)
            } else {
                Button("开始录制") {
                    browser.startRecording()
                    browser.showingRecorder = false
                    app.show("开始录制：请在网页里播放视频")
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 44))
                .frame(maxWidth: .infinity)
                .disabled(browser.savingRecording)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func saveRecording() {
        Task {
            // 连点「停止并保存」：第一次已经停下了，后面的不再报「当前没有在录制」
            guard browser.recording else { return }
            do {
                let message = try await browser.stopRecording(into: app.downloads)
                browser.showingRecorder = false
                app.show(message)
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack)
                .accessibilityLabel("后退")
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward)
                .accessibilityLabel("前进")
            Spacer()
            Button { browser.showingList = true } label: {
                HStack(spacing: 6) {
                    if browser.loading { Spinner(size: 14) }
                    Text(browser.medias.isEmpty ? (browser.loading ? "正在查找视频…" : "播放后自动抓取") : "发现 \(browser.medias.count) 个媒体")
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
                    Text("按时长排序，最长的通常是正片。没找到就先在网页里点播放。")
                }
                if !previews.isEmpty {
                    Section {
                        ForEach(previews) { mediaRow($0) }
                    } header: {
                        Text("可能是预览片段或广告")
                    } footer: {
                        Text("不到 30 秒或很小的视频，多半是预览或广告。")
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
                AnyLayout.adaptive(typeSize, spacing: 6) {
                    Text(media.label).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text(media.detail).font(.monoSmall).foregroundStyle(media.isPreview ? Color.ink3 : Color.clayInk)
                }
                Text(media.url).font(.monoSmall).foregroundStyle(Color.ink3).lineLimit(2)
            }
            .padding(.vertical, 2)
        }
        .contextMenu {
            Button {
                Clipboard.copy(media.url)
                app.show("已复制地址")
            } label: { Label("复制地址", glyph: .link) }
        }
    }

    private func download(_ media: SniffedMedia) {
        if app.downloads.items.contains(where: { $0.request.url == media.url && $0.status != .failed }) {
            app.show("已在下载列表中")
            return
        }
        guard enqueuing.insert(media.url).inserted else { return }
        Task {
            defer { enqueuing.remove(media.url) }
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
            app.show("已加入下载")
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
    /// 页面没能打开时的原因（显示出错卡片）；开始新的导航时清掉
    private(set) var loadError: String?
    /// 有没有页面成功显示过：之后的导航失败（点了坏链接）不盖住已显示的页面
    @ObservationIgnored private var committed = false
    var showingList = false
    @ObservationIgnored private var seen = Set<String>()
    /// 等待探测的媒体与正在探测的数量：页面一下子请求几十个地址时，同时最多探测 maxProbes 个
    @ObservationIgnored private var probeQueue: [SniffedMedia] = []
    @ObservationIgnored private var activeProbes = 0
    private static let maxProbes = 4

    /// 页面里出现过的 MSE 轨道：SourceBuffer 编号 → MIME
    private(set) var mseTracks: [String: String] = [:]
    private(set) var recording = false
    private(set) var savingRecording = false
    private(set) var recordedBytes: Int64 = 0
    private(set) var recordedTracks = 0
    private(set) var recordCapped = false
    var showingRecorder = false
    @ObservationIgnored private var recorder: MSERecorder?
    /// 每次开始录制加一；页面脚本只在编号非 0 时回传数据
    @ObservationIgnored private var recordSession = 0
    /// 每个 SourceBuffer 所在的框架（开始 / 停止录制要通知到 iframe 里）
    @ObservationIgnored private var mseFrames: [String: WKFrameInfo] = [:]
    @ObservationIgnored private var recordPage = ""

    var mseDetected: Bool { !mseTracks.isEmpty }

    /// 检测到的轨道格式（去掉 codecs 参数、去重）
    var mseSummary: String {
        var kinds: [String] = []
        for mime in mseTracks.values {
            let base = mime.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? mime
            let name = base.isEmpty ? "未知格式" : base
            if !kinds.contains(name) { kinds.append(name) }
        }
        return kinds.sorted().joined(separator: "、")
    }

    init(url: String) {
        currentURL = url
        let config = WKWebViewConfiguration()
        // 用默认数据存储：在这里登录过的网站下次还在，下载时也能带上它的 Cookie
        config.websiteDataStore = .default()
        config.websiteDataStore.useAppProxy()
        config.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.sniffScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Self.mseScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        controller.add(WeakMessageHandler(self), name: "cloudnSniff")
        controller.add(WeakMessageHandler(self), name: "cloudnMSE")
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
        if message.name == "cloudnMSE" {
            if let body = message.body as? [String: Any] { handleMSE(body, frame: message.frameInfo) }
            return
        }
        guard let body = message.body as? [String: Any], let url = body["url"] as? String else { return }
        add(url: url, page: body["page"] as? String ?? "", title: body["title"] as? String ?? "")
    }

    private func add(url: String, page: String, title: String) {
        guard url.hasPrefix("http"), !seen.contains(url) else { return }
        seen.insert(url)
        let media = SniffedMedia(url: url, kind: SniffedMedia.classify(url), page: page.isEmpty ? currentURL : page,
                                 title: title.isEmpty ? self.title : title)
        medias.append(media)
        probeQueue.append(media)
        pumpProbes()
    }

    /// 从队列里取出等待的媒体开始探测，保持同时进行的不超过 maxProbes 个
    private func pumpProbes() {
        while activeProbes < Self.maxProbes, !probeQueue.isEmpty {
            let media = probeQueue.removeFirst()
            activeProbes += 1
            Task {
                await probe(media)
                activeProbes -= 1
                pumpProbes()
            }
        }
    }

    /// 后台探测大小 / 时长，结果回填到列表
    private func probe(_ media: SniffedMedia) async {
        let headers = await headers(for: media)
        let info = await MediaProbe.probe(media.url, headers: headers, isHLS: media.kind == .hls)
        guard let i = medias.firstIndex(where: { $0.id == media.id }) else { return }
        medias[i].info = info
        medias[i].probing = false
    }

    // MARK: MSE 录制

    /// 页面脚本的消息：sb = 新的 SourceBuffer（或换了格式），data = 录制中追加的一片数据（base64）
    private func handleMSE(_ body: [String: Any], frame: WKFrameInfo) {
        guard let type = body["type"] as? String, let id = body["sb"] as? String else { return }
        let mime = body["mime"] as? String ?? ""
        switch type {
        case "sb":
            if mseTracks[id] != mime { mseTracks[id] = mime }
            mseFrames[id] = frame
            if recording {
                recorder?.setMime(mime, track: id)
                // 录制中新出现的 SourceBuffer（换了视频 / 新的 iframe）：让它也开始回传
                if !recordCapped { setRecordFlag(recordSession, frames: [frame]) }
            }
        case "data":
            guard recording, !recordCapped, let recorder, let data = body["data"] as? String else { return }
            let part = body["part"] as? Int ?? 0
            recorder.append(track: id, mime: mime, part: part, base64: data)
        default:
            break
        }
    }

    /// 通知页面（主框架 + 有 MSE 的 iframe）开始 / 停止回传数据；0 = 停止
    private func setRecordFlag(_ session: Int, frames: [WKFrameInfo]? = nil) {
        let js = "window.__cloudnSetRecord && window.__cloudnSetRecord(\(session));"
        guard let frames else {
            webView.evaluateJavaScript(js, completionHandler: nil)
            for frame in mseFrames.values where !frame.isMainFrame {
                webView.evaluateJavaScript(js, in: frame, in: .page) { _ in }
            }
            return
        }
        for frame in frames {
            webView.evaluateJavaScript(js, in: frame, in: .page) { _ in }
        }
    }

    func startRecording() {
        guard !recording, !savingRecording else { return }
        recorder?.discard()
        let recorder = MSERecorder()
        recorder.onProgress = { [weak self] progress in
            Task { @MainActor [weak self] in self?.applyRecordProgress(progress) }
        }
        self.recorder = recorder
        recordSession += 1
        recording = true
        recordedBytes = 0
        recordedTracks = 0
        recordCapped = false
        recordPage = currentURL
        setRecordFlag(recordSession)
    }

    private func applyRecordProgress(_ progress: MSERecorder.Progress) {
        guard recording else { return }
        recordedBytes = progress.bytes
        recordedTracks = progress.tracks
        if progress.capped && !recordCapped {
            recordCapped = true
            setRecordFlag(0)
        }
    }

    /// 放弃录制（没在录制时什么都不做）
    func cancelRecording() {
        guard recording else { return }
        setRecordFlag(0)
        recording = false
        recorder?.discard()
        recorder = nil
        recordedBytes = 0
        recordedTracks = 0
        recordCapped = false
    }

    /// 停止录制并存入下载列表，返回给用户看的结果说明
    func stopRecording(into downloads: DownloadStore) async throws -> String {
        guard recording, let recorder else { throw CloudnError("当前没有在录制") }
        setRecordFlag(0)
        recording = false
        savingRecording = true
        defer {
            savingRecording = false
            recordedBytes = 0
            recordedTracks = 0
            recordCapped = false
            // 保存成功的文件已移入下载目录，剩下的临时文件一并删除
            recorder.discard()
            if self.recorder === recorder { self.recorder = nil }
        }
        let results = await recorder.finish()
        let page = recordPage.isEmpty ? currentURL : recordPage
        let base = FileNames.base(title, fallback: URL(string: page)?.host ?? "video")
        let outcome = try await MSERecordingSaver.save(results, base: base, page: page, workDirectory: recorder.directory, downloads: downloads)
        return outcome.message
    }

    /// 刷新；页面一次都没打开成功时 webView 没有地址，reload 什么也不做，改为重新载入原地址
    func retry() {
        loadError = nil
        if committed {
            webView.reload()
        } else if let target = URL(string: currentURL) {
            webView.load(URLRequest(url: target))
        }
    }

    private func refreshState() {
        title = webView.title ?? ""
        currentURL = webView.url?.absoluteString ?? currentURL
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        loadError = nil
        // 换页面了：旧页面的 MSE 轨道作废（录制中保留，结束后再清）
        if !recording && !mseTracks.isEmpty {
            mseTracks = [:]
            mseFrames = [:]
        }
        refreshState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committed = true
        loadError = nil
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
        // 被新的导航顶掉（-999）、或页面交给了别的应用 / 下载（WebKit 102）不算失败；已经有页面显示着的也不盖住
        let ns = error as NSError
        let ignored = (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) || (ns.domain == "WebKitErrorDomain" && ns.code == 102)
        if !ignored && !committed { loadError = ns.localizedDescription }
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

    /// 录制 MSE 视频流：钩住 MediaSource.addSourceBuffer / SourceBuffer.appendBuffer。
    /// 平时只报告出现了哪些 SourceBuffer（并记住各自最近的初始化段）；应用开始录制后，
    /// 每次追加的数据按 ≤512KB 一片转成 base64 发回（中途开始录制时先补发初始化段）。
    /// 原始字符串：脚本里的反斜杠不需要转义
    static let mseScript = #"""
    (function(){
      if (window.__cloudnMSE) return; window.__cloudnMSE = true;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cloudnMSE;
      if (!handler) return;
      var PIECE = 512 * 1024;
      var frameKey = Math.random().toString(36).slice(2, 10);
      var nextId = 1;
      var session = 0;
      function post(msg){ try { handler.postMessage(msg); } catch (e) {} }
      function owner(proto, name){
        while (proto && !Object.prototype.hasOwnProperty.call(proto, name)) proto = Object.getPrototypeOf(proto);
        return proto;
      }
      function bytesOf(data){
        try {
          if (data instanceof ArrayBuffer) return new Uint8Array(data);
          if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        } catch (e) {}
        return null;
      }
      function isInit(u8){
        if (u8.length >= 8) {
          var t = String.fromCharCode(u8[4], u8[5], u8[6], u8[7]);
          if (t === 'ftyp' || t === 'moov') return true;
        }
        return u8.length >= 4 && u8[0] === 0x1A && u8[1] === 0x45 && u8[2] === 0xDF && u8[3] === 0xA3;
      }
      function b64(u8){
        var s = '', step = 0x8000;
        for (var i = 0; i < u8.length; i += step) s += String.fromCharCode.apply(null, u8.subarray(i, Math.min(u8.length, i + step)));
        return btoa(s);
      }
      function announce(info){
        post({type: 'sb', sb: info.id, mime: info.mime, page: location.href, title: document.title || ''});
      }
      function send(info, u8){
        var parts = Math.max(1, Math.ceil(u8.length / PIECE));
        for (var p = 0; p < parts; p++) {
          var piece = u8.subarray(p * PIECE, Math.min(u8.length, (p + 1) * PIECE));
          post({type: 'data', sb: info.id, mime: info.mime, seq: info.seq++, part: p, parts: parts, data: b64(piece)});
        }
      }
      function onAppend(sb, data){
        var info = sb.__cloudnInfo;
        if (!info) return;
        var u8 = bytesOf(data);
        if (!u8 || !u8.length) return;
        var init = isInit(u8);
        // 记住最近的初始化段：录制中途开始时先补发它，否则录到的媒体段无法播放
        if (init && u8.length <= 4 * 1024 * 1024) info.init = u8.slice();
        if (!session) return;
        if (info.session !== session) {
          info.session = session;
          if (!init && info.init) send(info, info.init);
        }
        send(info, u8);
      }
      function track(sb, mime){
        if (!sb || sb.__cloudnInfo) return;
        var info = {id: frameKey + '-' + (nextId++), mime: String(mime || ''), seq: 0, session: 0, init: null};
        try { Object.defineProperty(sb, '__cloudnInfo', {value: info, enumerable: false}); } catch (e) { sb.__cloudnInfo = info; }
        announce(info);
      }
      function patchAppend(proto){
        if (!proto || typeof proto.appendBuffer !== 'function' || proto.appendBuffer.__cloudn) return;
        var orig = proto.appendBuffer;
        var wrapped = function(data){
          // 先交给原方法：它抛错（如缓冲区满）时页面会重试，这次不能记
          var result = orig.apply(this, arguments);
          try { onAppend(this, data); } catch (e) {}
          return result;
        };
        wrapped.__cloudn = true;
        proto.appendBuffer = wrapped;
      }
      function patchChangeType(proto){
        if (!proto || typeof proto.changeType !== 'function' || proto.changeType.__cloudn) return;
        var orig = proto.changeType;
        var wrapped = function(type){
          var result = orig.apply(this, arguments);
          try {
            var info = this.__cloudnInfo;
            if (info) { info.mime = String(type || ''); info.init = null; announce(info); }
          } catch (e) {}
          return result;
        };
        wrapped.__cloudn = true;
        proto.changeType = wrapped;
      }
      function patchBuffer(proto){
        patchAppend(owner(proto, 'appendBuffer'));
        patchChangeType(owner(proto, 'changeType'));
      }
      function patchSource(proto){
        proto = owner(proto, 'addSourceBuffer');
        if (!proto || typeof proto.addSourceBuffer !== 'function' || proto.addSourceBuffer.__cloudn) return;
        var orig = proto.addSourceBuffer;
        var wrapped = function(mime){
          var sb = orig.apply(this, arguments);
          try { patchBuffer(Object.getPrototypeOf(sb)); track(sb, mime); } catch (e) {}
          return sb;
        };
        wrapped.__cloudn = true;
        proto.addSourceBuffer = wrapped;
      }
      ['MediaSource', 'ManagedMediaSource', 'WebKitMediaSource'].forEach(function(name){
        try { if (window[name] && window[name].prototype) patchSource(window[name].prototype); } catch (e) {}
      });
      ['SourceBuffer', 'ManagedSourceBuffer'].forEach(function(name){
        try { if (window[name] && window[name].prototype) patchBuffer(window[name].prototype); } catch (e) {}
      });
      // 应用通过它开始（录制编号）/ 停止（0）录制
      window.__cloudnSetRecord = function(n){ session = Number(n) || 0; };
    })();
    """#
}

#if DEBUG
extension SnifferBrowser {
    /// 截图模式：直接放进演示用的媒体与 MSE 轨道（已探测完成），不等网页真的播放
    func loadDemo(_ list: [(url: String, kind: SniffedMedia.Kind, info: MediaProbeResult)], mse: [String: String] = [:]) {
        for entry in list where !seen.contains(entry.url) {
            seen.insert(entry.url)
            var media = SniffedMedia(url: entry.url, kind: entry.kind, page: currentURL, title: title)
            media.info = entry.info
            media.probing = false
            medias.append(media)
        }
        mseTracks.merge(mse) { $1 }
    }
}
#endif

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
