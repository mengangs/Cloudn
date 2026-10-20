// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let torrent = UTType(importedAs: "org.bittorrent.torrent")
}

/// 要打开的磁力链接（来自输入框或导入的 .torrent 文件）
struct TorrentTarget: Hashable, Identifiable {
    let magnet: MagnetLink
    var id: String { magnet.hexHash }
}

/// 磁力 / 种子：先向节点要种子信息，列出文件勾选后下载
struct TorrentView: View {
    @Environment(AppModel.self) private var app
    let target: TorrentTarget
    @State private var info: TorrentInfo?
    @State private var errorMessage: String?
    @State private var peers = (connected: 0, known: 0)
    @State private var note = ""
    @State private var selected = Set<Int>()
    @State private var attempt = 0

    private var files: [TorrentFile] { info?.visibleFiles ?? [] }
    private var selectedSize: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.length } }
    private var title: String {
        if let info { return info.name }
        return target.magnet.displayName.isEmpty ? "磁力链接" : target.magnet.displayName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let info {
                    fileSection(info)
                } else if let errorMessage {
                    EmptyStateCard(icon: .warning, title: "没有拿到种子信息", detail: errorMessage, actionTitle: "重试") {
                        self.errorMessage = nil
                        attempt += 1
                    }
                } else {
                    loadingCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 96)
        }
        .background(Color.paper)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { UIPasteboard.general.string = target.magnet.uri; app.show("已复制磁力链接") } label: {
                        Label { Text("复制磁力链接") } icon: { Image(icon: .link) }
                    }
                    Button { UIPasteboard.general.string = target.magnet.hexHash; app.show("已复制特征码") } label: {
                        Label { Text("复制特征码") } icon: { Image(icon: .tag) }
                    }
                } label: { Image(icon: .more).foregroundStyle(Color.ink) }
                .accessibilityLabel("更多")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if info != nil { bottomBar.padding(.horizontal, 16).padding(.bottom, 8) }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .task(id: attempt) { await load() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PlatformGlyph(mark: .magnet, size: 15)
                Text("磁力链接")
                if let info {
                    Text("·")
                    Text(ByteFormat.string(info.totalLength))
                    Text("·")
                    Text("\(info.visibleFiles.count) 个文件")
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.ink2)
            Text(title)
                .font(.serif(22, relativeTo: .title2))
                .foregroundStyle(Color.ink)
                .textSelection(.enabled)
                .lineLimit(4)
            Text(target.magnet.hexHash)
                .font(.monoSmall)
                .foregroundStyle(Color.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 4)
    }

    private var loadingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Spinner(size: 18)
                Text("正在从节点获取种子信息").font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
            }
            Text(peers.known == 0 ? "正在通过 DHT 与 Tracker 寻找节点…" : "已连接 \(peers.connected) 个节点 · 已发现 \(peers.known) 个")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.ink2)
                .contentTransition(.numericText())
            if !note.isEmpty {
                Text(note).font(.caption.monospacedDigit()).foregroundStyle(Color.ink3)
            }
            Text("热门资源通常几秒内就绪；冷门资源可能要等几分钟，可以先离开此页，回来时继续。")
                .font(.caption)
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .animation(.snappy, value: peers.known)
    }

    // MARK: 文件

    private func fileSection(_ info: TorrentInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "文件 \(files.count) 个")
                Spacer()
                if files.count > 1 {
                    Button(selected.count == files.count ? "全不选" : "全选") {
                        selected = selected.count == files.count ? [] : Set(files.map(\.id))
                    }
                    .font(.footnote.weight(.medium))
                }
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    fileRow(file, single: info.isSingleFile)
                    if index < files.count - 1 { RowDivider(leading: files.count > 1 ? 92 : 64) }
                }
            }
            .card()
            Text("BT 只下载不上传，只在应用打开时下载；切到后台约半分钟后暂停，回到前台自动继续。")
                .font(.caption)
                .foregroundStyle(Color.ink3)
                .padding(.horizontal, 4)
        }
    }

    private func fileRow(_ file: TorrentFile, single: Bool) -> some View {
        let on = selected.contains(file.id)
        let folder = file.path.dropLast().joined(separator: "/")
        return Button {
            guard files.count > 1 else { return }
            if on { selected.remove(file.id) } else { selected.insert(file.id) }
        } label: {
            HStack(spacing: 12) {
                if files.count > 1 { SelectMark(on: on) }
                FileIcon(name: file.name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name).lineLimit(2).truncationMode(.middle).font(.subheadline).foregroundStyle(Color.ink)
                    HStack(spacing: 6) {
                        Text(ByteFormat.string(file.length))
                        if !folder.isEmpty { Text(folder).lineLimit(1).truncationMode(.head) }
                    }
                    .font(.monoSmall)
                    .foregroundStyle(Color.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var bottomBar: some View {
        let count = selected.count
        let all = count == files.count
        let label = count == 0 ? "选择要下载的文件" : (all ? "下载全部" : "下载所选 · \(count) 个") + " · " + ByteFormat.string(selectedSize)
        return Button(action: download) {
            HStack(spacing: 6) {
                Image(icon: .download)
                Text(label).contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(kind: .primary, height: 48))
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
        .floatingShadow()
    }

    // MARK: 动作

    private func load() async {
        let cache = app.downloads.engine.torrentCacheDirectory
        let trackers = app.settings.useExtraTrackers ? TorrentDefaults.publicTrackers : []
        do {
            let result = try await TorrentMetadata.fetch(target.magnet, cacheDirectory: cache, extraTrackers: trackers) { connected, known, status in
                Task { @MainActor in
                    peers = (connected, known)
                    note = status
                }
            }
            try Task.checkCancellation()
            info = result
            selected = Set(result.visibleFiles.map(\.id))
            app.bookmarks.record(title: result.name, text: target.magnet.uri, source: "磁力链接")
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    private func download() {
        guard let info, !selected.isEmpty else { return }
        let ids = files.map(\.id)
        let all = Set(ids).isSubset(of: selected)
        // 链接里带上种子名，任务在元数据缓存丢失时也有个像样的名字
        let magnet = MagnetLink(infoHash: target.magnet.infoHash, displayName: info.name, trackers: target.magnet.trackers)
        let pending = app.downloads.items.contains { item in
            if case .torrent = item.request.kind, item.request.url.contains(magnet.hexHash), item.status != .failed, item.status != .completed { return true }
            return false
        }
        guard !pending else {
            app.show("这个种子已在下载列表中")
            return
        }
        app.downloads.enqueue(DownloadRequest(url: magnet.uri, fileName: info.name,
                                              kind: .torrent(files: all ? nil : selected.sorted()),
                                              expectedSize: selectedSize, source: "磁力链接"))
        app.show("已添加到下载")
    }
}
