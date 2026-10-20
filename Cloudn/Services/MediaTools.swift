// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import CloudnKit
import Foundation
import Photos

enum MediaTools {
    /// B 站 DASH 合轨：两路 fMP4 直接复用（passthrough，不重编码）合成一个 mp4
    static let merger: TrackMerger = { video, audio, output in
        // AVFoundation 按扩展名判断容器，.m4s 需要换个名字才能打开
        let fm = FileManager.default
        let v = video.deletingPathExtension().appendingPathExtension("mp4")
        let a = audio.deletingPathExtension().appendingPathExtension("m4a")
        for (src, dst) in [(video, v), (audio, a)] where src != dst {
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        }
        defer {
            // 合轨失败时保留原始分轨文件名，便于重试
            if !fm.fileExists(atPath: output.path) {
                try? fm.moveItem(at: v, to: video)
                try? fm.moveItem(at: a, to: audio)
            }
        }

        let videoAsset = AVURLAsset(url: v)
        let audioAsset = AVURLAsset(url: a)
        let composition = AVMutableComposition()
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw MergeError("视频轨读取失败")
        }
        // 按轨道自己的时间范围取：网页中途开始录制的流，时间戳不从 0 开始（如从 2:00 起），
        // 从 0 取会在开头留一段空白、时长也算错
        let videoRange = try await videoTrack.load(.timeRange)
        let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compVideo?.insertTimeRange(videoRange, of: videoTrack, at: .zero)
        compVideo?.preferredTransform = try await videoTrack.load(.preferredTransform)
        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
            // 两轨按各自的时间戳对齐，只取与画面重叠的部分
            let audioRange = try await audioTrack.load(.timeRange)
            let start = CMTimeMaximum(audioRange.start, videoRange.start)
            let end = CMTimeMinimum(audioRange.end, videoRange.end)
            if end > start {
                let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compAudio?.insertTimeRange(CMTimeRange(start: start, end: end), of: audioTrack,
                                               at: CMTimeSubtract(start, videoRange.start))
            }
        }
        try await MediaTools.exportPassthrough(composition, to: output, failure: "音视频合并失败")
    }

    /// 单个 MP4 的时间戳不从 0 开始时（中途开始录制的网页视频），把所有轨道整体平移到 0 起，
    /// 去掉开头的空白、修正时长。不需要平移时返回 false，不生成文件
    static func rebase(_ input: URL, to output: URL) async throws -> Bool {
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return false }
        var ranges: [CMTimeRange] = []
        for track in tracks { ranges.append(try await track.load(.timeRange)) }
        guard let origin = ranges.map(\.start).min(), origin.seconds > 0.5 else { return false }
        let composition = AVMutableComposition()
        for (track, range) in zip(tracks, ranges) {
            let comp = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            try comp?.insertTimeRange(range, of: track, at: CMTimeSubtract(range.start, origin))
            if track.mediaType == .video { comp?.preferredTransform = try await track.load(.preferredTransform) }
        }
        try await exportPassthrough(composition, to: output, failure: "视频整理失败")
        return true
    }

    private static func exportPassthrough(_ composition: AVComposition, to output: URL, failure: String) async throws {
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MergeError("无法创建合并任务")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        if export.status != .completed {
            throw MergeError("\(failure)：\(export.error?.localizedDescription ?? "未知错误")")
        }
    }

    struct MergeError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    static func canSaveToPhotos(_ url: URL) -> Bool {
        switch FileNames.kind(of: url.lastPathComponent) {
        case .image: return true
        case .video: return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
        default: return false
        }
    }

    /// 存入相册（只申请「仅添加」权限）
    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw MergeError("没有相册写入权限，请到系统设置中允许") }
        let isImage = FileNames.kind(of: url.lastPathComponent) == .image
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: isImage ? .photo : .video, fileURL: url, options: nil)
        }
    }
}
