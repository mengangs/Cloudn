// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import AVKit
import CloudnKit
import CryptoKit
import ImageIO
import QuickLook
import SwiftUI
import UIKit

/// 下载好的文件全屏预览：按类型选最合适的查看方式，顶部统一的深色操作栏（关闭 / 分享 / 更多），轻点画面隐藏或显示
struct FilePreviewView: View {
    let url: URL
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var chromeVisible = true
    @State private var player: AVPlayer?
    /// 下滑关闭：手指往下拖的距离
    @State private var dragY: CGFloat = 0
    /// MKV 转出的 MP4（转好后改播它）
    @State private var converted: URL?
    /// 转换进度 0...1；nil 表示没在转
    @State private var converting: Double?
    @State private var convertError: String?
    @State private var convertNotes: [String] = []
    @State private var convertSubtitles: [ConvertedSubtitle] = []
    /// 读文件头判断能不能转：nil 还没判断，"" 可以转，其余为不能转的原因
    @State private var remuxIssue: String?
    /// 正在进行的转换；关闭预览时取消
    @State private var remuxTask: Task<Void, Never>?
    /// 文件大小：打开时读一次（nil 表示还没读到），不在每次刷新界面时访问磁盘
    @State private var fileSize: Int64?
    /// 图片解码失败（文件损坏或格式不支持）时改显示「无法预览」卡片
    @State private var imageFailed = false
    /// 正在把转好的 MP4 存进下载（防止连点存出好几份）
    @State private var savingConverted = false

    enum Mode { case player, image, text, document, unsupported }

