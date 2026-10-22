// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 115 网盘离线下载（云下载）：lixianssp add_task_urls 提交（请求体与响应都走电脑端 m115 加密，同 Pan115Crypto）、
// lixian task_lists 列任务、task_del 删除记录。
// 协议参考 OpenList（AGPL-3.0）drivers/115、internal/offline_download/115 及其使用的 SheltonZhu/115driver（MIT）pkg/driver/offline.go。
import Foundation

extension Pan115Resolver: DriveOfflineDownloader {
    static let lixianAddURL = "https://lixian.115.com/lixianssp/?ac=add_task_urls"
    static let lixianListURL = "https://lixian.115.com/lixian/?ct=lixian&ac=task_lists"
    static let lixianDeleteURL = "https://lixian.115.com/lixian/?ct=lixian&ac=task_del"

    public var offlineSchemes: [String] { ["magnet:", "http", "ed2k:", "ftp:"] }
    public var offlineNote: String { "支持磁力、电驴与网址链接。离线配额按 115 会员等级发放，非会员可能无法添加" }

    public func addOfflineTask(_ url: String, to folderId: String) async throws -> String? {
        let link = url.trimmed
        guard !link.isEmpty else { throw CloudnError("链接无效") }
        let cookie = try await driveCookie()
        guard let uid = Self.userId(fromCookie: cookie) else { throw CloudnError("登录态缺少用户标识，请重新登录 115 网盘") }
        await refreshClientVersion()
        let ua = await clientUA()
        let payload = Self.offlineAddPayload(urls: [link], folderId: folderId.nilIfBlank ?? "0",
                                             appVersion: Self.appVersion(fromUA: ua), uid: uid)
        let key = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let req = HTTPRequest.postForm(Self.lixianAddURL + "&t=\(Int64(Date().timeIntervalSince1970))",
                                       [("data", Pan115Crypto.encode(payload, key: key))],
                                       headers: headers(cookie: cookie, referer: Self.referer, ua: ua))
        let r = try await client.send(req)
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.checkOffline(json, fallback: "添加离线任务失败")
        guard let plain = Pan115Crypto.decode(json["data"].string, key: key), let decoded = JSON(text: plain) else {
            throw CloudnError("115 离线响应解析失败")
        }
        return try Self.parseOfflineAddResult(decoded)
    }

    public func offlineTasks() async throws -> [OfflineTask] {
        let cookie = try await driveCookie()
        let ua = await clientUA()
        var all: [OfflineTask] = []
        var page = 1
        while page <= 5 {
            let req = HTTPRequest(url: Self.lixianListURL + "&page=\(page)", method: "POST",
                                  headers: headers(cookie: cookie, referer: Self.referer, ua: ua))
            let r = try await client.send(req)
            guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
            try Self.checkOffline(json, fallback: "获取离线任务失败")
            all += Self.parseOfflineTasks(json)
            if page >= json["page_count"].int { break }
            page += 1
        }
        return all
    }

    /// 与 115driver 一致：一个 hash 一次请求（form 里重复的 hash 键服务端只认最后一个）；flag=0 保留已下载文件
    public func removeOfflineTasks(_ ids: [String]) async throws {
        let cookie = try await driveCookie()
        let ua = await clientUA()
        for hash in ids where !hash.isEmpty {
            let r = try await client.send(.postForm(Self.lixianDeleteURL, Self.offlineDeleteFields(hash: hash),
                                                    headers: headers(cookie: cookie, referer: Self.referer, ua: ua)))
            guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
            try Self.checkOffline(json, fallback: "删除离线任务失败")
        }
    }

    // MARK: 请求体 / 解析

    /// 115driver 用 Go map 序列化（键按字母序）：ac、app_ver、uid、url[i]、wp_path_id
    static func offlineAddPayload(urls: [String], folderId: String, appVersion: String, uid: String) -> String {
        var pairs: [(String, OrderedJSON)] = [("ac", .string("add_task_urls")), ("app_ver", .string(appVersion)), ("uid", .string(uid))]
        for (i, u) in urls.enumerated() { pairs.append(("url[\(i)]", .string(u))) }
        pairs.append(("wp_path_id", .string(folderId)))
        return OrderedJSON.object(pairs).text
    }

    static func offlineDeleteFields(hash: String) -> [(String, String)] {
        [("hash", hash), ("flag", "0")]
    }

    /// UA 形如 "Mozilla/5.0 115Browser/36.0.1"
    static func appVersion(fromUA ua: String) -> String {
        guard let range = ua.range(of: "115Browser/") else { return "36.0.1" }
        return String(ua[range.upperBound...]).trimmed.nilIfBlank ?? "36.0.1"
    }

    /// 解密后的 {"state":true,"result":[{"state":..., "errcode"/"errno":..., "error_msg":..., "info_hash":..., "name":...}]}
    static func parseOfflineAddResult(_ json: JSON) throws -> String? {
        if json.has("state"), !json["state"].bool { try checkOffline(json, fallback: "添加离线任务失败") }
        guard let item = json["result"].array.first else { return nil }
        if item.has("state"), !item["state"].bool {
            let code = item.has("errcode") ? item["errcode"].int : errorNo(item)
            throw CloudnError(offlineMessage(code) ?? item.string("error_msg", "error").nilIfBlank ?? "添加离线任务失败", code: code)
        }
        return item["name"].string.nilIfBlank
    }

    /// status：-1 失败、0 等待、1 下载中、2 完成；percentDone 为 0...100
    static func parseOfflineTasks(_ json: JSON) -> [OfflineTask] {
        json["tasks"].array.compactMap { t in
            let hash = t["info_hash"].string
            guard !hash.isEmpty else { return nil }
            let state: OfflineTaskState
            switch t["status"].int {
            case 2: state = .done
            case -1: state = .failed("离线下载失败")
            case 1: state = .running
            default: state = .waiting
            }
            let progress = state == .done ? 1 : min(1, max(0, t["percentDone"].double / 100))
            return OfflineTask(id: hash, name: t["name"].string.nilIfBlank ?? t["url"].string, progress: progress,
                               size: t["size"].int64, state: state, folderId: t["wp_path_id"].string.nilIfBlank)
        }
    }

    static func offlineMessage(_ code: Int) -> String? {
        switch code {
        case 10010: return "离线配额已用完，需要会员"
        case 10004: return "链接无效"
        case 10008: return "该任务已存在"
        case 99, 990001: return "115 登录已过期，请到「我的」页重新登录"
        case 911: return "115 需要安全验证，请在官方 App 中完成验证后重试"
        default: return nil
        }
    }

    static func checkOffline(_ json: JSON, fallback: String) throws {
        guard !ok(json) else { return }
        let code = errorNo(json)
        if let msg = offlineMessage(code) { throw CloudnError(msg, code: code) }
        try check(json, fallback: fallback)
    }
}
