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
    @State private var shareModel: ShareBrowserModel?
    @State private var videoResult: VideoParseResult?
    @State private var githubLink: GitHubLink?
    @State private var torrentTarget: TorrentTarget?
    @State private var importingTorrent = false
    @State private var showBookmarks = false
    /// 剪贴板里有链接、且这一条还没处理过
    @State private var clipboardOffer = false
    /// 已处理（粘贴或关掉）过的剪贴板版本，同一条内容只提示一次
    @AppStorage("clipboardHandledChange") private var handledChange = -1
    @FocusState private var focused: Bool

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var detected: DetectedInput? { DetectedInput.detect(input) }
    /// 识别不出链接、但像迅雷中文口令
    private var isKouling: Bool { detected == nil && XunleiKouling.looksLikeKouling(input) }
    private var canSubmit: Bool { detected != nil || isKouling }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("解析")
                        .font(.pageTitle)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 4)
                        .padding(.top, 12)
                    if !app.bookmarks.bookmarks.isEmpty { bookmarkSection }
                    if !app.bookmarks.history.isEmpty { historySection }
                    supportFooter
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
            // 点空白处收起键盘
            .simultaneousGesture(TapGesture().onEnded { focused = false })
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if clipboardOffer && trimmed.isEmpty && app.settings.clipboardHint {
                        clipboardCard.transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    composer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: clipboardOffer)
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: detectionKey)
            }
            .background(Color.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $shareModel) { ShareBrowserView(model: $0) }
            .navigationDestination(item: $videoResult) { VideoResultView(result: $0) }
            .navigationDestination(item: $githubLink) { link in
                switch link {
                case .account(let owner): GitHubAccountView(owner: owner)
                case .repository(let owner, let repo, let sub): GitHubRepoView(owner: owner, repo: repo, subPath: sub)
                case .file: EmptyView()
                }
            }
            .navigationDestination(item: $torrentTarget) { TorrentView(target: $0) }
            .fileImporter(isPresented: $importingTorrent, allowedContentTypes: [.torrent, .data]) { result in
                if case .success(let url) = result { app.openTorrentFile(url) }
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarksView { bookmark in
                    showBookmarks = false
                    open(text: bookmark.text)
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
            Button { cancelWork() } label: { ProgressRing(value: nil, size: 30) }
                .buttonStyle(.plain)
                .accessibilityLabel("正在解析，点按取消")
        } else if trimmed.isEmpty {
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
                    .opacity(canSubmit ? 1 : 0.4)
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
        if case .direct = detected { return "添加到下载" }
        if case .github(.file) = detected { return "添加到下载" }
        return "开始解析"
    }

    /// 识别结果：平台 + 说明；网盘分享可就地改提取码
    @ViewBuilder
    private var detectionRow: some View {
        HStack(spacing: 8) {
            if let mark = detectedMark {
                PlatformGlyph(mark: mark, size: 15).foregroundStyle(Color.ink2)
            } else {
                IconView(canSubmit ? .download : .warning, size: 15).foregroundStyle(Color.ink3)
            }
            Text(detectionText).font(.footnote).foregroundStyle(Color.ink2).lineLimit(1)
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
    }

    private var detectedMark: PlatformMark? {
        switch detected {
        case .share(let s): return .share(s.platform)
        case .video(let v): return .video(v.platform)
        case .github: return .github
        case .magnet: return .magnet
        case .direct, nil: return isKouling ? .share(.xunlei) : nil
        }
    }

    private var detectionText: String {
        switch detected {
        case .share(let s): return s.platform.displayName
        case .video(let v): return v.platform.displayName + (input.count > v.url.count + 8 ? " · 已从文案里取出链接" : "")
        case .github(.file): return "GitHub 文件 · 直接下载"
        case .github(.account(let owner)): return "GitHub · \(owner) 的仓库"
        case .github: return "GitHub 仓库"
        case .direct: return "下载直链"
        case .magnet(let m): return m.displayName.isEmpty ? "磁力链接" : "磁力链接 · " + m.displayName
        case nil: return isKouling ? "迅雷口令" : "没有识别到链接"
        }
    }

    // MARK: 剪贴板

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
            .tint(Color.ink)
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

    // MARK: 收藏与最近

    private var bookmarkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "收藏")
                Button("全部") { showBookmarks = true }.font(.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(app.bookmarks.bookmarks.prefix(12)) { b in
                        Button { open(text: b.text) } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                markView(for: b.text, size: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(Color.ink)
                                    Text(b.source).font(.caption).foregroundStyle(Color.ink2).lineLimit(1)
                                }
                            }
                            .frame(width: 124, alignment: .leading)
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
                    .rowDialog("清空最近记录？", isPresented: $confirmClearHistory, message: "收藏不受影响") {
                        Button("清空", role: .destructive) { withAnimation { app.bookmarks.clearHistory() } }
                    }
            }
            VStack(spacing: 0) {
                let items = Array(app.bookmarks.history.prefix(10))
                ForEach(Array(items.enumerated()), id: \.element.id) { index, h in
                    HistoryRow(item: h, progress: downloadProgress(for: h.text)) { open(text: h.text) }
                        .contextMenu {
                            Button { UIPasteboard.general.string = h.text } label: { Label { Text("复制链接") } icon: { Image(icon: .link) } }
                            Button { app.bookmarks.add(title: h.title, text: h.text, source: h.source) } label: {
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
        guard let share = ShareLinkParser.parse(text),
              let key = app.downloads.shareKey(platform: share.platform, shareURL: share.url),
              let p = app.downloads.shareProgress[key] else { return nil }
        return (p.done, p.total)
    }

    /// 支持的平台：一排图标，不写长段文字
    private var supportFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(SharePlatform.allCases) { PlatformGlyph(mark: .share($0), size: 15) }
            }
            HStack(spacing: 10) {
                ForEach(VideoPlatform.allCases) { PlatformGlyph(mark: .video($0), size: 15) }
                PlatformGlyph(mark: .github, size: 15)
            }
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
        working = false
    }

    private func submit() {
        focused = false
        editingPwd = false
        guard let detected else {
            if isKouling { resolveKouling() }
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
            run {
                let result = try await app.videoService.parse(link)
                try Task.checkCancellation()
                guard !result.medias.isEmpty else { throw CloudnError("没有解析到可下载的媒体") }
                app.bookmarks.record(title: result.title.isEmpty ? result.platform.displayName : result.title,
                                     text: text, source: result.platform.displayName)
                videoResult = result
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
            let name = URL(string: url).map { u -> String in
                let last = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
                return last.isEmpty || last == "/" ? (u.host ?? "download") : last
            } ?? "download"
            let kind: DownloadKind = url.lowercased().contains(".m3u8") ? .hls : .file
            app.downloads.enqueue(DownloadRequest(url: url, headers: ["User-Agent": VideoHTTP.uaChrome],
                                                  fileName: kind == .hls ? (name as NSString).deletingPathExtension + ".mp4" : name,
                                                  kind: kind, source: "直链"))
            app.show("已添加到下载")
            input = ""
        }
    }

    /// 后台执行一次解析；发送键变成可取消的进度环
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        workTask?.cancel()
        working = true
        workTask = Task { @MainActor in
            defer { working = false }
            do {
                try await operation()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { app.show(error.localizedDescription, error: true) }
            }
        }
    }

    /// 迅雷中文口令：直接问迅雷换成带提取码的分享链接，再按普通分享打开
    private func resolveKouling() {
        let text = input
        run {
            let url = try await XunleiKouling.resolve(text)
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
                    Text(item.title).font(.body).lineLimit(1).foregroundStyle(Color.ink)
                    Text("\(item.source) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(Color.ink2).lineLimit(1)
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
                        Circle().stroke(Color.hairline, lineWidth: 2)
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
