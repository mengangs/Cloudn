// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation

/// 网页 MSE 视频流录制：页面每次追加给 SourceBuffer 的数据，按追加顺序写进该轨道（每个 SourceBuffer 一条）自己的临时文件。
/// base64 解码与文件写入都在一个串行队列上，主线程只负责转交消息。
///
/// 页面切换清晰度时会追加一个新的初始化段：同一轨道从这里另起一段（run），保存时只取最长的那段；
/// 与上一个完全相同的初始化段（有的播放器每次切片前都重发一遍）直接跳过。
final class MSERecorder: @unchecked Sendable {
    struct Progress: Sendable {
        var bytes: Int64
        var tracks: Int
        var capped: Bool
    }

    /// 一段连续数据：一个初始化段 + 其后的媒体段
    struct Run: Sendable {
        let url: URL
        let mime: String
        let bytes: Int64
    }

    struct TrackResult: Sendable {
        let id: String
        /// 该轨道里最长的那段
        let best: Run
        /// 录制中途换过初始化段（多半是切换了清晰度）
        let switched: Bool
    }

    /// 录制总量上限
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let directoryPrefix = "mse-record-"

    let directory: URL
    /// 进度回调（在录制队列上调用，约 4 次 / 秒）
    var onProgress: (@Sendable (Progress) -> Void)?

    private let queue = DispatchQueue(label: "cloudn.mse-recorder", qos: .utility)
    private var tracks: [String: Track] = [:]
    private var order: [String] = []
    private var total: Int64 = 0
    private var capped = false
    private var closed = false
    private var lastReport = Date.distantPast

    private final class Track {
        let index: Int
        var mime: String
        var runs: [Run] = []
        var handle: FileHandle?
        var current: URL?
        var currentMime = ""
        var currentBytes: Int64 = 0
        var lastInit: Data?
        var hasInit = false

        init(index: Int, mime: String) {
            self.index = index
            self.mime = mime
        }
    }