    /// AVFoundation 能直接播的格式；mkv / avi / flv 等交给其他应用
    static let playable: Set<String> = ["mp4", "mov", "m4v", "3gp", "mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "m3u8", "ts"]

    /// 能无损转成 MP4 再播的容器
    static let remuxable: Set<String> = ["mkv", "webm", "mka"]

    private var mode: Mode {
        if converted != nil { return .player }
        let ext = url.pathExtension.lowercased()
        switch FileNames.kind(of: url.lastPathComponent) {
        case .video, .audio: return Self.playable.contains(ext) ? .player : .unsupported
        case .image: return imageFailed ? .unsupported : .image
        case .text: return .text
        default: return QLPreviewController.canPreview(url as NSURL) ? .document : .unsupported
        }
    }

    /// 文档 / 文本页面是浅色的，操作栏常驻；媒体类全屏黑底，轻点隐藏
    private var immersive: Bool { mode == .player || mode == .image }

    var body: some View {
        ZStack(alignment: .top) {
            // 下拉时背景逐渐透明，露出下面的页面
            (immersive ? Color.black.opacity(DismissDrag.backdrop(dragY)) : Color.paper).ignoresSafeArea()
            if immersive {
                // 图片 / 视频铺满全屏，操作栏浮在画面上：轻点切换，播放中几秒后自动隐藏（不再把画面往下挤）
                content.dismissDragEffect(dragY)
                if chromeVisible && dragY == 0 { topBar.transition(.opacity) }
            } else {
                // 播放器顶部有它自己的画中画 / 音量按钮，操作栏放在画面之外，不叠在一起
                VStack(spacing: 0) {
                    topBar.opacity(dragY > 0 ? 0 : 1)
                    content.frame(maxHeight: .infinity).dismissDragEffect(dragY)
                }
            }
        }
        .statusBarHidden(immersive && !chromeVisible)
        .task(id: chromeVisible) { await autoHideChrome() }
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .preferredColorScheme(immersive ? .dark : nil)
        .presentationBackground(.clear)
        .task {
            guard fileSize == nil else { return }
            let source = url
            fileSize = await Task.detached { FileChunks.size(of: source) }.value
        }
        .onDisappear {
            // 关闭预览就不再等转换结果（已转好的部分照样留在缓存里，下次直接用）
            remuxTask?.cancel()
            remuxTask = nil
        }
    }

    private var isVideo: Bool { mode == .player && FileNames.kind(of: url.lastPathComponent) != .audio }

    /// 视频播放中，操作栏显示 3 秒后自动隐藏（跟系统播放控件的节奏一致）
    private func autoHideChrome() async {
        guard chromeVisible, isVideo else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, (player?.rate ?? 0) > 0 else { return }
        chromeVisible = false
    }

    private var dismissDrag: DismissDrag {
        DismissDrag(onChange: { dragY = $0 }, onEnd: { distance, velocity in
            if DismissDrag.shouldDismiss(distance, velocity) {
                dismiss()
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragY = 0 }
            }
        })
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .player:
            if let player {
                // 系统播放控件让出顶栏的高度；画面本身铺满全屏
                PlayerController(player: player, drag: dismissDrag, topInset: chromeVisible ? 56 : 0,
                                 onTap: { chromeVisible.toggle() })
                    .ignoresSafeArea()
            } else {
                Color.black.onAppear { player = PlayerController.makePlayer(converted ?? url) }
            }
        case .image:
            ZoomableImageFile(url: url, onTap: { chromeVisible.toggle() }, onFailure: { imageFailed = true }, drag: dismissDrag)
                .ignoresSafeArea()
        case .text:
            LocalTextView(url: url)
        case .document:
            QuickLookContent(url: url)
        case .unsupported:
            unsupportedCard
        }
    }

    // MARK: 顶部操作栏

    private var meta: String {
        let size = fileSize ?? 0
        let ext = url.pathExtension.uppercased()
        return [ext.isEmpty ? nil : ext, size > 0 ? ByteFormat.string(size) : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { IconView(.close, size: 15) }
                .buttonStyle(PreviewBarButtonStyle(dark: immersive))
                .accessibilityLabel("关闭")
            VStack(spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !meta.isEmpty {
                    Text(meta).font(.caption2.monospacedDigit()).opacity(0.65)
                }
            }
            .foregroundStyle(immersive ? Color.white : Color.ink)
            .frame(maxWidth: .infinity)
            if mode == .player, FileNames.kind(of: url.lastPathComponent) == .video {
                RotateButton()
            }
            // 保存到相册放在顶栏上（以前在「…」里），预览完直接存
            if MediaTools.canSaveToPhotos(url) {
                Button { saveToPhotos() } label: { IconView(.download, size: 16) }
                    .buttonStyle(PreviewBarButtonStyle(dark: immersive))
                    .accessibilityLabel("保存到相册")
            }
            ShareLink(item: url) { IconView(.share, size: 16) }
                .buttonStyle(PreviewBarButtonStyle(dark: immersive))
                .accessibilityLabel("分享")
            Menu {
                if converted != nil {
                    Button { saveConverted() } label: { Label("保存转换后的 MP4 到下载", glyph: .download) }
                        .disabled(savingConverted)
                }
                Button { DownloadsView.revealInFiles(url.deletingLastPathComponent()) } label: { Label("在「文件」中查看", glyph: .folder) }
                Button { Clipboard.copy(url.lastPathComponent); app.show("已复制文件名") } label: { Label("复制文件名", glyph: .paste) }
            } label: { IconView(.more, size: 16) }
                .buttonStyle(PreviewBarButtonStyle(dark: immersive))
                .accessibilityLabel("更多")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background {
            if immersive {
                LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            } else {
                (immersive ? Color.black : Color.paper).ignoresSafeArea(edges: .top)
            }
        }
    }

    private func saveToPhotos() {
        Task {
            do { app.show(try await MediaTools.saveToPhotosSmart(url)) } catch { app.show(error.localizedDescription, error: true) }
        }
    }

    // MARK: 不能直接预览

    private var canRemux: Bool {
        Self.remuxable.contains(url.pathExtension.lowercased()) && (fileSize ?? 0) >= 1024 && remuxIssue == ""
    }

    private var unsupportedCard: some View {
        let kind = FileNames.kind(of: url.lastPathComponent)
        let size = fileSize ?? 0
        let tooSmall = (kind == .video || kind == .audio) && fileSize != nil && size < 1024
        let hint: String = switch kind {
        case _ where tooSmall: "文件只有 \(ByteFormat.string(size))，可能没有下载完整，请重新下载"
        case .image where imageFailed: "图片无法解码，可能已损坏或格式不受支持"
        case _ where !(remuxIssue ?? "").isEmpty: remuxIssue ?? ""
        case _ where canRemux: "正在把 \(url.pathExtension.uppercased()) 转为 MP4 封装播放，不重新编码、画质不变，通常几秒钟"
        case .video, .audio: "系统播放器不支持此格式，可用 VLC、Infuse 等应用打开"
        case .archive: "压缩包可在「文件」App 中轻点解压"
        case .apk: "安装包请用「分享」发送到对应的安装工具"
        default: "可以用其他应用打开，或在「文件」App 中查看"
        }
        return VStack(spacing: 18) {
            Spacer()
            FileIcon(name: url.lastPathComponent).scaleEffect(1.6).frame(width: 80, height: 80)
            VStack(spacing: 6) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if !meta.isEmpty { Text(meta).font(.footnote.monospacedDigit()).foregroundStyle(Color.ink3) }
            }
            Text(hint).font(.footnote).foregroundStyle(Color.ink2).multilineTextAlignment(.center)
            if let convertError {
                Text(convertError).font(.footnote).foregroundStyle(Color.clayInk).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                if canRemux && convertError == nil {
                    if let converting {
                        VStack(spacing: 8) {
                            ProgressLine(value: converting)
                            Text("正在准备播放 \(Int(converting * 100))%").font(.footnote.monospacedDigit()).foregroundStyle(Color.ink3)
                        }
                        .padding(.vertical, 6)
                    } else {
                        Button { startRemux() } label: {
                            Label("转换为 MP4 播放", glyph: .play).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                    }
                }
                ShareLink(item: url) {
                    Label("用其他应用打开", glyph: .share).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: canRemux && convertError == nil ? .secondary : .primary))
                Button { DownloadsView.revealInFiles(url.deletingLastPathComponent()) } label: {
                    Label("在「文件」中查看", glyph: .folder).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: fileSize) {
            guard remuxIssue == nil, Self.remuxable.contains(url.pathExtension.lowercased()), let size = fileSize, size >= 1024 else { return }
            let source = url
            // 转过且源文件没改动：缓存里的 MP4 直接能播，不必再读文件头
            remuxIssue = await Task.detached { ConvertedCache.lookup(source) != nil ? "" : (MKVRemuxer.check(source) ?? "") }.value
            // 能转就直接转：只是把音视频原样换个容器（不重新编码、几秒钟），转好自动播放
            if remuxIssue == "" && !Task.isCancelled { startRemux() }
        }
    }

    // MARK: MKV 转 MP4

    /// 转出的 MP4 放在缓存目录（同一文件转过且没改动就直接复用，见 ConvertedCache）；转好后改播它
    private func startRemux() {
        guard converting == nil else { return }
        convertError = nil
        converting = 0
        let source = url
        let progress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in if converting != nil { converting = value } }
        }
        remuxTask = Task {
            do {
                let (output, meta) = try await Task.detached(priority: .userInitiated) {
                    try ConvertedCache.convert(source, progress: progress)
                }.value
                // 预览已关闭：结果留在缓存里，不再切换播放器、不提示
                guard !Task.isCancelled else { return }
                converting = nil
                convertNotes = meta.skipped
                convertSubtitles = meta.subtitles
                player = nil
                converted = output
                var message = "已转换为 MP4"
                if !meta.skipped.isEmpty { message += "；" + meta.skipped.joined(separator: "；") }
                app.show(message)
            } catch {
                guard !Task.isCancelled else { return }
                converting = nil
                convertError = error.localizedDescription
            }
        }
    }

    /// 把转好的 MP4（和文字字幕）存进下载列表，「文件」App 里可见、可存相册
    private func saveConverted() {
        guard let converted, !savingConverted else { return }
        savingConverted = true
        let base = url.deletingPathExtension().lastPathComponent
        let subtitles = convertSubtitles
        Task {
            defer { savingConverted = false }
            do {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                try FileManager.default.copyItem(at: converted, to: copy)
                try await app.downloads.importLocalFile(copy, name: base + ".mp4", source: "格式转换")
                for (i, sub) in subtitles.enumerated() {
                    let tag = [sub.language, sub.name].filter { !$0.isEmpty }.first ?? "\(i + 1)"
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
                    try Data(sub.srt.utf8).write(to: file)
                    try await app.downloads.importLocalFile(file, name: "\(base).\(tag).srt", source: "格式转换")
                }
                app.show(subtitles.isEmpty ? "已保存 MP4 到下载" : "已保存 MP4 和 \(subtitles.count) 个字幕到下载")
            } catch {
                app.show(error.localizedDescription, error: true)
            }
        }
    }
}

