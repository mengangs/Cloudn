// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 迅雷网盘离线下载（云添加）：POST drive/v1/files（kind=drive#file、upload_type=UPLOAD_TYPE_URL）提交，
// GET drive/v1/tasks?type=offline 列任务，DELETE drive/v1/tasks 删除记录。
// 协议参考 OpenList（AGPL-3.0）drivers/thunder 与 internal/offline_download/thunder。
import Foundation

extension XunleiResolver: DriveOfflineDownloader {
    public var offlineSchemes: [String] { ["magnet:", "http", "ed2k:", "ftp:", "thunder:"] }
    public var offlineNote: String { "支持磁力、电驴与网址链接。每日添加次数与下载速度受迅雷会员等级限制" }

    public func addOfflineTask(_ url: String, to folderId: String) async throws -> String? {
        let link = url.trimmed
        guard !link.isEmpty else { throw CloudnError("链接无效") }
        let id = try await driveIdentity()
        let data = try await pan("POST:/drive/v1/files", url: panBase + "/drive/v1/files",
                                 body: Self.offlineAddBody(url: link, parent: Self.driveParent(folderId)), identity: id)
        let task = data["task"]
        if task["phase"].string == "PHASE_TYPE_ERROR" {
            throw CloudnError(task["message"].string.nilIfBlank ?? "迅雷离线任务创建失败")
        }
        return task.string("name", "file_name").nilIfBlank ?? data["file"]["name"].string.nilIfBlank
    }

    public func offlineTasks() async throws -> [OfflineTask] {
        let id = try await driveIdentity()
        var all: [OfflineTask] = []
        var pageToken = ""
        for _ in 0..<5 {
            let data = try await pan("GET:/drive/v1/tasks", url: Self.offlineListURL(panBase, pageToken: pageToken), identity: id)
            all += Self.parseOfflineTasks(data)
            pageToken = data["next_page_token"].string
            if pageToken.isEmpty { break }
        }
        return all
    }

    public func removeOfflineTasks(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let id = try await driveIdentity()
        do {
            _ = try await pan("DELETE:/drive/v1/tasks", url: Self.offlineDeleteURL(panBase, ids: ids), method: "DELETE", identity: id)
        } catch let error as CloudnError where error.message.hasPrefix("迅雷响应解析失败（HTTP 2") {
            // 删除成功时可能返回空 body
        }
    }

    // MARK: 请求体 / 解析

    /// name 留空由服务端按链接命名；space 必须是字符串
    static func offlineAddBody(url: String, parent: String) -> OrderedJSON {
        .object([("kind", .string("drive#file")), ("name", .string("")), ("parent_id", .string(parent)),
                 ("upload_type", .string("UPLOAD_TYPE_URL")), ("url", .object([("url", .string(url))])), ("space", .string(""))])
    }

    static func offlineListURL(_ base: String, pageToken: String) -> String {
        base + "/drive/v1/tasks?type=offline&limit=100&page_token=\(pageToken.formEncoded)&space="
    }

    static func offlineDeleteURL(_ base: String, ids: [String]) -> String {
        base + "/drive/v1/tasks?task_ids=\(ids.joined(separator: ",").formEncoded)&delete_files=false&space="
    }

    /// phase：PENDING / RUNNING / COMPLETE / ERROR；progress 为 0...100；file_size 为字符串
    static func parseOfflineTasks(_ data: JSON) -> [OfflineTask] {
        data["tasks"].array.compactMap { t in
            let id = t["id"].string
            guard !id.isEmpty else { return nil }
            let state: OfflineTaskState
            switch t["phase"].string {
            case "PHASE_TYPE_COMPLETE": state = .done
            case "PHASE_TYPE_ERROR": state = .failed(t["message"].string.nilIfBlank ?? "下载失败")
            case "PHASE_TYPE_RUNNING": state = .running
            default: state = .waiting
            }
            let progress = state == .done ? 1 : min(1, max(0, t["progress"].double / 100))
            let name = t.string("name", "file_name").nilIfBlank ?? "离线任务"
            return OfflineTask(id: id, name: name, progress: progress, size: t["file_size"].int64, state: state)
        }
    }
}
