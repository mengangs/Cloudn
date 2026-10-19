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
        let duration = try await videoAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compVideo?.insertTimeRange(range, of: videoTrack, at: .zero)
        compVideo?.preferredTransform = try await videoTrack.load(.preferredTransform)
        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
            let audioDuration = try await audioAsset.load(.duration)
            let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try compAudio?.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audioDuration)), of: audioTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MergeError("无法创建合并任务")
        }
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        if export.status != .completed {
            throw MergeError("音视频合并失败：\(export.error?.localizedDescription ?? "未知错误")")
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
