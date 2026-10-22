// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 夸克网盘离线下载（云添加，仅夸克，UC 不支持）。非公开接口，走网页端主机 drive.quark.cn（Cookie 即可；drive-pc 需客户端签名头）：
//   POST /1/clouddrive/offline/download/parse?api_ver=2  → token + 文件清单（finished=false 时稍等重试）
//   POST /1/clouddrive/offline/download/submit           → task_id（selected_files 为 file_no，默认全选）
//   GET  /1/clouddrive/task/current/list?task_type=5     → 任务列表；GET /1/clouddrive/task?task_id= 精确查询
//   POST /1/clouddrive/task/status {task_ids, op_type:0}  → 删除任务记录
// parse / submit 的请求体用「wg」封装：base64(2 字节大端 secureNo ‖ AES-128-CBC(PKCS7(明文 JSON), key=iv=数据密钥))，
// 并带 X-U-Content-Encoding: wg；secureNo 14100 的数据密钥 e21247a68938d36f 来自客户端逆向。
// 协议参考 qrypt（yinzhenyu-su/qrypt，pkg/drivers/quark/offline.go、offline_crypto.go 与
// openspec/changes/add-offline-download/design.md 附录 A）及 QuarkPlusPlus（TabNahida/QuarkPlusPlus docs/protocol.md）。
import Foundation

extension QuarkFamilyResolver: DriveOfflineDownloader {
    static let offlineBase = "https://drive.quark.cn/1/clouddrive"
    static let wgSecureNo: UInt16 = 14100
    static let wgKey = Array("e21247a68938d36f".utf8)

    /// 本进程提交过的任务 id：列表接口取不到时按 id 逐个查询兜底
    private static let recent = RecentQuarkOfflineTasks()

    public var offlineSchemes: [String] { config.platform == .quark ? ["magnet:", "http", "ftp:"] : [] }
    public var offlineNote: String {
        config.platform == .quark
            ? "支持磁力与网址链接（夸克非公开接口）。次数与速度受夸克会员限制；资源在夸克服务器上没有缓存时可能很快失败"
            : "UC 网盘暂不支持离线下载"
    }

