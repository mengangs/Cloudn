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
    @FocusState private var retryPwdFocused: Bool
    @State private var saveItems: SaveItems?
    /// 就地弹出的登录页；登录成功回来后重新打开分享（换成登录态）
    @State private var loginKind: AccountKind?
    /// 弹出登录页前主账号的保存时间：关掉登录页时据此判断是否真的（重新）登录了
    @State private var loginStamp: Date?
    @State private var textPreview: TextPreviewItem?
    /// 正在预览的文件取到的直链：可能是临时转存，预览关闭后清理
    @State private var previewLink: DownloadLink?
    @State private var filePreview: RemoteFileItem?
    @State private var query = ""
    /// 标题块滚出屏幕后，导航栏才显示标题
    @State private var headerHidden = false
    /// 每个目录离开时停在哪一行，返回时回到原处
    @State private var topRow: String?
    @State private var anchors: [String: String] = [:]
    /// 拖选：起点、是选还是取消、开始前的选择
    @State private var rowFrames = FrameBox()
    @State private var drag: (start: String, adding: Bool, base: Set<String>)?
    @Environment(\.dynamicTypeSize) private var typeSize

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
                .readableWidth()
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
            .safeAreaInset(edge: .bottom) { actionBar.padding(.horizontal, 16).padding(.bottom, 8).readableWidth() }
            .liftsToast(72)
            .refreshable { await model.reloadCurrent(force: true) }
            .task { await model.open() }
            // 离开分享页（返回、切到别的标签页）：预览 / 复制直链留下的临时转存一并清理；全屏预览盖住时不算离开
            .onDisappear { if preview == nil && textPreview == nil && filePreview == nil { model.releaseAllTemporary() } }
            .sensoryFeedback(.selection, trigger: model.selection)
            .animation(.snappy(duration: 0.25), value: model.selecting)
            .animation(.snappy(duration: 0.25), value: model.batch?.total)
        }
        .fullScreenCover(item: $preview, onDismiss: releasePreviewLink) { item in
            MediaPreviewView(item: item)
        }
        .sheet(item: $textPreview, onDismiss: releasePreviewLink) { TextPreviewView(item: $0) }
        .fullScreenCover(item: $filePreview, onDismiss: releasePreviewLink) { RemoteFilePreview(item: $0) }
        .sheet(item: $saveItems) { items in
            SaveToDriveView(model: model, files: items.files)
        }
        .sheet(item: $loginKind, onDismiss: {
            // 真的登录了才换登录态重新打开；直接关掉登录页不重开（重开会回到分享根目录）
            guard let kind = model.share.platform.accountKind, app.accounts.isLoggedIn(kind),
                  app.accounts.list(kind).first?.updatedAt != loginStamp else { return }
            Task { await model.retry(with: model.pwd) }
        }) { LoginSheet(kind: $0) }
    }

    // MARK: 标题块

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PlatformGlyph(mark: .share(model.share.platform), size: 15)
                Text(model.share.platform.displayName)
                if let kind = model.share.platform.accountKind {
                    Text("·")
                    if model.loginExpired {
                        Button { presentLogin() } label: {
                            Text("登录已失效 · 重新登录").foregroundStyle(Color.clayInk)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(app.accounts.isLoggedIn(kind) ? "已登录" : "未登录")
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.ink2)
            Text(headline)
                .font(.pageTitle)
                .foregroundStyle(Color.ink)
                .lineLimit(3)
                .textSelection(.enabled)
            if !summary.isEmpty {
                Text(summary).font(.figuresSmall).foregroundStyle(Color.ink3)
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

    /// 大标题：打开失败时直接说是什么情况，而不是只显示平台名
    private var headline: String {
        guard model.session == nil else { return model.title }
        if model.errorMessage == nil { return "正在打开分享…" }
        if model.needsPassword { return "需要提取码" }
        return model.linkInvalid ? "分享已失效" : "无法打开分享"
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
        AdaptiveStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconView(.user, size: 18).foregroundStyle(Color.clayInk)
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Color.clayInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button(model.loginExpired ? "重新登录" : "登录") { presentLogin() }
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
                .expandedHitArea(7)
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
            EmptyStateCard(icon: .folder, title: "空文件夹", detail: "这里没有文件")
        } else if visibleFiles.isEmpty {
            EmptyStateCard(icon: .search, title: "没有匹配的文件", detail: "当前文件夹里没有名字包含「\(query.trimmingCharacters(in: .whitespaces))」的文件")
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
                    .truncationMode(.middle)
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
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
            DownloadStateControl(item: state, busy: model.busyFileIds.contains(file.fid)) { download(file) }
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
                        .focused($retryPwdFocused)
                        .onSubmit { retry() }
                        // 要提取码时直接进入输入
                        .onAppear { retryPwdFocused = true }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(Color.fillMuted, in: Capsule())
                    Button("解析", action: retry)
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 40))
                        .disabled(retryPwd.trimmingCharacters(in: .whitespaces).isEmpty || model.loading)
                }
            } else if model.linkInvalid {
                // 已失效的分享重试也没用：给能做的下一步（大字号下上下排）
                AdaptiveStack(spacing: 10) {
                    Button { Clipboard.copy(model.sourceText); app.show("已复制分享链接") } label: {
                        Label { Text("复制链接").lineLimit(1) } icon: { Image(icon: .link) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                    if let url = URL(string: model.share.url) {
                        Link(destination: url) {
                            Label { Text("用浏览器打开").lineLimit(1) } icon: { Image(icon: .share) }
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                    }
                }
            } else {
                Button { Task { await model.reloadCurrent(force: true) } } label: {
                    Label { Text("重试") } icon: { Image(icon: .refresh) }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                .disabled(model.loading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func retry() {
        let pwd = retryPwd.trimmingCharacters(in: .whitespaces)
        guard !pwd.isEmpty, !model.loading else { return }
        Task { await model.retry(with: pwd) }
    }

    // MARK: 工具栏与底部操作

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.selecting {
                // 按搜索过滤后看得见的文件判断（selection 里可能还有过滤掉的）
                let visible = Set(visibleFiles.map(\.fid))
                let allOn = !visible.isEmpty && visible.isSubset(of: model.selection)
                Button(allOn ? "全不选" : "全选") {
                    if allOn { model.selection.subtract(visible) } else { model.selection.formUnion(visible) }
                }
                .disabled(visible.isEmpty)
                Button("完成") { model.selecting = false; model.selection = [] }
                    .fontWeight(.semibold)
            } else {
                Button { model.toggleBookmark() } label: {
                    Image(icon: .star).foregroundStyle(model.isBookmarked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.ink))
                }
                .accessibilityLabel(model.isBookmarked ? "取消收藏" : "收藏")
                .disabled(model.session == nil)
                .sensoryFeedback(.success, trigger: model.isBookmarked)
                Menu {
                    Button { model.selecting = true } label: { Label { Text("多选") } icon: { Image(icon: .checkCircle) } }
                        .disabled(model.files.isEmpty)
                    Button { Clipboard.copy(model.sourceText); app.show("已复制分享链接") } label: {
                        Label { Text("复制分享链接") } icon: { Image(icon: .link) }
                    }
                    if let url = URL(string: model.share.url) {
                        Link(destination: url) { Label { Text("在浏览器中打开") } icon: { Image(icon: .share) } }
                    }
                } label: {
                    Image(icon: .more).foregroundStyle(Color.ink)
                }
                .accessibilityLabel("更多")
            }
        }
    }

    /// 底部浮动操作条：平时是「全部下载 / 转存 / 多选」，多选时是已选数量与操作，批量取链时是进度
    @ViewBuilder
    private var actionBar: some View {
        if let batch = model.batch {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(batch.total == 0 ? "正在读取文件夹…" : "正在获取直链").font(.footnote.weight(.medium))
                    Spacer()
                    if batch.total > 0 { Text("\(batch.done) / \(batch.total)").font(.figuresSmall) }
                }
                .foregroundStyle(Color.ink)
                ProgressLine(value: batch.total == 0 ? nil : Double(batch.done) / Double(batch.total))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
            .floatingShadow()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.selecting {
            let chosen = model.files.filter { model.selection.contains($0.fid) }
            let large = typeSize.isAccessibilitySize
            // 辅助字号下：已选数量在上、两个按钮在下，各占一半宽
            AdaptiveStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chosen.isEmpty ? "未选择" : "已选 \(chosen.count) 项").font(.subheadline.weight(.semibold))
                    Text(selectionDetail(chosen)).font(.figuresSmall).foregroundStyle(Color.ink3)
                }
                .foregroundStyle(Color.ink)
                .contentTransition(.numericText())
                if !large { Spacer(minLength: 0) }
                // 按钮保持原宽，挤的是左边的说明文字；辅助字号下两个按钮上下排、各占满一行
                AdaptiveStack(spacing: 10) {
                    if model.saver != nil {
                        // 宽度放在标签里：放在按钮外面撑不开胶囊
                        Button { startSave(chosen) } label: { Text("转存").frame(maxWidth: large ? .infinity : nil) }
                            .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
                    }
                    Button { whenLoggedIn { Task { await model.downloadSelected() } } } label: {
                        Label { Text("下载") } icon: { Image(icon: .download) }
                            .frame(maxWidth: large ? .infinity : nil)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 40))
                }
                .fixedSize(horizontal: !large, vertical: false)
            }
            .disabled(chosen.isEmpty)
            .padding(.leading, large ? 14 : 18)
            .padding(.trailing, large ? 14 : 8)
            .padding(.vertical, large ? 12 : 8)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: large ? 24 : 30, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: large ? 24 : 30, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
            .floatingShadow()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if !model.files.isEmpty && model.errorMessage == nil {
            // 辅助字号下：「全部下载」占满一行，「转存」与多选在下一行
            AdaptiveStack(spacing: 8) {
                Button { whenLoggedIn { Task { await model.downloadAll() } } } label: {
                    HStack(spacing: 6) {
                        Image(icon: model.downloadNeedsLogin ? .user : .download)
                        if model.downloadNeedsLogin {
                            // 不登录下不了：主按钮直接说清下一步，点了就地登录
                            Text("登录后下载")
                        } else if typeSize.isAccessibilitySize {
                            // 大字号下合成一段文字，换行时不会拆成两块
                            Text("全部下载 · \(model.files.count) 项").multilineTextAlignment(.center)
                        } else {
                            Text("全部下载")
                            // 跟随按钮前景色（浅色强调色上是深墨色），只是淡一点
                            Text("· \(model.files.count) 项").opacity(0.75)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .primary, height: 46))
                HStack(spacing: 8) {
                    if model.saver != nil {
                        Button { startSave(model.files) } label: {
                            Text("转存").frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 46))
                    }
                    Button { model.selecting = true } label: { IconView(.checkCircle, size: 19) }
                        .buttonStyle(CircleIconButtonStyle(size: 46))
                        .background(Color.surface, in: Circle())
                        .accessibilityLabel("多选")
                }
            }
            .padding(6)
            .background(Color.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: 29, style: .continuous))
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
            presentLogin()
            return
        }
        saveItems = SaveItems(files: files)
    }

    private func presentLogin() {
        guard let kind = model.share.platform.accountKind else { return }
        loginStamp = app.accounts.list(kind).first?.updatedAt
        loginKind = kind
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
            Button { whenLoggedIn { Task { await model.downloadFolder(file) } } } label: { Label { Text("下载整个文件夹") } icon: { Image(icon: .download) } }
            if model.saver != nil {
                Button { startSave([file]) } label: { Label { Text("转存到我的网盘") } icon: { Image(icon: .save) } }
            }
        } else {
            fileActions(file)
        }
    }

    @ViewBuilder
    private func fileActions(_ file: ShareFile) -> some View {
        Button { download(file) } label: {
            Label { Text("下载") } icon: { Image(icon: .download) }
        }
        let kind = FileNames.kind(of: file.name)
        if kind == .video || kind == .audio || kind == .image {
            Button {
                run {
                    let link = try await model.temporaryLink(for: file)
                    model.releaseTemporary(previewLink)
                    previewLink = link
                    preview = MediaPreviewItem(url: link.url, headers: link.headers, title: file.name,
                                               kind: kind == .image ? .image : (kind == .audio ? .audio : .video))
                }
            } label: {
                Label { Text(kind == .image ? "预览" : "在线播放") } icon: { Image(icon: kind == .image ? .eye : .play) }
            }
        }
        if kind == .document {
            Button {
                run {
                    let link = try await model.temporaryLink(for: file)
                    model.releaseTemporary(previewLink)
                    previewLink = link
                    filePreview = RemoteFileItem(url: link.url, headers: link.headers, name: file.name, size: file.size)
                }
            } label: {
                Label { Text("预览") } icon: { Image(icon: .eye) }
            }
        }
        if kind == .text {
            Button {
                run {
                    let link = try await model.temporaryLink(for: file)
                    model.releaseTemporary(previewLink)
                    previewLink = link
                    textPreview = TextPreviewItem(url: link.url, headers: link.headers, title: file.name)
                }
            } label: {
                Label { Text("在线查看") } icon: { Image(icon: .text) }
            }
        }
        Button {
            run {
                let link = try await model.temporaryLink(for: file)
                Clipboard.copy(link.url)
                // 临时转存取到的直链：留一分钟给别的应用开始下载，之后清理网盘里的临时文件
                model.releaseTemporary(link, after: 60)
                app.show(link.cleanupToken == nil ? "已复制直链（下载可能需带请求头）" : "已复制直链（临时转存约 1 分钟后清理）")
            }
        } label: {
            Label { Text("复制直链") } icon: { Image(icon: .link) }
        }
        if model.saver != nil {
            Button { startSave([file]) } label: { Label { Text("转存到我的网盘") } icon: { Image(icon: .save) } }
        }
    }

    /// 单个文件下载：正在取链的（连点、或菜单里又点了一次）不再重复取
    /// 需要先登录才能下载时弹出就地登录（登录回来会重新打开分享），否则直接执行
    private func whenLoggedIn(_ action: () -> Void) {
        if model.downloadNeedsLogin { presentLogin() } else { action() }
    }

    private func download(_ file: ShareFile) {
        guard !model.downloadNeedsLogin else { presentLogin(); return }
        guard !model.busyFileIds.contains(file.fid) else { return }
        run {
            // 两次点按都排进来时，第二个在这里看到第一个已占住（取链开始前同步记下）
            guard !model.busyFileIds.contains(file.fid) else { return }
            try await model.download(file)
            app.show("已加入下载")
        }
    }

    private func releasePreviewLink() {
        model.releaseTemporary(previewLink)
        previewLink = nil
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
