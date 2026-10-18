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

    public init(platform: String, token: String) {
        self.platform = platform
        self.token = token
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

    public init(url: String, headers: [String: String] = [:], fileName: String, folder: String = "", kind: DownloadKind = .file,
                expectedSize: Int64 = -1, source: String = "", cleanup: CleanupToken? = nil, origin: ShareOrigin? = nil) {
        self.origin = origin
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
    /// 瞬时速度（不落盘）
    public var speed: Double = 0

    enum CodingKeys: String, CodingKey {
        case id, request, status, totalBytes, receivedBytes, errorMessage, createdAt, finishedAt, outputPath, chunks, phase, segmentsDone, segmentsTotal
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

    public init(maxConcurrentTasks: Int = 3, connectionsPerTask: Int = 8, retryCount: Int = 3) {
        self.maxConcurrentTasks = maxConcurrentTasks
        self.connectionsPerTask = connectionsPerTask
        self.retryCount = retryCount
    }
}