    public func addOfflineTask(_ url: String, to folderId: String) async throws -> String? {
        guard config.platform == .quark else { throw CloudnError("UC 网盘暂不支持离线下载") }
        let link = url.trimmed
        guard !link.isEmpty else { throw CloudnError("链接无效") }
        guard let cookie = await freshCookie() else { throw config.platform.loginRequired }
        var parsed = JSON(nil)
        for attempt in 0..<4 {
            parsed = try await offlineRequest("/offline/download/parse", query: "&api_ver=2", wg: Self.offlineParseBody(url: link),
                                              cookie: cookie, fallback: "链接解析失败")
            if parsed["finished"].bool || attempt == 3 { break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard parsed["finished"].bool else { throw CloudnError("夸克仍在解析链接，请稍后再试") }
        let token = parsed["token"].string
        guard !token.isEmpty else { throw CloudnError("链接解析失败") }
        let files = Self.selectedFileNumbers(parsed["files"].array)
        let submitted = try await offlineRequest("/offline/download/submit", query: "",
                                                 wg: Self.offlineSubmitBody(token: token, pdirFid: folderId.nilIfBlank ?? "0", files: files),
                                                 cookie: cookie, fallback: "提交离线任务失败")
        let taskId = submitted["task_id"].string
        guard !taskId.isEmpty else { throw CloudnError("提交离线任务失败") }
        await Self.recent.add(taskId)
        return parsed["title"].string.nilIfBlank ?? (parsed["files"].array.count == 1 ? parsed["files"][0]["file_name"].string.nilIfBlank : nil)
    }

    public func offlineTasks() async throws -> [OfflineTask] {
        guard config.platform == .quark else { return [] }
        guard let cookie = await freshCookie() else { throw config.platform.loginRequired }
        var tasks: [OfflineTask] = []
        var listError: Error?
        do {
            let data = try await offlineRequest("/task/current/list", query: "&task_type=5&status=0,1,2,3,4", wg: nil, method: "GET",
                                                cookie: cookie, fallback: "获取离线任务失败")
            tasks = Self.parseOfflineTasks(data)
        } catch {
            listError = error
        }
        // 列表接口按状态过滤不可靠：本进程提交过、但不在列表里的任务按 id 补查
        var seen = Set(tasks.map(\.id))
        for id in await Self.recent.ids where !seen.contains(id) {
            guard let data = try? await offlineRequest("/task", query: "&task_id=\(id.formEncoded)", wg: nil, method: "GET",
                                                       cookie: cookie, fallback: "查询离线任务失败"),
                  let task = Self.parseOfflineTask(data) else { continue }
            tasks.append(task)
            seen.insert(id)
        }
        if tasks.isEmpty, let listError { throw listError }
        return tasks
    }

    public func removeOfflineTasks(_ ids: [String]) async throws {
        guard config.platform == .quark, !ids.isEmpty else { return }
        guard let cookie = await freshCookie() else { throw config.platform.loginRequired }
        do {
            _ = try await offlineRequest("/task/status", query: "", plain: Self.taskStatusBody(ids: ids, opType: 0),
                                         cookie: cookie, fallback: "删除离线任务失败")
        } catch let error as CloudnError where error.code == 23004 {
            // 任务已不存在
        }
        await Self.recent.remove(ids)
    }

    /// wg 非空时请求体加密并带 X-U-Content-Encoding: wg；plain 为普通 JSON 体；都为空则无 body
    private func offlineRequest(_ path: String, query: String, wg: OrderedJSON? = nil, plain: OrderedJSON? = nil, method: String = "POST",
                                cookie: String, fallback: String) async throws -> JSON {
        var headers: [(String, String)] = [
            ("Cookie", cookie), ("User-Agent", config.apiUA), ("Origin", config.webOrigin), ("Referer", config.webOrigin),
            ("Accept", "application/json, text/plain, */*")
        ]
        var body: Data?
        if let wg {
            headers += [("Content-Type", "application/json"), ("X-U-Content-Encoding", "wg")]
            body = Data(Self.wgEncrypt(wg.text).utf8)
        } else if let plain {
            headers.append(("Content-Type", "application/json"))
            body = Data(plain.text.utf8)
        }
        let r = try await client.send(HTTPRequest(url: Self.offlineBase + path + "?pr=ucpro&fr=pc" + query, method: method,
                                                  headers: headers, body: body))
        let json = Self.decodeOfflineResponse(r)
        guard let json, json.isObject else { throw CloudnError("夸克响应解析失败（HTTP \(r.status)）") }
        try Self.checkOffline(json, status: r.status, fallback: fallback)
        return json["data"].isNull ? json : json["data"]
    }

    // MARK: wg 封装

    static func wgEncrypt(_ plain: String) -> String {
        guard let aes = AES(key: wgKey) else { return "" }
        let cipher = aes.encrypt(Array(plain.utf8), mode: .cbc(iv: wgKey))
        return Data([UInt8(wgSecureNo >> 8), UInt8(wgSecureNo & 0xff)] + cipher).base64EncodedString()
    }

    /// 只认 secureNo 14100；其他版本号或填充不合法返回 nil
    static func wgDecrypt(_ text: String) -> String? {
        guard let raw = Crypto.base64Decode(text.trimmed), raw.count >= 18 else { return nil }
        let bytes = [UInt8](raw)
        guard UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == wgSecureNo, let aes = AES(key: wgKey),
              let plain = aes.decrypt(Array(bytes[2...]), mode: .cbc(iv: wgKey)) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    /// 响应头标了 wg 时先解密；也兼容明文 JSON
    static func decodeOfflineResponse(_ r: HTTPResponse) -> JSON? {
        let marked = [r.header("X-U-Content-Encoding"), r.header("Content-Encoding")].contains { $0?.trimmed.lowercased() == "wg" }
        if marked || r.json == nil, let plain = wgDecrypt(r.text), let json = JSON(text: plain) { return json }
        return r.json
    }

    // MARK: 请求体 / 解析

    static func offlineParseBody(url: String) -> OrderedJSON {
        .object([
            ("url", .string(url)), ("fid", .string("")), ("title", .string("")), ("parse_mode", .int(0)), ("cookie", .string("")),
            ("referer", .string("")), ("page_url", .string("")), ("entry", .string("download")),
            ("req_info", .object([("method", .string("")), ("body", .string("")), ("is_multipart", .bool(false))])),
            ("conflict_mode", .int(4)), ("save_path", .string("")), ("auto_download", .bool(false)), ("support_v2_play", .bool(true))
        ])
    }

    static func offlineSubmitBody(token: String, pdirFid: String, files: [Int]) -> OrderedJSON {
        .object([("token", .string(token)), ("entry", .string("download")), ("parse_mode", .int(0)), ("pdir_fid", .string(pdirFid)),
                 ("auto_select", .bool(false)), ("selected_files", .array(files.map { .int(Int64($0)) })), ("title", .string(""))])
    }

    static func taskStatusBody(ids: [String], opType: Int) -> OrderedJSON {
        .object([("task_ids", .array(ids.map { .string($0) })), ("op_type", .int(Int64(opType)))])
    }

    /// file_no 可能是数字，也可能是文件夹条目的 "3,4,5"：展开、去重、保持顺序
    static func selectedFileNumbers(_ files: [JSON]) -> [Int] {
        var out: [Int] = []
        for f in files {
            let raw = f["file_no"]
            let numbers: [Int] = raw.raw is String
                ? raw.string.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                : (raw.isNull ? [] : [raw.int])
            for n in numbers where !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// 列表字段名随版本不同：list / tasks / task_list，或 data 本身就是数组
    static func parseOfflineTasks(_ data: JSON) -> [OfflineTask] {
        let items = data.isArray ? data.array : data.arrayValue("list", "tasks", "task_list")
        return items.filter { !$0.has("task_type") || $0["task_type"].int == 5 }.compactMap(parseOfflineTask)
    }

    /// status：0 排队、1 下载中、2 完成、3 失败、4 已取消；progress 为 0...1000
    static func parseOfflineTask(_ t: JSON) -> OfflineTask? {
        let id = t["task_id"].string
        guard !id.isEmpty else { return nil }
        let state: OfflineTaskState
        switch t["status"].int {
        case 2: state = .done
        case 3: state = .failed(t.string("message", "err_msg").nilIfBlank ?? "离线下载失败")
        case 4: state = .failed("任务已取消")
        case 1: state = .running
        default: state = .waiting
        }
        let results = t["offdl_result"]["list"].array
        var size = t["size"].int64
        if size <= 0 { size = t["total_size"].int64 }
        if size <= 0 { size = results.reduce(0) { $0 + $1["size"].int64 } }
        let progress = state == .done ? 1 : min(1, max(0, t["progress"].double / 1000))
        let name = t.string("task_title", "title").nilIfBlank ?? results.first?["file_name"].string.nilIfBlank ?? "离线任务"
        return OfflineTask(id: id, name: name, progress: progress, size: size, state: state,
                           folderId: results.first?["pdir_fid"].string.nilIfBlank)
    }

    static func checkOffline(_ json: JSON, status: Int, fallback: String) throws {
        let code = json["code"].int
        // 外层 status 是 HTTP 风格的 200；无 data 包装的任务详情里 status 是 0...4 的任务状态，不算失败
        guard code != 0 || json["status"].int >= 400 || status == 401 else { return }
        let server = json["message"].string
        throw CloudnError(offlineMessage(code) ?? (server.isEmpty ? "\(fallback)（\(code)）" : server), code: code)
    }

    static func offlineMessage(_ code: Int) -> String? {
        switch code {
        case 31001, 31004, 43004: return "夸克登录已失效，请到「我的」页重新登录"
        case 32005, 32006, 32018, 32022: return "离线次数已用完，需要会员"
        case 25005: return "链接无效"
        case 14014, 14016, 22001: return "资源受限，无法离线下载"
        case 32003: return "网盘空间不足"
        case 32004, 25003, 25004: return "文件过大，需要会员"
        case 32007: return "该任务已存在"
        case 15000: return "夸克服务繁忙，请稍后再试"
        case 31007: return "夸克请求校验失败，接口可能已变更"
        case 14013: return "任务不存在"
        default: return nil
        }
    }
}

/// 最近提交的夸克离线任务 id（进程内，最多 50 个）
actor RecentQuarkOfflineTasks {
    private(set) var ids: [String] = []

    func add(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > 50 { ids.removeLast(ids.count - 50) }
    }

    func remove(_ removed: [String]) { ids.removeAll { removed.contains($0) } }
}
