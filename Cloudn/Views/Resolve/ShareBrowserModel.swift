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
    /// 批量取链进度；total 为 0 表示还在展开文件夹、清点要下载的文件
    private(set) var batch: (done: Int, total: Int)?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var cache: [String: [ShareFile]] = [:]
    /// 预览 / 在线查看 / 复制直链取到的临时转存（夸克 / UC 兜底、115、光鸭）：清理凭据 → 账号序号。
    /// 下载入队的由下载完成后清理；这些没有下载任务兜底，预览关闭、复制约一分钟后、离开分享页时在这里清理
    @ObservationIgnored private var temporaryCopies: [String: Int] = [:]
    /// 正在打开分享：.task 重入（页面重新出现）、登录回来重试等同时触发时只开一次
    @ObservationIgnored private var opening = false

    init(app: AppModel, share: ParsedShare, pwd: String?, sourceText: String) {
        self.app = app
        self.share = share
        self.pwd = pwd ?? ""
        self.sourceText = sourceText
    }

    private var resolver: ShareResolver? {
        #if DEBUG
        // 截图模式：换成本地演示数据（见 ScreenshotMode.swift）
        if let demo = ScreenshotMode.shareService(for: share.platform) { return demo }
        #endif
        return app.resolvers.resolver(for: share.platform)
    }
    var title: String { session?.title ?? share.platform.displayName }
    var currentDir: String { crumbs.last?.id ?? session?.rootId ?? "0" }

    /// 对应平台的主账号登录已失效（「我的」页检测出来的）
    var loginExpired: Bool {
        guard let kind = share.platform.accountKind else { return false }
        return app.accounts.isExpired(kind)
    }

    /// 未登录 / 登录已失效时给用户的能力说明（nil 表示不需要提示）
    var guestNotice: String? {
        guard let kind = share.platform.accountKind else { return nil }
        if app.accounts.isExpired(kind) { return "\(kind.displayName)登录已失效，下载、转存可能失败" }
        guard !app.accounts.isLoggedIn(kind) else { return nil }
        switch share.platform {
        case .quark: return "未登录夸克：只能下载约 50MB 以内的文件"
        case .uc: return "未登录 UC：可直接下载，登录后视频取原画"
        case .pan115: return "未登录 115：只能下载小文件"
        default:
            guard resolver?.supportsGuestDownload == false else { return nil }
            return "未登录\(kind.displayName)：可浏览，下载需先登录"
        }
    }

    // MARK: 浏览

    func open() async {
        guard session == nil, !opening, let resolver else { return }
        opening = true
        loading = true
        errorMessage = nil
        needsPassword = false
        defer {
            opening = false
            loading = false
        }
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
        let sorted = Self.sorted(list)
        cache[dir] = sorted
        // 等待期间已切到别的目录（或重新打开了分享）：结果只进缓存，不覆盖当前列表
        guard self.session == session, dir == currentDir else { return }
        files = sorted
    }

    /// 文件夹在前，再按文件名自然排序（缓存里的列表都按这个顺序）
    private static func sorted(_ list: [ShareFile]) -> [ShareFile] {
        list.sorted { a, b in
            a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
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
        let dir = currentDir
        loading = true
        errorMessage = nil
        do {
            try await load(dir, force: force)
        } catch {
            // 已切到别的目录：旧目录的错误不显示
            if dir == currentDir { errorMessage = error.localizedDescription }
        }
        // 已切到别的目录：加载状态交给新目录那次去收
        if dir == currentDir { loading = false }
    }

    // MARK: 下载

    func link(for file: ShareFile, slot: Int = 0) async throws -> DownloadLink {
        guard let session, let resolver else { throw CloudnError("分享会话已失效，请重新解析") }
        busyFileIds.insert(file.fid)
        defer { busyFileIds.remove(file.fid) }
        return try await AccountSlot.$current.withValue(slot) {
            try await resolver.downloadLink(session, file: file)
        }
    }

    /// 预览、在线查看、复制直链用的取链：需要临时转存的记下清理凭据，用完调 releaseTemporary
    func temporaryLink(for file: ShareFile) async throws -> DownloadLink {
        let link = try await link(for: file)
        if let token = link.cleanupToken { temporaryCopies[token] = 0 }
        return link
    }

    /// 清理一条临时转存；delay 秒后再清（复制出去的直链留点时间给别的应用开始下载）
    func releaseTemporary(_ link: DownloadLink?, after delay: TimeInterval = 0) {
        guard let token = link?.cleanupToken, let slot = temporaryCopies.removeValue(forKey: token), let resolver else { return }
        Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await AccountSlot.$current.withValue(slot) { await resolver.cleanup(token: token) }
        }
    }

    /// 离开分享页：还没清理的临时转存全部清掉（已排了延时清理的不在这里）
    func releaseAllTemporary() {
        guard !temporaryCopies.isEmpty, let resolver else { return }
        let pending = temporaryCopies
        temporaryCopies = [:]
        Task {
            for (token, slot) in pending {
                await AccountSlot.$current.withValue(slot) { await resolver.cleanup(token: token) }
            }
        }
    }

    func download(_ file: ShareFile, folder: String = "", group: DownloadGroup? = nil, slot: Int = 0) async throws {
        let link = try await link(for: file, slot: slot)
        let mirrors = await extraSources(for: file, primarySlot: slot, primary: link)
        app.downloads.enqueue(link: link, platform: share.platform, folder: folder,
                              origin: ShareOrigin(platform: share.platform, shareURL: share.url, pwd: pwd, file: file), group: group, slot: slot,
                              mirrors: mirrors)
    }

    /// 多源分片：大文件再用其他账号各取一条直链。需要临时转存才能取到的链接不用（下载完成后无法逐个清理），取到了就立即清理
    private func extraSources(for file: ShareFile, primarySlot: Int, primary: DownloadLink) async -> [DownloadLink] {
        let rotation = rotationCount
        guard app.settings.multiSourceDownload, rotation > 1, !file.isDirectory,
              max(file.size, primary.size) >= 64 * 1024 * 1024, let session, let resolver else { return [] }
        var result: [DownloadLink] = []
        for offset in 1..<rotation {
            let slot = (primarySlot + offset) % rotation
            guard let extra = try? await AccountSlot.$current.withValue(slot, operation: {
                try await resolver.downloadLink(session, file: file)
            }) else { continue }
            if let token = extra.cleanupToken {
                await AccountSlot.$current.withValue(slot) { await resolver.cleanup(token: token) }
                continue
            }
            if extra.url != primary.url { result.append(extra) }
        }
        return result
    }

    /// 多账号下载：开启且该平台登录了多个账号时，批量下载按文件轮换账号
    private var rotationCount: Int {
        guard app.settings.multiAccountDownload, let kind = share.platform.accountKind else { return 1 }
        return max(1, app.accounts.count(for: kind))
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
        // 上一批还在取链（连点「全部下载」、或又点了「下载整个文件夹」）：不再并行开一批，免得重复入队
        guard batch == nil else {
            app.show("上一批还在获取直链，请稍候")
            return
        }
        // 先占住进度条：展开文件夹要逐层请求，期间底部就显示进行中
        batch = (0, 0)
        defer { batch = nil }
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
        // 已下完或正在下载的文件跳过，重复点「全部下载」不会重复入队
        let existing = Set(app.downloads.items.compactMap { item -> String? in
            guard item.status != .failed, let origin = item.request.origin,
                  origin.platform == share.platform, origin.shareURL == share.url else { return nil }
            return origin.fileId
        })
        let total = queue.count
        queue.removeAll { existing.contains($0.0.fid) }
        let skipped = total - queue.count
        guard !queue.isEmpty else {
            app.show("这些文件都已在下载列表中")
            return
        }
        batch = (0, queue.count)
        // 多个文件归成一组：只选了一个文件夹时以它命名，否则用分享标题
        let groupTitle = items.count == 1 && items[0].isDirectory ? items[0].name : title
        let group = queue.count > 1 ? DownloadGroup(title: groupTitle) : nil
        var failures = 0
        var lastError = ""
        let rotation = rotationCount
        for (index, entry) in queue.enumerated() {
            do {
                try await download(entry.0, folder: entry.1, group: group, slot: index % rotation)
            } catch {
                failures += 1
                lastError = error.localizedDescription
            }
            batch = (index + 1, queue.count)
        }
        let skipNote = skipped > 0 ? " · 跳过 \(skipped) 个已下载" : ""
        if failures == 0 {
            app.show("已加入下载 \(queue.count) 个\(skipNote)")
        } else {
            app.show("\(queue.count - failures) 个已加入下载，\(failures) 个失败：\(lastError)", error: true)
        }
    }

    private func collect(_ dir: String, path: String, into queue: inout [(ShareFile, String)],
                         session: ShareSession, resolver: ShareResolver, depth: Int) async throws {
        guard depth < 12 else { return }
        let list: [ShareFile]
        if let hit = cache[dir] { list = hit } else {
            // 与浏览时同样排序后再进缓存：之后点进这个文件夹不会是乱序
            list = try await Self.sorted(resolver.list(session, dirId: dir))
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

    var saver: ShareSaver? {
        #if DEBUG
        if let demo = ScreenshotMode.shareService(for: share.platform) { return demo }
        #endif
        return app.resolvers.saver(for: share.platform)
    }

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
