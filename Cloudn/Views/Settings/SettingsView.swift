// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var cacheCleared = false
    @State private var pickingFolder = false
    @State private var logCleared = false
    @State private var checking = false
    @State private var showingLayout = false
    /// 诊断日志文件：进入页面时查一次，不在每次刷新界面（拨动开关）时访问磁盘
    @State private var logFile: URL?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Group {
                    Section {
                        AdaptiveStepper(title: "同时下载任务", value: "\(settings.maxConcurrentTasks)",
                                        number: $settings.maxConcurrentTasks, range: 1...5)
                        AdaptiveStepper(title: "失败自动重试", value: "\(settings.retryCount) 次",
                                        number: $settings.retryCount, range: 0...10)
                        Picker("下载限速", selection: $settings.speedLimitKB) {
                            ForEach(SpeedLimitOption.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        NavigationLink("连接数（按平台）") { PlatformConnectionsView() }
                        Toggle("下载完成后存入相册", isOn: $settings.autoSaveToPhotos)
                        Toggle("下载完成通知", isOn: $settings.notifyOnFinish)
                        Toggle("锁屏与灵动岛显示进度", isOn: $settings.liveActivity)
                    } header: {
                        Text("下载")
                    } footer: {
                        Text("切到后台后普通文件由系统继续下载，m3u8 与分轨视频回到前台后继续。文件在「文件」App →「我的 iPhone」→ Cloudn 中。")
                    }

                    Section {
                        Toggle("回到应用时提示剪贴板链接", isOn: $settings.clipboardHint)
                        Toggle("夸克免转存下载", isOn: $settings.directFirst)
                        Toggle("多账号下载", isOn: $settings.multiAccountDownload)
                        if settings.multiAccountDownload {
                            Toggle("单文件多源分片（实验性）", isOn: $settings.multiSourceDownload)
                        }
                        Toggle("夸克 / UC 中文口令解析", isOn: $settings.allowCommandService)
                        Toggle("抖音按「昵称_抖音号_发布时间」命名", isOn: $settings.authorStyledNames)
                    } header: {
                        Text("解析")
                    } footer: {
                        Text("夸克免转存：先直接取链，失败再临时转存；关闭则总是先转存，下载后自动删除。多账号下载：同一网盘登录多个账号时，批量下载按文件轮换账号；多源分片会让大文件同时用各账号的直链下载。夸克 / UC 口令需发给第三方「\(QuarkKouling.serviceName)」换取分享 ID（只发口令文字），关闭后每次使用前询问。")
                    }

                    Section {
                        Toggle("附加公共 Tracker", isOn: $settings.useExtraTrackers)
                    } header: {
                        Text("磁力 / BT")
                    } footer: {
                        Text("磁力链接自带的 Tracker 常已失效，附加公共 Tracker 能更快找到节点。BT 只下载不上传，切到后台约半分钟后暂停。")
                    }

                    Section {
                        LabeledContent("完成后保存到", value: app.settings.exportFolder?.lastPathComponent ?? "应用下载目录")
                        Button("选择文件夹…") { pickingFolder = true }
                        if app.settings.exportFolderBookmark != nil {
                            Button("恢复为应用下载目录") { app.settings.setExportFolder(nil) }.foregroundStyle(Color.clayInk)
                        }
                    } header: {
                        Text("下载位置")
                    } footer: {
                        Text("选择「文件」App 中的文件夹（如 iCloud 云盘）后，下载完成的文件会移过去并保留目录层级。\n\n若选好后点「打开」没反应，是当前签名方式不允许访问外部文件夹：可在下载页多选文件，用文件夹按钮存储到「文件」。")
                    }

                    Section("外观") {
                        Picker("主题", selection: $settings.appearance) {
                            ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        AccentPicker()
                        PlatformIconStylePicker()
                        Button { showingLayout = true } label: {
                            HStack {
                                Text("「我的」页排序与显示").foregroundStyle(Color.ink)
                                Spacer()
                                IconView(.chevronRight, size: 13).foregroundStyle(Color.ink3)
                            }
                        }
                    }

                    Section {
                        Button {
                            checkUpdate()
                        } label: {
                            HStack {
                                Text("检查更新")
                                Spacer()
                                if checking { Spinner(size: 18) } else { Text("当前 \(AppModel.currentVersion)").font(.mono).foregroundStyle(Color.ink2) }
                            }
                        }
                        .disabled(checking)
                        Toggle("自动检查更新", isOn: $settings.autoCheckUpdates)
                        Toggle("接受预发布版更新", isOn: $settings.acceptPrerelease)
                    } header: {
                        Text("更新")
                    } footer: {
                        Text("从 GitHub Releases（\(UpdateChecker.repository)）检查，每天最多自动检查一次。")
                    }

                    Section {
                        NavigationLink("GitHub Token 与下载镜像") { GitHubSettingsView() }
                        NavigationLink {
                            NetworkProxyView()
                        } label: {
                            LabeledContent("网络代理") {
                                Text(settings.proxy.map { "\($0.kind.title) \($0.host):\($0.port)" } ?? "跟随系统")
                                    .foregroundStyle(Color.ink2)
                            }
                        }
                    } header: {
                        Text("网络与 GitHub")
                    } footer: {
                        Text("GitHub 访问慢时可选下载镜像，或设置网络代理。")
                    }

                    Section("诊断") {
                        if let logFile {
                            ShareLink(item: logFile) { Label("导出诊断日志", glyph: .share) }
                        }
                        Button(logCleared ? "已清空日志" : "清空日志") {
                            Log.clear()
                            logCleared = true
                        }
                        .disabled(logCleared)
                    }

                    Section("存储") {
                        Button("打开下载目录") {
                            // 用「文件」App 打开本应用的文档目录
                            let path = app.downloads.engine.downloadsDirectory.path
                            if let url = URL(string: "shareddocuments://" + path) { UIApplication.shared.open(url) }
                        }
                        Button(cacheCleared ? "已清除图片缓存" : "清除图片缓存") {
                            ImageLoader.shared.clear()
                            cacheCleared = true
                        }
                        .disabled(cacheCleared)
                    }

                    Section {
                        NavigationLink("关于 Cloudn") { AboutView() }
                        NavigationLink("开源许可") { LicenseView() }
                        Link(destination: URL(string: "https://github.com/mengangs/Cloudn/blob/main/PRIVACY.md")!) {
                            HStack {
                                Text("隐私政策").foregroundStyle(Color.ink)
                                Spacer()
                                IconView(.share, size: 14).foregroundStyle(Color.ink3)
                            }
                        }
                    }
            }
            .listRowBackground(Color.surface)
        }
        .scrollContentBackground(.hidden)
        .readableWidth()
        .background(Color.paper)
        .navigationTitle("设置")
        .sheet(isPresented: $showingLayout) { PlatformLayoutView() }
        .navigationBarTitleDisplayMode(.inline)
        .documentPicker(isPresented: $pickingFolder, types: [.folder], asCopy: false) { urls in
            if let url = urls.first { app.settings.setExportFolder(url) }
        }
        .task {
            if let log = Log.fileURL, FileManager.default.fileExists(atPath: log.path) { logFile = log }
        }
    }
}

