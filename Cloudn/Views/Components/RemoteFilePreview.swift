// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 网盘里文档类文件（PDF、Office、电子书…）的预览：先下到临时目录，再用本地预览打开；关闭即删
struct RemoteFileItem: Identifiable {
    let id = UUID()
    let url: String
    let headers: [String: String]
    let name: String
    let size: Int64

    /// 超过这个大小就别预览了，建议下载
    static let limit: Int64 = 200 << 20
}

struct RemoteFilePreview: View {
    let item: RemoteFileItem
    @Environment(\.dismiss) private var dismiss
    @State private var local: URL?
    @State private var received: Int64 = 0
    @State private var failure: String?

    var body: some View {
        if let local {
            FilePreviewView(url: local)
                .onDisappear { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        } else {
            VStack(spacing: 14) {
                FileIcon(name: item.name, isDirectory: false)
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Color.clayInk).multilineTextAlignment(.center)
                    Button("重试") { self.failure = nil; Task { await fetch() } }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                } else {
                    if item.size > 0 {
                        ProgressLine(value: min(1, Double(received) / Double(item.size)))
                            .frame(maxWidth: 220)
                        Text("\(ByteFormat.string(received)) / \(ByteFormat.string(item.size))")
                            .font(.monoSmall)
                            .foregroundStyle(Color.ink3)
                            .contentTransition(.numericText())
                    } else {
                        Spinner(size: 22)
                    }
                    Text("正在载入预览…").font(.footnote).foregroundStyle(Color.ink2)
                }
                Button("取消") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                    .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paper)
            .task { await fetch() }
        }
    }

    private func fetch() async {
        guard let url = URL(string: item.url) else { failure = "链接无效"; return }
        var request = URLRequest(url: url)
        for (k, v) in item.headers { request.setValue(v, forHTTPHeaderField: k) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview/\(item.id.uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(FileNames.sanitize(item.name))
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = "载入失败（HTTP \(http.statusCode)），链接可能已过期"
                return
            }
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            var count: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    count += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    received = count
                }
            }
            try handle.write(contentsOf: buffer)
            received = count + Int64(buffer.count)
            local = target
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}

enum OnlinePreview {
    /// 网盘里点开能直接预览的文件（其余仍然下载）；MKV、AVI 等系统播放器放不了的视频也走下载
    static func supports(_ name: String) -> Bool {
        switch FileNames.kind(of: name) {
        case .video, .audio: return FilePreviewView.playable.contains(FileNames.fileExtension(name).lowercased())
        case .image, .text, .document: return true
        default: return false
        }
    }
}
