// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 解析页：输入框停在底部（单手够得着，随键盘上移），上面是收藏与最近记录
struct ResolveView: View {
    @Environment(AppModel.self) private var app
    @State private var input = ""
    @State private var pwd = ""
    @State private var editingPwd = false
    @FocusState private var pwdFocused: Bool
    @State private var confirmClearHistory = false
    @State private var working = false
    @State private var workTask: Task<Void, Never>?
    /// 当前这次解析的编号：被新的解析顶掉的旧任务结束时不再收起进度环
    @State private var workID: UUID?
    /// 主页 / 播放列表这类翻页解析的实时进度（已获取多少个）；用户可提前停止、用已拿到的部分
    @State private var collectProgress: CollectionProgress?
    @State private var collectSnapshot: CollectionProgress.Snapshot?
    @State private var collectStopping = false
    @State private var shareModel: ShareBrowserModel?
    @State private var videoResult: VideoParseResult?
    @State private var githubLink: GitHubLink?
    @State private var torrentTarget: TorrentTarget?
    @State private var importingTorrent = false
    @State private var showBookmarks = false
    /// 在收藏面板里点的那一条：面板收起后再打开，免得结果页 / 批量进度页在面板退场途中弹出而被系统丢掉
    @State private var bookmarkToOpen: String?
    /// 网页嗅探打开的地址
    @State private var sniffTarget: SniffTarget?
    /// 平台解析失败后，询问是否改用网页嗅探
    @State private var sniffOffer: SniffOffer?
    @State private var batchJob: BatchJob?
    /// 解析失败后就地登录的平台；登录成功回来后重新解析 loginRetry 里的链接
    @State private var loginKind: AccountKind?
    @State private var loginRetry: LoginRetry?
    /// 剪贴板里有链接、且这一条还没处理过
    @State private var clipboardOffer = false
    /// 已处理（粘贴或关掉）过的剪贴板版本，同一条内容只提示一次；应用自己复制的内容也记在这里（见 Clipboard.copy）
    @AppStorage(Clipboard.handledChangeKey) private var handledChange = -1
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 收藏卡片宽度随字号放大（最宽 260），大字号下标题不会只剩一个字
    @ScaledMetric(relativeTo: .subheadline) private var bookmarkWidth: CGFloat = 124

    init() {}

    #if DEBUG
    /// 截图模式：输入框里预先填好内容，停在识别结果上
    init(demoInput: String) { _input = State(initialValue: demoInput) }
    #endif

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 输入识别（几十条正则）：body 里十几处要用，同一段输入只算一次
    private var detection: InputDetection { Self.detection(for: input) }
    private var detected: DetectedInput? { detection.detected }
    private var isXunleiKouling: Bool { detection.xunlei }
    private var isQuarkKouling: Bool { detection.quark }
    /// 识别不出链接、但像中文口令（迅雷，或要经第三方解析的夸克 / UC）
    private var isKouling: Bool { isXunleiKouling || isQuarkKouling }
    /// 夸克 / UC 口令要发给第三方服务解析：没开总是允许时先问
    @State private var askingKoulingConsent = false
    private var canSubmit: Bool { detected != nil || isKouling }
    /// 一次粘贴了多个视频链接：批量解析下载（只有识别成视频时才找）
    private var batchLinks: [String] { detection.batchLinks }

    @MainActor private static var detectionMemo: (text: String, value: InputDetection)?

    @MainActor private static func detection(for text: String) -> InputDetection {
        if let memo = detectionMemo, memo.text == text { return memo.value }
        let value = InputDetection(text)
        detectionMemo = (text, value)
        return value
    }

