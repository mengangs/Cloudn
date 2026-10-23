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
    /// 各清晰度组选中的那一个（没选过就是组内第一个，即最高画质）
    @State private var chosen: [String: UUID] = [:]
    /// 合集里取消勾选的条目（默认全选）
    @State private var unpicked = Set<UUID>()
    @State private var batchJob: BatchJob?
    /// 正在保存的字幕（可以同时存几条）
    @State private var savingSubtitles = Set<UUID>()
    /// 下载前探测到的大小 / 清晰度 / 时长（平台没给的才探测）
    @State private var probes: [UUID: MediaProbeResult] = [:]
    @State private var probing = Set<UUID>()
    /// 探测过的（含失败的），不再重复探测
    @State private var probed = Set<UUID>()
    /// 分轨视频各清晰度共用同一条音轨：音轨大小只探一次
    @State private var audioProbes = AudioProbeCache()
    /// 就地弹出的登录页（登录已失效时）
    @State private var loginKind: AccountKind?
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 实况照片：图片 id → 配对的视频。配上对的视频挂在图片上，不单独列为视频
    private let livePairs: [UUID: VideoMedia]
    private let liveClipIDs: Set<UUID>
    /// 结果不会变：视频、图片与清晰度分组在这里算一次，body 里多处直接用，不必每次重绘都重新筛
    private let videos: [VideoMedia]
    private let images: [VideoMedia]
    /// 视频区的行：同一清晰度组合成一行
    private let videoRows: [[VideoMedia]]

    init(result: VideoParseResult) {
        self.result = result
        let pairs = result.livePairs
        livePairs = pairs
        let clipIDs = Set(pairs.values.map(\.id))
        liveClipIDs = clipIDs
        let videos = result.medias.filter { $0.kind != .image && !clipIDs.contains($0.id) }
        self.videos = videos
        images = result.medias.filter { $0.kind == .image }
        var rows: [[VideoMedia]] = []
        var index: [String: Int] = [:]
        for media in videos {
            if media.variantGroup.isEmpty {
                rows.append([media])
            } else if let i = index[media.variantGroup] {
                rows[i].append(media)
            } else {
                index[media.variantGroup] = rows.count
                rows.append([media])
            }
        }
        videoRows = rows
    }

    private func selection(_ options: [VideoMedia]) -> VideoMedia {
        let group = options[0].variantGroup
        return options.first { $0.id == chosen[group] } ?? options[0]
    }

    /// 「全部下载」的对象：图片（连同实况视频）+ 每行选中的视频
    private var downloadAll: [VideoMedia] { videoRows.map(selection) + withLive(images) }

    /// 图片后面紧跟它的实况视频（下载时一起入队，下载页据此配成实况照片）
    private func withLive(_ medias: [VideoMedia]) -> [VideoMedia] {
        medias.flatMap { media in [media] + (livePairs[media.id].map { [$0] } ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let kind = result.platform.accountKind, app.accounts.isExpired(kind) { expiredCard(kind) }
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
                if !result.entries.isEmpty { entriesSection }
                if !result.subtitles.isEmpty { subtitleSection }
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
                    if !result.url.isEmpty {
                        Button { Clipboard.copy(result.url); app.show("已复制作品链接") } label: {
                            Label { Text("复制作品链接") } icon: { Image(icon: .link) }
                        }
                    }
                    if !result.text.isEmpty {
                        Button { Clipboard.copy(result.text); app.show("已复制文案") } label: {
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
        .safeAreaInset(edge: .bottom) { bottomBar.padding(.horizontal, 16).padding(.bottom, 8).readableWidth() }
        .sensoryFeedback(.selection, trigger: selected)
        .animation(.snappy(duration: 0.25), value: selecting)
        .fullScreenCover(item: $preview) { MediaPreviewView(item: $0) }
        .sheet(item: $batchJob) { BatchView(job: $0) }
        .sheet(item: $loginKind) { LoginSheet(kind: $0) }
        .task(id: result.medias.map(\.id)) { await probeAll() }
    }

    /// 该平台的登录已失效：解析结果可能不完整（清晰度受限、拿不到需登录的内容），旁边就是重新登录入口
    private func expiredCard(_ kind: AccountKind) -> some View {
        AnyLayout.adaptive(typeSize, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconView(.user, size: 18).foregroundStyle(Color.clayInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(kind.displayName)登录已失效").font(.footnote.weight(.semibold))
                    Text("重新登录可获取更高清晰度").font(.caption)
                }
                .foregroundStyle(Color.clayInk)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button("重新登录") { loginKind = kind }
                .buttonStyle(PillButtonStyle(kind: .dark, height: 30))
                .font(.footnote)
        }
        .padding(14)
        .background(Color.claySoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                            .buttonStyle(TextLinkButtonStyle())
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
        .contextMenu {
            Button { saveCover() } label: { Label { Text("保存封面") } icon: { Image(icon: .download) } }
            Button { Clipboard.copy(result.cover); app.show("已复制封面地址") } label: {
                Label { Text("复制封面地址") } icon: { Image(icon: .link) }
            }
        }
    }

    /// 封面作为一条下载加入列表（完成后可在下载页存到相册）
    private func saveCover() {
        let ext = URL(string: result.cover).map { $0.pathExtension.lowercased() } ?? ""
        let name = FileNames.base(result.title, fallback: result.platform.displayName) + "_cover."
            + (["jpg", "jpeg", "png", "webp", "heic", "avif", "gif"].contains(ext) ? ext : "jpg")
        if let item = app.downloads.items.last(where: { $0.request.url == result.cover }), item.status != .failed {
            app.show("封面已在下载列表中")
            return
        }
        app.downloads.enqueue(DownloadRequest(url: result.cover, headers: videos.first?.headers ?? [:], fileName: name,
                                              kind: .file, source: result.platform.displayName))
        app.show("封面已添加到下载")
    }

    // MARK: 视频

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let rows = videoRows
            SectionLabel(title: (videos.allSatisfy { $0.kind == .audio } ? "音频" : "视频") + (rows.count > 1 ? " \(rows.count) 个" : ""))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element[0].id) { index, options in
                    let media = selection(options)
                    // 清晰度不多时直接平铺成胶囊（各带大小），多了才收进菜单
                    let inline = options.count > 1 && options.count <= 4
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            FileIcon(name: media.fileName)
                            VStack(alignment: .leading, spacing: 3) {
                                // 最先看到的是清晰度与大小；自动生成的文件名退到次要一行
                                let title = headline(media)
                                Text(title ?? media.fileName)
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .contentTransition(.numericText())
                                if options.count > 4 { qualityPicker(options, selected: media) }
                                if title != nil {
                                    Text(media.fileName).font(.caption).foregroundStyle(Color.ink3).lineLimit(1).truncationMode(.middle)
                                }
                                let meta = metaText(media)
                                if !meta.isEmpty { Text(meta).font(.monoSmall).foregroundStyle(Color.ink3) }
                            }
                            Spacer(minLength: 0)
                            Button { play(media) } label: { IconView(.play, size: 15) }
                                .buttonStyle(CircleIconButtonStyle(size: 32))
                                .accessibilityLabel("在线播放")
                            DownloadStateControl(item: state(of: media)) { download([media]) }
                        }
                        if inline { qualityChips(options, selected: media).padding(.leading, 50) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .contextMenu { videoMenu(media) }
                    if index < rows.count - 1 { RowDivider(leading: 64) }
                }
            }
            .card()
            if videos.contains(where: { !$0.audioURL.isEmpty }) {
                Text("分轨视频在线播放无声，下载后会自动合并音轨")
                    .font(.caption)
                    .foregroundStyle(Color.ink3)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func videoMenu(_ media: VideoMedia) -> some View {
        Button { Clipboard.copy(media.url); app.show("已复制直链（下载可能需带请求头）") } label: {
            Label { Text("复制直链") } icon: { Image(icon: .link) }
        }
        if let url = URL(string: media.url) {
            ShareLink(item: url) { Label { Text("分享链接") } icon: { Image(icon: .share) } }
        }
    }

    /// 行的主文字：「1080P · 86.4 MB」；清晰度和大小都不知道时为 nil（显示文件名）
    private func headline(_ media: VideoMedia) -> String? {
        var parts: [String] = []
        if let quality = qualityText(media) { parts.append(quality) }
        if let size = sizeText(media) {
            parts.append(size)
        } else if probing.contains(media.id) {
            parts.append("正在获取大小…")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 次要信息：时长、m3u8、分轨
    private func metaText(_ media: VideoMedia) -> String {
        var parts: [String] = []
        if let duration = probes[media.id]?.duration { parts.append(Self.clock(duration)) }
        if media.isHLS { parts.append("m3u8") }
        if !media.audioURL.isEmpty { parts.append("音视频分轨") }
        return parts.joined(separator: " · ")
    }

    /// 平铺的清晰度胶囊：每个都带大小（没给大小的出现时就去探测）
    private func qualityChips(_ options: [VideoMedia], selected: VideoMedia) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    FilterChip(title: optionTitle(option), selected: option.id == selected.id) {
                        chosen[option.variantGroup] = option.id
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .task { await probe(options) }
    }

    /// 清晰度选择：组内第一个是最高画质。打开菜单时才探测其余清晰度的大小
    private func qualityPicker(_ options: [VideoMedia], selected: VideoMedia) -> some View {
        Menu {
            ForEach(options) { option in
                Button {
                    chosen[option.variantGroup] = option.id
                    Task { await probe([option]) }
                } label: {
                    if option.id == selected.id {
                        Label(optionTitle(option), systemImage: "checkmark")
                    } else {
                        Text(optionTitle(option))
                    }
                }
            }
            .onAppear { Task { await probe(options) } }
        } label: {
            HStack(spacing: 4) {
                Text("清晰度 · \(options.count) 档")
                Image(icon: .chevronRight).resizable().scaledToFit().frame(width: 9, height: 9).rotationEffect(.degrees(90))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.clayInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.claySoft, in: Capsule())
        }
        .accessibilityLabel("清晰度：\(selected.quality)")
    }

    private func optionTitle(_ media: VideoMedia) -> String {
        var parts = [qualityText(media) ?? media.fileName]
        if let size = sizeText(media) { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    // MARK: 大小与清晰度探测

    private func qualityText(_ media: VideoMedia) -> String? {
        if !media.quality.isEmpty { return media.quality }
        if let height = probes[media.id]?.height, height > 0 { return "\(height)P" }
        return nil
    }

    private func sizeText(_ media: VideoMedia) -> String? {
        if media.size > 0 { return ByteFormat.string(media.size) }
        guard let info = probes[media.id], let size = info.size else { return nil }
        return (info.estimated ? "约 " : "") + ByteFormat.string(size)
    }

    /// 平台没给大小或清晰度的才探测：一开始只探每行当前选中的那个，其余清晰度等打开清晰度菜单再探
    private func probeAll() async {
        await probe(videoRows.map(selection))
    }

    /// 逐个探测（同时最多 4 个），探过的跳过；分轨视频的大小 = 画面 + 声音（同一条音轨只探一次）
    private func probe(_ medias: [VideoMedia]) async {
        let targets = medias.filter { ($0.size <= 0 || $0.quality.isEmpty) && !probed.contains($0.id) && !probing.contains($0.id) }
        guard !targets.isEmpty else { return }
        probing.formUnion(targets.map(\.id))
        let audio = audioProbes
        await withTaskGroup(of: (UUID, MediaProbeResult?).self) { group in
            var pending = targets.makeIterator()
            for _ in 0..<4 {
                if let media = pending.next() { group.addTask { await Self.probe(media, audio: audio) } }
            }
            for await (id, info) in group {
                probing.remove(id)
                if let info { probes[id] = info }
                // 被取消（离开页面）的不算探过，下次进来再探
                if !Task.isCancelled { probed.insert(id) }
                if let media = pending.next() { group.addTask { await Self.probe(media, audio: audio) } }
            }
        }
        probing.subtract(targets.map(\.id))
    }

    nonisolated private static func probe(_ media: VideoMedia, audio: AudioProbeCache) async -> (UUID, MediaProbeResult?) {
        guard var info = await MediaProbe.probe(media.url, headers: media.headers, isHLS: media.isHLS) else { return (media.id, nil) }
        if !media.audioURL.isEmpty, let size = info.size {
            let audioSize = await audio.size(media.audioURL, headers: media.headers)
            info.size = audioSize.map { size + $0 }
        }
        return (media.id, info)
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
                .buttonStyle(TextLinkButtonStyle())
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
        let live = livePairs[media.id]
        return Button {
            if selecting {
                if on { selected.remove(media.id) } else { selected.insert(media.id) }
            } else {
                // 带上整组图片：预览里左右滑动看其他图
                preview = MediaPreviewItem(url: media.url, headers: media.headers, title: media.fileName, kind: .image,
                                           gallery: images.map { .init(url: $0.url, headers: $0.headers, title: $0.fileName) })
            }
        } label: {
            Color.fillMuted
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { RemoteImage(url: media.url, headers: media.headers).allowsHitTesting(false) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                // 裁切只管画面不管触摸：铺满的大图会越过格子盖住旁边一格，点左边那格反被右边那张接走
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.hairline), lineWidth: on ? 2.5 : 1)
                }
                .overlay(alignment: .bottomLeading) {
                    if live != nil {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                            .accessibilityLabel("实况照片")
                    }
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
            Button { download(withLive([media])) } label: { Label { Text("下载这张") } icon: { Image(icon: .download) } }
            if let live {
                Button { play(live) } label: { Label { Text("播放实况") } icon: { Image(icon: .play) } }
            }
            Button { Clipboard.copy(media.url); app.show("已复制图片地址") } label: {
                Label { Text("复制图片地址") } icon: { Image(icon: .link) }
            }
        }
    }

    // MARK: 合集

    private var pickedEntries: [VideoEntry] { result.entries.filter { !unpicked.contains($0.id) } }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 作者主页叫「作品」，播放列表 / 合集叫「合集」
                SectionLabel(title: "\(result.title.hasSuffix("的作品") ? "作品" : "合集") \(result.entries.count) 个")
                Spacer()
                Button(unpicked.isEmpty ? "全不选" : "全选") {
                    unpicked = unpicked.isEmpty ? Set(result.entries.map(\.id)) : []
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(TextLinkButtonStyle())
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(result.entries.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        if unpicked.contains(entry.id) { unpicked.remove(entry.id) } else { unpicked.insert(entry.id) }
                    } label: {
                        HStack(spacing: 12) {
                            SelectMark(on: !unpicked.contains(entry.id), size: 20)
                            if !entry.cover.isEmpty {
                                Color.fillMuted
                                    .frame(width: 64, height: 40)
                                    .overlay { RemoteImage(url: VideoHTTP.secureURL(entry.cover)) }
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title.isEmpty ? entry.url : entry.title)
                                    .font(.subheadline).foregroundStyle(Color.ink).lineLimit(2)
                                if let d = entry.duration, d > 0 {
                                    Text(Self.clock(d)).font(.monoSmall).foregroundStyle(Color.ink3)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < result.entries.count - 1 { RowDivider(leading: 46) }
                }
            }
            .card()
            Text("逐条按最高画质加入下载")
                .font(.caption)
                .foregroundStyle(Color.ink3)
                .padding(.horizontal, 4)
        }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1e9 else { return "--:--" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: 字幕

    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "字幕 \(result.subtitles.count) 个")
            VStack(spacing: 0) {
                ForEach(Array(result.subtitles.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 12) {
                        IconView(.text, size: 18).foregroundStyle(Color.ink2).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name).font(.subheadline).foregroundStyle(Color.ink)
                            Text(track.automatic ? "自动生成 · 存为 SRT" : "存为 SRT").font(.caption).foregroundStyle(Color.ink3)
                        }
                        Spacer(minLength: 0)
                        if savingSubtitles.contains(track.id) {
                            Spinner(size: 18)
                        } else {
                            Button { saveSubtitle(track) } label: { IconView(.download, size: 15) }
                                .buttonStyle(CircleIconButtonStyle(size: 32))
                                .accessibilityLabel("下载\(track.name)字幕")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if index < result.subtitles.count - 1 { RowDivider(leading: 52) }
                }
            }
            .card()
        }
    }

    private func saveSubtitle(_ track: SubtitleTrack) {
        guard savingSubtitles.insert(track.id).inserted else { return }
        Task {
            defer { savingSubtitles.remove(track.id) }
            do {
                let name = try await app.saveSubtitle(track, title: result.title.isEmpty ? result.platform.displayName : result.title,
                                                      source: result.platform.displayName, page: result.url)
                app.show("字幕已加入下载：\(name)")
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }

    // MARK: 底部

    @ViewBuilder
    private var bottomBar: some View {
        if !result.entries.isEmpty && !selecting {
            let picked = pickedEntries
            Button {
                startBatch(picked)
            } label: {
                HStack(spacing: 6) {
                    Image(icon: .download)
                    Text(picked.isEmpty ? "选择要下载的条目" : "下载所选 · \(picked.count) 个").contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary, height: 48))
            .disabled(picked.isEmpty)
            .floatingShadow()
        } else {
            mediaBottomBar
        }
    }

    @ViewBuilder
    private var mediaBottomBar: some View {
        let picked = images.filter { selected.contains($0.id) }
        let targets = selecting ? withLive(picked) : downloadAll
        // 数量按作品算：实况照片的视频随图片一起下，不另计
        let count = selecting ? picked.count : videoRows.count + images.count
        let title = selecting ? (picked.isEmpty ? "选择要下载的图片" : "下载所选 · \(count) 张")
            : (count > 1 ? "全部下载 · \(count) 项" : "下载")
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
        .floatingShadow()
    }

    // MARK: 动作

    /// 合集批量下载：同样这些条目已经有批量任务（连点、或关掉进度页后再点）就打开那个，不重复建；
    /// 停下的、有失败的在进度页里继续 / 重试
    private func startBatch(_ picked: [VideoEntry]) {
        guard batchJob == nil, !picked.isEmpty else { return }
        let urls = Set(picked.map(\.url))
        if let existing = app.batchJobs.last(where: { Set($0.items.map(\.url)) == urls }) {
            batchJob = existing
            return
        }
        let title = result.title.isEmpty ? result.platform.displayName : result.title
        batchJob = app.startBatch(title: title, entries: picked.map { (title: $0.title, url: $0.url) })
    }

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
        // 多张图片归到以作品标题命名的文件夹；实况照片的视频跟着图片走（同一目录才能配对），不单独计数
        let units = pending.filter { !liveClipIDs.contains($0.id) }.count
        let folder = units > 1 ? FileNames.base(result.title, fallback: result.platform.displayName) : ""
        let group = units > 1 ? DownloadGroup(title: result.title.isEmpty ? result.platform.displayName : result.title) : nil
        for m in pending { app.downloads.enqueue(media: m, result: result, folder: folder, group: group) }
        let skipped = medias.filter { !liveClipIDs.contains($0.id) }.count - units
        app.show(units > 1 ? "已添加 \(units) 个" + (skipped > 0 ? " · 跳过 \(skipped) 个已下载" : "") : "已添加到下载")
    }
}

/// 同一条音轨的大小探测合并成一次（各清晰度共用一条音轨时）
private actor AudioProbeCache {
    private var tasks: [String: Task<Int64?, Never>] = [:]

    func size(_ url: String, headers: [String: String]) async -> Int64? {
        if let task = tasks[url] { return await task.value }
        let task = Task { await MediaProbe.probe(url, headers: headers, isHLS: false)?.size }
        tasks[url] = task
        return await task.value
    }
}
