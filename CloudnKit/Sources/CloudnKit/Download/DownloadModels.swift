// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public enum DownloadKind: Codable, Sendable, Hashable {
    /// 普通直链（支持 Range 时多连接分片）
    case file
    /// m3u8：分片下载后按序拼接
    case hls
    /// 音视频分轨（B 站 DASH）：两路分别下载，完成后由后处理合轨
    case dash(audioURL: String)
}

/// 下载完成后要交还给网盘解析器清理的令牌
public struct CleanupToken: Codable, Sendable, Hashable {
    public let platform: String
    public let token: String
    /// 产生该令牌的账号序号（多账号下载时清理要用同一个账号）；旧数据没有该字段
    public let slot: Int?

    public init(platform: String, token: String, slot: Int? = nil) {
        self.platform = platform
        self.token = token
        self.slot = slot
    }
}

/// 网盘文件的来源信息：直链过期后据此重新解析取链
public struct ShareOrigin: Codable, Sendable, Hashable {
    public let platform: SharePlatform
    public let shareURL: String
    public let pwd: String
    public let fileId: String
    public let fileToken: String
    public let parentId: String
    public let fileName: String
    public let size: Int64

    public init(platform: SharePlatform, shareURL: String, pwd: String, file: ShareFile) {
        self.platform = platform
        self.shareURL = shareURL
        self.pwd = pwd
        fileId = file.fid
        fileToken = file.token
        parentId = file.parentId
        fileName = file.name
        size = file.size
    }

    public var file: ShareFile {
        ShareFile(fid: fileId, name: fileName, size: size, isDirectory: false, parentId: parentId, token: fileToken)
    }
}

/// 自己网盘里的文件（我的网盘下载）：直链过期后按它重新取链
public struct DriveFileRef: Codable, Sendable, Hashable {
    public let fid: String
    public let name: String
    public let size: Int64
    public let parentId: String
    public let token: String

    public init(_ file: ShareFile) {
        fid = file.fid
        name = file.name
        size = file.size
        parentId = file.parentId
        token = file.token
    }

    public var file: ShareFile {
        ShareFile(fid: fid, name: name, size: size, isDirectory: false, parentId: parentId, token: token)
    }
}

/// 不是从分享链接来的下载（我的网盘、短视频 / 图集）：直链过期后据此重新取链
public enum RefreshSource: Codable, Sendable, Hashable {
    /// 自己网盘里的文件
    case drive(platform: SharePlatform, file: DriveFileRef)
    /// 作品页地址 + 媒体文件名（找不到同名的再按序号）
    case video(pageURL: String, fileName: String, index: Int)
}

/// 一次批量下载（整个文件夹、一组图片）：下载页把同组任务收成一个可折叠分组
public struct DownloadGroup: Codable, Sendable, Hashable {
    public let id: UUID
    public let title: String

    public init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
    }
}

/// 同一文件的另一条直链（多账号各自取到的链接），多源分片下载时分摊分片
public struct DownloadSource: Codable, Sendable, Hashable {
    public var url: String
    public var headers: [String: String]

    public init(url: String, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public struct DownloadRequest: Codable, Sendable, Hashable {
    public var url: String
    public var headers: [String: String]
    public var fileName: String
    /// 下载目录下的相对子目录（文件夹下载时保留层级），可为空
    public var folder: String
    public var kind: DownloadKind
    public var expectedSize: Int64
    /// 来源展示名（如「夸克网盘」「抖音」）
    public var source: String
    public var cleanup: CleanupToken?
    public var origin: ShareOrigin?
    /// 所属批次（可选；旧任务表里没有这个字段）
    public var group: DownloadGroup?
    /// 同一文件的其他直链（多源分片；旧任务表里没有这个字段）
    public var mirrors: [DownloadSource]?
    /// 非分享来源的重新取链信息（旧任务表里没有这个字段）
    public var refresh: RefreshSource?

    /// 直链过期后能否重新取链
    public var canRefresh: Bool { origin != nil || refresh != nil }

    public init(url: String, headers: [String: String] = [:], fileName: String, folder: String = "", kind: DownloadKind = .file,
                expectedSize: Int64 = -1, source: String = "", cleanup: CleanupToken? = nil, origin: ShareOrigin? = nil,
                group: DownloadGroup? = nil, mirrors: [DownloadSource]? = nil, refresh: RefreshSource? = nil) {
        self.refresh = refresh
        self.mirrors = mirrors
        self.origin = origin
        self.group = group
        self.url = url
        self.headers = headers
        self.fileName = fileName
        self.folder = folder
        self.kind = kind
        self.expectedSize = expectedSize
        self.source = source
        self.cleanup = cleanup
    }
}

public enum DownloadStatus: String, Codable, Sendable {
    case queued, running, paused, merging, completed, failed

    public var isActive: Bool { self == .queued || self == .running || self == .merging }
}

/// 分片：[start, end]（end = -1 表示长度未知、读到流结束）
public struct DownloadChunk: Codable, Sendable, Hashable {
    public var start: Int64
    public var end: Int64
    public var received: Int64

    public var isDone: Bool { end >= 0 && start + received > end }
}

public struct DownloadItem: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public var request: DownloadRequest
    public var status: DownloadStatus
    public var totalBytes: Int64
    public var receivedBytes: Int64
    public var errorMessage: String?
    public let createdAt: Date
    public var finishedAt: Date?
    /// 完成后的文件路径（相对下载目录）
    public var outputPath: String?
    /// 断点续传用的分片计划（当前阶段）
    public var chunks: [DownloadChunk]
    /// 分轨下载阶段：0 视频轨 / 1 音轨 / 2 合轨
    public var phase: Int
    public var segmentsDone: Int
    public var segmentsTotal: Int
    /// 剩余分片已交给系统后台下载会话（状态仍为 running）
    public var backgrounded: Bool = false
    /// 完成后已移动到用户选择的文件夹（展示用的位置描述）；此时 outputPath 为空
    public var exportedTo: String?
    /// 瞬时速度（不落盘）
    public var speed: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, request, status, totalBytes, receivedBytes, errorMessage, createdAt, finishedAt, outputPath, chunks, phase, segmentsDone, segmentsTotal
        case backgrounded, exportedTo
    }

