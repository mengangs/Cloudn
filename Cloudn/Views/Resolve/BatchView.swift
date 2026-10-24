// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 批量解析进度：逐条显示等待 / 解析中 / 已加入下载 / 失败
struct BatchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let job: BatchJob
    /// 失败的那条改用网页嗅探
    @State private var sniffing: SniffLink?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(job.items) { item in
                        HStack(spacing: 12) {
                            stateIcon(item.state)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title.isEmpty ? item.url : item.title)
                                    .font(.subheadline).foregroundStyle(Color.ink).lineLimit(2)
                                if let detail = detail(item.state) {
                                    Text(detail).font(.caption).foregroundStyle(stateColor(item.state)).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            // 解析失败的：直接在网页里播放后抓取
                            if case .failed = item.state {
                                Button("网页嗅探") { sniffing = SniffLink(url: item.url) }
                                    .font(.footnote)
                                    .buttonStyle(TextLinkButtonStyle())
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                    .paperRow()
                } header: {
                    // 汇总 + 总进度：一眼看出进行到哪了
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary).font(.subheadline).foregroundStyle(Color.ink2)
                        ProgressLine(value: Double(job.doneCount + job.failedCount) / Double(max(1, job.items.count)))
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                } footer: {
                    Text("逐条按最高画质加入下载，离开此页也会继续。")
                }
            }
            .paperList()
            .safeAreaInset(edge: .bottom) {
                // 跑完了：直接去下载页看
                if job.finished && job.doneCount > 0 {
                    Button {
                        app.selectedTab = .downloads
                        dismiss()
                    } label: {
                        Label { Text("查看下载") } icon: { Image(icon: .download) }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .fullScreenCover(item: $sniffing) { SnifferView(url: $0.url) }
            .navigationTitle(job.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if job.running {
                        Button("停止") { job.cancel() }
                    } else if job.failedCount > 0 {
                        Button("重试失败的") { job.retryFailed(app: app) }
                    } else if !job.finished {
                        Button("继续") { job.start(app: app) }
                    }
                }
            }
        }
    }

    private var summary: String {
        let total = job.items.count
        var text = "\(job.doneCount) / \(total) 已加入下载"
        if job.failedCount > 0 { text += " · \(job.failedCount) 个失败" }
        if job.running { text += " · 解析中…" }
        return text
    }

    @ViewBuilder
    private func stateIcon(_ state: BatchJob.State) -> some View {
        switch state {
        case .waiting: IconView(.clock, size: 16).foregroundStyle(Color.ink3).frame(width: 22)
        case .parsing: Spinner(size: 16).frame(width: 22)
        case .added: IconView(.checkCircle, size: 16).foregroundStyle(Color.success).frame(width: 22)
        case .failed: IconView(.warning, size: 16).foregroundStyle(Color.clayInk).frame(width: 22)
        }
    }

    private func detail(_ state: BatchJob.State) -> String? {
        switch state {
        case .waiting: return nil
        case .parsing: return "解析中…"
        case .added(let n): return n > 1 ? "已加入下载 · \(n) 个文件" : "已加入下载"
        case .failed(let message): return message
        }
    }

    private func stateColor(_ state: BatchJob.State) -> Color {
        if case .failed = state { return Color.clayInk }
        return Color.ink3
    }
}

/// 要用网页嗅探打开的作品链接
private struct SniffLink: Identifiable {
    let url: String
    var id: String { url }
}
