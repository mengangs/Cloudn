// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

struct Crumb: Hashable {
    let id: String
    let name: String
}

@MainActor
@Observable
final class ShareBrowserModel: Hashable, Identifiable {
    nonisolated static func == (lhs: ShareBrowserModel, rhs: ShareBrowserModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    let share: ParsedShare
    let sourceText: String
    var pwd: String
    private(set) var session: ShareSession?
    private(set) var crumbs: [Crumb] = []
    private(set) var files: [ShareFile] = []
    private(set) var loading = false
    private(set) var errorMessage: String?
    private(set) var needsPassword = false
    var selecting = false
    var selection = Set<String>()
    private(set) var busyFileIds = Set<String>()
    private(set) var batch: (done: Int, total: Int)?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var cache: [String: [ShareFile]] = [:]

    init(app: AppModel, share: ParsedShare, pwd: String?, sourceText: String) {
        self.app = app
        self.share = share
        self.pwd = pwd ?? ""
        self.sourceText = sourceText
    }

    private var resolver: ShareResolver? { app.resolvers.resolver(for: share.platform) }
    var title: String { session?.title ?? share.platform.displayName }
    var currentDir: String { crumbs.last?.id ?? session?.rootId ?? "0" }

    /// 未登录时给用户的能力说明（nil 表示不需要提示）
    var guestNotice: String? {
        guard let kind = share.platform.accountKind, !app.accounts.isLoggedIn(kind) else { return nil }
        switch share.platform {
        case .quark: return "未登录夸克：可直接下载约 50MB 以内的文件，登录后不限大小"
        case .uc: return "未登录 UC：也可以直接下载，登录后视频可取原画"
        case .pan115: return "未登录 115：可直接下载小文件，大文件需要先登录"
        default:
            guard resolver?.supportsGuestDownload == false else { return nil }
            return "未登录\(kind.displayName)：可以浏览分享内容，下载前请先到「账号」页登录"
        }
    }

    // MARK: 浏览

    func open() async {
        guard session == nil, let resolver else { return }
        loading = true
        errorMessage = nil
        needsPassword = false
        defer { loading = false }
        do {
            let s = try await resolver.openSession(share, pwd: pwd.isEmpty ? nil : pwd)
            session = s
            crumbs = []
            app.bookmarks.record(title: s.title, text: sourceText, source: share.platform.displayName)
            try await load(s.rootId)
        } catch {
            let message = error.localizedDescription
            needsPassword = message.contains("提取码") || message.contains("密码") || message.contains("访问码") || message.contains("passcode")
            errorMessage = message
        }
    }

    func retry(with newPwd: String) async {
        pwd = newPwd
        session = nil
        cache = [:]
        await open()
    }

    private func load(_ dir: String, force: Bool = false) async throws {
        guard let session, let resolver else { return }
        if !force, let hit = cache[dir] {
            files = hit
            return
        }
        let list = try await resolver.list(session, dirId: dir)
        let sorted = list.sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        cache[dir] = sorted
        files = sorted
    }

    func enter(_ dir: ShareFile) async {
        crumbs.append(Crumb(id: dir.fid, name: dir.name))
        selection = []
        await reloadCurrent(force: false)
    }

    func jump(to index: Int?) async {
        if let index { crumbs = Array(crumbs.prefix(index + 1)) } else { crumbs = [] }
        selection = []
        await reloadCurrent(force: false)
    }

    func reloadCurrent(force: Bool) async {
        if session == nil { await open(); return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            try await load(currentDir, force: force)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 下载

    func link(for file: ShareFile) async throws -> DownloadLink {
        guard let session, let resolver else { throw CloudnError("分享会话已失效，请重新解析") }
        busyFileIds.insert(file.fid)
        defer { busyFileIds.remove(file.fid) }
        return try await resolver.downloadLink(session, file: file)
    }

    func download(_ file: ShareFile, folder: String = "") async throws {
        let link = try await link(for: file)
        app.downloads.enqueue(link: link, platform: share.platform, folder: folder,
                              origin: ShareOrigin(platform: share.platform, shareURL: share.url, pwd: pwd, file: file))
    }

    /// 下载所选：文件直接入队，文件夹递归展开并保留目录层级
    func downloadSelected() async {
        let chosen = files.filter { selection.contains($0.fid) }
        selecting = false
        selection = []
        await downloadBatch(chosen)
    }

    func downloadFolder(_ dir: ShareFile) async {
        await downloadBatch([dir])
    }

    func downloadAll() async {
        await downloadBatch(files)
    }

    private func downloadBatch(_ items: [ShareFile]) async {
        guard let session, let resolver else { return }
        var queue: [(ShareFile, String)] = []
        do {
            for item in items {
                if item.isDirectory {
                    try await collect(item.fid, path: FileNames.sanitize(item.name), into: &queue, session: session, resolver: resolver, depth: 0)
                } else {
                    queue.append((item, ""))
                }
                if queue.count > 2000 { break }
            }
        } catch {
            app.show("读取文件夹失败：\(error.localizedDescription)", error: true)
            return
        }
        guard !queue.isEmpty else {
            app.show("没有可下载的文件", error: true)
            return
        }
        batch = (0, queue.count)
        var failures = 0
        var lastError = ""
        for (index, entry) in queue.enumerated() {
            do {
                try await download(entry.0, folder: entry.1)
            } catch {
                failures += 1
                lastError = error.localizedDescription
            }
            batch = (index + 1, queue.count)
        }
        batch = nil
        if failures == 0 {
            app.show("已添加 \(queue.count) 个下载任务")
        } else {
            app.show("\(queue.count - failures) 个已添加，\(failures) 个失败：\(lastError)", error: true)
        }
    }

    private func collect(_ dir: String, path: String, into queue: inout [(ShareFile, String)],
                         session: ShareSession, resolver: ShareResolver, depth: Int) async throws {
        guard depth < 12 else { return }
        let list: [ShareFile]
        if let hit = cache[dir] { list = hit } else {
            list = try await resolver.list(session, dirId: dir)
            cache[dir] = list
        }
        for f in list {
            if f.isDirectory {
                try await collect(f.fid, path: path + "/" + FileNames.sanitize(f.name), into: &queue, session: session, resolver: resolver, depth: depth + 1)
            } else {
                queue.append((f, path))
            }
        }
    }

    // MARK: 转存到我的网盘

    var saver: ShareSaver? { app.resolvers.saver(for: share.platform) }

    /// 支持转存、但还没登录对应账号
    var saveNeedsLogin: Bool {
        guard let kind = share.platform.accountKind else { return false }
        return !app.accounts.isLoggedIn(kind)
    }

    func save(_ items: [ShareFile], to folderId: String) async throws {
        guard let session, let saver else { throw CloudnError("分享会话已失效，请重新解析") }
        try await saver.save(session, files: items, to: folderId)
    }

    // MARK: 收藏

    var isBookmarked: Bool { app.bookmarks.isBookmarked(sourceText) }

    func toggleBookmark() {
        app.bookmarks.toggle(title: title, text: sourceText, source: share.platform.displayName)
    }
}