    /// 文本里所有能识别的视频 / 图集链接（按作品去重：同一作品的不同写法只留第一个，保持顺序）
    static func videoLinks(in text: String) -> [String] {
        guard text.count < 200_000, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let urls = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let url = match.url?.absoluteString, url.hasPrefix("http") else { return nil }
            return url
        }
        return VideoLinkParser.uniqueLinks(urls)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("解析")
                        .font(.pageTitle)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 4)
                        .padding(.top, 12)
                    if isFirstRun { firstRunCard }
                    if !app.batchJobs.isEmpty { batchSection }
                    if !app.bookmarks.bookmarks.isEmpty { bookmarkSection }
                    if !app.bookmarks.history.isEmpty { historySection }
                    supportFooter
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.immediately)
            // 点空白处收起键盘
            .simultaneousGesture(TapGesture().onEnded { focused = false })
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if showsClipboardCard {
                        clipboardCard.transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    composer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .readableWidth()
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: clipboardOffer)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: detectionKey)
            }
            .background(Color.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $shareModel) { ShareBrowserView(model: $0) }
            // 离开分享页（返回或换了一个分享）：清掉预览 / 复制直链留下的临时转存
            .onChange(of: shareModel) { old, new in
                if let old, old != new { old.releaseAllTemporary() }
            }
            .navigationDestination(item: $videoResult) { VideoResultView(result: $0) }
            .navigationDestination(item: $githubLink) { link in
                switch link {
                case .account(let owner): GitHubAccountView(owner: owner)
                case .repository(let owner, let repo, let sub): GitHubRepoView(owner: owner, repo: repo, subPath: sub)
                case .file: EmptyView()
                }
            }
            .navigationDestination(item: $torrentTarget) { TorrentView(target: $0) }
            .documentPicker(isPresented: $importingTorrent, types: [.torrent, .data]) { urls in
                if let url = urls.first {
                    app.openTorrentFile(url)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            .fullScreenCover(item: $sniffTarget) { SnifferView(url: $0.url) }
            .sheet(item: $batchJob) { BatchView(job: $0) }
            .alert("使用第三方服务解析口令？", isPresented: $askingKoulingConsent) {
                Button("取消", role: .cancel) {}
                Button("仅这一次") { resolveKouling(consented: true) }
                Button("总是允许") {
                    app.settings.allowCommandService = true
                    resolveKouling(consented: true)
                }
            } message: {
                Text("夸克 / UC 口令需发给第三方「\(QuarkKouling.serviceName)」服务换取分享 ID，只发送口令文字，不含账号信息。可在「设置 › 解析」中更改。")
            }
            .alert(sniffOffer?.message ?? "", isPresented: Binding(get: { sniffOffer != nil }, set: { if !$0 { sniffOffer = nil } })) {
                Button("网页嗅探") { if let offer = sniffOffer { sniffTarget = SniffTarget(url: offer.url) } }
                if let kind = sniffOffer?.loginKind {
                    Button("去登录") {
                        loginRetry = LoginRetry(text: sniffOffer?.text ?? "", kind: kind,
                                                stamp: app.accounts.list(kind).first?.updatedAt)
                        loginKind = kind
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(sniffOffer?.loginKind.map { "登录\($0.displayName)后可重新解析，也可以用网页嗅探：在网页里播放后抓取视频。" }
                     ?? "可以用网页嗅探：在网页里播放后抓取视频。")
            }
            .sheet(item: $loginKind, onDismiss: {
                // 真的登录了（主账号是新保存的）才重新解析刚才失败的链接；取消登录不重试
                defer { loginRetry = nil }
                guard let retry = loginRetry, !retry.text.isEmpty,
                      let account = app.accounts.list(retry.kind).first, account.updatedAt != retry.stamp else { return }
                open(text: retry.text)
            }) { LoginSheet(kind: $0) }
            .sheet(isPresented: $showBookmarks, onDismiss: {
                guard let text = bookmarkToOpen else { return }
                bookmarkToOpen = nil
                open(text: text)
            }) {
                BookmarksView { bookmark in
                    bookmarkToOpen = bookmark.text
                    showBookmarks = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sensoryFeedback(.selection, trigger: detectionKey) { _, new in !new.isEmpty }
        .onAppear(perform: consumePending)
        .onChange(of: app.pendingInput) { _, _ in consumePending() }
        .onChange(of: app.pendingTorrent) { _, _ in consumePending() }
        .task { await checkClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await checkClipboard() }
        }
    }

    /// 识别结果变化时触发一次轻触感
    private var detectionKey: String {
        switch detected {
        case .share(let s): return "s." + s.platform.rawValue
        case .video(let v): return "v." + v.platform.rawValue
        case .github: return "g"
        case .direct: return "d"
        case .magnet: return "m"
        case nil: return isKouling ? "k" : ""
        }
    }

    // MARK: 输入框

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !trimmed.isEmpty {
                detectionRow.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 10) {
                IconView(.link, size: 18)
                    .foregroundStyle(Color.ink3)
                    .frame(height: 34)
                TextField("粘贴链接、口令或 GitHub 地址", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                    .padding(.vertical, 6)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onChange(of: input) { old, new in
                        if handleReturnKey(old: old, new: new) { return }
                        // 只有链接本身变了才清掉手改的提取码
                        if old.filter({ $0 != "\n" }) != new.filter({ $0 != "\n" }) { pwd = "" }
                    }
                trailingControl
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(focused || canSubmit ? Color.ink3.opacity(0.6) : Color.hairline, lineWidth: 1)
        }
        .floatingShadow()
    }

    @ViewBuilder
    private var trailingControl: some View {
        if working {
            // 转圈中间画 ×：点按是取消，不是暂停
            Button { cancelWork() } label: {
                ZStack {
                    ProgressRing(value: nil, size: 30, glyph: false)
                    IconView(.close, size: 10).foregroundStyle(.tint)
                }
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel("正在解析，点按取消")
        } else if trimmed.isEmpty {
            // 输入框为空：一键粘贴（系统粘贴控件，不弹授权提示）。上方已有剪贴板卡片时不重复
            if !showsClipboardCard {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in
                        markClipboardHandled()
                        open(text: text)
                    }
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
                .tint(Self.pasteTint)
                .controlSize(.small)
            }
            Menu {
                Button { showBookmarks = true } label: { Label { Text("从收藏打开") } icon: { Image(icon: .star) } }
                Button { importingTorrent = true } label: { Label { Text("打开种子文件") } icon: { Image(icon: .magnet) } }
                Button { focused = true } label: { Label { Text("手动输入") } icon: { Image(icon: .pencil) } }
            } label: {
                IconView(.plus, size: 18)
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Color.ink2)
            }
            .accessibilityLabel("更多来源")
        } else {
            HStack(spacing: 2) {
                Button {
                    input = ""
                    focused = true
                } label: {
                    IconView(.close, size: 14).frame(width: 34, height: 34).contentShape(Rectangle().inset(by: -5)).foregroundStyle(Color.ink3)
                }
                .accessibilityLabel("清空")
                Button(action: submit) { IconView(.arrowUp, size: 17) }
                    .buttonStyle(CircleIconButtonStyle(size: 34, filled: canSubmit))
                    .disabled(!canSubmit)
                    .accessibilityLabel(submitLabel)
            }
        }
    }

    /// 多行输入框里回车会插入换行：只敲了一个回车时当作「前往」——能解析就解析，否则收起键盘。粘贴进来的多行文案不受影响
    private func handleReturnKey(old: String, new: String) -> Bool {
        guard new.count == old.count + 1, new.filter({ $0 == "\n" }).count == old.filter({ $0 == "\n" }).count + 1 else { return false }
        input = old
        if canSubmit { submit() } else { focused = false }
        return true
    }

    private var submitLabel: String {
        if case .direct = detected { return "加入下载" }
        if case .github(.file) = detected { return "加入下载" }
        return "开始解析"
    }

    /// 识别结果：平台 + 说明；网盘分享可就地改提取码
    @ViewBuilder
    private var detectionRow: some View {
        if working, let snapshot = collectSnapshot, snapshot.fetched > 0 {
            collectProgressRow(snapshot)
        } else {
            plainDetectionRow
        }
    }

    /// 翻页解析中：已获取数（接口给了总数时带上），右侧「停止」用已拿到的部分出结果
    private func collectProgressRow(_ snapshot: CollectionProgress.Snapshot) -> some View {
        HStack(spacing: 8) {
            if let mark = detectedMark {
                PlatformGlyph(mark: mark, size: 15).foregroundStyle(Color.ink2)
            }
            Group {
                if let total = snapshot.total {
                    Text("正在获取 \(snapshot.fetched) / \(total)")
                } else {
                    Text("正在获取，已获取 \(snapshot.fetched) 个")
                }
            }
            .font(.footnote)
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(Color.ink2)
            .lineLimit(1)
            Spacer(minLength: 0)
            if collectStopping {
                Text("正在停止…").font(.footnote).foregroundStyle(Color.ink3)
            } else {
                Button("停止") {
                    collectProgress?.requestStop()
                    collectStopping = true
                }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(TextLinkButtonStyle())
                    .accessibilityLabel("停止加载，使用已获取的 \(snapshot.fetched) 个")
            }
        }
        .padding(.trailing, 8)
        .accessibilityElement(children: .combine)
    }

    private var plainDetectionRow: some View {
        HStack(spacing: 8) {
            if let mark = detectedMark {
                PlatformGlyph(mark: mark, size: 15).foregroundStyle(Color.ink2)
            } else {
                IconView(canSubmit ? .download : .warning, size: 15).foregroundStyle(Color.ink3)
            }
            Text(working ? detectionText + " · 正在解析…" : detectionText).font(.footnote).foregroundStyle(Color.ink2).lineLimit(1)
            Spacer(minLength: 0)
            if case .share(let share) = detected {
                pwdToken(recognized: share.pwd)
            }
        }
        .padding(.trailing, 8)
    }

    private func pwdToken(recognized: String?) -> some View {
        let value = pwd.isEmpty ? (recognized ?? "") : pwd
        return Group {
            if editingPwd {
                TextField("提取码", text: $pwd)
                    .font(.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(width: 90)
                    .focused($pwdFocused)
                    .submitLabel(.done)
                    .onSubmit { editingPwd = false }
                    // 点了「加提取码」就直接进入输入，不用再点一次
                    .onAppear { pwdFocused = true }
            } else {
                Button { pwd = value; editingPwd = true } label: {
                    Text(value.isEmpty ? "加提取码" : value)
                        .font(value.isEmpty ? .caption : .mono)
                        .foregroundStyle(value.isEmpty ? Color.ink2 : Color.clayInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(value.isEmpty ? "添加提取码" : "提取码 \(value)，点按修改")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(value.isEmpty && !editingPwd ? Color.fillMuted : Color.claySoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .expandedHitArea(9)
    }

    private var detectedMark: PlatformMark? {
        switch detected {
        case .share(let s): return .share(s.platform)
        case .video(let v): return .video(v.platform)
        case .github: return .github
        case .magnet: return .magnet
        case .direct, nil: return isKouling ? .share(isXunleiKouling && !QuarkKouling.mentionsQuarkOrUC(input) ? .xunlei : .quark) : nil
        }
    }

    private var detectionText: String {
        switch detected {
        case .share(let s): return s.platform.displayName
        case .video(let v):
            let count = batchLinks.count
            if count > 1 { return "识别到 \(count) 个视频链接 · 批量下载" }
            return v.platform.displayName + (input.count > v.url.count + 8 ? " · 已从文案里取出链接" : "")
        case .github(.file): return "GitHub 文件 · 直接下载"
        case .github(.account(let owner)): return "GitHub · \(owner) 的仓库"
        case .github: return "GitHub 仓库"
        case .direct: return "链接 · 直接下载或网页嗅探"
        case .magnet(let m): return m.displayName.isEmpty ? "磁力链接" : "磁力链接 · " + m.displayName
        case nil:
            guard isKouling else { return "没有识别到链接" }
            if QuarkKouling.mentionsQuarkOrUC(input) || !isXunleiKouling { return "夸克 / UC 口令" }
            return isQuarkKouling ? "迅雷 / 夸克口令" : "迅雷口令"
        }
    }

    // MARK: 首次使用

    /// 还没有任何收藏、最近记录与批量任务
    private var isFirstRun: Bool {
        app.batchJobs.isEmpty && app.bookmarks.bookmarks.isEmpty && app.bookmarks.history.isEmpty
    }

    /// 首次打开：告诉用户第一步做什么（下方输入框旁就是「粘贴」）
    private var firstRunCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("粘贴一个链接").font(.cardTitle).foregroundStyle(Color.ink)
            Text("网盘分享、短视频、网页视频、GitHub 或磁力链接都可以。复制后点下方的「粘贴」，Cloudn 会自动识别并解析。")
                .font(.subheadline)
                .foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                IconView(.share, size: 14).foregroundStyle(Color.ink3)
                Text("在其他 App 里点「分享」→ Cloudn 也能直接打开")
                    .font(.footnote)
                    .foregroundStyle(Color.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: 剪贴板

    private var showsClipboardCard: Bool { clipboardOffer && trimmed.isEmpty && app.settings.clipboardHint }

    private var clipboardCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.fillMuted)
                .frame(width: 38, height: 38)
                .overlay { IconView(.paste, size: 20).foregroundStyle(Color.ink) }
            VStack(alignment: .leading, spacing: 2) {
                Text("剪贴板里有一个链接").font(.subheadline)
                Text("粘贴后自动识别并打开").font(.caption).foregroundStyle(Color.ink2)
            }
            Spacer(minLength: 0)
            // 系统粘贴控件：读取剪贴板不弹授权提示
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    markClipboardHandled()
                    open(text: text)
                }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            // 系统粘贴按钮的文字固定是白色：深色模式下墨色是浅色，换成深暖灰，否则看不清（对比度不足时系统也会拒绝粘贴）
            .tint(Self.pasteTint)
            .controlSize(.small)
            Button { markClipboardHandled() } label: {
                IconView(.close, size: 12).frame(width: 36, height: 44).contentShape(Rectangle()).foregroundStyle(Color.ink3)
            }
            .accessibilityLabel("忽略")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .card()
    }

    private static let pasteTint = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x57524A) : UIColor(hex: 0x1F1E1B) })

    private func markClipboardHandled() {
        handledChange = UIPasteboard.general.changeCount
        clipboardOffer = false
    }

    private func checkClipboard() async {
        // 只探测「有没有链接」，不读取内容，不会触发系统的粘贴提示；处理过的同一份内容不再提示
        let board = UIPasteboard.general
        guard app.settings.clipboardHint, board.hasStrings, board.changeCount != handledChange else {
            clipboardOffer = false
            return
        }
        let pattern = UIPasteboard.DetectionPattern.probableWebURL
        clipboardOffer = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            board.detectPatterns(for: [pattern]) { result in
                cont.resume(returning: (try? result.get())?.contains(pattern) ?? false)
            }
        }
    }

    // MARK: 批量任务

    /// 批量下载任务：关掉进度页后从这里回去查看进度、继续或重试失败的
    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "批量任务")
                if app.batchJobs.contains(where: { $0.finished && $0.failedCount == 0 }) {
                    Button("清除已完成") { withAnimation { app.batchJobs.removeAll { $0.finished && $0.failedCount == 0 } } }
                        .font(.subheadline)
                        .buttonStyle(TextLinkButtonStyle())
                }
            }
            VStack(spacing: 0) {
                let jobs = Array(app.batchJobs.reversed())
                ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                    BatchJobRow(job: job) { batchJob = job }
                        .contextMenu {
                            if job.running {
                                Button { job.cancel() } label: { Label { Text("停止") } icon: { Image(icon: .close) } }
                            } else if job.failedCount > 0 {
                                Button { job.retryFailed(app: app) } label: { Label { Text("重试失败的") } icon: { Image(icon: .refresh) } }
                            } else if !job.finished {
                                Button { job.start(app: app) } label: { Label { Text("继续") } icon: { Image(icon: .play) } }
                            }
                            if !job.running {
                                Button(role: .destructive) { withAnimation { app.batchJobs.removeAll { $0.id == job.id } } } label: {
                                    Label { Text("移除") } icon: { Image(icon: .trash) }
                                }
                            }
                        }
                    if index < jobs.count - 1 { RowDivider() }
                }
            }
            .card()
        }
    }

    // MARK: 收藏与最近

    private var bookmarkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "收藏")
                Button("全部") { showBookmarks = true }.font(.subheadline).buttonStyle(TextLinkButtonStyle())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(app.bookmarks.bookmarks.prefix(12)) { b in
                        Button { open(text: b.text) } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                markView(for: b.text, size: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.title).font(.subheadline.weight(.medium)).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                                        .foregroundStyle(Color.ink)
                                    Text(b.source).font(.caption).foregroundStyle(Color.ink2).lineLimit(1)
                                }
                            }
                            .frame(width: min(bookmarkWidth, 260), alignment: .leading)
                            .padding(12)
                            .card()
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { app.bookmarks.remove([b.id]) } label: {
                                Label { Text("取消收藏") } icon: { Image(icon: .trash) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "最近")
                Button("清空") { confirmClearHistory = true }
                    .font(.subheadline)
                    .buttonStyle(TextLinkButtonStyle())
                    .rowDialog("清空最近记录？", isPresented: $confirmClearHistory, message: "收藏不受影响") {
                        Button("清空", role: .destructive) { withAnimation { app.bookmarks.clearHistory() } }
                    }
            }
            VStack(spacing: 0) {
                let items = Array(app.bookmarks.history.prefix(10))
                ForEach(Array(items.enumerated()), id: \.element.id) { index, h in
                    HistoryRow(item: h, progress: downloadProgress(for: h.text)) { open(text: h.text) }
                        .contextMenu {
                            Button { Clipboard.copy(h.text) } label: { Label { Text("复制链接") } icon: { Image(icon: .link) } }
                            Button {
                                app.bookmarks.add(title: h.title, text: h.text, source: h.source)
                                app.show("已收藏")
                            } label: {
                                Label { Text("收藏") } icon: { Image(icon: .star) }
                            }
                            Button(role: .destructive) { withAnimation { app.bookmarks.removeHistory(h.id) } } label: {
                                Label { Text("删除这条记录") } icon: { Image(icon: .trash) }
                            }
                        }
                    if index < items.count - 1 { RowDivider() }
                }
            }
            .card()
        }
    }

    @ViewBuilder
    private func markView(for text: String, size: CGFloat) -> some View {
        if let mark = Self.mark(for: text) {
            PlatformGlyph(mark: mark, size: size).foregroundStyle(mark.isVideo ? Color.clayInk : Color.ink)
        } else {
            IconView(.link, size: size).foregroundStyle(Color.ink)
        }
    }

    /// 链接识别要跑几十条正则：按文本缓存，最近记录与收藏重绘时不再重复识别
    @MainActor private static var markCache: [String: PlatformMark?] = [:]

    @MainActor static func mark(for text: String) -> PlatformMark? {
        if let hit = markCache[text] { return hit }
        let mark: PlatformMark? = switch DetectedInput.detect(text) {
        case .share(let s): .share(s.platform)
        case .video(let v): .video(v.platform)
        case .github: .github
        default: nil
        }
        if markCache.count > 500 { markCache.removeAll() }
        markCache[text] = mark
        return mark
    }

    /// 某条记录对应分享的下载情况：(已完成, 总数)。读的是只在数量变化时更新的汇总，不随进度重绘
    private func downloadProgress(for text: String) -> (done: Int, total: Int)? {
        guard let share = Self.share(for: text),
              let key = app.downloads.shareKey(platform: share.platform, shareURL: share.url),
              let p = app.downloads.shareProgress[key] else { return nil }
        return (p.done, p.total)
    }

    /// 最近记录对应的分享链接：同样按文本缓存，输入框每敲一个字整页重绘时不再逐条跑正则
    @MainActor private static var shareCache: [String: ParsedShare?] = [:]

    @MainActor private static func share(for text: String) -> ParsedShare? {
        if let hit = shareCache[text] { return hit }
        let share = ShareLinkParser.parse(text)
        if shareCache.count > 500 { shareCache.removeAll() }
        shareCache[text] = share
        return share
    }

    private func glyphRows(_ marks: [PlatformMark], prefix: String) -> some View {
        ForEach(Array(stride(from: 0, to: marks.count, by: 10)), id: \.self) { start in
            HStack(spacing: 10) {
                ForEach(start..<min(start + 10, marks.count), id: \.self) { PlatformGlyph(mark: marks[$0], size: 15) }
            }
            .id("\(prefix)\(start)")
        }
    }

    /// 支持的平台：一排图标，不写长段文字
    private var supportFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 网盘一组、视频平台一组，都按每行 10 个排：各行列对齐，窄屏也不溢出
            glyphRows(SharePlatform.allCases.map(PlatformMark.share), prefix: "s")
            glyphRows(VideoPlatform.allCases.map(PlatformMark.video) + [.github], prefix: "v")
            Text("以及任意 http(s) 下载直链与 m3u8").font(.caption)
        }
        .foregroundStyle(Color.ink3)
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("支持 \(SharePlatform.allCases.count) 个网盘、\(VideoPlatform.allCases.count) 个视频平台、GitHub 与下载直链")
    }

    // MARK: 动作

    private func consumePending() {
        if let t = app.pendingTorrent {
            app.pendingTorrent = nil
            torrentTarget = t
            return
        }
        guard let text = app.pendingInput else { return }
        app.pendingInput = nil
        // 分享扩展会顺手把链接放进剪贴板：已经打开了，就别再提示「剪贴板里有一个链接」
        markClipboardHandled()
        open(text: text)
    }

    private func open(text: String) {
        input = text
        pwd = ""
        submit()
    }

    private func cancelWork() {
        workTask?.cancel()
        workTask = nil
        workID = nil
        working = false
        collectProgress = nil
        collectSnapshot = nil
        collectStopping = false
    }

    /// 解析失败时要不要给「去登录」：平台支持登录，且报错提到登录、还没登录或登录已失效
    private func loginSuggestion(for platform: VideoPlatform, message: String) -> AccountKind? {
        guard let kind = platform.accountKind else { return nil }
        let mentionsLogin = message.contains("登录") || message.localizedCaseInsensitiveContains("login")
        return mentionsLogin || !app.accounts.isLoggedIn(kind) || app.accounts.isExpired(kind) ? kind : nil
    }

    private func submit() {
        focused = false
        editingPwd = false
        guard let detected else {
            if isKouling { resolveKouling() }
            return
        }
        // 新的一次解析顶掉还没完成的上一次：免得旧结果晚到，又推出一页
        cancelWork()
        let links = batchLinks
        if case .video = detected, links.count > 1 {
            batchJob = app.startBatch(title: "批量下载 \(links.count) 个", entries: links.map { (title: "", url: $0) })
            input = ""
            return
        }
        switch detected {
        case .share(let share):
            guard share.platform.isResolvable else {
                app.show("暂不支持解析\(share.platform.displayName)", error: true)
                return
            }
            let effectivePwd = pwd.isEmpty ? share.pwd : pwd
            // 收藏/历史里保存的文本要带上手填的提取码，下次点开能直接解析
            var source = trimmed
            if let p = effectivePwd, !p.isEmpty, ShareLinkParser.parse(source)?.pwd != p { source += " 提取码：\(p)" }
            shareModel = ShareBrowserModel(app: app, share: share, pwd: effectivePwd, sourceText: source)
        case .video(let link):
            let text = input
            let progress = CollectionProgress()
            collectProgress = progress
            collectSnapshot = nil
            collectStopping = false
            run {
                // 翻页解析每拿到一页报一次进度：只留最新一条，显示在识别行
                let watcher = Task { @MainActor in
                    for await snapshot in progress.updates where collectProgress === progress {
                        withAnimation(.snappy) { collectSnapshot = snapshot }
                    }
                }
                defer {
                    watcher.cancel()
                    progress.finish()
                    if collectProgress === progress {
                        collectProgress = nil
                        collectSnapshot = nil
                        collectStopping = false
                    }
                }
                do {
                    let result = try await CollectionProgress.$current.withValue(progress) { try await parseVideo(link) }
                    try Task.checkCancellation()
                    guard !result.medias.isEmpty || !result.entries.isEmpty else { throw CloudnError("没有解析到可下载的媒体") }
                    app.bookmarks.record(title: result.title.isEmpty ? result.platform.displayName : result.title,
                                         text: text, source: result.platform.displayName)
                    videoResult = result
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 专门的解析失败时，退一步用网页嗅探试试（短链展开到不支持的页面时，嗅探展开后的地址）；
                    // 需要登录 / 登录已失效的平台，同时给出「去登录」
                    guard !Task.isCancelled else { throw error }
                    let message = error.localizedDescription
                    let sniffURL = (error as? VideoParseError)?.sniffURL ?? link.url
                    sniffOffer = SniffOffer(url: sniffURL, message: message, text: text,
                                            loginKind: loginSuggestion(for: link.platform, message: message))
                }
            }
        case .github(let link):
            if case .file(let url, let name) = link {
                app.downloadGitHubFile(url: url, name: name)
                input = ""
            } else {
                app.bookmarks.record(title: trimmed, text: input, source: "GitHub")
                githubLink = link
            }
        case .magnet(let magnet):
            torrentTarget = TorrentTarget(magnet: magnet)
        case .direct(let url):
            if Self.mayBeWebPage(url) {
                run {
                    if try await Self.isWebPage(url) {
                        sniffTarget = SniffTarget(url: url)
                    } else {
                        enqueueDirect(url)
                    }
                }
            } else {
                enqueueDirect(url)
            }
        }
    }

    private func parseVideo(_ link: DetectedVideoLink) async throws -> VideoParseResult {
        #if DEBUG
        // 截图模式：解析中 / 解析失败等状态用演示结果（见 ScreenshotMode.swift）
        if let demo = try await ScreenshotMode.parse(link) { return demo }
        #endif
        return try await app.videoService.parse(link)
    }

    /// 地址没有文件扩展名，或扩展名是网页类（html / php …），可能是网页而不是文件
    private static func mayBeWebPage(_ url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        let ext = u.pathExtension.lowercased()
        return ext.isEmpty || ["html", "htm", "shtml", "php", "asp", "aspx", "jsp", "do", "action"].contains(ext)
    }

    /// 取开头一小段看是不是 HTML
    private static func isWebPage(_ url: String) async throws -> Bool {
        let head = try await HTTPClient.fetchPrefix(url, headers: [("User-Agent", VideoHTTP.uaIPhone)], limit: 2048)
        let text = String(decoding: head.data, as: UTF8.self).lowercased()
        return text.contains("<html") || text.contains("<!doctype html") || text.contains("<head")
    }

    private func enqueueDirect(_ url: String) {
        let name = URL(string: url).map { u -> String in
            let last = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
            return last.isEmpty || last == "/" ? (u.host ?? "download") : last
        } ?? "download"
        let kind: DownloadKind = url.lowercased().contains(".m3u8") ? .hls : .file
        app.downloads.enqueue(DownloadRequest(url: url, headers: ["User-Agent": VideoHTTP.uaChrome],
                                              fileName: kind == .hls ? (name as NSString).deletingPathExtension + ".mp4" : name,
                                              kind: kind, source: "直链"))
        app.show("已加入下载")
        input = ""
    }

    /// 后台执行一次解析；发送键变成可取消的进度环
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        workTask?.cancel()
        working = true
        let id = UUID()
        workID = id
        workTask = Task { @MainActor in
            // 只有自己仍是当前这次解析时才收起进度环：被顶掉的旧任务晚结束，不能把新任务的进度环关掉
            defer {
                if workID == id {
                    working = false
                    workTask = nil
                    workID = nil
                }
            }
            do {
                try await operation()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { app.show(error.localizedDescription, error: true) }
            }
        }
    }

    /// 中文口令：带夸克 / UC 标记的直接按夸克口令解析；否则先问迅雷，迅雷没有对应分享再按夸克 / UC 口令解析。
    /// 夸克 / UC 口令只能经第三方「星海」服务换取分享 ID（只发口令文字），没开「总是允许」时先征得同意
    private func resolveKouling(consented: Bool = false) {
        let text = input
        let quarkFirst = QuarkKouling.mentionsQuarkOrUC(text)
        let tryXunlei = !quarkFirst && XunleiKouling.looksLikeKouling(text)
        let canQuark = QuarkKouling.extract(text) != nil
        let allowed = app.settings.allowCommandService || consented
        run {
            var lastError: Error?
            if tryXunlei {
                do {
                    let url = try await XunleiKouling.resolve(text)
                    try Task.checkCancellation()
                    guard let share = ShareLinkParser.parse(url) else { throw CloudnError("口令对应的链接无法识别") }
                    shareModel = ShareBrowserModel(app: app, share: share, pwd: share.pwd, sourceText: url)
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            guard canQuark else { throw lastError ?? CloudnError("无法识别该口令") }
            guard allowed else {
                askingKoulingConsent = true
                return
            }
            let url = try await QuarkKouling.resolve(text)
            try Task.checkCancellation()
            guard let share = ShareLinkParser.parse(url) else { throw CloudnError("口令对应的链接无法识别") }
            shareModel = ShareBrowserModel(app: app, share: share, pwd: share.pwd, sourceText: url)
        }
    }
}

/// 最近记录的一行：平台图标、标题、来源、下载情况
private struct HistoryRow: View {
    let item: Bookmark
    let progress: (done: Int, total: Int)?
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let mark = ResolveView.mark(for: item.text) {
                    PlatformTile(mark: mark, size: 36)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.fillMuted).frame(width: 36, height: 36)
                        .overlay { IconView(.link, size: 18).foregroundStyle(Color.ink) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.body).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).foregroundStyle(Color.ink)
                    Text("\(item.source) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(Color.ink2).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trailing: some View {
        if let progress {
            if progress.done == progress.total {
                IconView(.check, size: 18).foregroundStyle(Color.success).accessibilityLabel("已下载")
            } else {
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(Color.track, lineWidth: 2)
                        Circle().trim(from: 0, to: Double(progress.done) / Double(max(1, progress.total)))
                            .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)
                    Text("\(progress.done)/\(progress.total)").font(.monoSmall).foregroundStyle(.tint)
                }
            }
        } else {
            IconView(.chevronRight, size: 14).foregroundStyle(Color.ink3)
        }
    }
}

