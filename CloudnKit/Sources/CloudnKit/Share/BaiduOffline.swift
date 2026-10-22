// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 百度网盘离线下载：pan.baidu.com/rest/2.0/services/cloud_dl（app_id=250528），Cookie 登录态。
// 网址 / 电驴：add_task（task_from=0、selected_idx=1）；磁力：先 query_magnetinfo 取文件数，再 add_task（type=4、全选 selected_idx）。
// list_task 列任务，query_task（op_type=1）补大小与进度，cancel_task + delete_task 删除记录。
// 协议参考 BaiduPCS-Go（Apache-2.0，qjfoidnh/BaiduPCS-Go）baidupcs/cloud_dl.go 与 prepare.go。
import Foundation

extension BaiduResolver: DriveOfflineDownloader {
    static let cloudDlURL = "https://pan.baidu.com/rest/2.0/services/cloud_dl"

    public var offlineSchemes: [String] { ["magnet:", "http", "ed2k:", "ftp:"] }
    public var offlineNote: String {
        "支持磁力、电驴与网址链接。磁力能否下载成功取决于百度服务器上是否有资源，部分资源或高峰期需要会员；同时进行的任务数量有限"
    }

    public func addOfflineTask(_ url: String, to folderId: String) async throws -> String? {
        let link = url.trimmed
        guard !link.isEmpty else { throw CloudnError("链接无效") }
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let token = try await bdstoken(cookie)
        let savePath = folderId.nilIfBlank ?? "/"
        if link.lowercased().hasPrefix("magnet:") {
            let info = try await cloudDl(Self.magnetInfoParams(source: link, savePath: savePath), cookie: cookie, bdstoken: token)
            let files = info["magnet_info"].array
            let count = max(files.count, info["total"].int)
            guard count > 0 else { throw CloudnError("磁力链接无效或暂时无法解析") }
            _ = try await cloudDl(Self.addTaskParams(source: link, savePath: savePath, magnetFileCount: count), cookie: cookie, bdstoken: token)
            return files.count == 1 ? files[0]["file_name"].string.nilIfBlank : nil
        }
        _ = try await cloudDl(Self.addTaskParams(source: link, savePath: savePath, magnetFileCount: nil), cookie: cookie, bdstoken: token)
        return nil
    }

    public func offlineTasks() async throws -> [OfflineTask] {
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let token = try await bdstoken(cookie)
        let list = try await cloudDl(Self.listTaskParams(), cookie: cookie, bdstoken: token)
        var tasks = Self.parseOfflineTasks(list)
        // list_task 不一定带大小与进度：再按 id 精确查询一次（最多 100 个，失败不影响列表）
        let ids = tasks.prefix(100).map(\.id)
        if !ids.isEmpty, let detail = try? await cloudDl(Self.queryTaskParams(ids: Array(ids)), cookie: cookie, bdstoken: token) {
            tasks = Self.mergeQueryTask(tasks, detail)
        }
        return tasks
    }

    /// 进行中的任务要先取消才能删；cancel 对已结束的任务会报错，忽略
    public func removeOfflineTasks(_ ids: [String]) async throws {
        guard let cookie = await loginCookie() else { throw SharePlatform.baidu.loginRequired }
        let token = try await bdstoken(cookie)
        for id in ids where !id.isEmpty {
            _ = try? await cloudDl([("method", "cancel_task"), ("app_id", Self.appId), ("task_id", id)], cookie: cookie, bdstoken: token)
            _ = try await cloudDl([("method", "delete_task"), ("app_id", Self.appId), ("task_id", id)], cookie: cookie, bdstoken: token)
        }
    }

    /// 参数全部放在查询串里 POST（同 BaiduPCS-Go）；失败为 {error_code, error_msg}，网页参数下也可能是 {errno}
    private func cloudDl(_ params: [(String, String)], cookie: String, bdstoken: String) async throws -> JSON {
        let url = Self.cloudDlRequestURL(params, bdstoken: bdstoken)
        let r = try await client.send(HTTPRequest(url: url, method: "POST", headers: [
            ("Cookie", cookie), ("User-Agent", Self.netdiskUA), ("Referer", "https://pan.baidu.com/"),
            ("Content-Type", "application/x-www-form-urlencoded")
        ], body: Data()))
        guard let json = r.json, json.isObject else { throw CloudnError("响应解析失败（HTTP \(r.status)）") }
        try Self.checkCloudDl(json)
        return json
    }

    // MARK: 请求参数 / 解析

    static func cloudDlRequestURL(_ params: [(String, String)], bdstoken: String) -> String {
        let all = params + [("channel", "chunlei"), ("web", "1"), ("clienttype", "0"), ("bdstoken", bdstoken)]
        return cloudDlURL + "?" + all.map { "\($0.0)=\($0.1.formEncoded)" }.joined(separator: "&")
    }

