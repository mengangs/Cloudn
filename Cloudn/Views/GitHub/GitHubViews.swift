// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// GitHub 仓库浏览与下载，界面参考 YunX（AGPL-3.0）。
import CloudnKit
import SwiftUI

extension AppModel {
    var github: GitHubClient { GitHubClient(token: settings.githubToken) }

    /// 下载 GitHub 文件：配置了镜像时走镜像；直连且有 Token 时带上鉴权（私有仓库的 raw 文件需要）
    func downloadGitHubFile(url: String, name: String, size: Int64 = -1, folder: String = "", group: DownloadGroup? = nil) {
        let mirrored = GitHubMirror.apply(url, prefix: settings.githubMirror)
        var headers = ["User-Agent": "Cloudn-iOS"]
        if mirrored == url, !settings.githubToken.isEmpty, URL(string: url)?.host == "raw.githubusercontent.com" {
            headers["Authorization"] = "Bearer " + settings.githubToken
        }
        downloads.enqueue(DownloadRequest(url: mirrored, headers: headers, fileName: name, folder: folder,
                                          expectedSize: size, source: "GitHub", group: group))
        show("已添加到下载")
    }

    /// GitHub 文件最近一次的下载任务（按文件名与目录对上）
    func gitHubDownload(name: String, folder: String) -> DownloadItem? {
        downloads.items.last { $0.request.source == "GitHub" && $0.request.fileName == name && $0.request.folder == folder }
    }
}

/// 用户 / 组织的仓库列表
struct GitHubAccountView: View {
    let owner: String
    @Environment(AppModel.self) private var app
    @State private var repos: [GitHubRepo] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        let shown = query.isEmpty ? repos : repos.filter { $0.name.localizedCaseInsensitiveContains(query) }
        List {
            if let error {
                Label(error, glyph: .warning).foregroundStyle(Color.clayInk)
            }
            ForEach(shown) { repo in
                NavigationLink {
                    GitHubRepoView(owner: repo.owner.isEmpty ? owner : repo.owner, repo: repo.name, subPath: nil)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(repo.name).font(.body.weight(.medium)).foregroundStyle(Color.ink)
                        if !repo.description.isEmpty {
                            Text(repo.description).font(.caption).foregroundStyle(Color.ink2).lineLimit(2)
                        }
                        HStack(spacing: 4) {
                            IconView(.star, size: 12)
                            Text("\(repo.stars)").font(.monoSmall)
                        }
                        .foregroundStyle(Color.ink3)
                    }
                    .padding(.vertical, 2)
                }
                .paperRow()
            }
        }
        .paperList()
        .overlay { if loading { ProgressView() } }
        .searchable(text: $query, prompt: "搜索仓库")
        .navigationTitle(owner)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            defer { loading = false }
            do { repos = try await app.github.repositories(of: owner) } catch { self.error = error.localizedDescription }
        }
    }
}

/// 仓库：文件浏览 + Releases
struct GitHubRepoView: View {
    let owner: String
    let repo: String
    let subPath: String?
    @Environment(AppModel.self) private var app
    @State private var info: GitHubRepo?
    @State private var tab: Tab = .files
    @State private var error: String?

    enum Tab: String, CaseIterable, Identifiable {
        case files = "文件", releases = "Releases"
        var id: String { rawValue }
    }

    /// tree/<分支>/<路径>、blob/<分支>/<文件> → (分支, 目录)；releases → 直接打开 Releases
    private var initial: (ref: String?, path: String) {
        guard let sub = subPath else { return (nil, "") }
        let parts = sub.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "tree" || parts[0] == "blob" else { return (nil, "") }
        var rest = Array(parts.dropFirst(2))
        if parts[0] == "blob" { rest = Array(rest.dropLast()) }
        return (parts[1], rest.joined(separator: "/"))
    }

