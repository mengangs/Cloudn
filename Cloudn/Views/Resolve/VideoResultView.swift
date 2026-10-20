// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

/// 视频 / 图集解析结果：封面 + 作者 + 正文，视频逐条下载，图集两列网格可多选
struct VideoResultView: View {
    @Environment(AppModel.self) private var app
    let result: VideoParseResult
    @State private var preview: MediaPreviewItem?
    @State private var selected = Set<UUID>()
    @State private var selecting = false
    @State private var textExpanded = false

    private var videos: [VideoMedia] { result.medias.filter { $0.kind != .image } }
    private var images: [VideoMedia] { result.medias.filter { $0.kind == .image } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !result.notice.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        IconView(.warning, size: 16)
                        Text(result.notice).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color.clayInk)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.claySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !videos.isEmpty { videoSection }
                if !images.isEmpty { imageSection }
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
                    if !result.url.isEmpty {
                        Button { UIPasteboard.general.string = result.url; app.show("已复制作品链接") } label: {
                            Label { Text("复制作品链接") } icon: { Image(icon: .link) }
                        }
                    }
                    if !result.text.isEmpty {
                        Button { UIPasteboard.general.string = result.text; app.show("已复制文案") } label: {
                            Label { Text("复制文案") } icon: { Image(icon: .text) }
                        }
                    }
                    if let url = URL(string: result.url), !result.url.isEmpty {
                        Link(destination: url) { Label { Text("在浏览器中打开") } icon: { Image(icon: .share) } }
                    }
                } label: { Image(icon: .more).foregroundStyle(Color.ink) }
                .accessibilityLabel("更多")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar.padding(.horizontal, 16).padding(.bottom, 8) }
        .sensoryFeedback(.selection, trigger: selected)
        .animation(.snappy(duration: 0.25), value: selecting)
        .sheet(item: $preview) { MediaPreviewView(item: $0) }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                PlatformGlyph(mark: .video(result.platform), size: 15)
                Text(result.platform.displayName)
                if result.timestamp > 0 {
                    Text("·")
                    Text(Date(timeIntervalSince1970: TimeInterval(result.timestamp)).formatted(date: .abbreviated, time: .omitted))
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.ink2)
            .padding(.horizontal, 4)

            if !result.cover.isEmpty && !videos.isEmpty { cover }

            if !result.title.isEmpty {
                Text(result.title)
                    .font(.serif(22, relativeTo: .title2))
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 4)
            }
            if !result.author.isEmpty {
                HStack(spacing: 8) {
                    if !result.avatar.isEmpty {
                        RemoteImage(url: result.avatar)
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                            .overlay { Circle().strokeBorder(Color.hairline, lineWidth: 1) }
                    }
                    Text(result.author).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
                }
                .padding(.horizontal, 4)
            }
            if !result.text.isEmpty && result.text != result.title {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.text)
                        .font(.callout)
                        .foregroundStyle(Color.ink2)
                        .lineLimit(textExpanded ? nil : 4)
                        .textSelection(.enabled)
                    if result.text.count > 90 {
                        Button(textExpanded ? "收起" : "展开") { withAnimation(.snappy) { textExpanded.toggle() } }
                            .font(.footnote.weight(.medium))
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var cover: some View {
        Button { play(videos[0]) } label: {
            Color.fillMuted
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay { RemoteImage(url: result.cover, headers: videos[0].headers) }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1) }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) {
                        Image(icon: .play).resizable().scaledToFit().frame(width: 13, height: 13)
                        Text("播放").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("播放视频")
    }

    // MARK: 视频

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: videos.count > 1 ? "视频 \(videos.count) 个" : "视频")
            VStack(spacing: 0) {
                ForEach(Array(videos.enumerated()), id: \.element.id) { index, media in
                    HStack(spacing: 12) {
                        FileIcon(name: media.fileName)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(media.fileName).lineLimit(2).truncationMode(.middle).font(.subheadline).foregroundStyle(Color.ink)
                            HStack(spacing: 6) {
                                if !media.quality.isEmpty { Text(media.quality) }
                                if media.size > 0 { Text(ByteFormat.string(media.size)) }
                                if media.isHLS { Text("m3u8") }
                                if !media.audioURL.isEmpty { Text("音视频分轨") }
                            }
                            .font(.monoSmall)
                            .foregroundStyle(Color.ink3)
                        }
                        Spacer(minLength: 0)
                        Button { play(media) } label: { IconView(.play, size: 15) }
                            .buttonStyle(CircleIconButtonStyle(size: 32))
                            .accessibilityLabel("在线播放")
                        DownloadStateControl(item: state(of: media)) { download([media]) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if index < videos.count - 1 { RowDivider(leading: 64) }
                }
            }
            .card()
            if videos.contains(where: { !$0.audioURL.isEmpty }) {
                Text("分轨视频在线播放没有声音，下载完成后会自动合并为带声音的 MP4")
                    .font(.caption)
                    .foregroundStyle(Color.ink3)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: 图集

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "图片 \(images.count) 张")
                Spacer()
                Button(selecting ? "完成" : "多选") {
                    selecting.toggle()
                    selected = []
                }
                .font(.footnote.weight(.medium))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(images) { media in
                    imageTile(media)
                }
            }
        }
    }

    private func imageTile(_ media: VideoMedia) -> some View {
        let on = selected.contains(media.id)
        let state = state(of: media)
        return Button {
            if selecting {
                if on { selected.remove(media.id) } else { selected.insert(media.id) }
            } else {
                preview = MediaPreviewItem(url: media.url, headers: media.headers, title: media.fileName, kind: .image)
            }
        } label: {
            Color.fillMuted
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { RemoteImage(url: media.url, headers: media.headers) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.hairline), lineWidth: on ? 2.5 : 1)
                }
                .scaleEffect(on ? 0.96 : 1)
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        SelectMark(on: on)
                            .background(on ? Color.clear : Color.black.opacity(0.18), in: Circle())
                            .padding(8)
                    } else if state?.status == .completed {
                        IconView(.check, size: 12)
                            .foregroundStyle(Color.surface)
                            .frame(width: 22, height: 22)
                            .background(Color.success, in: Circle())
                            .padding(8)
                            .accessibilityLabel("已下载")
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { download([media]) } label: { Label { Text("下载这张") } icon: { Image(icon: .download) } }
            Button { UIPasteboard.general.string = media.url; app.show("已复制图片地址") } label: {
                Label { Text("复制图片地址") } icon: { Image(icon: .link) }
            }
        }
    }

    // MARK: 底部

    @ViewBuilder
    private var bottomBar: some View {
        let targets = selecting ? images.filter { selected.contains($0.id) } : result.medias
        let title = selecting ? (targets.isEmpty ? "选择要下载的图片" : "下载所选 · \(targets.count) 张")
            : (result.medias.count > 1 ? "全部下载 · \(result.medias.count) 项" : "下载")
        Button {
            download(targets)
            selecting = false
            selected = []
        } label: {
            HStack(spacing: 6) {
                Image(icon: .download)
                Text(title).contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(kind: .primary, height: 48))
        .disabled(targets.isEmpty)
        .opacity(targets.isEmpty ? 0.5 : 1)
        .floatingShadow()
    }

    // MARK: 动作

    private func state(of media: VideoMedia) -> DownloadItem? {
        app.downloads.items.last { $0.request.url == media.url }
    }

    private func play(_ media: VideoMedia) {
        preview = MediaPreviewItem(url: media.url, headers: media.headers, title: media.fileName,
                                   kind: media.kind == .audio ? .audio : .video)
    }

    private func download(_ medias: [VideoMedia]) {
        // 已下载或正在下载的跳过
        let pending = medias.filter { m in state(of: m).map { $0.status == .failed } ?? true }
        guard !pending.isEmpty else {
            app.show("已在下载列表中")
            return
        }
        // 多张图片归到以作品标题命名的文件夹
        let folder = pending.count > 1 ? FileNames.base(result.title, fallback: result.platform.displayName) : ""
        let group = pending.count > 1 ? DownloadGroup(title: result.title.isEmpty ? result.platform.displayName : result.title) : nil
        for m in pending { app.downloads.enqueue(media: m, result: result, folder: folder, group: group) }
        let skipped = medias.count - pending.count
        app.show(pending.count > 1 ? "已添加 \(pending.count) 个" + (skipped > 0 ? " · 跳过 \(skipped) 个已下载" : "") : "已添加到下载")
    }
}
