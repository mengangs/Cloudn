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
    @State private var selected = Set<Int>()
    @State private var offlining = false

    /// 查找在应用层进行：离开本页不中断，回来接着看
    private var status: TorrentFetchStore.Status { app.torrents.status(target.magnet) }
    private var info: TorrentInfo? { status.info }
    private var errorMessage: String? { status.error }
    private var peers: (connected: Int, known: Int) { (status.connected, status.known) }
    private var note: String { status.note }

    private var files: [TorrentFile] { info?.visibleFiles ?? [] }
    private var selectedSize: Int64 { files.reduce(0) { selected.contains($1.id) ? $0 + $1.length : $0 } }
    private var title: String {
        if let info { return info.name }
        return target.magnet.displayName.isEmpty ? "磁力链接" : target.magnet.displayName
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !app.offlineDrives.isEmpty { offlineCard }
                if let info {
                    fileSection(info)
                } else if let errorMessage {
                    EmptyStateCard(icon: .warning, title: "没有拿到种子信息", detail: errorMessage, actionTitle: "重试") {
                        app.torrents.start(target.magnet)
                    }
                } else {
                    loadingCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 96)
            .readableWidth()
        }
        .background(Color.paper)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Clipboard.copy(target.magnet.uri); app.show("已复制磁力链接") } label: {
                        Label { Text("复制磁力链接") } icon: { Image(icon: .link) }
                    }
                    // 走 Clipboard：解析页不会把刚复制的特征码当成「剪贴板里有一个链接」再提示
                    Button { Clipboard.copy(target.magnet.hexHash); app.show("已复制特征码") } label: {
                        Label { Text("复制特征码") } icon: { Image(icon: .tag) }
                    }
                } label: { Image(icon: .more).foregroundStyle(Color.ink) }
                .accessibilityLabel("更多")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if info != nil { bottomBar.padding(.horizontal, 16).padding(.bottom, 8).readableWidth() }
        }
        .sheet(isPresented: $offlining) { AddOfflineTaskView(links: target.magnet.uri) }
        .sensoryFeedback(.selection, trigger: selected)
        .onAppear {
            // 一打开就记进「最近」：还没拿到种子信息就退出，也能从解析页找回来
            if info == nil { app.bookmarks.record(title: title, text: target.magnet.uri, source: "磁力链接") }
            app.torrents.start(target.magnet)
            if let info, selected.isEmpty { selected = Set(info.visibleFiles.map(\.id)) }
        }
        .onChange(of: info?.hexHash) { _, _ in
            guard let info else { return }
            selected = Set(info.visibleFiles.map(\.id))
            app.bookmarks.record(title: info.name, text: target.magnet.uri, source: "磁力链接")
        }
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

    /// 已登录支持离线下载的网盘时：交给网盘服务器下载，不用等节点、不占手机流量
    private var offlineCard: some View {
        Button { offlining = true } label: {
            HStack(spacing: 12) {
                IconView(.cloud, size: 20)
                    .foregroundStyle(Color.clayInk)
                    .frame(width: 36, height: 36)
                    .background(Color.claySoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("离线到网盘").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text("由" + app.offlineDrives.prefix(3).map(\.displayName).joined(separator: "、") + "下载，不占手机流量")
                        .font(.caption).foregroundStyle(Color.ink3).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconView(.chevronRight, size: 13).foregroundStyle(Color.ink3)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
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
            Text("热门资源通常几秒就绪，冷门的可能要几分钟。离开此页会继续查找，可从解析页「最近」回来。")
                .font(.caption)
                .foregroundStyle(Color.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: downloadWithoutWaiting) {
                Label("直接下载全部", glyph: .download).frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .animation(.snappy, value: peers.known)
    }

    // MARK: 文件

    private func fileSection(_ info: TorrentInfo) -> some View {
        // visibleFiles 每次访问都要重新过滤：这里取一次，不在每一行里重算
        let files = info.visibleFiles
        let multi = files.count > 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "文件 \(files.count) 个")
                Spacer()
                if multi {
                    Button(selected.count == files.count ? "全不选" : "全选") {
                        selected = selected.count == files.count ? [] : Set(files.map(\.id))
                    }
                    .font(.footnote.weight(.medium))
                }
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    fileRow(file, multi: multi)
                    if index < files.count - 1 { RowDivider(leading: multi ? 92 : 64) }
                }
            }
            .card()
            Text("只下载不上传；切到后台约半分钟后暂停，回到前台自动继续。")
                .font(.caption)
                .foregroundStyle(Color.ink3)
                .padding(.horizontal, 4)
        }
    }

    private func fileRow(_ file: TorrentFile, multi: Bool) -> some View {
        let on = selected.contains(file.id)
        let folder = file.path.dropLast().joined(separator: "/")
        return Button {
            guard multi else { return }
            if on { selected.remove(file.id) } else { selected.insert(file.id) }
        } label: {
            HStack(spacing: 12) {
                if multi { SelectMark(on: on) }
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

    /// 不等种子信息：直接建下载任务（下载任务自己去取，进度与节点数在下载页看）
    private func downloadWithoutWaiting() {
        guard !isQueued(target.magnet) else {
            app.show("这个种子已在下载列表中")
            return
        }
        app.torrents.cancel(target.magnet)
        let dn = target.magnet.displayName.trimmingCharacters(in: .whitespaces)
        let name = dn.isEmpty ? "磁力链接 " + String(target.magnet.hexHash.prefix(8)) : dn
        app.downloads.enqueue(DownloadRequest(url: target.magnet.uri, fileName: name, kind: .torrent(files: nil), source: "磁力链接"))
        app.show("已添加到下载，种子信息稍后获取")
    }

    private func isQueued(_ magnet: MagnetLink) -> Bool {
        app.downloads.items.contains { item in
            if case .torrent = item.request.kind, item.request.url.contains(magnet.hexHash), item.status != .failed, item.status != .completed { return true }
            return false
        }
    }

    private func download() {
        guard let info, !selected.isEmpty else { return }
        let ids = files.map(\.id)
        let all = Set(ids).isSubset(of: selected)
        // 链接里带上种子名，任务在元数据缓存丢失时也有个像样的名字
        let magnet = MagnetLink(infoHash: target.magnet.infoHash, displayName: info.name, trackers: target.magnet.trackers)
        guard !isQueued(magnet) else {
            app.show("这个种子已在下载列表中")
            return
        }
        app.downloads.enqueue(DownloadRequest(url: magnet.uri, fileName: info.name,
                                              kind: .torrent(files: all ? nil : selected.sorted()),
                                              expectedSize: selectedSize, source: "磁力链接"))
        app.show("已添加到下载")
    }
}