/// 预览页顶栏的圆形按钮（深色画面上用半透明黑底）
struct PreviewBarButtonStyle: ButtonStyle {
    var dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(dark ? Color.white : Color.ink)
            .frame(width: 38, height: 38)
            .background(dark ? AnyShapeStyle(Color.white.opacity(0.14)) : AnyShapeStyle(Color.fillMuted), in: Circle())
            .contentShape(Circle().inset(by: -4))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - 播放器

/// 系统播放器（AVPlayerViewController）：自带进度、画中画、隔空播放、倍速
struct PlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    var drag: DismissDrag?
    /// 顶部浮着的操作栏高度：系统控件往下让，画面不动
    var topInset: CGFloat = 0
    /// 轻点画面（与系统控件的显隐同步切换操作栏）
    var onTap: (() -> Void)?

    /// 本地文件或带请求头的直链
    static func makePlayer(_ url: URL, headers: [String: String] = [:]) -> AVPlayer {
        var options: [String: Any] = [:]
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        if let ua = headers["User-Agent"] { options[AVURLAssetHTTPUserAgentKey] = ua }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        return AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: options)))
    }

    func makeCoordinator() -> DismissPanCoordinator { DismissPanCoordinator(drag: drag) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.view.backgroundColor = .clear
        if drag != nil { context.coordinator.attach(to: controller.view) }
        context.coordinator.tapAction = onTap
        context.coordinator.attachTap(to: controller.view)
        controller.additionalSafeAreaInsets.top = topInset
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.drag = drag
        context.coordinator.tapAction = onTap
        if controller.additionalSafeAreaInsets.top != topInset {
            UIView.animate(withDuration: 0.2) {
                controller.additionalSafeAreaInsets.top = topInset
                controller.view.layoutIfNeeded()
            }
        }
        if controller.player !== player { controller.player = player; player.play() }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: DismissPanCoordinator) {
        controller.player?.pause()
    }
}