    var body: some View {
        Group {
            if let info {
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    switch tab {
                    case .files:
                        GitHubDirectoryView(owner: owner, repo: repo, ref: initial.ref ?? info.defaultBranch, path: initial.path, description: info.description)
                    case .releases:
                        GitHubReleasesView(owner: owner, repo: repo)
                    }
                }
            } else if let error {
                ContentUnavailableView("无法打开仓库", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("\(owner)/\(repo)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if subPath?.hasPrefix("releases") == true { tab = .releases }
            do { info = try await app.github.repository(owner, repo) } catch { self.error = error.localizedDescription }
        }
    }
}

/// 仓库某个目录
struct GitHubDirectoryView: View {
    let owner: String
    let repo: String
    let ref: String
    let path: String
    var description = ""
    @Environment(AppModel.self) private var app
    @State private var entries: [GitHubEntry] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if path.isEmpty && !description.isEmpty {
                Section { Text(description).font(.callout).foregroundStyle(Color.ink2) }
                    .listRowBackground(Color.clear)
            }
            if let error {
                Label(error, glyph: .warning).foregroundStyle(Color.clayInk)
            }
            Section {
                ForEach(entries) { entry in
                    Group {
                        if entry.isDirectory {
                            NavigationLink {
                                GitHubDirectoryView(owner: owner, repo: repo, ref: ref, path: entry.path)
                                    .navigationTitle(entry.name)
                            } label: { row(entry) }
                        } else {
                            row(entry)
                        }
                    }
                    .paperRow()
                }
            } header: {
                HStack(spacing: 6) {
                    IconView(.branch, size: 13)
                    Text(path.isEmpty ? ref : "\(ref) · \(path)").font(.monoSmall).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(Color.ink2)
                .textCase(nil)
            }
        }
        .paperList()
        .overlay { if loading { ProgressView() } }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ entry: GitHubEntry) -> some View {
        HStack(spacing: 12) {
            FileIcon(name: entry.name, isDirectory: entry.isDirectory)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(2).foregroundStyle(Color.ink)
                if !entry.isDirectory { Text(ByteFormat.string(entry.size)).font(.caption).foregroundStyle(Color.ink3) }
            }
            Spacer(minLength: 0)
            if !entry.isDirectory {
                DownloadStateControl(item: app.gitHubDownload(name: entry.name, folder: repo)) { download(entry) }
            }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            entries = try await app.github.contents(owner, repo, path: path, ref: ref)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func download(_ entry: GitHubEntry) {
        guard !entry.downloadURL.isEmpty else { return app.show("该文件没有下载地址（可能是子模块或符号链接）", error: true) }
        app.downloadGitHubFile(url: entry.downloadURL, name: entry.name, size: entry.size, folder: repo)
    }
}

/// Releases 与附件
struct GitHubReleasesView: View {
    let owner: String
    let repo: String
    @Environment(AppModel.self) private var app
    @State private var releases: [GitHubRelease] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, glyph: .warning).foregroundStyle(Color.clayInk)
            } else if releases.isEmpty && !loading {
                ContentUnavailableView("没有发布版本", systemImage: "shippingbox")
            }
            ForEach(releases) { release in
                Section {
                    if release.assets.isEmpty {
                        Text("没有附件").foregroundStyle(Color.ink3).paperRow()
                    }
                    ForEach(release.assets) { asset in
                        HStack(spacing: 12) {
                            FileIcon(name: asset.name)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.name).lineLimit(2).foregroundStyle(Color.ink)
                                Text("\(ByteFormat.string(asset.size)) · 下载 \(asset.downloads) 次").font(.caption).foregroundStyle(Color.ink3)
                            }
                            Spacer(minLength: 0)
                            DownloadStateControl(item: app.gitHubDownload(name: asset.name, folder: repo)) {
                                app.downloadGitHubFile(url: asset.url, name: asset.name, size: asset.size, folder: repo)
                            }
                        }
                        .paperRow()
                    }
                    if !release.notes.isEmpty {
                        DisclosureGroup("更新说明") {
                            Text(release.notes).font(.callout).foregroundStyle(Color.ink2).textSelection(.enabled)
                        }
                        .paperRow()
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(release.name).font(.serif(16, relativeTo: .headline)).foregroundStyle(Color.ink).textCase(nil)
                        if release.isPrerelease {
                            Text("预发布").font(.caption2.weight(.medium)).foregroundStyle(Color.clayInk)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.claySoft, in: Capsule())
                        }
                        Spacer()
                        Text(String(release.publishedAt.prefix(10))).font(.monoSmall).foregroundStyle(Color.ink3).textCase(nil)
                    }
                }
            }
        }
        .paperList()
        .overlay { if loading { ProgressView() } }
        .task {
            defer { loading = false }
            do { releases = try await app.github.releases(owner, repo) } catch { self.error = error.localizedDescription }
        }
    }
}

/// 设置页：GitHub Token 与下载镜像
struct GitHubSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var token = ""
    @State private var checking = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Group {
                Section {
                    SecureField("ghp_… / github_pat_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(checking ? "正在校验…" : "保存并校验") { save() }
                        .disabled(checking || token == app.settings.githubToken)
                    if !app.settings.githubToken.isEmpty {
                        Button("清除 Token", role: .destructive) {
                            app.settings.githubToken = ""
                            token = ""
                        }
                    }
                } header: {
                    Text("GitHub Token（可选）")
                } footer: {
                    Text("未填写时每小时只能调用 60 次 GitHub 接口；填写后提升到 5000 次，并能浏览自己的私有仓库。Token 只保存在本机钥匙串，建议只授予只读权限。")
                }
                Section {
                    TextField("https://镜像地址/（留空直连）", text: $settings.githubMirror)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !app.settings.githubMirror.isEmpty {
                        Button("关闭镜像（直连 GitHub）", role: .destructive) { app.settings.githubMirror = "" }
                    }
                } header: {
                    Text("下载镜像")
                } footer: {
                    Text("默认直连 GitHub。如有自己信任的镜像，可填写其前缀，GitHub 文件与 Release 附件会经「前缀 + 原始地址」下载。应用不内置任何第三方镜像。")
                }
            }
            .listRowBackground(Color.surface)
        }
        .paperList()
        .navigationTitle("GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { token = app.settings.githubToken }
    }

    private func save() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            app.settings.githubToken = ""
            return
        }
        checking = true
        Task {
            defer { checking = false }
            do {
                let login = try await GitHubClient(token: value).validate()
                app.settings.githubToken = value
                app.show("已保存，GitHub 账号：\(login)")
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }
}
