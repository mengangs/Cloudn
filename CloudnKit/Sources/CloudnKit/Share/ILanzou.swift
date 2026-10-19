// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 蓝奏云优享版（ilanzou.com）匿名分享解析：设备 uuid → /unproved/share/list 列目录 → /unproved/file/redirect 取直链。
// 协议细节参考 YunX（AGPL-3.0）的 ILanzouApi / ILanzouResolveRepository。
import Foundation

public final class ILanzouResolver: ShareResolver, @unchecked Sendable {
    public var platform: SharePlatform { .ilanzou }
    public var supportsGuestDownload: Bool { true }

    static let apiBase = "https://apis.ilanzou.com"
    static let shareAPIBase = "https://apix.ilanzou.com"
    static let webSite = "https://www.ilanzou.com"
    static let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let aesKey = Array("lanZouY-disk-app".utf8)
    static let devType = "6"
    static let devVersion = "125"
    static let pageSize = 60
    static let folderPrefix = "d:"
    static let filePrefix = "f:"

    private let client: HTTPClient
    private let state = State()
    private let base: String
    private let shareBase: String

    private actor State {
        var uuid: String?
        func set(_ v: String) { uuid = v }
    }

    /// `apiBase` / `shareBase` 仅供测试替换为本地服务器
    public init(client: HTTPClient = .shared, apiBase: String = ILanzouResolver.apiBase, shareBase: String = ILanzouResolver.shareAPIBase) {
        self.client = client
        self.base = apiBase
        self.shareBase = shareBase
    }

    // MARK: ShareResolver

