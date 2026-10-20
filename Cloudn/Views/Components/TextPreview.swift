// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

struct TextPreviewItem: Identifiable {
    let id = UUID()
    let url: String
    let headers: [String: String]
    let title: String
}

/// 网盘里的文本文件在线查看：只取前 2MB，UTF-8 解不开时按 GB18030（中文 txt 常见）再试
struct TextPreviewView: View {
    let item: TextPreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var truncated = false
    @State private var error: String?
    @State private var copied = 0

    static let limit = 2 * 1024 * 1024

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if truncated {
                                Label("文件较大，只显示前 2MB", glyph: .warning).font(.footnote).foregroundStyle(Color.ink3)
                            }
                            Text(text)
                                .font(.mono)
                                .foregroundStyle(Color.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                    }
                } else if let error {
                    ScrollView {
                        EmptyStateCard(icon: .warning, title: "无法打开", detail: error, actionTitle: "重试") {
                            self.error = nil
                            Task { await load() }
                        }
                        .padding(16)
                    }
                } else {
                    VStack(spacing: 12) {
                        Spinner(size: 26)
                        Text("正在读取…").font(.footnote).foregroundStyle(Color.ink2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.paper)
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                if let text {
                    ToolbarItem(placement: .primaryAction) {
                        Button { UIPasteboard.general.string = text; copied += 1 } label: { Image(icon: .paste) }
                            .accessibilityLabel("复制全文")
                            .sensoryFeedback(.success, trigger: copied)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let r = try await HTTPClient.fetchPrefix(item.url, headers: item.headers.map { ($0.key, $0.value) }, limit: Self.limit)
            guard (200..<300).contains(r.status) else { throw CloudnError("读取失败（HTTP \(r.status)）") }
            truncated = r.partial
            text = Self.decode(Data(r.data))
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        // 截断处可能切断一个多字节字符：去掉末尾几个字节再试
        for cut in 1...3 where data.count > cut {
            if let s = String(data: data.dropLast(cut), encoding: .utf8) { return s }
        }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}