extension SettingsView {
    private func checkUpdate() {
        checking = true
        Task {
            defer { checking = false }
            do {
                app.settings.lastUpdateCheck = Date()
                if let release = try await UpdateChecker.check(current: AppModel.currentVersion, includePrerelease: app.settings.acceptPrerelease) {
                    app.availableUpdate = release
                } else {
                    app.show("已是最新版本")
                }
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }
}

/// 新版本提示：版本对比、更新说明、下载（GitHub / 网盘）或交给侧载工具直接安装
/// 步进器：辅助字号下标题与数值在上、加减键在下，免得标题被挤成一字一行
private struct AdaptiveStepper: View {
    let title: String
    let value: String
    @Binding var number: Int
    let range: ClosedRange<Int>
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                Text(value).foregroundStyle(Color.ink2)
                Stepper(title, value: $number, in: range).labelsHidden()
            }
            .accessibilityElement(children: .combine)
        } else {
            Stepper(value: $number, in: range) {
                LabeledContent(title, value: value)
            }
        }
    }
}

struct UpdateSheet: View {
    let release: AppRelease
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var busy: String?

    private var shares: [ParsedShare] { UpdatePackage.shares(in: release.notes) }

    /// 侧载工具的「从链接安装」：把 IPA 地址交给它自己下载安装
    private static let installers: [(name: String, scheme: String)] = [
        ("TrollStore", "apple-magnifier://install?url="), ("SideStore", "sidestore://install?url="), ("AltStore", "altstore://install?url=")
    ]

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section { summary }
                    if !release.notes.isEmpty {
                        Section("更新说明") {
                            MarkdownText(source: release.notes)
                                .textSelection(.enabled)
                                .padding(.vertical, 4)
                        }
                    }
                    if !release.ipaURL.isEmpty || !shares.isEmpty {
                        Section {
                            if !release.ipaURL.isEmpty { installMenu }
                            ForEach(shares, id: \.url) { share in
                                Button {
                                    guard busy == nil else { return }
                                    busy = share.url
                                    Task {
                                        await app.startUpdateDownload(share)
                                        busy = nil
                                        dismiss()
                                    }
                                } label: {
                                    HStack {
                                        Label("网盘下载 · \(share.platform.displayName)", glyph: .cloud)
                                        Spacer()
                                        if busy == share.url { Spinner(size: 16) }
                                    }
                                }
                                .disabled(busy != nil)
                            }
                        } header: {
                            Text("其他方式")
                        } footer: {
                            Text("下载后在下载页长按安装包，用「分享」交给 TrollStore、SideStore 等工具安装。GitHub 慢时可改用网盘下载。")
                        }
                    }
                    Section {
                        if let url = URL(string: release.pageURL) {
                            Button { openURL(url) } label: { Label("前往发布页", glyph: .share) }
                        }
                        Button("忽略此版本") {
                            app.settings.skippedVersion = release.tag
                            dismiss()
                        }
                        .foregroundStyle(Color.clayInk)
                    }
                }
                .listRowBackground(Color.surface)
            }
            .paperList()
            .safeAreaInset(edge: .bottom) {
                if !release.ipaURL.isEmpty {
                    Button(action: downloadFromGitHub) {
                        Label(release.ipaSize > 0 ? "下载更新 · \(ByteFormat.string(release.ipaSize))" : "下载更新", glyph: .download)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 50))
                    .floatingShadow()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("发现新版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() } }
            }
        }
    }

    /// 1.0.0 → 1.1.0，发布日期与安装包大小
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(AppModel.currentVersion).font(.cardTitle).foregroundStyle(Color.ink3)
                IconView(.chevronRight, size: 14).foregroundStyle(Color.ink3)
                Text(release.tag).font(.pageTitle).foregroundStyle(Color.ink)
                if release.isPrerelease {
                    Text("预发布")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.claySoft, in: Capsule())
                        .foregroundStyle(Color.clayInk)
                }
            }
            let details = [Self.dateText(release.publishedAt).map { "发布于 \($0)" },
                           release.ipaSize > 0 ? "安装包 \(ByteFormat.string(release.ipaSize))" : nil].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.footnote).foregroundStyle(Color.ink3)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// 交给侧载工具从链接直接安装
    private var installMenu: some View {
        Menu {
            ForEach(Self.installers, id: \.name) { installer in
                Button("用 \(installer.name) 安装") { install(with: installer) }
            }
        } label: {
            Label("用侧载工具直接安装", glyph: .share)
        }
    }

    private func downloadFromGitHub() {
        let name = URL(string: release.ipaURL)?.lastPathComponent ?? "Cloudn.ipa"
        app.downloadGitHubFile(url: release.ipaURL, name: name.isEmpty ? "Cloudn.ipa" : name, size: release.ipaSize > 0 ? release.ipaSize : -1)
        app.selectedTab = .downloads
        dismiss()
    }

    private func install(with installer: (name: String, scheme: String)) {
        let ipa = GitHubMirror.apply(release.ipaURL, prefix: app.settings.githubMirror)
        guard let encoded = ipa.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: installer.scheme + encoded) else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { app.show("没有找到 \(installer.name)，请先安装它，或改用「下载更新」", error: true) }
        }
    }

    static func dateText(_ iso: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.formatted(.dateTime.year().month().day())
    }
}

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
                    Text("Cloudn").font(.pageTitle).foregroundStyle(Color.ink)
                    Text("版本 \(version)").font(.mono).foregroundStyle(Color.ink3)
                    Text("粘贴分享链接，浏览并高速下载网盘文件与短视频。")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.ink2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
            Group {
                Section("能力") {
                    LabeledContent("网盘", value: SharePlatform.allCases.filter(\.isResolvable).map(\.displayName).joined(separator: "、"))
                    LabeledContent("视频", value: VideoPlatform.allCases.map(\.displayName).joined(separator: "、"))
                    LabeledContent("下载", value: "多连接分片 · 断点续传 · m3u8 · 音视频合轨")
                }
                Section {
                    Text("本应用为个人独立开发，仅供学习与技术交流。请只解析你有权访问的内容，并遵守各平台的服务条款与当地法律法规。")
                        .font(.footnote)
                        .foregroundStyle(Color.ink2)
                }
            }
            .listRowBackground(Color.surface)
        }
        .paperList()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cloudn 以 GNU Affero General Public License v3.0（AGPL-3.0）发布。")
                    .font(.cardTitle)
                    .foregroundStyle(Color.ink)
                Text("""
                部分网盘与视频平台的协议实现参考了开源项目 YunX（https://github.com/CYQawa/YunX，AGPL-3.0），\
                依照该许可，Cloudn 的完整源代码同样以 AGPL-3.0 开放。

                其他视频平台的解析分别参考了：ParseHub（https://github.com/z-mio/ParseHub，MIT License，Copyright (c) 2024 梓澪）、\
                parse-video（https://github.com/wujunwei928/parse-video，MIT License，Copyright (c) 2022 wujunwei928）、\
                yt-dlp（https://github.com/yt-dlp/yt-dlp，Unlicense / 公有领域）。\
                YouTube 签名求解脚本取自 yt-dlp-ejs（Unlicense），其中打包了 meriyah（ISC License）与 astring（MIT License）。

                平台图标改绘自 Arcticons（https://github.com/Arcticons-Team/Arcticons，CC BY-SA 4.0），\
                115、光鸭云盘、蓝奏云、蓝奏云优享版、AcFun 及后来新增平台的图标为本项目按同一规格绘制，同样以 CC BY-SA 4.0 提供。\
                实心平台图标中，百度、哔哩哔哩、抖音、快手、微博、小红书、Pixiv、GitHub 取自 Simple Icons（https://simpleicons.org，CC0 1.0），\
                其余由本项目在上述线性图标基础上绘制（CC BY-SA 4.0）；\
                各平台名称与标识归其所有者，仅用于标明来源。

                标题字体为思源宋体（Noto Serif SC，SIL Open Font License 1.1）的子集，许可文本随应用一同分发。

                本程序不提供任何担保。详见源代码仓库中的 LICENSE 文件或 https://www.gnu.org/licenses/agpl-3.0.html。
                """)
                .font(.callout)
                .foregroundStyle(Color.ink2)
                .textSelection(.enabled)
            }
            .padding()
        }
        .background(Color.paper)
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 平台图标风格：线性 / 实心，各带一排预览，点哪排选哪个
struct PlatformIconStylePicker: View {
    @Environment(AppModel.self) private var app
    private let samples: [PlatformMark] = [.share(.quark), .share(.baidu), .share(.xunlei), .share(.pan115), .video(.bilibili), .video(.douyin), .github]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("平台图标")
            ForEach(PlatformIconStyle.allCases) { style in
                let on = app.settings.platformIconStyle == style
                Button {
                    withAnimation(.snappy) { app.settings.platformIconStyle = style }
                } label: {
                    HStack(spacing: 12) {
                        SelectMark(on: on, size: 20)
                        Text(style.title).font(.subheadline).foregroundStyle(Color.ink).frame(width: 34, alignment: .leading)
                        HStack(spacing: 10) {
                            ForEach(samples, id: \.name) { mark in
                                Image(mark.asset(style))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                    .foregroundStyle(mark.isVideo ? Color.clayInk : Color.ink)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(style.title)平台图标")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: app.settings.platformIconStyle)
    }
}