/// 批量任务的一行：标题、进度、失败数；点开回到进度页
private struct BatchJobRow: View {
    let job: BatchJob
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if job.running {
                        ProgressRing(value: Double(job.doneCount + job.failedCount) / Double(max(1, job.items.count)), size: 22)
                    } else if job.failedCount > 0 {
                        IconView(.warning, size: 18).foregroundStyle(Color.clayInk)
                    } else if job.finished {
                        IconView(.checkCircle, size: 18).foregroundStyle(Color.success)
                    } else {
                        IconView(.clock, size: 18).foregroundStyle(Color.ink3)
                    }
                }
                .frame(width: 36, height: 36)
                .background(Color.fillMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.body).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).foregroundStyle(Color.ink)
                    Text(detail).font(.caption).foregroundStyle(job.failedCount > 0 ? Color.clayInk : Color.ink2)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                Spacer(minLength: 0)
                IconView(.chevronRight, size: 14).foregroundStyle(Color.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(job.title)，\(detail)")
    }

    private var detail: String {
        var text = "\(job.doneCount) / \(job.items.count) 已加入下载"
        if job.failedCount > 0 { text += " · \(job.failedCount) 个失败" }
        if job.running { text += " · 解析中…" } else if !job.finished { text += " · 已停止" }
        return text
    }
}

