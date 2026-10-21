// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import CryptoKit
import SwiftUI
import UIKit

/// 下载页长按 →「调试信息」：单个任务的地址、请求头、分片、错误与相关日志，可整份复制给开发者。
/// Cookie / 令牌类请求头只显示开头几位，直链查询串照原样保留（复制前会去掉）
struct DownloadDebugView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let itemId: UUID
    @State private var sha256: String?
    @State private var hashing = false
    @State private var logLines: [String] = []
    /// 可计算校验值的文件（已完成且不是目录）；任务完成时查一次，不在界面刷新时查磁盘
    @State private var hashTarget: URL?

    private var item: DownloadItem? { app.downloads.items.first { $0.id == itemId } }

    var body: some View {
        NavigationStack {
            Group {
                if let item {
                    content(item)
                } else {
                    EmptyStateCard(icon: .warning, title: "任务已删除", detail: "这条下载记录已不存在。")
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.paper)
                }
            }
            .navigationTitle("调试信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if let item {
                    ToolbarItem(placement: .primaryAction) {
                        Button("复制") {
                            UIPasteboard.general.string = Self.snapshot(item, sha256: sha256, log: logLines)
                            app.show("已复制调试信息")
                        }
                    }
                }
            }
        }
        .task { logLines = await Self.relatedLog(item?.request.fileName ?? "") }
        .task(id: item?.status == .completed ? (item?.outputPath ?? item?.exportedTo ?? "") : nil) {
            guard let item, item.status == .completed, let url = app.downloads.fileURL(item) else { hashTarget = nil; return }
            hashTarget = DownloadsView.isDirectory(url) ? nil : url
        }
    }

    private func content(_ item: DownloadItem) -> some View {
        Form {
            Group {
                ForEach(Self.sections(item), id: \.title) { section in
                    Section(section.title) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            infoRow(row.0, row.1)
                        }
                    }
                }
                if !item.chunks.isEmpty {
                    Section {
                        ForEach(Array(item.chunks.prefix(64).enumerated()), id: \.offset) { i, chunk in
                            Text(Self.chunkLine(i, chunk))
                                .font(.monoSmall)
                                .foregroundStyle(chunk.isDone ? Color.ink3 : Color.ink)
                        }
                        if item.chunks.count > 64 {
                            Text("…另有 \(item.chunks.count - 64) 个分片，复制后可看到全部").font(.footnote).foregroundStyle(Color.ink3)
                        }
                    } header: {
                        Text("分片（\(item.chunks.filter(\.isDone).count)/\(item.chunks.count) 完成）")
                    }
                }
                if item.status == .completed, let url = hashTarget {
                    Section {
                        if let sha256 {
                            Text(sha256).font(.monoSmall).textSelection(.enabled)
                        } else {
                            Button {
                                Task { await computeHash(url) }
                            } label: {
                                HStack {
                                    Text(hashing ? "正在计算…" : "计算 SHA-256")
                                    Spacer()
                                    if hashing { Spinner(size: 18) }
                                }
                            }
                            .disabled(hashing)
                        }
                    } header: {
                        Text("文件校验")
                    } footer: {
                        Text("与发布方给出的校验值比对，可确认文件完整、未被篡改。大文件需要一点时间。")
                    }
                }
                Section {
                    if logLines.isEmpty {
                        Text("诊断日志里没有这个任务的记录").font(.footnote).foregroundStyle(Color.ink3)
                    } else {
                        Text(logLines.joined(separator: "\n"))
                            .font(.monoSmall)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("相关日志")
                }
            }
            .listRowBackground(Color.surface)
        }
        .paperList()
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).font(.caption).foregroundStyle(Color.ink3)
            Text(value).font(.monoSmall).foregroundStyle(Color.ink).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func computeHash(_ url: URL) async {
        hashing = true
        defer { hashing = false }
        sha256 = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try? handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value ?? "读取文件失败"
    }

    // MARK: - 内容

    struct InfoSection {
        let title: String
        let rows: [(String, String)]
    }

    static func sections(_ item: DownloadItem) -> [InfoSection] {
        let r = item.request
        let date = Date.FormatStyle(date: .numeric, time: .standard)
        var basic: [(String, String)] = [
            ("文件名", r.fileName),
            ("任务 ID", item.id.uuidString),
            ("状态", statusText(item)),
            ("来源 / 类型", "\(r.source) · \(kindText(r.kind))"),
            ("创建时间", item.createdAt.formatted(date))
        ]
        if !r.folder.isEmpty { basic.append(("子目录", r.folder)) }
        if let group = r.group { basic.append(("分组", group.title)) }
        if let finished = item.finishedAt {
            let seconds = max(1, finished.timeIntervalSince(item.createdAt))
            basic.append(("完成时间", finished.formatted(date)))
            basic.append(("用时 / 平均速度", "\(Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))) · \(ByteFormat.speed(Double(item.receivedBytes) / seconds))"))
        }

        var progress: [(String, String)] = [
            ("大小", item.totalBytes > 0 ? "\(ByteFormat.string(item.totalBytes))（\(item.totalBytes) 字节）" : "未知"),
            ("已下载", "\(ByteFormat.string(item.receivedBytes))（\(item.receivedBytes) 字节）")
        ]
        if item.status == .running { progress.append(("当前速度", ByteFormat.speed(item.speed))) }
        if item.segmentsTotal > 0 { progress.append(("分段", "\(item.segmentsDone)/\(item.segmentsTotal)（阶段 \(item.phase)）")) }
        if item.backgrounded { progress.append(("后台", "已交给系统后台下载")) }
        if case .torrent = r.kind { progress.append(("节点", "已连接 \(item.peers) · 已知 \(item.knownPeers)")) }
        if let note = item.note, !note.isEmpty { progress.append(("说明", note)) }
        if let error = item.errorMessage, !error.isEmpty { progress.append(("失败原因", error)) }

        var request: [(String, String)] = [("下载地址", r.url)]
        if case .dash(let audio) = r.kind { request.append(("音轨地址", audio)) }
        for (i, m) in (r.mirrors ?? []).enumerated() { request.append(("备用源 \(i + 1)", m.url)) }
        if !r.headers.isEmpty {
            let lines = r.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { "\($0.key): \(maskHeader($0.key, $0.value))" }
            request.append(("请求头", lines.joined(separator: "\n")))
        }
        request.append(("直链过期时", r.canRefresh ? "可重新取链" : "不能重新取链（需重新解析）"))
        if let cleanup = r.cleanup { request.append(("下载后清理", "\(cleanup.platform) 临时转存文件")) }

        var output: [(String, String)] = []
        if let path = item.outputPath { output.append(("保存位置", path)) }
        if let exported = item.exportedTo { output.append(("已移到", exported)) }

        return [InfoSection(title: "任务", rows: basic), InfoSection(title: "进度", rows: progress),
                InfoSection(title: "请求", rows: request), InfoSection(title: "文件", rows: output)].filter { !$0.rows.isEmpty }
    }

    static func chunkLine(_ i: Int, _ c: DownloadChunk) -> String {
        let end = c.end >= 0 ? "\(c.end)" : "?"
        let length = c.end >= 0 ? c.end - c.start + 1 : 0
        let mark = c.isDone ? "✓" : (c.received > 0 ? "…" : "·")
        return "#\(i) \(c.start)-\(end)  \(ByteFormat.string(c.received))\(length > 0 ? "/" + ByteFormat.string(length) : "")  \(mark)"
    }

    /// 凭据类请求头只露开头几位与长度，复制给别人也不会把登录态交出去
    static func maskHeader(_ key: String, _ value: String) -> String {
        let k = key.lowercased()
        let sensitive = ["cookie", "authorization", "token", "x-csrf", "sign"].contains { k.contains($0) }
        guard sensitive, value.count > 8 else { return value }
        return "\(value.prefix(6))…（共 \(value.count) 字符）"
    }

    static func statusText(_ item: DownloadItem) -> String {
        switch item.status {
        case .queued: return "排队中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .merging: return "合并中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    static func kindText(_ kind: DownloadKind) -> String {
        switch kind {
        case .file: return "普通文件"
        case .hls: return "m3u8（HLS）"
        case .dash: return "音视频分轨（DASH）"
        case .torrent(let files): return files.map { "BT（选了 \($0.count) 个文件）" } ?? "BT（全部文件）"
        }
    }

    /// 诊断日志里提到这个文件名的最近几十行
    static func relatedLog(_ fileName: String) async -> [String] {
        guard !fileName.isEmpty, let url = Log.fileURL else { return [] }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains(fileName) }
            return lines.suffix(40).map(String.init)
        }.value
    }

    /// 整份文本（复制用）：直链查询串里的签名去掉，免得贴出去就能被人直接下载
    static func snapshot(_ item: DownloadItem, sha256: String?, log: [String]) -> String {
        var out = ["Cloudn \(AppModel.currentVersion) 下载调试信息"]
        for section in sections(item) {
            out.append("\n[\(section.title)]")
            for (k, v) in section.rows { out.append("\(k)：\(stripQuery(v))") }
        }
        if !item.chunks.isEmpty {
            out.append("\n[分片]")
            out += item.chunks.enumerated().map { chunkLine($0.offset, $0.element) }
        }
        if let sha256 { out.append("\nSHA-256：\(sha256)") }
        if !log.isEmpty {
            out.append("\n[相关日志]")
            out += log
        }
        return out.joined(separator: "\n")
    }

    static func stripQuery(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(https?://[^\s?]+)\?\S*"#) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1?…")
    }
}