// MARK: - 图片

/// 可缩放图片的来源：本地文件，或带请求头的网络图片
enum ZoomSource: Equatable {
    case file(URL)
    case remote(String, headers: [String: String])
}

/// 图片：双指缩放、拖动、双击放大 / 还原，单击切换操作栏（本地文件与网络图片共用，图集翻页时每页一个）
struct ZoomableImageFile: UIViewRepresentable {
    let source: ZoomSource
    var onTap: () -> Void = {}
    /// 解码失败（文件损坏 / 格式不支持）
    var onFailure: () -> Void = {}
    var drag: DismissDrag?

    init(source: ZoomSource, onTap: @escaping () -> Void = {}, onFailure: @escaping () -> Void = {}, drag: DismissDrag? = nil) {
        self.source = source
        self.onTap = onTap
        self.onFailure = onFailure
        self.drag = drag
    }

    init(url: URL, onTap: @escaping () -> Void = {}, onFailure: @escaping () -> Void = {}, drag: DismissDrag? = nil) {
        self.init(source: .file(url), onTap: onTap, onFailure: onFailure, drag: drag)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(onTap: onTap, drag: drag)
        coordinator.onFailure = onFailure
        return coordinator
    }

    /// 按需缩小解码：长边不超过屏幕的约 3 倍像素，几十兆像素的大图也不会一次解出整张、占满内存
    nonisolated static func downsampled(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor)
        ])
        context.coordinator.imageView = imageView
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: double)
        scroll.addGestureRecognizer(double)
        scroll.addGestureRecognizer(single)
        // 未放大时往下拖关闭；放大后交给滚动视图平移
        context.coordinator.scroll = scroll
        if drag != nil { context.coordinator.attach(to: scroll) }
        // 在后台解码，解好再放上去；主线程不做整张图的解码
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor)
        ])
        spinner.startAnimating()
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
        let maxPixel = max(screen?.width ?? 1024, screen?.height ?? 1366) * 3
        let source = source
        let coordinator = context.coordinator
        context.coordinator.loading = Task { @MainActor [weak imageView, weak spinner] in
            let image: UIImage?
            switch source {
            case .file(let url):
                image = await Task.detached(priority: .userInitiated) { Self.downsampled(url, maxPixel: maxPixel) }.value
            case .remote(let url, let headers):
                image = await ImageLoader.shared.load(url, headers: headers)
            }
            guard !Task.isCancelled else { return }
            spinner?.removeFromSuperview()
            if let image {
                imageView?.image = image
            } else {
                coordinator.onFailure()
            }
        }
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onFailure = onFailure
        context.coordinator.drag = drag
    }

    static func dismantleUIView(_ scroll: UIScrollView, coordinator: Coordinator) {
        coordinator.loading?.cancel()
    }

    final class Coordinator: DismissPanCoordinator, UIScrollViewDelegate {
        var onTap: () -> Void
        var onFailure: () -> Void = {}
        weak var imageView: UIImageView?
        weak var scroll: UIScrollView?
        var loading: Task<Void, Never>?
        init(onTap: @escaping () -> Void, drag: DismissDrag?) {
            self.onTap = onTap
            super.init(drag: drag)
        }

        override func canBegin() -> Bool {
            guard let scroll else { return true }
            return scroll.zoomScale <= scroll.minimumZoomScale + 0.01
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func singleTap() { onTap() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

// MARK: - 文本

/// 本地文本：只读前 2MB，编码自动识别（UTF-8 / GB18030）。读文件、识别编码都在后台做，显示用 UITextView（大文本也不卡）
struct LocalTextView: View {
    let url: URL
    @State private var text: String?
    @State private var truncated = false

    var body: some View {
        Group {
            if let text {
                VStack(alignment: .leading, spacing: 0) {
                    if truncated {
                        Label("文件较大，只显示前 2MB", glyph: .warning)
                            .font(.footnote)
                            .foregroundStyle(Color.ink3)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                    ReadOnlyTextView(text: text)
                }
            } else {
                Spinner(size: 26).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let limit = TextPreviewView.limit
            let source = url
            let (decoded, isTruncated) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
                let data = (try? FileChunks.read(source, offset: 0, length: limit)) ?? Data()
                return (TextPreviewView.decode(data), FileChunks.size(of: source) > Int64(limit))
            }.value
            truncated = isTruncated
            text = decoded
        }
    }
}

// MARK: - 文档（QuickLook，不带它自己的导航栏）

struct QuickLookContent: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// MARK: - 横屏

/// 视频横屏：锁定了竖屏也能切过去；关闭预览时转回竖屏
@MainActor
enum ScreenRotation {
    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    }

    static var isLandscape: Bool { scene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false }

    static func set(landscape: Bool) {
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
    }
}

/// 预览顶栏的「横屏 / 竖屏」切换；离开预览时如果是它转的横屏，就转回来
struct RotateButton: View {
    var dark = true
    @State private var landscape = false

    var body: some View {
        Button {
            landscape.toggle()
            ScreenRotation.set(landscape: landscape)
        } label: {
            Image(systemName: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                .font(.system(size: 15, weight: .medium))
        }
        .buttonStyle(PreviewBarButtonStyle(dark: dark))
        .accessibilityLabel(landscape ? "竖屏" : "横屏")
        .onAppear { landscape = ScreenRotation.isLandscape }
        .onDisappear { if landscape { ScreenRotation.set(landscape: false) } }
    }
}

// MARK: - 下滑关闭

/// 下滑关闭的回调：拖动距离；松手时的距离与速度
struct DismissDrag {
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    static func shouldDismiss(_ distance: CGFloat, _ velocity: CGFloat) -> Bool { distance > 120 || velocity > 900 }
    static func backdrop(_ distance: CGFloat) -> Double { Double(max(0.15, 1 - distance / 420)) }
}

extension View {
    /// 跟手下移并略微缩小
    func dismissDragEffect(_ distance: CGFloat) -> some View {
        offset(y: distance).scaleEffect(1 - min(distance, 400) / 1600)
    }
}

/// UIKit 层的下滑手势：只在明显向下拖时开始，不抢横向拖动（进度条、翻页）
class DismissPanCoordinator: NSObject, UIGestureRecognizerDelegate {
    var drag: DismissDrag?

    /// 播放器画面的轻点回调（图片页的 Coordinator 另有自己的 onTap）
    var tapAction: (() -> Void)?

    init(drag: DismissDrag?) { self.drag = drag }

    func attach(to view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    /// 轻点：和系统播放器自己的轻点手势同时识别，不抢它的控件显隐
    func attachTap(to view: UIView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc func tapped() { tapAction?() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g is UITapGestureRecognizer
    }

    /// 子类可加条件（如图片放大时不响应）
    func canBegin() -> Bool { true }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UITapGestureRecognizer { return true }
        guard let pan = g as? UIPanGestureRecognizer, drag != nil, canBegin() else { return false }
        let v = pan.velocity(in: pan.view)
        return v.y > 0 && v.y > abs(v.x) * 1.5
    }

    /// 位移按窗口坐标量：被拖的视图本身在跟手移动、缩小，按它自己的坐标量会来回抖
    @objc func handle(_ pan: UIPanGestureRecognizer) {
        let y = max(0, pan.translation(in: nil).y)
        switch pan.state {
        case .changed: drag?.onChange(y)
        case .ended: drag?.onEnd(y, pan.velocity(in: nil).y)
        case .cancelled, .failed: drag?.onEnd(0, 0)
        default: break
        }
    }
}

// MARK: - MKV 转换缓存

/// 转换出的字幕（转好的结果连同字幕一起缓存，复用时也能「保存到下载」）
struct ConvertedSubtitle: Codable, Sendable {
    var language: String
    var name: String
    var srt: String
}

/// MKV 转出的 MP4 放在 Caches/Converted：按源文件路径 + 大小 + 修改时间的哈希取名，不同文件不会互相覆盖；
/// 同一文件转过且没改动就直接复用。旁边的 .json 记着跳过的轨道与字幕。启动时清理旧文件（见 trim）
enum ConvertedCache {
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    struct Meta: Codable, Sendable {
        var skipped: [String]
        var subtitles: [ConvertedSubtitle]
    }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Converted", isDirectory: true)
    }

    /// 缓存键：源文件路径（去掉会随应用更新变化的容器路径）+ 大小 + 修改时间
    static func key(for source: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let path = source.standardizedFileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let digest = SHA256.hash(data: Data("\(path)|\(size)|\(modified)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 已有的转换结果（顺手更新修改时间，清理时按最近使用保留）
    static func lookup(_ source: URL) -> (URL, Meta)? {
        guard let key = key(for: source) else { return nil }
        return cached(key)
    }

    private static func cached(_ key: String) -> (URL, Meta)? {
        let fm = FileManager.default
        let video = directory.appendingPathComponent(key + ".mp4")
        guard let size = (try? fm.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.int64Value, size > 0 else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: video.path)
        let meta = (try? Data(contentsOf: metaURL(key))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        return (video, meta ?? Meta(skipped: [], subtitles: []))
    }

    private static func metaURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    /// 有缓存直接返回；否则转到一个临时名字，成功后再改成正式名字（转到一半被打断不会留下坏文件冒充缓存）
    static func convert(_ source: URL, progress: @escaping @Sendable (Double) -> Void) throws -> (URL, Meta) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let key = key(for: source) else { throw CloudnError("无法读取文件") }
        if let hit = cached(key) { return hit }
        let partial = directory.appendingPathComponent("\(key)-\(UUID().uuidString).partial")
        let result: MKVRemuxer.Result
        do {
            result = try MKVRemuxer.remux(source, to: partial, progress: progress)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        let video = directory.appendingPathComponent(key + ".mp4")
        if fm.fileExists(atPath: video.path) {
            // 同一文件同时转了两次（如关掉又马上打开）：用先转好的那份
            try? fm.removeItem(at: partial)
        } else {
            try fm.moveItem(at: partial, to: video)
        }
        let meta = Meta(skipped: result.skipped,
                        subtitles: result.subtitles.map { ConvertedSubtitle(language: $0.language, name: $0.name, srt: $0.srt) })
        if let data = try? JSONEncoder().encode(meta) { try? data.write(to: metaURL(key), options: .atomic) }
        return (video, meta)
    }

    /// 启动时清理：超过 7 天没用过的、总量超过 2GB 的（从最久没用的删起）、中断留下的半成品
    static func trim(now: Date = Date()) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var videos: [(url: URL, date: Date, size: Int64)] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            let age = now.timeIntervalSince(date)
            switch file.pathExtension {
            case "partial":
                // 正在写的半成品修改时间一直在更新；一小时没动过的是上次被打断留下的
                if age > 3600 { try? fm.removeItem(at: file) }
            case "mp4":
                if age > maxAge {
                    try? fm.removeItem(at: file)
                } else {
                    videos.append((file, date, Int64(values?.fileSize ?? 0)))
                }
            default:
                break
            }
        }
        var total: Int64 = 0
        for (index, video) in videos.sorted(by: { $0.date > $1.date }).enumerated() {
            total += video.size
            // 最近用的那个总是留着
            if total > maxBytes && index > 0 { try? fm.removeItem(at: video.url) }
        }
        // 视频删掉后，旁边的说明文件也删
        for file in files where file.pathExtension == "json" {
            let video = file.deletingPathExtension().appendingPathExtension("mp4")
            if !fm.fileExists(atPath: video.path) { try? fm.removeItem(at: file) }
        }
    }
}
