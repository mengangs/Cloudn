// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

struct ShareBrowserView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ShareBrowserModel
    @State private var actionFile: ShareFile?
    @State private var preview: MediaPreviewItem?
    @State private var retryPwd = ""
    @State private var saveItems: SaveItems?
    @State private var textPreview: TextPreviewItem?
    @State private var query = ""
    /// 标题块滚出屏幕后，导航栏才显示标题
    @State private var headerHidden = false
    /// 每个目录离开时停在哪一行，返回时回到原处
    @State private var topRow: String?
    @State private var anchors: [String: String] = [:]
    /// 拖选：起点、是选还是取消、开始前的选择
    @State private var rowFrames = FrameBox()
    @State private var drag: (start: String, adding: Bool, base: Set<String>)?

    private static let topID = "share.top"
    private static let space = "share.scroll"

    /// 当前目录按文件名过滤（不区分大小写）
    private var visibleFiles: [ShareFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.files : model.files.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header.id(Self.topID)
                    if let notice = model.guestNotice { guestCard(notice) }
                    if !model.crumbs.isEmpty { pathBar(proxy) }
                    content(proxy)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 96)
            }
            .coordinateSpace(name: Self.space)
            .scrollPosition(id: $topRow, anchor: .top)
            .scrollDismissesKeyboard(.immediately)
            .background(Color.paper)
            .onPreferenceChange(HeaderOffsetKey.self) { y in
                let hidden = y < 0
                if hidden != headerHidden { headerHidden = hidden }
            }
            .navigationTitle(headerHidden ? (model.crumbs.last?.name ?? model.title) : "")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "在当前文件夹中搜索")
            .onChange(of: model.currentDir) { query = "" }
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { actionBar.padding(.horizontal, 16).padding(.bottom, 8) }
            .refreshable { await model.reloadCurrent(force: true) }
            .task { await model.open() }
            .sensoryFeedback(.selection, trigger: model.selection)
            .animation(.snappy(duration: 0.25), value: model.selecting)
            .animation(.snappy(duration: 0.25), value: model.batch?.total)
        }
        .sheet(item: $preview) { item in
            MediaPreviewView(item: item)
        }
        .sheet(item: $textPreview) { TextPreviewView(item: $0) }
        .sheet(item: $saveItems) { items in
            SaveToDriveView(model: model, files: items.files)
        }
    }

    // MARK: 标题块

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PlatformGlyph(mark: .share(model.share.platform), size: 15)
                Text(model.share.platform.displayName)
                if let kind = model.share.platform.accountKind {
                    Text("·")
                    Text(app.accounts.isLoggedIn(kind) ? "已登录" : "未登录")
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.ink2)
            Text(model.session == nil && model.errorMessage == nil ? "正在打开分享…" : model.title)
                .font(.pageTitle)
                .foregroundStyle(Color.ink)
                .lineLimit(3)
                .textSelection(.enabled)
            if !summary.isEmpty {
                Text(summary).font(.monoSmall).foregroundStyle(Color.ink3)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: HeaderOffsetKey.self, value: geo.frame(in: .named(Self.space)).maxY)
            }
        }
    }

    private var summary: String {
        let dirs = model.files.filter(\.isDirectory).count
        let count = model.files.count - dirs
        let size = model.files.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        var parts: [String] = []
        if dirs > 0 { parts.append("\(dirs) 个文件夹") }
        if count > 0 { parts.append("\(count) 个文件") }
        if size > 0 { parts.append(ByteFormat.string(size)) }
        return parts.joined(separator: " · ")
    }

    /// 未登录提示：说清能做什么，旁边就是登录入口
    private func guestCard(_ notice: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            IconView(.user, size: 18).foregroundStyle(Color.clayInk)
            Text(notice)
                .font(.footnote)
                .foregroundStyle(Color.clayInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("登录") { app.selectedTab = .me }
                .buttonStyle(PillButtonStyle(kind: .dark, height: 30))
                .font(.footnote)
        }
        .padding(14)
        .background(Color.claySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 路径条：每一级是一个胶囊，当前目录实心
    private func pathBar(_ proxy: ScrollViewProxy) -> some View {
        ScrollViewReader { bar in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    crumbChip("全部文件", current: false) { navigate(proxy) { await model.jump(to: nil) } }
                    ForEach(Array(model.crumbs.enumerated()), id: \.offset) { index, crumb in
                        IconView(.chevronRight, size: 12).foregroundStyle(Color.ink3)
                        let current = index == model.crumbs.count - 1
                        crumbChip(crumb.name, current: current) { navigate(proxy) { await model.jump(to: index) } }
                            .id(index)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear { bar.scrollTo(model.crumbs.count - 1, anchor: .trailing) }
            .onChange(of: model.crumbs.count) { withAnimation { bar.scrollTo(model.crumbs.count - 1, anchor: .trailing) } }
        }
    }

    private func crumbChip(_ title: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(current ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 180)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .foregroundStyle(current ? Color.paper : Color.ink)
                .background(current ? Color.ink : Color.surface, in: Capsule())
                .overlay { if !current { Capsule().strokeBorder(Color.hairline, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .disabled(current)
    }

    // MARK: 文件列表

    @ViewBuilder
    private func content(_ proxy: ScrollViewProxy) -> some View {
        if let error = model.errorMessage {
            errorCard(error)
        } else if model.loading && model.files.isEmpty {
            placeholderList
        } else if model.files.isEmpty {
            emptyCard(icon: .folder, title: "空文件夹", detail: "这里没有文件")
        } else if visibleFiles.isEmpty {
            emptyCard(icon: .search, title: "没有匹配的文件", detail: "当前文件夹里没有名字包含「\(query)」的文件")
        } else {
            VStack(spacing: 0) {
                if model.loading { ProgressLine(value: nil).padding(.horizontal, 14).padding(.top, 2) }
                LazyVStack(spacing: 0) {
                    let states = app.downloads.shareFiles[model.share.url] ?? [:]
                    let files = visibleFiles
                    ForEach(Array(files.enumerated()), id: \.element.fid) { index, file in
                        row(file, state: states[file.fid], proxy: proxy)
                        if index < files.count - 1 { RowDivider(leading: model.selecting ? 96 : 64) }
                    }
                }
                .scrollTargetLayout()
            }
            .card()
            .overlay(alignment: .leading) { if model.selecting { dragStrip } }
            .onPreferenceChange(RowFrameKey.self) { rowFrames.frames = $0 }
        }
    }

    private func row(_ file: ShareFile, state: DownloadItem?, proxy: ScrollViewProxy) -> some View {
        let selected = model.selection.contains(file.fid)
        return HStack(spacing: 12) {
            if model.selecting {
                SelectMark(on: selected)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            FileIcon(name: file.name, isDirectory: file.isDirectory)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.body)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if !file.isDirectory && file.size > 0 { Text(ByteFormat.string(file.size)) }
                    if !file.modified.isEmpty { Text(FileRow.dateText(file.modified)) }
                }
                .font(.caption)
                .foregroundStyle(Color.ink3)
            }
            Spacer(minLength: 0)
            if !model.selecting { trailing(file, state: state) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(selected ? Color.claySoft.opacity(0.55) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { tap(file, proxy: proxy) }
        .contextMenu { menu(for: file, proxy: proxy) }
        .rowDialog(file.name, isPresented: presenting($actionFile) { $0.fid == file.fid }) { fileActions(file) }
        .background {
            if model.selecting {
                GeometryReader { geo in
                    Color.clear.preference(key: RowFrameKey.self, value: [file.fid: geo.frame(in: .named(Self.space))])
                }
            }
        }
    }

    /// 行尾：文件夹是箭头，文件是下载状态
    @ViewBuilder
    private func trailing(_ file: ShareFile, state: DownloadItem?) -> some View {
        if file.isDirectory && !model.busyFileIds.contains(file.fid) {
            IconView(.chevronRight, size: 14).foregroundStyle(Color.ink3)
        } else {
            DownloadStateControl(item: state, busy: model.busyFileIds.contains(file.fid)) {
                run { try await model.download(file); app.show("已添加到下载") }
            }
        }
    }

    /// 多选时左侧一条拖动区：按住上下滑，一次选中（或取消）一串
    private var dragStrip: some View {
        Color.clear
            .frame(width: 52)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let files = visibleFiles
                        guard let current = fileIndex(at: value.location.y, in: files) else { return }
                        if drag == nil {
                            guard let start = fileIndex(at: value.startLocation.y, in: files) else { return }
                            let fid = files[start].fid
                            drag = (fid, !model.selection.contains(fid), model.selection)
                        }
                        guard let drag, let start = files.firstIndex(where: { $0.fid == drag.start }) else { return }
                        let range = Set(files[min(start, current)...max(start, current)].map(\.fid))
                        let next = drag.adding ? drag.base.union(range) : drag.base.subtracting(range)
                        if next != model.selection { model.selection = next }
                    }
                    .onEnded { _ in drag = nil }
            )
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { value in
                    let files = visibleFiles
                    guard let index = fileIndex(at: value.location.y, in: files) else { return }
                    let fid = files[index].fid
                    if model.selection.contains(fid) { model.selection.remove(fid) } else { model.selection.insert(fid) }
                }
            )
    }

    private func fileIndex(at y: CGFloat, in files: [ShareFile]) -> Int? {
        files.firstIndex { rowFrames.frames[$0.fid].map { $0.minY <= y && y < $0.maxY } ?? false }
    }

    private var placeholderList: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.fillMuted).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Color.fillMuted).frame(width: [180, 140, 210, 120, 160, 190][index], height: 11)
                        Capsule().fill(Color.fillMuted.opacity(0.7)).frame(width: 70, height: 8)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                if index < 5 { RowDivider(leading: 64) }
            }
        }
        .card()
        .phaseAnimator([0.55, 1]) { view, phase in view.opacity(phase) } animation: { _ in .easeInOut(duration: 0.9) }
        .accessibilityLabel("正在加载")
    }

    private func emptyCard(icon: Icon, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            IconView(icon, size: 26).foregroundStyle(Color.ink3)
            Text(title).font(.cardTitle).foregroundStyle(Color.ink)
            Text(detail).font(.footnote).foregroundStyle(Color.ink2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .card()
    }

    /// 出错时直接给下一步：缺提取码就地输入，其他错误给重试
    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                IconView(model.needsPassword ? .lock : .warning, size: 18).foregroundStyle(Color.clayInk)
                Text(error).font(.subheadline).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
            }
            if model.needsPassword {
                HStack(spacing: 10) {
                    TextField("提取码", text: $retryPwd)
                        .font(.mono)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { retry() }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Color.fillMuted, in: Capsule())
                    Button("解析", action: retry)
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 40))
                        .disabled(retryPwd.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button { Task { await model.reloadCurrent(force: true) } } label: {
                    Label { Text("重试") } icon: { Image(icon: .refresh) }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func retry() {
        let pwd = retryPwd.trimmingCharacters(in: .whitespaces)
        guard !pwd.isEmpty else { return }
        Task { await model.retry(with: pwd) }
    }

    // MARK: 工具栏与底部操作

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.selecting {
                Button(model.selection.count == visibleFiles.count ? "全不选" : "全选") {
                    model.selection = model.selection.count == visibleFiles.count ? [] : Set(visibleFiles.map(\.fid))
                }
                Button("完成") { model.selecting = false; model.selection = [] }
                    .fontWeight(.semibold)
            } else {
                Button { model.toggleBookmark() } label: {
                    Image(icon: .star).foregroundStyle(model.isBookmarked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.ink))
                }
                .accessibilityLabel(model.isBookmarked ? "取消收藏" : "收藏")
                .disabled(model.session == nil)
                Menu {
                    Button { model.selecting = true } label: { Label { Text("多选") } icon: { Image(icon: .checkCircle) } }
                        .disabled(model.files.isEmpty)
                    Button { UIPasteboard.general.string = model.sourceText; app.show("已复制分享链接") } label: {
                        Label { Text("复制分享链接") } icon: { Image(icon: .link) }
                    }
                    if let url = URL(string: model.share.url) {
                        Link(destination: url) { Label { Text("在浏览器中打开") } icon: { Image(icon: .share) } }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Color.ink)
                }
            }
        }
    }

    /// 底部浮动操作条：平时是「下载全部 / 转存 / 多选」，多选时是已选数量与操作，批量取链时是进度
    @ViewBuilder
    private var actionBar: some View {
        if let batch = model.batch {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("正在获取直链").font(.footnote.weight(.medium))
                    Spacer()
                    Text("\(batch.done) / \(batch.total)").font(.monoSmall)
                }
                .foregroundStyle(Color.ink)
                ProgressLine(value: Double(batch.done) / Double(max(1, batch.total)))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
            .floatingShadow()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.selecting {
            let chosen = model.files.filter { model.selection.contains($0.fid) }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chosen.isEmpty ? "未选择" : "已选 \(chosen.count) 项").font(.subheadline.weight(.semibold))
                    Text(selectionDetail(chosen)).font(.monoSmall).foregroundStyle(Color.ink3)
                }
                .foregroundStyle(Color.ink)
                .contentTransition(.numericText())
                Spacer(minLength: 0)
                if model.saver != nil {
                    Button("转存") { startSave(chosen) }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
                }
                Button { Task { await model.downloadSelected() } } label: {
                    Label { Text("下载") } icon: { Image(icon: .download) }
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 40))
            }
            .disabled(chosen.isEmpty)
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Color.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.hairline, lineWidth: 1) }
            .floatingShadow()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !model.files.isEmpty && model.errorMessage == nil {
            HStack(spacing: 8) {
                Button { Task { await model.downloadAll() } } label: {
                    HStack(spacing: 6) {
                        Image(icon: .download)
                        Text("下载全部")
                        Text("· \(model.files.count) 项").foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 46))
                if model.saver != nil {
                    Button("转存") { startSave(model.files) }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 46))
                }
                Button { model.selecting = true } label: { IconView(.checkCircle, size: 19) }
                    .buttonStyle(CircleIconButtonStyle(size: 46))
                    .background(Color.surface, in: Circle())
                    .accessibilityLabel("多选")
            }
            .padding(6)
            .background(Color.paper.opacity(0.92), in: Capsule())
            .floatingShadow()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func selectionDetail(_ files: [ShareFile]) -> String {
        let dirs = files.filter(\.isDirectory).count
        let size = files.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        var parts: [String] = []
        if size > 0 { parts.append(ByteFormat.string(size)) }
        if dirs > 0 { parts.append("含 \(dirs) 个文件夹") }
        return parts.isEmpty ? "按住左侧上下滑动可连续选择" : parts.joined(separator: " · ")
    }

    // MARK: 动作

    /// 打开「转存到我的网盘」；没登录就引导去「我的」
    private func startSave(_ files: [ShareFile]) {
        guard !files.isEmpty else { return }
        if model.saveNeedsLogin {
            app.show("转存需要先登录\(model.share.platform.displayName)", error: true)
            app.selectedTab = .me
            return
        }
        saveItems = SaveItems(files: files)
    }

    /// 切换目录：记住离开时的位置，进入新目录回到顶部，返回旧目录回到原处
    private func navigate(_ proxy: ScrollViewProxy, _ action: @escaping () async -> Void) {
        if let topRow { anchors[model.currentDir] = topRow }
        Task {
            await action()
            try? await Task.sleep(for: .milliseconds(40))
            proxy.scrollTo(anchors[model.currentDir] ?? Self.topID, anchor: .top)
        }
    }

    private func tap(_ file: ShareFile, proxy: ScrollViewProxy) {
        if model.selecting {
            if model.selection.contains(file.fid) { model.selection.remove(file.fid) } else { model.selection.insert(file.fid) }
        } else if file.isDirectory {
            navigate(proxy) { await model.enter(file) }
        } else {
            actionFile = file
        }
    }

    @ViewBuilder
    private func menu(for file: ShareFile, proxy: ScrollViewProxy) -> some View {
        if file.isDirectory {
            Button { navigate(proxy) { await model.enter(file) } } label: { Label { Text("打开") } icon: { Image(icon: .folder) } }
            Button { Task { await model.downloadFolder(file) } } label: { Label { Text("下载整个文件夹") } icon: { Image(icon: .download) } }
            if model.saver != nil {
                Button { startSave([file]) } label: { Label { Text("转存到我的网盘") } icon: { Image(icon: .save) } }
            }
        } else {
            fileActions(file)
        }
    }

    @ViewBuilder
    private func fileActions(_ file: ShareFile) -> some View {
        Button { run { try await model.download(file); app.show("已添加到下载") } } label: {
            Label { Text("下载") } icon: { Image(icon: .download) }
        }
        let kind = FileNames.kind(of: file.name)
        if kind == .video || kind == .audio || kind == .image {
            Button {
                run {
                    let link = try await model.link(for: file)
                    preview = MediaPreviewItem(url: link.url, headers: link.headers, title: file.name,
                                               kind: kind == .image ? .image : (kind == .audio ? .audio : .video))
                }
            } label: {
                Label { Text(kind == .image ? "预览" : "在线播放") } icon: { Image(icon: kind == .image ? .eye : .play) }
            }
        }
        if kind == .text {
            Button {
                run {
                    let link = try await model.link(for: file)
                    textPreview = TextPreviewItem(url: link.url, headers: link.headers, title: file.name)
                }
            } label: {
                Label { Text("在线查看") } icon: { Image(icon: .text) }
            }
        }
        Button {
            run {
                let link = try await model.link(for: file)
                UIPasteboard.general.string = link.url
                app.show("已复制直链（需带请求头才能下载）")
            }
        } label: {
            Label { Text("复制直链") } icon: { Image(icon: .link) }
        }
        if model.saver != nil {
            Button { startSave([file]) } label: { Label { Text("转存到我的网盘") } icon: { Image(icon: .save) } }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { app.show(error.localizedDescription, error: true) }
        }
    }
}

/// 行位置只给拖选用，变化时不需要重绘
private final class FrameBox {
    var frames: [String: CGRect] = [:]
}

private struct HeaderOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct RowFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

enum FileRow {
    /// 接口给的时间可能是毫秒时间戳，也可能已经是文本
    static func dateText(_ raw: String) -> String {
        guard let n = Double(raw) else { return raw }
        let date = Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        return date.formatted(date: .numeric, time: .shortened)
    }
}

/// 待转存的条目（sheet 用）
struct SaveItems: Identifiable {
    let id = UUID()
    let files: [ShareFile]
}