/// 一段输入的识别结果
private struct InputDetection {
    let detected: DetectedInput?
    /// 识别不出链接时：像迅雷口令 / 能取出夸克（UC）口令
    let xunlei: Bool
    let quark: Bool
    /// 识别成视频时，文本里所有视频链接（去重）
    let batchLinks: [String]

    @MainActor init(_ text: String) {
        let detected = DetectedInput.detect(text)
        self.detected = detected
        xunlei = detected == nil && XunleiKouling.looksLikeKouling(text)
        quark = detected == nil && QuarkKouling.extract(text) != nil
        if case .video = detected { batchLinks = ResolveView.videoLinks(in: text) } else { batchLinks = [] }
    }
}

/// 网页嗅探要打开的地址
private struct SniffTarget: Identifiable {
    let url: String
    var id: String { url }
}

/// 「去登录」之后要重新解析的链接；stamp 是登录前主账号的保存时间，用来判断是否真的重新登录了
private struct LoginRetry {
    let text: String
    let kind: AccountKind
    let stamp: Date?
}

/// 解析失败后的嗅探提议
private struct SniffOffer {
    let url: String
    let message: String
    /// 原始输入：登录后重新解析用
    var text = ""
    /// 可以就地登录的平台（需要登录 / 登录已失效时）
    var loginKind: AccountKind?
}
