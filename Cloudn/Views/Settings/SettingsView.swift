// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var cacheCleared = false
    @State private var pickingFolder = false
    @State private var logCleared = false
    @State private var checking = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Group {
                    Section {
                        Stepper(value: $settings.maxConcurrentTasks, in: 1...5) {
                            LabeledContent("同时下载任务", value: "\(settings.maxConcurrentTasks)")
                        }
                        Stepper(value: $settings.connectionsPerTask, in: 1...16) {
                            LabeledContent("单任务连接数", value: "\(settings.connectionsPerTask)")
                        }
                        Stepper(value: $settings.retryCount, in: 0...10) {
                            LabeledContent("失败自动重试", value: "\(settings.retryCount) 次")
                        }
                        Picker("下载限速", selection: $settings.speedLimitKB) {
                            ForEach(SpeedLimitOption.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        NavigationLink("按平台设置连接数") { PlatformConnectionsView() }
                        Toggle("下载完成后存入相册", isOn: $settings.autoSaveToPhotos)
                        Toggle("下载完成通知", isOn: $settings.notifyOnFinish)
                        Toggle("锁屏与灵动岛显示进度", isOn: $settings.liveActivity)
                    } header: {
                        Text("下载")
                    } footer: {
                        Text("连接数越多速度越快，但部分网盘会限制并发；遇到失败可调低。切到后台后普通文件由系统继续下载，m3u8 与分轨视频会在回到前台时继续。下载的文件可在「文件」App →「我的 iPhone」→ Cloudn 中找到。")
                    }

                    Section {
                        Toggle("回到应用时提示剪贴板链接", isOn: $settings.clipboardHint)
                        Toggle("夸克免转存下载", isOn: $settings.directFirst)
                        Toggle("多账号下载", isOn: $settings.multiAccountDownload)
                        if settings.multiAccountDownload {
                            Toggle("单文件多源分片（实验性）", isOn: $settings.multiSourceDownload)
                        }
                    } header: {
                        Text("解析")
                    } footer: {
                        Text("夸克免转存：先直接取直链，失败再临时转存；关闭后一律先转存再取链，下载完成后自动删除。多账号下载：同一网盘登录了多个账号时，批量下载按文件轮换账号取链；开启多源分片后，大文件还会同时用各账号的直链分段下载。")
                    }

                    Section {
                        LabeledContent("完成后保存到", value: app.settings.exportFolder?.lastPathComponent ?? "应用下载目录")
                        Button("选择文件夹…") { pickingFolder = true }
                        if app.settings.exportFolderBookmark != nil {
                            Button("恢复为应用下载目录", role: .destructive) { app.settings.setExportFolder(nil) }
                        }
                    } header: {
                        Text("下载位置")
                    } footer: {
                        Text("选择「文件」App 里的文件夹（如 iCloud 云盘）后，下载完成的文件会移动过去，并保留文件夹层级。")
                    }

                    Section("外观") {
                        Picker("主题", selection: $settings.appearance) {
                            ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        AccentPicker()
                        PlatformIconStylePicker()
                    }

                    Section {
                        Button {
                            checkUpdate()
                        } label: {
                            HStack {
                                Text("检查更新")
                                Spacer()
                                if checking { ProgressView() } else { Text("当前 \(AppModel.currentVersion)").foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(checking)
                        Toggle("自动检查更新", isOn: $settings.autoCheckUpdates)
                        Toggle("接受预发布版更新", isOn: $settings.acceptPrerelease)
                    } header: {
                        Text("更新")
                    } footer: {
                        Text("从 GitHub Releases（\(UpdateChecker.repository)）读取最新版本，每天最多自动检查一次。")
                    }

                    Section {
                        NavigationLink("GitHub Token 与下载镜像") { GitHubSettingsView() }
                    } header: {
                        Text("GitHub")
                    } footer: {
                        Text("粘贴 GitHub 仓库、用户主页或 Release 链接即可浏览并下载文件。")
                    }

                    Section("诊断") {
                        if let log = Log.fileURL, FileManager.default.fileExists(atPath: log.path) {
                            ShareLink(item: log) { Label("导出诊断日志", glyph: .share) }
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
                    }
            }
            .listRowBackground(Color.surface)
        }
        .paperList()
        .navigationTitle("设置")
        .sheet(isPresented: $pickingFolder) {
            FolderPicker { app.settings.setExportFolder($0) }
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

/// 新版本提示：更新说明 + 前往下载
struct UpdateSheet: View {
    let release: AppRelease
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        LabeledContent("新版本", value: release.isPrerelease ? "\(release.tag)（预发布）" : release.tag)
                        LabeledContent("当前版本", value: AppModel.currentVersion)
                    }
                    if !release.notes.isEmpty {
                        Section("更新说明") {
                            Text(release.notes).font(.callout).textSelection(.enabled)
                        }
                    }
                    Section {
                        if let url = URL(string: release.pageURL) {
                            Button { openURL(url) } label: { Label("前往发布页", glyph: .share) }
                        }
                        if let url = URL(string: release.ipaURL), !release.ipaURL.isEmpty {
                            Button { openURL(url) } label: { Label("下载 IPA（需自行签名安装）", glyph: .download) }
                        }
                        Button("忽略此版本", role: .destructive) {
                            app.settings.skippedVersion = release.tag
                            dismiss()
                        }
                    }
                }
                .listRowBackground(Color.surface)
            }
            .paperList()
            .navigationTitle(release.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() } }
            }
        }
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
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
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
                        .foregroundStyle(.secondary)
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
                    .font(.headline)
                Text("""
                部分网盘与视频平台的协议实现参考了开源项目 YunX（https://github.com/CYQawa/YunX，AGPL-3.0）。\
                依照该许可，Cloudn 的完整源代码同样以 AGPL-3.0 开放。

                平台图标改绘自 Arcticons（https://github.com/Arcticons-Team/Arcticons，CC BY-SA 4.0），\
                115、光鸭云盘、蓝奏云、蓝奏云优享版、AcFun 图标为本项目按同一规格绘制，同样以 CC BY-SA 4.0 提供。\
                实心平台图标中，百度、哔哩哔哩、抖音、快手、微博、小红书、Pixiv、GitHub 取自 Simple Icons（https://simpleicons.org，CC0 1.0），\
                其余由本项目在上述线性图标基础上绘制（CC BY-SA 4.0）；\
                各平台名称与标识归其所有者，仅用于标明来源。

                标题字体为思源宋体（Noto Serif SC，SIL Open Font License 1.1）的子集，许可文本随应用一同分发。

                本程序不提供任何担保。详见源代码仓库中的 LICENSE 文件或 https://www.gnu.org/licenses/agpl-3.0.html。
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
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
