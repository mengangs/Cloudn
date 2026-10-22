// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 123 云盘离线下载：/b/api/v2/offline_download/task/resolve 解析资源 → task/submit 提交到目录，
// /b/api/offline_download/task/list 列任务、task/delete 删除记录（均带 auth-key / auth-value 签名头）。
// 协议参考 OpenList（AGPL-3.0）drivers/123（util.go / types.go）与 internal/offline_download/123。
import Foundation

extension Pan123Resolver: DriveOfflineDownloader {
    static let offlineResolvePath = "/b/api/v2/offline_download/task/resolve"
    static let offlineSubmitPath = "/b/api/v2/offline_download/task/submit"
    static let offlineListPath = "/b/api/offline_download/task/list"
    static let offlineDeletePath = "/b/api/offline_download/task/delete"

    public var offlineSchemes: [String] { ["magnet:", "http"] }
    public var offlineNote: String { "支持磁力与网址链接。离线下载的次数与可用性取决于 123 云盘会员权益" }

    public func addOfflineTask(_ url: String, to folderId: String) async throws -> String? {
        let link = url.trimmed
        guard !link.isEmpty else { throw CloudnError("链接无效") }
        guard let dir = Int64(folderId.nilIfBlank ?? "0") else { throw CloudnError("目标文件夹无效") }
        let token = try await driveToken()
        let resolved = try await offlineCall(Self.offlineResolvePath, ["urls": link], token: token, fallback: "解析链接失败")
        let resource = try Self.parseOfflineResolve(resolved)
        let submitted = try await offlineCall(Self.offlineSubmitPath,
                                              Self.offlineSubmitBody(resourceId: resource.id, fileIds: resource.fileIds, uploadDir: dir),
                                              token: token, fallback: "提交离线任务失败")
        try Self.checkOfflineSubmit(submitted)
        return resource.name
    }

    public func offlineTasks() async throws -> [OfflineTask] {
        let token = try await driveToken()
        var all: [OfflineTask] = []
        for page in 1...5 {
            let json = try await offlineCall(Self.offlineListPath, Self.offlineListBody(page: page), token: token, fallback: "获取离线任务失败")
            let tasks = Self.parseOfflineTasks(json)
            all += tasks
            if tasks.isEmpty || page * 100 >= json["data"]["total"].int { break }
        }
        return all
    }

    public func removeOfflineTasks(_ ids: [String]) async throws {
        let taskIds = ids.compactMap { Int64($0) }
        guard !taskIds.isEmpty else { return }
        let token = try await driveToken()
        _ = try await offlineCall(Self.offlineDeletePath, ["task_ids": taskIds], token: token, fallback: "删除离线任务失败")
    }

    /// 签名 path 必须与请求 path 逐字一致
    private func offlineCall(_ path: String, _ body: [String: Any], token: String, fallback: String) async throws -> JSON {
        let json = try await callJSON(.postJSON(apiBase + path, body, headers: jsonAuthHeaders(path: path, token: token)))
        try Self.check(json, fallback: fallback)
        return json
    }

    // MARK: 请求体 / 解析

    static func offlineSubmitBody(resourceId: Int64, fileIds: [Int64], uploadDir: Int64) -> [String: Any] {
        ["resource_list": [["resource_id": resourceId, "select_file_id": fileIds]], "upload_dir": uploadDir]
    }

    static func offlineListBody(page: Int) -> [String: Any] {
        ["current_page": page, "page_size": 100, "status_arr": [0, 1, 2, 3]]
    }

    /// data.list[0]：result != 0 为解析失败（err_msg）；files 为可选文件，默认全选
    static func parseOfflineResolve(_ json: JSON) throws -> (id: Int64, fileIds: [Int64], name: String?) {
        guard let item = json["data"]["list"].array.first else { throw CloudnError("链接解析失败") }
        if item["result"].int != 0 {
            throw CloudnError(item["err_msg"].string.nilIfBlank ?? "链接无效或暂不支持", code: item["err_code"].int)
        }
        let id = item["id"].int64
        guard id != 0 else { throw CloudnError("链接解析失败") }
        let files = item["files"].array
        let fileIds = files.map { $0["id"].int64 }.filter { $0 > 0 }
        guard !fileIds.isEmpty else { throw CloudnError("链接里没有可下载的文件") }
        let name = item.string("name", "resource_name", "file_name").nilIfBlank
            ?? (files.count == 1 ? files[0].string("name", "file_name").nilIfBlank : nil)
        return (id, fileIds, name)
    }

    static func checkOfflineSubmit(_ json: JSON) throws {
        guard let task = json["data"]["task_list"].array.first else { throw CloudnError("提交离线任务失败") }
        guard task["result"].int == 0, task["task_id"].int64 != 0 else {
            throw CloudnError(task.string("err_msg", "message").nilIfBlank ?? "提交离线任务失败")
        }
    }

    /// status：0 下载中、1 失败、2 成功、3 重试中；progress 可能是 0...1 或 0...100，统一成 0...1
    static func parseOfflineTasks(_ json: JSON) -> [OfflineTask] {
        json["data"]["list"].array.compactMap { t in
            let id = t["task_id"].int64
            guard id != 0 else { return nil }
            let state: OfflineTaskState
            switch t["status"].int {
            case 2: state = .done
            case 1: state = .failed(t.string("err_msg", "message").nilIfBlank ?? "离线下载失败")
            case 0, 3: state = .running
            default: state = .waiting
            }
            let size = t["size"].int64
            let raw = t["progress"].double
            var progress = raw > 1 ? raw / 100 : raw
            if progress <= 0, size > 0 { progress = Double(t["downloaded"].int64) / Double(size) }
            if state == .done { progress = 1 }
            let dir = t["upload_idr"].string
            return OfflineTask(id: String(id), name: t.string("name", "upload_name").nilIfBlank ?? "离线任务",
                               progress: min(1, max(0, progress)), size: size, state: state, folderId: dir.nilIfBlank)
        }
    }
}
