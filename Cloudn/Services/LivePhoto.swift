// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// 实况照片：解析结果里实况图的视频部分与图片同名、加 `_live` 后缀（如 `作品_1.jpg` + `作品_1_live.mp4`）。
/// 存相册时把两者配对：图片写入 Apple MakerNote 的内容标识（键 17），视频写入同一个
/// `com.apple.quicktime.content.identifier` 和一条 still-image-time 元数据轨，再作为一张实况照片导入
enum LivePhoto {
    static let suffix = "_live"
    private static let videoExtensions = ["mov", "mp4", "m4v"]
    private static let imageExtensions = ["jpg", "jpeg", "png", "webp", "heic", "avif"]

    /// 下载目录里与这个文件配对的另一半：(图片, 视频)；不是实况照片返回 nil
    static func pair(for url: URL) -> (image: URL, video: URL)? {
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext), stem.hasSuffix(suffix) {
            let imageStem = String(stem.dropLast(suffix.count))
            guard let image = existing(dir, imageStem, imageExtensions) else { return nil }
            return (image, url)
        }
        if imageExtensions.contains(ext), let video = existing(dir, stem + suffix, videoExtensions) {
            return (url, video)
        }
        return nil
    }

    /// 这个文件是实况照片的一半（按名字判断，另一半可能还没下载完）
    static func partnerNames(for fileName: String) -> [String] {
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext), stem.hasSuffix(suffix) {
            let imageStem = String(stem.dropLast(suffix.count))
            return imageExtensions.map { "\(imageStem).\($0)" }
        }
        if imageExtensions.contains(ext) { return videoExtensions.map { "\(stem)\(suffix).\($0)" } }
        return []
    }

    /// a 和 b 是同一张实况照片的两半（按文件名判断）
    static func isPartner(_ a: String, of b: String) -> Bool {
        partnerNames(for: b).contains { $0.caseInsensitiveCompare(a) == .orderedSame }
    }

    /// 一对实况照片共用的名字（图片去掉扩展名）：两半算出来相同；不是实况照片的一半返回 nil
    static func pairKey(for fileName: String) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext), stem.hasSuffix(suffix) { return String(stem.dropLast(suffix.count)) }
        if imageExtensions.contains(ext) { return stem }
        return nil
    }

    private static func existing(_ dir: URL, _ stem: String, _ exts: [String]) -> URL? {
        let fm = FileManager.default
        for ext in exts {
            for e in [ext, ext.uppercased()] {
                let url = dir.appendingPathComponent("\(stem).\(e)")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    // MARK: 存入相册

    static func save(image: URL, video: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw LiveError("没有相册写入权限，请到系统设置中允许") }
        let identifier = UUID().uuidString
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let still = work.appendingPathComponent("IMG.JPG")
        let motion = work.appendingPathComponent("IMG.MOV")
        try writeImage(image, to: still, identifier: identifier)
        try await writeVideo(video, to: motion, identifier: identifier)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: still, options: nil)
            request.addResource(with: .pairedVideo, fileURL: motion, options: nil)
        }
    }

    /// 转成 JPEG 并在 MakerNote 里写入内容标识
    static func writeImage(_ source: URL, to output: URL, identifier: String) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LiveError("实况照片的图片无法读取")
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var maker = (properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]) ?? [:]
        maker["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary] = maker
        properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImageFromSource(dest, src, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw LiveError("实况照片的图片写入失败") }
    }

    /// 原样复制音视频（不重编码）成 MOV，写入内容标识与 still-image-time 元数据
    static func writeVideo(_ source: URL, to output: URL, identifier: String) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw LiveError("实况照片的视频无法读取") }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)

        let idItem = AVMutableMetadataItem()
        idItem.keySpace = .quickTimeMetadata
        idItem.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier.rawValue as NSString
        idItem.value = identifier as NSString
        idItem.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [idItem]

        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                         sourceFormatHint: try await videoTrack.load(.formatDescriptions).first)
        videoIn.transform = try await videoTrack.load(.preferredTransform)
        videoIn.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { throw LiveError("实况照片的视频格式不支持") }
        reader.add(videoOut)
        writer.add(videoIn)
        pairs.append((videoOut, videoIn))
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: try await audioTrack.load(.formatDescriptions).first)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out)
                writer.add(input)
                pairs.append((out, input))
            }
        }

        // still-image-time：告诉相册哪一帧对应静态图
        let stillKey = "com.apple.quicktime.still-image-time"
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/\(stillKey)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                                                                    metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &description)
        let metadataIn = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataIn)
        guard writer.canAdd(metadataIn) else { throw LiveError("实况照片的视频写入失败") }
        writer.add(metadataIn)

        guard reader.startReading(), writer.startWriting() else {
            throw LiveError("实况照片的视频处理失败：\(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "未知错误")")
        }
        writer.startSession(atSourceTime: .zero)

        let stillItem = AVMutableMetadataItem()
        stillItem.keySpace = .quickTimeMetadata
        stillItem.key = stillKey as NSString
        stillItem.value = 0 as NSNumber
        stillItem.dataType = "com.apple.metadata.datatype.int8"
        adaptor.append(AVTimedMetadataGroup(items: [stillItem], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 100))))
        metadataIn.markAsFinished()

        // 各轨同时喂数据（写入器要求交错，逐轨写完会卡住）。
        // append 失败（写入器出错）后 isReadyForMoreMediaData 不会再变回 true、回调也不再来：
        // 必须当场结束这一轨，否则 group 永远等不齐，整个保存卡死
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (index, (out, input)) in pairs.enumerated() {
                group.enter()
                let queue = DispatchQueue(label: "com.mengangs.Cloudn.live.\(index)")
                let state = FeedState()
                input.requestMediaDataWhenReady(on: queue) {
                    guard !state.done else { return }
                    while input.isReadyForMoreMediaData {
                        if let buffer = out.copyNextSampleBuffer(), writer.status == .writing, input.append(buffer) { continue }
                        state.done = true
                        if writer.status == .writing { input.markAsFinished() }
                        group.leave()
                        return
                    }
                }
            }
            group.notify(queue: .global()) { cont.resume() }
        }
        // 写入器已失败时调用 finishWriting 会抛 Objective-C 异常（直接崩溃）：只在仍在写入时收尾
        if writer.status == .writing, reader.status != .failed {
            await writer.finishWriting()
        } else if writer.status == .writing {
            writer.cancelWriting()
        }
        reader.cancelReading()
        if writer.status != .completed {
            throw LiveError("实况照片的视频写入失败：\(writer.error?.localizedDescription ?? "未知错误")")
        }
    }

    /// 每一轨喂数据的状态（只在该轨自己的串行队列上读写）
    private final class FeedState: @unchecked Sendable {
        var done = false
    }

    struct LiveError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

extension MediaTools {
    /// 存相册：实况照片的任一半都按实况照片存（图片 + 视频配对），否则按原样存。返回给用户看的提示
    @discardableResult
    static func saveToPhotosSmart(_ url: URL) async throws -> String {
        if let pair = LivePhoto.pair(for: url) {
            try await LivePhoto.save(image: pair.image, video: pair.video)
            return "已保存为实况照片"
        }
        try await saveToPhotos(url)
        return "已保存到相册"
    }
}
