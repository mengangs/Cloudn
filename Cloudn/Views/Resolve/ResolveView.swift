// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

struct ResolveView: View {
    @Environment(AppModel.self) private var app
    @State private var input = ""
    @State private var pwd = ""
    @State private var parsingVideo = false
    @State private var shareModel: ShareBrowserModel?
    @State private var videoResult: VideoParseResult?
    @State private var clipboardHasURL = false
    @State private var showBookmarks = false
    @FocusState private var focused: Bool

    private var detected: DetectedInput? { DetectedInput.detect(input) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inputCard
                    if !app.bookmarks.bookmarks.isEmpty { shortcutSection }
                    if !app.bookmarks.history.isEmpty { historySection }
                    platformFooter
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Cloudn")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showBookmarks = true } label: { Image(systemName: "star") }
                        .accessibilityLabel("收藏")
                }
            }
            .navigationDestination(item: $shareModel) { model in
                ShareBrowserView(model: model)
            }
            .navigationDestination(item: $videoResult) { result in
                VideoResultView(result: result)
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarksView { bookmark in
                    showBookmarks = false
                    input = bookmark.text
                    resolve()
                }
            }
        }
        .onAppear(perform: consumePending)
        .onChange(of: app.pendingInput) { _, _ in consumePending() }
        .task { await checkClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await checkClipboard() }
        }
    }

    // MARK: 输入区

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("粘贴网盘分享链接、短视频链接或下载直链")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $input)
                    .focused($focused)
                    .frame(minHeight: 88, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in
                        input = text
                        pwd = ""
                        clipboardHasURL = false
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                if !input.isEmpty {
                    Button {
                        input = ""
                        pwd = ""
                    } label: {
                        Label("清空", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.secondary)
                }
                Spacer()
                if let detected { DetectionChip(detected: detected) }
            }

            if clipboardHasURL && input.isEmpty && app.settings.clipboardHint {
                Label("剪贴板里有链接，点「粘贴」即可填入", systemImage: "doc.on.clipboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if case .share(let share) = detected {
                HStack {
                    Image(systemName: "key")
                        .foregroundStyle(.secondary)
                    TextField(share.pwd.map { "提取码（已识别：\($0)）" } ?? "提取码（没有可留空）", text: $pwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button(action: resolve) {
                HStack {
                    if parsingVideo { ProgressView().tint(.white) }
                    Text(parsingVideo ? "正在解析…" : buttonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(detected == nil || parsingVideo)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.top, 8)
    }

    private var buttonTitle: String {
        if case .direct = detected { return "添加到下载" }
        return "开始解析"
    }

    // MARK: 收藏与历史

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "收藏", action: "全部") { showBookmarks = true }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(app.bookmarks.bookmarks.prefix(12)) { b in
                        Button {
                            input = b.text
                            resolve()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                Text(b.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                                Text(b.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 130, height: 92, alignment: .topLeading)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近解析", action: "清除") { app.bookmarks.clearHistory() }
            VStack(spacing: 0) {
                ForEach(Array(app.bookmarks.history.prefix(8).enumerated()), id: \.element.id) { index, h in
                    Button {
                        input = h.text
                        resolve()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.title).lineLimit(1).foregroundStyle(.primary)
                                Text(h.source).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < min(8, app.bookmarks.history.count) - 1 { Divider().padding(.leading, 44) }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var platformFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("支持的平台")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("网盘：" + SharePlatform.allCases.filter(\.isResolvable).map(\.displayName).joined(separator: "、"))
            Text("视频 / 图集：" + VideoPlatform.allCases.map(\.displayName).joined(separator: "、"))
            Text("以及任意 http(s) 下载直链与 m3u8")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    // MARK: 动作

    private func consumePending() {
        guard let text = app.pendingInput else { return }
        app.pendingInput = nil
        input = text
        resolve()
    }

    private func checkClipboard() async {
        // 只探测「有没有链接」，不读取内容，不会触发系统的粘贴提示
        guard app.settings.clipboardHint, UIPasteboard.general.hasStrings else { clipboardHasURL = false; return }
        let found = try? await UIPasteboard.general.detectPatterns(for: [.probableWebURL])
        clipboardHasURL = found?.contains(.probableWebURL) ?? false
    }

    private func resolve() {
        focused = false
        guard let detected else { return }
        switch detected {
        case .share(let share):
            guard share.platform.isResolvable else {
                app.show("暂不支持解析\(share.platform.displayName)，敬请期待", error: true)
                return
            }
            let effectivePwd = pwd.isEmpty ? share.pwd : pwd
            // 收藏/历史里保存的文本要带上手填的提取码，下次点开能直接解析
            var source = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if let p = effectivePwd, !p.isEmpty, ShareLinkParser.parse(source)?.pwd != p { source += " 提取码：\(p)" }
            let model = ShareBrowserModel(app: app, share: share, pwd: effectivePwd, sourceText: source)
            shareModel = model
        case .video(let link):
            parsingVideo = true
            let text = input
            Task {
                defer { parsingVideo = false }
                do {
                    let result = try await app.videoService.parse(link)
                    guard !result.medias.isEmpty else {
                        app.show("没有解析到可下载的媒体", error: true)
                        return
                    }
                    app.bookmarks.record(title: result.title.isEmpty ? result.platform.displayName : result.title,
                                         text: text, source: result.platform.displayName)
                    videoResult = result
                } catch {
                    app.show(error.localizedDescription, error: true)
                }
            }
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
}

private struct DetectionChip: View {
    let detected: DetectedInput

    var body: some View {
        let (symbol, text) = describe
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
            .lineLimit(1)
    }

    private var describe: (String, String) {
        switch detected {
        case .share(let s): return (s.platform.symbol, s.platform.displayName)
        case .video(let v): return (v.platform.symbol, v.platform.displayName)
        case .direct: return ("arrow.down.circle", "下载直链")
        }
    }
}

struct SectionHeader: View {
    let title: String
    var action: String?
    var onAction: (() -> Void)?

    init(title: String, action: String? = nil, onAction: (() -> Void)? = nil) {
        self.title = title
        self.action = action
        self.onAction = onAction
    }

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let action, let onAction {
                Button(action, action: onAction).font(.subheadline)
            }
        }
        .padding(.horizontal, 4)
    }
}