    init() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        // 上次没清掉的录制临时文件（例如录制中应用被杀）
        if let old = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for url in old where url.lastPathComponent.hasPrefix(Self.directoryPrefix) { try? fm.removeItem(at: url) }
        }
        directory = tmp.appendingPathComponent(Self.directoryPrefix + UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 页面换了 SourceBuffer 的格式（changeType）
    func setMime(_ mime: String, track id: String) {
        queue.async { [self] in
            tracks[id]?.mime = mime
        }
    }

    /// part 为 0 表示这是页面一次追加的开头（后面可能还有同一次追加拆出来的若干片）
    func append(track id: String, mime: String, part: Int, base64: String) {
        queue.async { [self] in
            guard !closed, !capped, var data = Data(base64Encoded: base64), !data.isEmpty else { return }
            let track: Track
            if let existing = tracks[id] {
                track = existing
            } else {
                track = Track(index: order.count, mime: mime)
                tracks[id] = track
                order.append(id)
            }
            if !mime.isEmpty { track.mime = mime }
            if part == 0, MSESegments.startsWithInit(data) {
                let length = MSESegments.initLength(data)
                if let length, let last = track.lastInit, data.prefix(length) == last {
                    // 重复追加的同一个初始化段
                    data = Data(data.dropFirst(length))
                    if data.isEmpty { return }
                } else {
                    // 新的初始化段（开始录制 / 切换清晰度）：另起一段
                    if track.currentBytes > 0 { closeRun(track) }
                    if let length {
                        track.lastInit = Data(data.prefix(length))
                    } else {
                        track.lastInit = nil
                    }
                    track.hasInit = true
                }
            }
            // 没有初始化段的媒体数据单独无法播放，等到初始化段出现再记
            guard track.hasInit else { return }
            if total + Int64(data.count) > Self.maxBytes {
                capped = true
                report(force: true)
                return
            }
            do {
                if track.handle == nil { try openRun(track) }
                try track.handle?.write(contentsOf: data)
                track.currentBytes += Int64(data.count)
                total += Int64(data.count)
            } catch {
                Log.error("网页录制写入失败：\(error.localizedDescription)")
            }
            report(force: false)
        }
    }

    /// 停止录制：关闭所有文件，返回每条轨道最长的那段
    func finish() async -> [TrackResult] {
        await withCheckedContinuation { (cont: CheckedContinuation<[TrackResult], Never>) in
            queue.async { [self] in
                closed = true
                var results: [TrackResult] = []
                for id in order {
                    guard let track = tracks[id] else { continue }
                    closeRun(track)
                    guard let best = track.runs.max(by: { $0.bytes < $1.bytes }) else { continue }
                    results.append(TrackResult(id: id, best: best, switched: track.runs.count > 1))
                }
                cont.resume(returning: results)
            }
        }
    }

    /// 丢弃录制内容并删除临时文件
    func discard() {
        queue.async { [self] in
            closed = true
            for track in tracks.values {
                try? track.handle?.close()
                track.handle = nil
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: 录制队列内部

    private func openRun(_ track: Track) throws {
        let ext = Self.fileExtension(for: track.mime)
        let url = directory.appendingPathComponent("track\(track.index)-run\(track.runs.count).\(ext)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        track.handle = try FileHandle(forWritingTo: url)
        track.current = url
        track.currentMime = track.mime
        track.currentBytes = 0
    }

    private func closeRun(_ track: Track) {
        try? track.handle?.close()
        track.handle = nil
        if let url = track.current {
            if track.currentBytes > 0 {
                track.runs.append(Run(url: url, mime: track.currentMime, bytes: track.currentBytes))
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        track.current = nil
        track.currentBytes = 0
    }

    private func report(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = now
        let count = tracks.values.filter { $0.currentBytes > 0 || !$0.runs.isEmpty }.count
        onProgress?(Progress(bytes: total, tracks: count, capped: capped))
    }

    /// 按 MIME 取扩展名：video/mp4 → mp4，audio/mp4 → m4a，webm → webm
    static func fileExtension(for mime: String) -> String {
        let lower = mime.lowercased()
        if lower.contains("webm") { return "webm" }
        if lower.contains("mp2t") { return "ts" }
        if lower.hasPrefix("audio/") { return "m4a" }
        return "mp4"
    }

    static func isVideo(_ mime: String) -> Bool { mime.lowercased().hasPrefix("video/") }
    static func isAudio(_ mime: String) -> Bool { mime.lowercased().hasPrefix("audio/") }
    static func isMP4(_ mime: String) -> Bool { mime.lowercased().contains("mp4") }
}

/// 录制结果存入下载列表
@MainActor
enum MSERecordingSaver {
    struct Outcome {
        let saved: Int
        let message: String
    }

    static let source = "网页录制"

    /// 一条视频轨 + 一条音轨（都是 MP4）合成一个 mp4；只有一条轨道（或音视频已混合）就直接保存；
    /// WebM 或合并失败时分别保存
    static func save(_ results: [MSERecorder.TrackResult], base: String, page: String, workDirectory: URL,
                     downloads: DownloadStore) async throws -> Outcome {
        let usable = results.filter { $0.best.bytes >= 4096 }
        guard !usable.isEmpty else {
            throw CloudnError("没有录到可用的视频数据。请在开始录制后，在网页里播放视频")
        }
        let videos = usable.filter { MSERecorder.isVideo($0.best.mime) }.sorted { $0.best.bytes > $1.best.bytes }
        let audios = usable.filter { MSERecorder.isAudio($0.best.mime) }.sorted { $0.best.bytes > $1.best.bytes }
        var notes: [String] = []
        if usable.contains(where: { $0.switched }) {
            notes.append("录制过程中清晰度变化过，只保存了最长的一段")
        }

        if let video = videos.first, let audio = audios.first, MSERecorder.isMP4(video.best.mime), MSERecorder.isMP4(audio.best.mime) {
            let output = workDirectory.appendingPathComponent("merged.mp4")
            do {
                try await MediaTools.merger(video.best.url, audio.best.url, output)
                try await downloads.importLocalFile(output, name: base + ".mp4", source: source, page: page)
                return Outcome(saved: 1, message: joined("已保存录制的视频到下载", notes))
            } catch {
                Log.error("网页录制合并失败：\(error.localizedDescription)")
                notes.append("音视频合并失败，画面和声音分别保存了")
            }
        }

        var picks: [(MSERecorder.TrackResult, String)] = []
        if let video = videos.first { picks.append((video, audios.isEmpty ? "" : "（画面）")) }
        if let audio = audios.first { picks.append((audio, videos.isEmpty ? "" : "（声音）")) }
        if picks.isEmpty, let other = usable.max(by: { $0.best.bytes < $1.best.bytes }) { picks.append((other, "")) }
        if picks.count > 1, !notes.contains(where: { $0.contains("分别保存") }) {
            notes.append("画面和声音是两个文件（WebM 无法在手机上合并）")
        }

        var saved = 0
        var firstError: Error?
        for (track, suffix) in picks {
            let ext = track.best.url.pathExtension.isEmpty ? MSERecorder.fileExtension(for: track.best.mime) : track.best.url.pathExtension
            var file = track.best.url
            if MSERecorder.isMP4(track.best.mime) {
                // 中途开始录制：时间戳平移到 0 起，失败就按原样保存
                let rebased = workDirectory.appendingPathComponent("rebased-\(saved).\(ext)")
                if (try? await MediaTools.rebase(file, to: rebased)) == true { file = rebased }
            }
            do {
                try await downloads.importLocalFile(file, name: base + suffix + "." + ext, source: source, page: page)
                saved += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if saved == 0 { throw firstError ?? CloudnError("保存失败") }
        if picks.contains(where: { $0.0.best.mime.lowercased().contains("webm") }) {
            notes.append("WebM 格式在系统相册和自带播放器里可能放不了，可用 VLC 等第三方播放器打开")
        }
        return Outcome(saved: saved, message: joined(saved > 1 ? "已保存 \(saved) 个文件到下载" : "已保存录制的视频到下载", notes))
    }

    private static func joined(_ head: String, _ notes: [String]) -> String {
        notes.isEmpty ? head : head + "。" + notes.joined(separator: "；")
    }
}
