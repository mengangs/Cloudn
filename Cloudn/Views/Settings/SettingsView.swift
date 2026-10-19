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
        NavigationStack {
            Form {
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
                } header: {
                    Text("下载")
                } footer: {
                    Text("连接数越多速度越快，但部分网盘会限制并发；遇到失败可调低。切到后台后普通文件由系统继续下载，m3u8 与分轨视频会在回到前台时继续。下载的文件可在「文件」App →「我的 iPhone」→ Cloudn 中找到。")
                }

                Section {
                    Toggle("回到应用时提示剪贴板链接", isOn: $settings.clipboardHint)
                    Toggle("免转存下载（夸克 / UC）", isOn: $settings.directFirst)
                    Toggle("多账号下载", isOn: $settings.multiAccountDownload)
                    Toggle("夸克 / UC 中文口令解析", isOn: $settings.allowCommandService)
                } header: {
                    Text("解析")
                } footer: {
                    Text("免转存：先用分享凭证直接取直链，失败再临时转存；关闭后一律先转存到「Cloudn临时转存」再取链，下载完成后自动删除。多账号下载：同一网盘登录了多个账号时，批量下载按文件轮换账号取链，分摊单账号的并发与限速。中文口令：夸克 / UC 口令需发给第三方「\(QuarkCommand.serviceName)」服务换取分享 ID（不含任何账号信息），迅雷口令直接问迅雷。")
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
                        ShareLink(item: log) { Label("导出诊断日志", systemImage: "square.and.arrow.up") }
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
            .navigationTitle("设置")
            .sheet(isPresented: $pickingFolder) {
                FolderPicker { app.settings.setExportFolder($0) }
            }
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
                Section {
                    LabeledContent("新版本", value: release.isPrerelease ? "\(release.version)（预发布）" : release.version)
                    LabeledContent("当前版本", value: AppModel.currentVersion)
                }
                if !release.notes.isEmpty {
                    Section("更新说明") {
                        Text(release.notes).font(.callout).textSelection(.enabled)
                    }
                }
                Section {
                    if let url = URL(string: release.pageURL) {
                        Button { openURL(url) } label: { Label("前往发布页", systemImage: "safari") }
                    }
                    if let url = URL(string: release.ipaURL), !release.ipaURL.isEmpty {
                        Button { openURL(url) } label: { Label("下载 IPA（需自行签名安装）", systemImage: "arrow.down.app") }
                    }
                    Button("忽略此版本", role: .destructive) {
                        app.settings.skippedVersion = release.version
                        dismiss()
                    }
                }
            }
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
                    Text("Cloudn").font(.title2.bold())
                    Text("版本 \(version)").font(.footnote).foregroundStyle(.secondary)
                    Text("粘贴分享链接，浏览并高速下载网盘文件与短视频。")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
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