    public func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        // 优享版分享没有提取码环节：先列一次根目录，既校验分享有效，也能尽早暴露风控问题
        let session = ShareSession(platform: .ilanzou, shareId: share.shareId, stoken: share.shareId, title: "蓝奏云优享版分享", rootId: "")
        let root = try await list(session, dirId: "")
        if root.count == 1, let only = root.first, !only.isDirectory {
            return ShareSession(platform: .ilanzou, shareId: share.shareId, stoken: share.shareId, title: only.name, rootId: "")
        }
        return session
    }

    public func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        let uuid = try await deviceId()
        let folderId = dirId.hasPrefix(Self.folderPrefix) ? String(dirId.dropFirst(Self.folderPrefix.count)) : dirId
        var all: [ShareFile] = []
        var seen = Set<String>()
        var page = 1
        while page <= 1000 {
            var params: [(String, String)] = []
            if !folderId.isEmpty && folderId != "0" { params.append(("folderId", folderId)) }
            params += [("offset", String(page)), ("limit", String(Self.pageSize))]
            let url = shareBase + "/unproved/share/list?" + Self.query(Self.commonParams(uuid: uuid, devModel: "Chrome") + [("extra", "2"), ("shareId", session.shareId)] + params)
            let r = try await client.send(.get(url, headers: Self.headers))
            guard let json = r.json, json.isObject else { throw CloudnError("蓝奏优享分享请求失败（HTTP \(r.status)）") }
            guard json["code"].int == 200 else {
                let msg = json["msg"].string
                throw CloudnError(msg.isEmpty ? "蓝奏优享分享请求失败（\(json["code"].int)）" : msg, code: json["code"].int)
            }
            let items = json["list"].array
            if items.isEmpty { break }
            var added = 0
            for item in items {
                guard let f = Self.parseItem(item, parent: dirId), seen.insert(f.fid).inserted else { continue }
                all.append(f)
                added += 1
            }
            if added == 0 { break }
            let totalPage = json["totalPage"].int
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && items.count < Self.pageSize { break }
            page += 1
        }
        return all
    }

    public func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard !file.isDirectory else { throw CloudnError("文件夹无法直接下载") }
        let uuid = try await deviceId()
        let fileId = file.fid.hasPrefix(Self.filePrefix) ? String(file.fid.dropFirst(Self.filePrefix.count)) : file.fid
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        // downloadId = AES('<fileId>|<userId>')（游客 userId 为空串）；auth = AES('<fileId>|<毫秒时间戳>')
        let params: [(String, String)] = [
            ("downloadId", Self.aesHex("\(fileId)|")), ("enable", "1"), ("devType", Self.devType), ("uuid", uuid),
            ("timestamp", Self.aesHex(ts)), ("auth", Self.aesHex("\(fileId)|\(ts)")), ("shareId", session.shareId)
        ]
        let url = shareBase + "/unproved/file/redirect?" + Self.query(params)
        let r = try await client.send(.get(url, headers: Self.headers, followRedirects: false))
        let dlHeaders = ["User-Agent": Self.ua, "Referer": Self.webSite + "/"]
        if (300..<400).contains(r.status), let location = r.header("Location"), !location.isEmpty {
            let resolved = URL(string: location, relativeTo: URL(string: shareBase))?.absoluteString ?? location
            return DownloadLink(fileName: file.name, url: resolved, size: -1, headers: dlHeaders)
        }
        guard let json = r.json, json.isObject else { throw CloudnError("蓝奏优享未返回下载地址") }
        let link = json["url"].string.nilIfBlank ?? json["data"]["url"].string
        guard !link.isEmpty else {
            throw CloudnError(json["msg"].string.nilIfBlank ?? "蓝奏优享未返回下载地址，请检查文件权限")
        }
        return DownloadLink(fileName: file.name, url: link, size: -1, headers: dlHeaders)
    }

    // MARK: 设备标识

    private func deviceId() async throws -> String {
        if let cached = await state.uuid { return cached }
        let url = base + "/unproved/getUuid?" + Self.query(Self.commonParams(uuid: "", devModel: "chrome") + [("extra", "2")])
        let r = try await client.send(.get(url, headers: Self.headers))
        let uuid = r.json?["uuid"].string ?? ""
        guard Self.uuidRx.matches(uuid) else {
            if r.status == 409 { throw CloudnError("蓝奏优享触发了访问验证，请稍后重试") }
            throw CloudnError("蓝奏优享未返回有效设备标识")
        }
        await state.set(uuid)
        return uuid
    }

    static let uuidRx = Rx(#"^[A-Za-z0-9_-]{8,128}$"#)

    // MARK: 请求构造

    /// 该站 CDN / WAF 对「裸」HTTP 客户端返回空列表，需补全浏览器客户端提示头
    static let headers: [(String, String)] = [
        ("User-Agent", ua), ("Origin", webSite), ("Referer", webSite + "/"),
        ("Accept", "application/json, text/plain, */*"), ("Accept-Language", "zh-CN,zh;q=0.9"),
        ("sec-ch-ua", "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\""),
        ("sec-ch-ua-mobile", "?0"), ("sec-ch-ua-platform", "\"Windows\""),
        ("sec-fetch-dest", "empty"), ("sec-fetch-mode", "cors"), ("sec-fetch-site", "same-site")
    ]

    static func commonParams(uuid: String, devModel: String) -> [(String, String)] {
        [("uuid", uuid), ("devType", devType), ("devCode", uuid), ("devModel", devModel), ("devVersion", devVersion),
         ("appVersion", ""), ("timestamp", aesHex(String(Int64(Date().timeIntervalSince1970 * 1000))))]
    }

    /// 查询串编码：表单编码后把 %3A 还原为冒号（与网页端一致）
    static func query(_ params: [(String, String)]) -> String {
        params.map { "\($0.0)=\($0.1.formEncoded.replacingOccurrences(of: "%3A", with: ":"))" }.joined(separator: "&")
    }

    static func aesHex(_ plain: String) -> String {
        Crypto.hex(AES(key: aesKey)!.encrypt(Array(plain.utf8)))
    }

    /// 列表项：fileType == 2 为文件夹；文件大小单位是 KiB
    static func parseItem(_ item: JSON, parent: String) -> ShareFile? {
        let modified = item.string("updTime", "addTime")
        if item["fileType"].int == 2 {
            let id = item["folderId"].string
            guard !id.isEmpty, id != "0" else { return nil }
            return ShareFile(fid: folderPrefix + id, name: item["folderName"].string, size: 0, isDirectory: true, parentId: parent, modified: modified)
        }
        let id = item["fileId"].string
        guard !id.isEmpty, id != "0" else { return nil }
        return ShareFile(fid: filePrefix + id, name: item["fileName"].string, size: item["fileSize"].int64 * 1024,
                         isDirectory: false, parentId: parent, modified: modified)
    }
}
