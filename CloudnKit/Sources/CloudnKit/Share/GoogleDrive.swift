// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// Google 云端硬盘公开分享解析（无需登录）：文件夹用 embeddedfolderview 页列目录，文件走 drive.usercontent 下载
// （confirm=t 跳过大文件的病毒扫描确认页），Google 文档 / 表格 / 幻灯片 / 绘图走 export 导出为 Office / PNG。
// 做法参考 gdown（MIT License，Copyright (c) 2015 Kentaro Wada）。
import Foundation

public final class GoogleDriveResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .gdrive }
    public var supportsGuestDownload: Bool { true }

    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    /// 列目录时探测文件大小的上限（页面本身不给大小）：再多就太慢，Google 也会开始限流；其余的取链时再探
    static let sizeProbeLimit = 60

    let client: HTTPClient
    let credentials: CredentialStore
    private let titles = TitleCache()

    public init(credentials: CredentialStore = NoCredentials(), client: HTTPClient = .shared) {
        self.credentials = credentials
        self.client = client
    }

    /// 链接指向的对象
    enum Target: Equatable {
        case folder(String)
        case file(String)
        /// Google 原生文档：kind 为 document / spreadsheets / presentation / drawings / forms
        case doc(kind: String, id: String)

        var id: String {
            switch self {
            case .folder(let id), .file(let id), .doc(_, let id): return id
            }
        }
    }

    private static let folderRx = Rx(#"drive\.google\.com/(?:drive/)?(?:u/\d+/)?folders/([-\w]{10,})"#, ignoreCase: true)
    private static let fileRx = Rx(#"drive\.google\.com/(?:u/\d+/)?file/(?:u/\d+/)?d/([-\w]{10,})"#, ignoreCase: true)
    private static let docRx = Rx(#"docs\.google\.com/(?:a/[^/]+/)?(document|spreadsheets|presentation|drawings|forms)/(?:u/\d+/)?d/(?:e/)?([-\w]{10,})"#, ignoreCase: true)
    private static let idParamRx = Rx(#"[?&]id=([-\w]{10,})"#)
    private static let resourceKeyRx = Rx(#"[?&]resourcekey=([-\w]+)"#)

    static func target(of url: String) -> Target? {
        if let id = folderRx.first(in: url) { return .folder(id) }
        if let id = fileRx.first(in: url) { return .file(id) }
        if let m = docRx.firstMatch(in: url) { return .doc(kind: m[1].lowercased(), id: m[2]) }
        if url.lowercased().contains("google.com/"), let id = idParamRx.first(in: url) {
            // open?id= 不区分文件和文件夹：按文件处理，打开会话时若是文件夹再改走文件夹
            return .file(id)
        }
        return nil
    }

    /// 旧版分享链接带的 resourcekey（2021 年安全更新前的分享缺了它会被拒）
    static func resourceKey(in url: String) -> String? { resourceKeyRx.first(in: url) }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        guard let target = Self.target(of: share.url) else { throw CloudnError("无法识别的 Google 云端硬盘链接") }
        let key = Self.resourceKey(in: share.url) ?? ""
        switch target {
        case .folder(let id):
            let page = try await folderPage(id, key: key)
            return ShareSession(platform: .gdrive, shareId: share.url, stoken: key, title: page.title.nilIfBlank ?? "Google 云端硬盘分享", rootId: id)
        case .file(let id):
            // open?id= 也可能是文件夹：文件下载探测失败时再试一次文件夹页
            if share.url.contains("open?"), let page = try? await folderPage(id, key: key), !page.entries.isEmpty {
                return ShareSession(platform: .gdrive, shareId: share.url, stoken: key, title: page.title, rootId: id)
            }
            let file = try await probeFile(id, key: key)
            await titles.set(share.url, [file])
            return ShareSession(platform: .gdrive, shareId: share.url, stoken: key, title: file.name, rootId: "")
        case .doc(let kind, let id):
            let file = try await docFile(kind: kind, id: id, key: key)
            await titles.set(share.url, [file])
            return ShareSession(platform: .gdrive, shareId: share.url, stoken: key, title: file.name, rootId: "")
        }
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        if session.rootId.isEmpty, dirId.isEmpty {
            if let single = await titles.get(session.shareId) { return single }
            throw CloudnError("Google 云端硬盘会话已失效，请重新解析")
        }
        let page = try await folderPage(dirId, key: session.stoken)
        return await withSizes(page.entries.map { $0.file(parent: dirId) }, key: session.stoken)
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let headers = ["User-Agent": Self.ua]
        if let kind = Self.docKind(file.token) {
            guard let format = Self.exportFormat(kind) else {
                throw CloudnError("Google 表单无法导出下载")
            }
            return DownloadLink(fileName: file.name, url: Self.exportURL(kind: kind, id: file.fid, format: format.format, key: session.stoken),
                                size: 0, headers: headers)
        }
        let url = Self.downloadURL(file.fid, key: session.stoken)
        // 先探一下：配额已满、未公开时返回的是网页，不能当文件下载
        let probed = try await probeFile(file.fid, key: session.stoken)
        return DownloadLink(fileName: file.name.nilIfBlank ?? probed.name, url: url, size: probed.size > 0 ? probed.size : file.size, headers: headers)
    }

    // MARK: 文件

    static func downloadURL(_ id: String, key: String) -> String {
        var url = "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t"
        if !key.isEmpty { url += "&resourcekey=\(key)" }
        return url
    }

    static func exportURL(kind: String, id: String, format: String, key: String) -> String {
        var url = kind == "drawings"
            ? "https://docs.google.com/drawings/d/\(id)/export/\(format)"
            : "https://docs.google.com/\(kind)/d/\(id)/export?format=\(format)"
        if !key.isEmpty { url += (url.contains("?") ? "&" : "?") + "resourcekey=\(key)" }
        return url
    }

    /// 导出格式与扩展名；表单不能导出
    static func exportFormat(_ kind: String) -> (format: String, ext: String)? {
        switch kind {
        case "document": return ("docx", "docx")
        case "spreadsheets": return ("xlsx", "xlsx")
        case "presentation": return ("pptx", "pptx")
        case "drawings": return ("png", "png")
        default: return nil
        }
    }

    static func docKind(_ token: String) -> String? {
        token.hasPrefix("doc:") ? String(token.dropFirst(4)) : nil
    }

    /// 文档导出后的文件名：标题已带扩展名就不重复加
    static func exportName(_ title: String, kind: String) -> String {
        guard let ext = exportFormat(kind)?.ext else { return title }
        return title.lowercased().hasSuffix("." + ext) ? title : "\(title).\(ext)"
    }

    /// 只取第 1 个字节：从 Content-Disposition 拿文件名、Content-Range 拿总大小
    func probeFile(_ id: String, key: String, timeout: TimeInterval = 30) async throws -> ShareFile {
        var headers: [(String, String)] = [("User-Agent", Self.ua), ("Range", "bytes=0-0")]
        if !key.isEmpty { headers.append(("X-Goog-Drive-Resource-Keys", "\(id)/\(key)")) }
        let r = try await client.send(HTTPRequest(url: Self.downloadURL(id, key: key), headers: headers, timeout: timeout))
        let type = r.header("Content-Type") ?? ""
        // 空文件取不了第 1 个字节（416，也不带文件名）
        if r.status == 416 {
            let name = Self.fileName(fromDisposition: r.header("Content-Disposition") ?? "") ?? id
            return ShareFile(fid: id, name: name, size: 0, isDirectory: false, token: "file")
        }
        if type.contains("text/html") || !(200..<300).contains(r.status) {
            throw Self.pageError(r)
        }
        let name = Self.fileName(fromDisposition: r.header("Content-Disposition") ?? "") ?? id
        let size = Self.totalSize(r)
        return ShareFile(fid: id, name: name, size: size, isDirectory: false, token: "file")
    }

    /// 网页形式的失败：配额已满 / 未公开 / 已删除
    static func pageError(_ r: HTTPResponse) -> CloudnError {
        let html = r.text
        if r.url.contains("accounts.google.com") || r.status == 401 || r.status == 403 && html.contains("ServiceLogin") {
            return CloudnError("这个 Google 云端硬盘文件没有公开分享（需要「知道链接的任何人均可查看」）")
        }
        if r.status == 404 { return CloudnError("Google 云端硬盘文件不存在或已被删除") }
        if html.contains("Too many users") || html.contains("quota") || html.contains("配额") {
            return CloudnError("这个文件近期下载人数过多，Google 暂时限制了下载，请过一段时间再试")
        }
        if let m = Rx(#"<p class="uc-error-subcaption">(.*?)</p>"#).first(in: html) {
            return CloudnError("Google 云端硬盘：\(Self.stripTags(m))")
        }
        return CloudnError("Google 云端硬盘没有返回文件（HTTP \(r.status)），请确认链接已公开分享")
    }

    static func fileName(fromDisposition disposition: String) -> String? {
        if let encoded = Rx(#"filename\*=UTF-8''([^;]+)"#, ignoreCase: true).first(in: disposition),
           let name = encoded.removingPercentEncoding?.nilIfBlank {
            return name
        }
        if let plain = Rx(#"filename="([^"]+)""#, ignoreCase: true).first(in: disposition)?.nilIfBlank {
            return plain
        }
        return nil
    }

    static func totalSize(_ r: HTTPResponse) -> Int64 {
        if let range = r.header("Content-Range"), let total = range.split(separator: "/").last, let n = Int64(total) { return n }
        if r.status == 200, let len = r.header("Content-Length"), let n = Int64(len) { return n }
        return 0
    }

    /// 原生文档：标题从查看页的 og:title 取
    private func docFile(kind: String, id: String, key: String) async throws -> ShareFile {
        guard Self.exportFormat(kind) != nil else { throw CloudnError("Google 表单无法导出下载") }
        var url = "https://docs.google.com/\(kind)/d/\(id)/edit"
        if !key.isEmpty { url += "?resourcekey=\(key)" }
        let r = try await client.send(HTTPRequest(url: url, headers: [("User-Agent", Self.ua)]))
        if r.url.contains("accounts.google.com") { throw CloudnError("这个 Google 文档没有公开分享（需要「知道链接的任何人均可查看」）") }
        guard r.isSuccess else { throw CloudnError("Google 文档无法打开（HTTP \(r.status)）") }
        var title = Rx(#"<meta property="og:title" content="([^"]*)""#).first(in: r.text).map(Self.decodeEntities) ?? ""
        if title.isEmpty {
            title = Rx(#"<title>([^<]*)</title>"#).first(in: r.text).map(Self.decodeEntities)?
                .replacingOccurrences(of: #"\s+-\s+Google [^-]+$"#, with: "", options: .regularExpression) ?? id
        }
        return ShareFile(fid: id, name: Self.exportName(title, kind: kind), size: 0, isDirectory: false, token: "doc:\(kind)")
    }

    /// 并发探测文件大小（失败的保持 0）
    private func withSizes(_ files: [ShareFile], key: String) async -> [ShareFile] {
        let targets = files.enumerated().filter { $0.element.token == "file" }.prefix(Self.sizeProbeLimit).map(\.offset)
        guard !targets.isEmpty else { return files }
        var sizes: [Int: Int64] = [:]
        await withTaskGroup(of: (Int, Int64).self) { group in
            var next = 0
            func add() {
                guard next < targets.count else { return }
                let index = targets[next]
                let id = files[index].fid
                next += 1
                group.addTask { [self] in (index, (try? await probeFile(id, key: key, timeout: 10))?.size ?? 0) }
            }
            for _ in 0..<min(6, targets.count) { add() }
            while let (index, size) = await group.next() {
                sizes[index] = size
                add()
            }
        }
        return files.enumerated().map { index, f in
            guard let size = sizes[index], size > 0 else { return f }
            return ShareFile(fid: f.fid, name: f.name, size: size, isDirectory: f.isDirectory, parentId: f.parentId, token: f.token, modified: f.modified)
        }
    }

    // MARK: 文件夹

    struct FolderEntry: Equatable {
        let id: String
        let name: String
        /// file / folder / doc:<kind>
        let kind: String
        let modified: String

        func file(parent: String) -> ShareFile {
            let name = GoogleDriveResolver.docKind(kind).map { GoogleDriveResolver.exportName(self.name, kind: $0) } ?? self.name
            return ShareFile(fid: id, name: name, size: 0, isDirectory: kind == "folder", parentId: parent, token: kind, modified: modified)
        }
    }

    struct FolderPage: Equatable {
        let title: String
        let entries: [FolderEntry]
    }

    private func folderPage(_ id: String, key: String) async throws -> FolderPage {
        var url = "https://drive.google.com/embeddedfolderview?id=\(id)"
        if !key.isEmpty { url += "&resourcekey=\(key)" }
        var headers: [(String, String)] = [("User-Agent", Self.ua), ("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")]
        if !key.isEmpty { headers.append(("X-Goog-Drive-Resource-Keys", "\(id)/\(key)")) }
        let r = try await client.send(HTTPRequest(url: url, headers: headers))
        if r.url.contains("accounts.google.com") || r.status == 401 || r.status == 403 {
            throw CloudnError("这个 Google 云端硬盘文件夹没有公开分享（需要「知道链接的任何人均可查看」）")
        }
        if r.status == 404 { throw CloudnError("Google 云端硬盘文件夹不存在或已被删除") }
        guard r.isSuccess else { throw CloudnError("Google 云端硬盘文件夹打开失败（HTTP \(r.status)）") }
        return Self.parseFolderPage(r.text)
    }

    private static let entryRx = Rx(#"<div class="flip-entry" id="entry-([-\w]+)"(.*?)(?=<div class="flip-entry" id="entry-|</body>|$)"#, dotAll: true)
    private static let hrefRx = Rx(#"<a href="([^"]+)""#)
    private static let titleRx = Rx(#"<div class="flip-entry-title">(.*?)</div>"#, dotAll: true)
    private static let modifiedRx = Rx(#"<div class="flip-entry-last-modified"><div>(.*?)</div>"#, dotAll: true)

    static func parseFolderPage(_ html: String) -> FolderPage {
        let title = Rx(#"<title>([^<]*)</title>"#).first(in: html).map(decodeEntities) ?? ""
        var entries: [FolderEntry] = []
        var seen = Set<String>()
        for m in entryRx.allMatches(in: html) {
            let id = m[1], block = m[2]
            guard seen.insert(id).inserted else { continue }
            let href = decodeEntities(hrefRx.first(in: block) ?? "")
            let name = decodeEntities(stripTags(titleRx.first(in: block) ?? "")).trimmed
            let modified = decodeEntities(stripTags(modifiedRx.first(in: block) ?? "")).trimmed
            let kind: String
            if folderRx.matches(href) {
                kind = "folder"
            } else if let m = docRx.firstMatch(in: href) {
                kind = "doc:" + m[1].lowercased()
            } else {
                kind = "file"
            }
            entries.append(FolderEntry(id: id, name: name.isEmpty ? id : name, kind: kind, modified: modified))
        }
        return FolderPage(title: title, entries: entries)
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        // 数字实体
        let rx = Rx(#"&#(x?)([0-9A-Fa-f]+);"#)
        while let m = rx.firstMatch(in: out), let code = UInt32(m[2], radix: m[1].isEmpty ? 10 : 16), let scalar = Unicode.Scalar(code) {
            out = out.replacingOccurrences(of: m[0], with: String(Character(scalar)))
        }
        return out
    }

    /// 单文件 / 单文档分享的条目缓存（list 根目录时直接返回）
    private actor TitleCache {
        var map: [String: [ShareFile]] = [:]
        func get(_ k: String) -> [ShareFile]? { map[k] }
        func set(_ k: String, _ v: [ShareFile]) { map[k] = v }
    }
}
