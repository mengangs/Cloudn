// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 蓝奏云匿名分享解析：分享页 HTML → 文件夹分页（filemoreajax）/ 单文件 → ajaxm 取下载参数 → 探测直链。
// 协议细节参考 YunX（AGPL-3.0）的 LanzouApi。
import Foundation

public final class LanzouResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .lanzou }
    public var supportsGuestDownload: Bool { true }

    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let hostRx = Rx(#"^(?:[a-z0-9-]+\.)*(?:lanzou[a-z0-9-]*|lan[zs]o[ux])\.(?:com|net|org|cn)$"#, ignoreCase: true)

    private let client: HTTPClient
    private let cookies = CookieJar()
    private let pages = PageCache()

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    struct Page: Sendable {
        let shareURL: String
        let origin: String
        let title: String
        let isFolder: Bool
        let needsPwd: Bool
        let html: String
        let folderParams: (lx: String, fid: String, t: String, k: String)?
        let displaySize: Int64
    }

    private actor PageCache {
        var pages: [String: Page] = [:]
        func get(_ k: String) -> Page? { pages[k] }
        func set(_ k: String, _ p: Page) { pages[k] = p }
    }

    /// 按 host 记录的 Cookie（acw_sc__v2 挑战与 down_ip）
    private actor CookieJar {
        var jar: [String: [String: String]] = [:]
        func set(_ host: String, _ name: String, _ value: String) { jar[host, default: [:]][name] = value }
        func header(_ host: String, extra: String? = nil) -> String {
            var parts = (jar[host] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            if let extra, !extra.isEmpty { parts.append(extra) }
            return parts.joined(separator: "; ")
        }
    }

    public static func isLanzouHost(_ host: String) -> Bool { hostRx.matches(host) }

    static func normalize(_ url: String) -> String {
        var u = url.trimmed
        if u.lowercased().hasPrefix("http://") { u = "https://" + u.dropFirst(7) }
        u = u.substringBefore("#")
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        let effectivePwd = pwd?.nilIfBlank ?? share.pwd ?? ""
        let page = try await resolvePage(share.url)
        if page.needsPwd && effectivePwd.isEmpty {
            throw CloudnError("此蓝奏分享需要提取码，请填写后重新解析")
        }
        await pages.set(page.shareURL, page)
        return ShareSession(platform: .lanzou, shareId: page.shareURL, stoken: effectivePwd, title: page.title, rootId: "")
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        guard let page = await pages.get(session.shareId) else { throw CloudnError("蓝奏分享会话已失效，请重新解析") }
        if !page.isFolder {
            return [ShareFile(fid: page.shareURL, name: page.title, size: page.displaySize, isDirectory: false, token: page.shareURL)]
        }
        return try await listFolder(page, pwd: session.stoken)
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let pwd = session.stoken.nilIfBlank
        // 文件夹里的文件各有独立的分享页（token 即其地址），要先解析该页再取下载参数
        let page: Page
        if let cached = await pages.get(file.token), !cached.isFolder {
            page = cached
        } else {
            page = try await resolvePage(file.token)
            await pages.set(page.shareURL, page)
        }
        return try await link(for: page, file: file, pwd: page.needsPwd ? pwd : nil)
    }

    // MARK: 分享页

    func resolvePage(_ shareURL: String) async throws -> Page {
        let normalized = Self.normalize(shareURL)
        let html = try await fetchFollowingLanzou(normalized)
        guard let u = URL(string: normalized), let host = u.host else { throw CloudnError("蓝奏分享链接无效") }
        let origin = "https://\(host)"
        let needsPwd = html.contains("请输入密码") || html.contains("id=\"pwbox\"") || html.contains("input_password") || html.contains("密码不正确")
        let isFolder = html.contains("filemoreajax") || html.contains("class=\"filemore\"") || html.contains("file_more")
        var params: (String, String, String, String)?
        if isFolder, let lx = Self.jsVar(html, "lx") ?? Self.jsVarRaw(html, "lx"),
           let t = Self.jsVar(html, "t") ?? Self.indirectVar(html, "t"),
           let k = Self.jsVar(html, "k") ?? Self.indirectVar(html, "k") {
            let fid = Self.jsVar(html, "fid") ?? Self.jsVarRaw(html, "fid") ?? u.lastPathComponent
            params = (lx, fid, t, k)
        }
        let sizeRx = Rx(#"(?:文件大小|大小)\s*[:：]\s*(?:<[^>]+>\s*)*([\d.]+\s*[KMGT]?)"#, ignoreCase: true)
        let displaySize = sizeRx.first(in: html).map(ByteFormat.parseDisplay) ?? 0
        let title = Self.extractTitle(html)
        return Page(shareURL: normalized, origin: origin, title: title.isEmpty ? "蓝奏分享" : title, isFolder: isFolder,
                    needsPwd: needsPwd, html: html, folderParams: params, displaySize: displaySize)
    }

    private func listFolder(_ page: Page, pwd: String) async throws -> [ShareFile] {
        guard let p = page.folderParams else { throw CloudnError("蓝奏分享分页异常，请重试") }
        var all: [ShareFile] = []
        var seen = Set<String>()
        var pg = 1
        var retries = 0
        while pg <= 500 {
            let json: JSON
            do {
                json = try await formPostJSON("\(page.origin)/filemoreajax.php", [
                    ("lx", p.lx), ("fid", p.fid), ("uid", Self.jsVar(page.html, "uid") ?? ""), ("pg", String(pg)),
                    ("rep", "0"), ("t", p.t), ("k", p.k), ("up", "1"), ("vip", "0"), ("webfoldersign", ""), ("pwd", pwd)
                ], referer: page.shareURL, origin: page.origin)
            } catch {
                retries += 1
                if retries > 2 { throw CloudnError("蓝奏请求过于频繁，请稍后再试") }
                try await Task.sleep(nanoseconds: 400_000_000)
                continue
            }
            switch json["zt"].int {
            case 1: break
            case 2: return all
            case 3: throw CloudnError("蓝奏提取码错误，请检查后重新解析")
            case 4:
                // 频控：稍等后重试同一页
                retries += 1
                if retries > 3 { throw CloudnError("蓝奏请求过于频繁，请稍后再试") }
                try await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            default:
                let info = json["info"].string
                throw CloudnError(info.isEmpty ? "蓝奏解析失败，请确认分享链接和提取码后重试" : "蓝奏：\(info)")
            }
            let items = json["text"].array
            if items.isEmpty { break }
            var added = 0
            for item in items {
                let id = item["id"].string
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                let name = item.string("name_all", "name")
                all.append(ShareFile(fid: id, name: name, size: ByteFormat.parseDisplay(item["size"].string), isDirectory: false,
                                     token: "\(page.origin)/\(id)", modified: item["time"].string))
                added += 1
            }
            if added == 0 { break }
            pg += 1
            retries = 0
            // 蓝奏对连续翻页频控很严
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return all
    }

    // MARK: 取直链

    private func link(for page: Page, file: ShareFile, pwd: String?) async throws -> DownloadLink {
        var html = page.html
        // 无密码文件：真实下载参数在同源 iframe 页里
        if let src = Rx(#"<iframe[^>]+src=["']([^"']+)["']"#).first(in: html) {
            let iframe = VideoHTTP.absolutize(base: page.origin + "/", src)
            guard URL(string: iframe)?.host?.lowercased() == URL(string: page.shareURL)?.host?.lowercased() else {
                throw CloudnError("蓝奏下载页面地址异常，请检查分享链接")
            }
            html = try await fetchPage(iframe, referer: page.shareURL)
        }
        guard let fileId = Rx(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#).first(in: html) ?? Rx(#"file=(\d+)"#).first(in: html) else {
            throw CloudnError("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let ajaxURL = Self.ajaxURL(html, origin: page.origin, fileId: fileId, withPwd: pwd != nil)
        guard let sign = Self.jsVar(html, "wp_sign") ?? Self.jsVar(html, "skdklds") ?? Self.jsVar(html, "sign") ?? Self.inputValue(html, "sign") else {
            throw CloudnError("蓝奏分享页缺少下载参数，请重新解析")
        }
        var fields: [(String, String)] = [("action", "downprocess"), ("sign", sign)]
        if let pwd {
            fields += [("p", pwd), ("kd", "1")]
        } else {
            let key = Self.jsVar(html, "ajaxdata") ?? Self.jsVar(html, "websignkey") ?? Self.inputValue(html, "websignkey") ?? ""
            fields += [("signs", Self.jsVar(html, "signs") ?? key), ("websignkey", key), ("websign", Self.jsVar(html, "websign") ?? ""),
                       ("kd", Self.jsVarRaw(html, "kdns") ?? "1"), ("ves", "1")]
        }
        let json = try await formPostJSON(ajaxURL, fields, referer: page.shareURL, origin: page.origin)
        try Self.validateAjax(json)
        let dom = json["dom"].string
        let rel = json["url"].string
        guard !dom.isEmpty, !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("://"),
              let domURL = URL(string: dom), let domHost = domURL.host else {
            throw CloudnError("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let jump = "https://\(domHost)/file/\(rel)"
        let (finalURL, size) = try await probe(jump, shareOrigin: page.origin)
        let nodeOrigin = URL(string: finalURL).flatMap { $0.host }.map { "https://\($0)" } ?? "https://pan.lanzoui.com"
        let name = file.name.isEmpty ? json["inf"].string : file.name
        return DownloadLink(fileName: name.isEmpty ? page.title : name, url: finalURL, size: size > 0 ? size : file.size,
                            headers: ["User-Agent": Self.ua, "Referer": nodeOrigin + "/", "Cookie": "down_ip=1"])
    }

    /// 跟随下载节点的跳转，处理 acw_sc__v2 挑战与「验证并下载」页，返回真实直链与大小
    private func probe(_ jump: String, shareOrigin: String) async throws -> (String, Int64) {
        var url = jump
        var visited = Set<String>()
        var challenged = Set<String>()
        var confirmed = Set<String>()
        for _ in 0..<8 {
            guard let host = URL(string: url)?.host else { throw CloudnError("蓝奏下载地址暂时不可用，请稍后重试") }
            guard visited.insert(url).inserted else { throw CloudnError("蓝奏下载地址循环跳转，请重新解析") }
            let r = try await client.send(HTTPRequest(url: url, method: "HEAD", headers: await nodeHeaders(host: host, shareOrigin: shareOrigin), followRedirects: false))
            switch r.status {
            case 300..<400:
                guard let loc = r.header("Location") else { throw CloudnError("蓝奏下载地址暂时不可用，请稍后重试") }
                url = VideoHTTP.absolutize(base: url, loc)
            case 200, 206:
                if (r.header("Content-Type") ?? "").contains("text/html") {
                    let body = try await client.send(HTTPRequest(url: url, headers: await nodeHeaders(host: host, shareOrigin: shareOrigin))).text
                    if let challenge = Self.challengeCookie(body) {
                        guard challenged.insert(host).inserted else { throw CloudnError("蓝奏需要进一步验证，请稍后重试") }
                        await cookies.set(host, "acw_sc__v2", challenge)
                        visited.remove(url)
                        continue
                    }
                    if body.contains("验证并下载"), confirmed.insert(host).inserted, let next = try await submitVerify(url, html: body) {
                        url = next
                        continue
                    }
                    throw CloudnError("蓝奏返回的是验证页面，请稍后重试")
                }
                var size = Self.totalSize(r)
                if size <= 0 { size = try await rangeProbe(url, host: host, shareOrigin: shareOrigin) }
                return (url, size)
            case 403, 404, 410: throw CloudnError("蓝奏下载地址已失效，请稍后重新解析")
            case 429: throw CloudnError("蓝奏下载请求过于频繁，请稍后再试")
            default:
                let size = try await rangeProbe(url, host: host, shareOrigin: shareOrigin)
                if size > 0 { return (url, size) }
                throw CloudnError("蓝奏下载地址暂时不可用，请稍后重试")
            }
        }
        throw CloudnError("蓝奏下载地址暂时不可用，请稍后重试")
    }

    private func nodeHeaders(host: String, shareOrigin: String) async -> [(String, String)] {
        [("User-Agent", Self.ua), ("Referer", shareOrigin + "/"), ("Cookie", await cookies.header(host, extra: "down_ip=1"))]
    }

    private func rangeProbe(_ url: String, host: String, shareOrigin: String) async throws -> Int64 {
        var h = await nodeHeaders(host: host, shareOrigin: shareOrigin)
        h.append(("Range", "bytes=0-0"))
        let r = try await client.send(HTTPRequest(url: url, headers: h, followRedirects: false))
        return Self.totalSize(r)
    }

    /// 新版确认页：data : { 'file':'…','el':el,'sign':'…' }，等待 2 秒后 POST ajax.php
    private func submitVerify(_ nodeURL: String, html: String) async throws -> String? {
        guard let u = URL(string: nodeURL), let host = u.host else { return nil }
        let block = Rx(#"data\s*:\s*\{([^{}]*)\}"#, dotAll: true).allMatches(in: html).map { $0[1] }
            .first(where: { $0.contains("'file'") || $0.contains("\"file\"") })
        guard let file = block.flatMap({ Rx(#"['"]?file['"]?\s*:\s*['"]([^'"]+)['"]"#).first(in: $0) })
                ?? Rx(#"name=["']file["'][^>]*value=["']([^"']+)["']"#).first(in: html),
              let sign = block.flatMap({ Rx(#"['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]"#).first(in: $0) })
                ?? Self.jsVar(html, "sign") ?? Self.inputValue(html, "sign") else { return nil }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let ajax = URL(string: "ajax.php", relativeTo: u)?.absoluteString ?? "https://\(host)/ajax.php"
        let json = try await formPostJSON(ajax, [("file", file), ("el", "2"), ("sign", sign)], referer: nodeURL, origin: "https://\(host)")
        let next = json["url"].string
        guard json["zt"].int == 1, !next.isEmpty else { throw CloudnError(next.isEmpty ? "蓝奏需要进一步验证，请稍后重试" : next) }
        if next == "?SignError" { throw CloudnError("蓝奏下载验证已过期，请重新解析") }
        return next
    }

    // MARK: HTTP

    private func fetchFollowingLanzou(_ start: String) async throws -> String {
        var current = start
        var challenged = Set<String>()
        for _ in 0..<8 {
            guard let host = URL(string: current)?.host else { throw CloudnError("蓝奏分享链接无效") }
            var headers: [(String, String)] = [("User-Agent", Self.ua), ("Referer", current)]
            let c = await cookies.header(host)
            if !c.isEmpty { headers.append(("Cookie", c)) }
            let r = try await client.send(HTTPRequest(url: current, headers: headers, followRedirects: false))
            if (300..<400).contains(r.status) {
                guard let loc = r.header("Location") else { throw CloudnError("蓝奏页面跳转异常") }
                let next = VideoHTTP.absolutize(base: current, loc)
                guard let nextHost = URL(string: next)?.host, Self.isLanzouHost(nextHost) else { throw CloudnError("蓝奏分享链接无效") }
                current = next
                continue
            }
            let body = r.text
            if let challenge = Self.challengeCookie(body) {
                guard challenged.insert(host).inserted else { throw CloudnError("蓝奏需要进一步验证，请稍后重试") }
                await cookies.set(host, "acw_sc__v2", challenge)
                continue
            }
            if body.contains("文件取消分享了") || body.contains("文件已取消") || (body.contains("不存在") && !body.contains("filemore")) {
                throw CloudnError("蓝奏文件已取消分享或不存在")
            }
            if body.contains("请求过于频繁") { throw CloudnError("蓝奏请求过于频繁，请稍后再试") }
            return body
        }
        throw CloudnError("蓝奏页面跳转次数过多，请重新解析")
    }

    private func fetchPage(_ url: String, referer: String) async throws -> String {
        let host = URL(string: url)?.host ?? ""
        var headers: [(String, String)] = [("User-Agent", Self.ua), ("Referer", referer)]
        let c = await cookies.header(host)
        if !c.isEmpty { headers.append(("Cookie", c)) }
        let r = try await client.send(HTTPRequest(url: url, headers: headers))
        guard r.isSuccess else { throw CloudnError("蓝奏文件已取消分享或不存在") }
        return r.text
    }

    private func formPostJSON(_ url: String, _ fields: [(String, String)], referer: String, origin: String) async throws -> JSON {
        let host = URL(string: url)?.host ?? ""
        var headers: [(String, String)] = [("User-Agent", Self.ua), ("Referer", referer), ("Origin", origin), ("X-Requested-With", "XMLHttpRequest")]
        let c = await cookies.header(host)
        if !c.isEmpty { headers.append(("Cookie", c)) }
        let r = try await client.send(.postForm(url, fields, headers: headers, followRedirects: false))
        if r.status == 429 { throw CloudnError("蓝奏请求过于频繁，请稍后再试") }
        guard let json = r.json, json.isObject else {
            if r.text.trimmed.hasPrefix("<") { throw CloudnError("蓝奏返回了验证页面，请稍后重试") }
            throw CloudnError("蓝奏解析服务响应异常（HTTP \(r.status)），请稍后重试")
        }
        return json
    }

    // MARK: 纯函数（便于单测）

    static func validateAjax(_ json: JSON) throws {
        if json["zt"].int == 1 { return }
        let inf = json["inf"].string
        if inf.contains("密码") || inf.contains("提取码") { throw CloudnError("蓝奏提取码错误，请检查后重新解析") }
        if ["不存在", "取消", "过期", "删除"].contains(where: inf.contains) { throw CloudnError("蓝奏文件已取消分享或不存在") }
        if ["频繁", "次数", "稍后"].contains(where: inf.contains) { throw CloudnError("蓝奏请求过于频繁，请稍后再试") }
        throw CloudnError("蓝奏解析失败，请确认分享链接和提取码后重试")
    }

    static func totalSize(_ r: HTTPResponse) -> Int64 {
        if let cr = r.header("Content-Range"), let total = Int64(cr.substringAfterLast("/").trimmed) { return total }
        if r.status == 200, let len = r.header("Content-Length").flatMap({ Int64($0.trimmed) }) { return len }
        return 0
    }

    static func extractTitle(_ html: String) -> String {
        if let t = Rx(#"<title>([^<]*)</title>"#).first(in: html) {
            let clean = t.replacingOccurrences(of: " - 蓝奏云", with: "").replacingOccurrences(of: "蓝奏云", with: "").trimmed
            if !clean.isEmpty && !clean.contains("密码") && !clean.contains("文件") { return clean }
        }
        if let n = Rx(#"class=["']n["']>([^<]+)<"#).first(in: html) { return n.trimmed }
        if let n = Rx(#"<div[^>]*class=["']b["'][^>]*>\s*<span>([^<]+)</span>"#).first(in: html) { return n.trimmed }
        if let n = Rx(#"var\s+filename\s*=\s*['"]([^'"]+)['"]"#).first(in: html) { return n }
        if let n = Rx(#"<div[^>]*id=["']filenajax["'][^>]*>([^<]+)<"#).first(in: html) { return n.trimmed }
        return ""
    }

    static func jsVar(_ html: String, _ name: String) -> String? {
        Rx(#"(?:(?:var|let|const)\s+)?\b"# + Rx.escape(name) + #"\s*=\s*['"]([^'"]*)['"]"#).first(in: html)
    }

    static func jsVarRaw(_ html: String, _ name: String) -> String? {
        Rx(#"(?:var|let|const)\s+"# + Rx.escape(name) + #"\s*=\s*([^;,\n\r]+)"#).first(in: html)?
            .trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// 文件夹页的 't':变量名 这种间接引用：先找 data 里的变量名，再取该变量的值
    static func indirectVar(_ html: String, _ key: String) -> String? {
        guard let varName = Rx(#"['"]"# + Rx.escape(key) + #"['"]\s*:\s*([A-Za-z_][A-Za-z0-9_]*)"#).first(in: html) else { return nil }
        return jsVar(html, varName)
    }

    static func inputValue(_ html: String, _ name: String) -> String? {
        Rx(#"<input[^>]*name=["']"# + Rx.escape(name) + #"["'][^>]*value=["']([^"']*)["']"#).first(in: html)
            ?? Rx(#"<input[^>]*value=["']([^"']*)["'][^>]*name=["']"# + Rx.escape(name) + #"["']"#).first(in: html)
    }

    static func ajaxURL(_ html: String, origin: String, fileId: String, withPwd: Bool) -> String {
        if let d = jsVar(html, "domain1"), d.contains("/ajax") { return d }
        if let d = jsVar(html, "domain2"), d.contains("/ajax") { return d }
        if let abs = Rx(#"https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+"#).first(in: html, group: 0) { return abs }
        if let rel = Rx(#"['"](/?(?:ajaxm|ajaxfile)\.php\?file=\d+)['"]"#).first(in: html) {
            return origin + (rel.hasPrefix("/") ? rel : "/" + rel)
        }
        return withPwd ? "\(origin)/ajaxfile.php?file=\(fileId)" : "\(origin)/ajaxm.php?file=\(fileId)"
    }

    static func challengeCookie(_ source: String) -> String? {
        guard let arg1 = Rx(#"\barg1\s*=\s*'([0-9A-Fa-f]{40})'"#).first(in: source) else { return nil }
        return acwScV2(arg1)
    }

    /// acw_sc__v2：40 位十六进制 arg1 按固定位置重排后与掩码逐字节异或（公开的固定变换，不执行页面脚本）
    static func acwScV2(_ arg1: String) -> String {
        let pos = [15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11,
                   39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36]
        let mask = Array("3000176000856006061501533003690027800375")
        let chars = Array(arg1)
        var q = [Character](repeating: "0", count: pos.count)
        for (x, ch) in chars.enumerated() {
            for (z, p) in pos.enumerated() where p == x + 1 { q[z] = ch }
        }
        var out = ""
        var i = 0
        while i + 2 <= q.count && i + 2 <= mask.count {
            let a = Int(String(q[i..<i + 2]), radix: 16) ?? 0
            let b = Int(String(mask[i..<i + 2]), radix: 16) ?? 0
            out += String(format: "%02x", a ^ b)
            i += 2
        }
        return out
    }
}