    static func magnetInfoParams(source: String, savePath: String) -> [(String, String)] {
        [("method", "query_magnetinfo"), ("app_id", appId), ("source_url", source), ("save_path", savePath), ("type", "4")]
    }

    /// 磁力：type=4、selected_idx 为 1...n 全选、task_from=1（网页端）；其他链接按 BaiduPCS-Go：task_from=0、selected_idx=1
    static func addTaskParams(source: String, savePath: String, magnetFileCount: Int?) -> [(String, String)] {
        var p: [(String, String)] = [("method", "add_task"), ("app_id", appId), ("save_path", savePath), ("source_url", source)]
        if let n = magnetFileCount {
            p += [("type", "4"), ("task_from", "1"), ("selected_idx", (1...max(1, n)).map(String.init).joined(separator: ","))]
        } else {
            p += [("task_from", "0"), ("selected_idx", "1")]
        }
        return p
    }

    static func listTaskParams() -> [(String, String)] {
        [("method", "list_task"), ("app_id", appId), ("need_task_info", "1"), ("status", "255"), ("start", "0"), ("limit", "100")]
    }

    static func queryTaskParams(ids: [String]) -> [(String, String)] {
        [("method", "query_task"), ("app_id", appId), ("op_type", "1"), ("task_ids", ids.joined(separator: ","))]
    }

    static func checkCloudDl(_ json: JSON) throws {
        let code = json.has("error_code") ? json["error_code"].int : json["errno"].int
        guard code != 0 else { return }
        let server = json.string("error_msg", "show_msg", "err_msg")
        throw CloudnError(cloudDlMessage(code) ?? (server.isEmpty ? "百度离线下载失败（\(code)）" : server), code: code)
    }

    static func cloudDlMessage(_ code: Int) -> String? {
        switch code {
        case 36013, 36022: return "同时进行的离线任务过多，请稍后再试"
        case 36016: return "该任务已存在"
        case 36018: return "链接无效或解析失败"
        case 36024: return "本月离线下载次数已用完，可能需要会员"
        case 36032: return "资源含违规内容，无法离线下载"
        case 36000, 36001, 36031: return "百度网盘繁忙，请稍后再试"
        case -6, 110, 111: return "百度网盘登录已失效，请到「我的」页重新登录"
        case -19: return "百度要求验证码，请先在官方 App 中添加一次离线任务"
        default: return nil
        }
    }

    /// status：0 成功、1 进行中、2 系统错误、3 资源不存在、4 超时、5 下载失败、6 空间不足、7 已取消
    static func offlineState(_ status: Int) -> OfflineTaskState {
        switch status {
        case 0: return .done
        case 1: return .running
        case 2: return .failed("系统错误")
        case 3: return .failed("资源不存在")
        case 4: return .failed("下载超时")
        case 5: return .failed("资源存在但下载失败")
        case 6: return .failed("网盘空间不足")
        case 7: return .failed("任务已取消")
        default: return .waiting
        }
    }

    static func parseOfflineTasks(_ json: JSON) -> [OfflineTask] {
        json["task_info"].array.compactMap { t in
            let id = t["task_id"].string
            guard !id.isEmpty else { return nil }
            return task(id: id, t)
        }
    }

    /// query_task 的 task_info 是 {task_id: 详情} 字典
    static func mergeQueryTask(_ tasks: [OfflineTask], _ json: JSON) -> [OfflineTask] {
        let info = json["task_info"]
        guard info.isObject else { return tasks }
        return tasks.map { old in
            let t = info[old.id]
            guard t.isObject else { return old }
            let merged = task(id: old.id, t)
            return OfflineTask(id: old.id, name: merged.name == "离线任务" ? old.name : merged.name, progress: merged.progress ?? old.progress,
                               size: merged.size > 0 ? merged.size : old.size, state: t.has("status") ? merged.state : old.state,
                               folderId: merged.folderId ?? old.folderId)
        }
    }

    static func task(id: String, _ t: JSON) -> OfflineTask {
        let state = t.has("status") ? offlineState(t["status"].int) : .waiting
        let size = t["file_size"].int64
        let finished = t["finished_size"].int64
        var progress: Double? = size > 0 && t.has("finished_size") ? min(1, Double(finished) / Double(size)) : nil
        if state == .done { progress = 1 }
        let name = t["task_name"].string.nilIfBlank ?? t["source_url"].string.nilIfBlank ?? "离线任务"
        return OfflineTask(id: id, name: name, progress: progress, size: size, state: state, folderId: t["save_path"].string.nilIfBlank)
    }
}
