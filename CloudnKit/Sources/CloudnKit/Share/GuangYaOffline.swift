// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 光鸭云盘离线下载（云收藏）：/cloudcollection/v1/resolve_res 解析 → create_task 提交（BT 默认全选子文件），
// /cloudcollection/v1/list_task 列任务、/cloudcollection/v2/delete_task 删除记录。
// 协议参考 OpenList（AGPL-3.0）drivers/guangyapan/offline.go 与 internal/offline_download/guangyapan。
import Foundation

extension GuangYaResolver: DriveOfflineDownloader {
    public var offlineSchemes: [String] { ["magnet:", "http", "ed2k:", "ftp:"] }
    public var offlineNote: String { "支持磁力与网址链接。离线次数与速度受光鸭云盘会员权益限制" }

    public func addOfflineTask(_ url: String, to folderId: String) async throws -> String? {
        let link = url.trimmed
        guard !link.isEmpty else { throw CloudnError("链接无效") }
        let cred = try await credential()
        let resolved = try await call("resolve_res", .object([("url", .string(link))]), fallback: "链接解析失败", cred: cred,
                                      prefix: "/cloudcollection/v1/")
        let request = Self.offlineCreateBody(resolved, source: link, parentId: folderId)
        let data = try await call("create_task", request.body, fallback: "创建离线任务失败", cred: cred, prefix: "/cloudcollection/v1/")
        guard !data["taskId"].string.isEmpty else { throw CloudnError("创建离线任务失败") }
        return request.name
    }

    public func offlineTasks() async throws -> [OfflineTask] {
        let cred = try await credential()
        var all: [OfflineTask] = []
        var cursor = ""
        for _ in 0..<5 {
            var pairs: [(String, OrderedJSON)] = [("pageSize", .int(100))]
            if !cursor.isEmpty { pairs.append(("cursor", .string(cursor))) }
            let data = try await call("list_task", .object(pairs), fallback: "获取离线任务失败", cred: cred, prefix: "/cloudcollection/v1/")
            let tasks = Self.parseOfflineTasks(data)
            all += tasks
            let next = data["cursor"].string
            if tasks.isEmpty || next.isEmpty || next == cursor { break }
            cursor = next
        }
        return all
    }

    public func removeOfflineTasks(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let cred = try await credential()
        _ = try await call("delete_task", .object([("taskIds", .array(ids.map { .string($0) }))]), fallback: "删除离线任务失败",
                           cred: cred, prefix: "/cloudcollection/v2/")
    }

    // MARK: 请求体 / 解析

    /// resolve_res 的 data：url 为规范化后的地址；btResInfo.subfiles 全选（fileIndex 缺失时按下标）；
    /// 根目录 parentId 传空串；newName 优先种子名，其次 URL 路径末段
    static func offlineCreateBody(_ resolved: JSON, source: String, parentId: String) -> (body: OrderedJSON, name: String) {
        let taskURL = resolved["url"].string.trimmed.nilIfBlank ?? source
        let bt = resolved["btResInfo"]
        let name = bt["fileName"].string.trimmed.nilIfBlank ?? defaultOfflineName(taskURL)
        var pairs: [(String, OrderedJSON)] = [("url", .string(taskURL)), ("parentId", .string(parentId == "0" ? "" : parentId)),
                                              ("newName", .string(name))]
        let subfiles = bt["subfiles"].array
        if !subfiles.isEmpty {
            let indexes = subfiles.enumerated().map { i, f in f.has("fileIndex") && !f["fileIndex"].isNull ? f["fileIndex"].int64 : Int64(i) }
            pairs.append(("fileIndexes", .array(indexes.map { .int($0) })))
        }
        return (.object(pairs), name)
    }

    static func defaultOfflineName(_ url: String) -> String {
        let path = URL(string: url)?.path ?? ""
        let last = (path as NSString).lastPathComponent
        guard !last.isEmpty, last != "/", last != "." else { return "offline_download" }
        return last.removingPercentEncoding ?? last
    }

    /// status：0 排队、1 下载中、2 完成、3 失败、4 已取消、5 部分完成；progress 为 0...100
    static func parseOfflineTasks(_ data: JSON) -> [OfflineTask] {
        listArray(data).compactMap { t in
            let id = t["taskId"].string
            guard !id.isEmpty else { return nil }
            let state: OfflineTaskState
            switch t["status"].int {
            case 2, 5: state = .done
            case 3: state = .failed("离线下载失败")
            case 4: state = .failed("任务已取消")
            case 1: state = .running
            default: state = .waiting
            }
            let progress = state == .done ? 1 : min(1, max(0, t["progress"].double / 100))
            return OfflineTask(id: id, name: t["fileName"].string.nilIfBlank ?? t["res"].string, progress: progress,
                               size: t["totalSize"].int64, state: state)
        }
    }
}
