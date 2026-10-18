// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI
import UIKit

/// 视频 / 图集解析结果：封面 + 作者 + 正文，视频单条下载，图集两列网格可多选
struct VideoResultView: View {
    @Environment(AppModel.self) private var app
    let result: VideoParseResult
    @State private var preview: MediaPreviewItem?
    @State private var selected = Set<UUID>()
    @State private var selecting = false

    private var videos: [VideoMedia] { result.medias.filter { $0.kind != .image } }
    private var images: [VideoMedia] { result.medias.filter { $0.kind == .image } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !videos.isEmpty { videoSection }
                if !images.isEmpty { imageSection }
            }
            .padding()
            .padding(.bottom, 80)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(result.platform.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !result.url.isEmpty {
                        Button { UIPasteboard.general.string = result.url; app.show("已复制作品链接") } label: {
                            Label("复制作品链接", systemImage: "link")
                        }
                    }
                    if !result.text.isEmpty {
                        Button { UIPasteboard.general.string = result.text; app.show("已复制文案") } label: {
                            Label("复制文案", systemImage: "doc.on.doc")
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(item: $preview) { MediaPreviewView(item: $0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !result.cover.isEmpty && !videos.isEmpty {
                Button { play(videos[0]) } label: {
                    RemoteImage(url: result.cover, headers: videos[0].headers)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipped()
                        .overlay {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if !result.title.isEmpty {
                Text(result.title).font(.headline).textSelection(.enabled)
            }
            if !result.author.isEmpty {
                HStack(spacing: 8) {
                    if !result.avatar.isEmpty {
                        RemoteImage(url: result.avatar).frame(width: 26, height: 26).clipShape(Circle())
                    }
                    Text(result.author).font(.subheadline).foregroundStyle(.secondary)
                    if result.timestamp > 0 {
                        Text(Date(timeIntervalSince1970: TimeInterval(result.timestamp)).formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if !result.text.isEmpty && result.text != result.title {
                Text(result.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8)
            }
        }
    }

    private var videoSection: some View {
        VStack(spacing: 10) {
            ForEach(videos) { media in
                HStack(spacing: 12) {
                    FileIcon(name: media.fileName)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.fileName).lineLimit(2).font(.subheadline)
                        HStack(spacing: 6) {
                            if !media.quality.isEmpty { Text(media.quality) }
                            if media.size > 0 { Text(ByteFormat.string(media.size)) }
                            if media.isHLS { Text("m3u8") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { play(media) } label: { Image(systemName: "play.circle").font(.title2) }
                        .buttonStyle(.borderless)
                    Button { download([media]) } label: { Image(systemName: "arrow.down.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if videos.contains(where: { !$0.audioURL.isEmpty }) {
                Label("高清为音视频分轨，在线播放没有声音；下载完成后会自动合并为带声音的 MP4", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("图片 \(images.count) 张").font(.headline)
                Spacer()
                Button(selecting ? "取消" : "多选") {
                    selecting.toggle()
                    selected = []
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(images) { media in
                    Button {
                        if selecting {
                            if selected.contains(media.id) { selected.remove(media.id) } else { selected.insert(media.id) }
                        } else {
                            preview = MediaPreviewItem(url: media.url, headers: media.headers, title: media.fileName, kind: .image)
                        }
                    } label: {
                        Color.clear
                            .aspectRatio(3 / 4, contentMode: .fit)
                            .overlay { RemoteImage(url: media.url, headers: media.headers) }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if selecting {
                                    Image(systemName: selected.contains(media.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(.white, Color.accentColor)
                                        .shadow(radius: 2)
                                        .padding(8)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { download([media]) } label: { Label("下载这张", systemImage: "arrow.down.circle") }
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        let targets = selecting ? images.filter { selected.contains($0.id) } : result.medias
        return Button {
            download(targets)
            selecting = false
            selected = []
        } label: {
            Label(selecting ? "下载所选（\(targets.count)）" : (result.medias.count > 1 ? "全部下载（\(result.medias.count)）" : "下载"),
                  systemImage: "arrow.down.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(targets.isEmpty)
        .padding()
        .background(.bar)
    }

    private func play(_ media: VideoMedia) {
        preview = MediaPreviewItem(url: media.url, headers: media.headers, title: media.fileName,
                                   kind: media.kind == .audio ? .audio : .video)
    }

    private func download(_ medias: [VideoMedia]) {
        // 多张图片归到以作品标题命名的文件夹
        let folder = medias.count > 1 ? FileNames.base(result.title, fallback: result.platform.displayName) : ""
        for m in medias { app.downloads.enqueue(media: m, result: result, folder: folder) }
        app.show(medias.count > 1 ? "已添加 \(medias.count) 个下载任务" : "已添加到下载")
    }
}