    /// 兼容旧版任务表：新增字段缺失时取默认值
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        request = try c.decode(DownloadRequest.self, forKey: .request)
        status = try c.decode(DownloadStatus.self, forKey: .status)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        receivedBytes = try c.decode(Int64.self, forKey: .receivedBytes)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath)
        chunks = try c.decodeIfPresent([DownloadChunk].self, forKey: .chunks) ?? []
        phase = try c.decodeIfPresent(Int.self, forKey: .phase) ?? 0
        segmentsDone = try c.decodeIfPresent(Int.self, forKey: .segmentsDone) ?? 0
        segmentsTotal = try c.decodeIfPresent(Int.self, forKey: .segmentsTotal) ?? 0
        backgrounded = try c.decodeIfPresent(Bool.self, forKey: .backgrounded) ?? false
        exportedTo = try c.decodeIfPresent(String.self, forKey: .exportedTo)
    }

    init(request: DownloadRequest) {
        id = UUID()
        self.request = request
        status = .queued
        totalBytes = request.expectedSize
        receivedBytes = 0
        createdAt = Date()
        chunks = []
        phase = 0
        segmentsDone = 0
        segmentsTotal = 0
    }

    public var displayName: String { request.fileName }

    /// 0...1；未知总大小返回 nil
    public var fraction: Double? {
        if status == .completed { return 1 }
        if segmentsTotal > 0 { return Double(segmentsDone) / Double(segmentsTotal) }
        guard totalBytes > 0 else { return nil }
        let base = min(1, Double(receivedBytes) / Double(totalBytes))
        if case .dash = request.kind { return phase == 0 ? base * 0.8 : (phase == 1 ? 0.8 + base * 0.15 : 0.97) }
        return base
    }
}

public struct DownloadSettings: Sendable {
    public var maxConcurrentTasks: Int
    public var connectionsPerTask: Int
    public var retryCount: Int
    /// 全局限速（字节 / 秒），0 表示不限
    public var speedLimit: Int64
    /// 按来源（DownloadRequest.source，即平台显示名）覆盖单任务连接数
    public var connectionsBySource: [String: Int]

    public init(maxConcurrentTasks: Int = 3, connectionsPerTask: Int = 8, retryCount: Int = 3,
                speedLimit: Int64 = 0, connectionsBySource: [String: Int] = [:]) {
        self.maxConcurrentTasks = maxConcurrentTasks
        self.connectionsPerTask = connectionsPerTask
        self.retryCount = retryCount
        self.speedLimit = speedLimit
        self.connectionsBySource = connectionsBySource
    }

    public func connections(for source: String) -> Int {
        max(1, connectionsBySource[source] ?? connectionsPerTask)
    }
}

/// 交给系统后台下载会话的一个分片：从 offset 下载到 end（end = -1 表示长度未知、整文件）
public struct BackgroundChunkJob: Codable, Sendable, Hashable {
    public let itemId: UUID
    public let chunkIndex: Int
    public let url: String
    public let headers: [String: String]
    public let offset: Int64
    public let end: Int64

    public init(itemId: UUID, chunkIndex: Int, url: String, headers: [String: String], offset: Int64, end: Int64) {
        self.itemId = itemId
        self.chunkIndex = chunkIndex
        self.url = url
        self.headers = headers
        self.offset = offset
        self.end = end
    }

    /// Range 请求头的值；整文件下载返回 nil
    public var rangeHeader: String? {
        if end >= 0 { return "bytes=\(offset)-\(end)" }
        return offset > 0 ? "bytes=\(offset)-" : nil
    }

    /// 写进 URLSessionTask.taskDescription，进程被系统回收后重新启动也能对上号
    public var taskDescription: String { "\(itemId.uuidString)|\(chunkIndex)|\(offset)|\(end)" }

    public static func parse(taskDescription: String?) -> (itemId: UUID, chunkIndex: Int, offset: Int64, end: Int64)? {
        let parts = (taskDescription ?? "").components(separatedBy: "|")
        guard parts.count == 4, let id = UUID(uuidString: parts[0]), let index = Int(parts[1]),
              let offset = Int64(parts[2]), let end = Int64(parts[3]) else { return nil }
        return (id, index, offset, end)
    }
}
