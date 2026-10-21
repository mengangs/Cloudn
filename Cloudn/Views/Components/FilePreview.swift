// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import AVKit
import CloudnKit
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
    @State private var convertSubtitles: [MKVRemuxer.Subtitle] = []
    /// 读文件头判断能不能转：nil 还没判断，"" 可以转，其余为不能转的原因
    @State private var remuxIssue: String?

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
        case .image: return .image
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
            if mode == .image {
                // 图片铺满全屏，操作栏浮在上面，轻点切换
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
        .statusBarHidden(mode == .image && !chromeVisible)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .preferredColorScheme(immersive ? .dark : nil)
        .presentationBackground(.clear)
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
                PlayerController(player: player, drag: dismissDrag).ignoresSafeArea(edges: .bottom)
            } else {
                Color.black.onAppear { player = PlayerController.makePlayer(converted ?? url) }
            }
        case .image:
            ZoomableImageFile(url: url, onTap: { chromeVisible.toggle() }, drag: dismissDrag).ignoresSafeArea()
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
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
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
            ShareLink(item: url) { IconView(.share, size: 16) }
                .buttonStyle(PreviewBarButtonStyle(dark: immersive))
                .accessibilityLabel("分享")
            Menu {
                if converted != nil {
                    Button { saveConverted() } label: { Label("保存转换后的 MP4 到下载", glyph: .download) }
                }
                if MediaTools.canSaveToPhotos(url) {
                    Button {
                        Task {
                            do { app.show(try await MediaTools.saveToPhotosSmart(url)) } catch { app.show(error.localizedDescription, error: true) }
                        }
                    } label: { Label("保存到相册", glyph: .image) }
                }
                Button { DownloadsView.revealInFiles(url.deletingLastPathComponent()) } label: { Label("在「文件」中查看", glyph: .folder) }
                Button { UIPasteboard.general.string = url.lastPathComponent; app.show("已复制文件名") } label: { Label("复制文件名", glyph: .paste) }
            } label: { IconView(.more, size: 16) }
                .buttonStyle(PreviewBarButtonStyle(dark: immersive))
                .accessibilityLabel("更多")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background {
            if mode == .image {
                LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            } else {
                (immersive ? Color.black : Color.paper).ignoresSafeArea(edges: .top)
            }
        }
    }

    // MARK: 不能直接预览

    private var fileSize: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private var canRemux: Bool {
        Self.remuxable.contains(url.pathExtension.lowercased()) && fileSize >= 1024 && remuxIssue == ""
    }

    private var unsupportedCard: some View {
        let kind = FileNames.kind(of: url.lastPathComponent)
        let tooSmall = (kind == .video || kind == .audio) && fileSize < 1024
        let hint: String = switch kind {
        case _ where tooSmall: "文件只有 \(ByteFormat.string(fileSize))，不是完整的视频，可能下载没有成功，请重新下载"
        case _ where !(remuxIssue ?? "").isEmpty: remuxIssue ?? ""
        case _ where canRemux: "系统播放器不支持 \(url.pathExtension.uppercased())，可以无损转成 MP4 后在这里播放（不重新编码，很快），也可以用 VLC、Infuse 等应用打开"
        case .video, .audio: "这个格式系统播放器不支持，可以用 VLC、Infuse 等应用打开"
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
                            ProgressView(value: converting)
                            Text("正在转换 \(Int(converting * 100))%").font(.footnote.monospacedDigit()).foregroundStyle(Color.ink3)
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
        .task {
            guard remuxIssue == nil, Self.remuxable.contains(url.pathExtension.lowercased()), fileSize >= 1024 else { return }
            let source = url
            remuxIssue = await Task.detached { MKVRemuxer.check(source) ?? "" }.value
        }
    }

    // MARK: MKV 转 MP4

    /// 转出的 MP4 放在缓存目录（同一文件转过且没改动就直接复用）；转好后改播它
    private func startRemux() {
        guard converting == nil else { return }
        convertError = nil
        converting = 0
        let source = url
        Task {
            do {
                let (output, result) = try await Self.remux(source) { value in
                    Task { @MainActor in if converting != nil { converting = value } }
                }
                converting = nil
                convertNotes = result.skipped
                convertSubtitles = result.subtitles
                player = nil
                converted = output
                var message = "已转换为 MP4"
                if !result.skipped.isEmpty { message += "；" + result.skipped.joined(separator: "；") }
                app.show(message)
            } catch {
                converting = nil
                convertError = error.localizedDescription
            }
        }
    }

    nonisolated private static func remux(_ source: URL, progress: @escaping @Sendable (Double) -> Void) async throws
        -> (URL, MKVRemuxer.Result) {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Converted", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let output = dir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mp4")
            let result = try MKVRemuxer.remux(source, to: output, progress: progress)
            return (output, result)
        }.value
    }

    /// 把转好的 MP4（和文字字幕）存进下载列表，「文件」App 里可见、可存相册
    private func saveConverted() {
        guard let converted else { return }
        let base = url.deletingPathExtension().lastPathComponent
        let subtitles = convertSubtitles
        Task {
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
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.drag = drag
        if controller.player !== player { controller.player = player; player.play() }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: DismissPanCoordinator) {
        controller.player?.pause()
    }
}

// MARK: - 图片

/// 本地图片：双指缩放、拖动、双击放大 / 还原，单击切换操作栏
struct ZoomableImageFile: UIViewRepresentable {
    let url: URL
    var onTap: () -> Void = {}
    var drag: DismissDrag?

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, drag: drag) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        let imageView = UIImageView(image: UIImage(contentsOfFile: url.path))
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
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.drag = drag
    }

    final class Coordinator: DismissPanCoordinator, UIScrollViewDelegate {
        var onTap: () -> Void
        weak var imageView: UIImageView?
        weak var scroll: UIScrollView?
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

/// 本地文本：只读前 2MB，编码自动识别（UTF-8 / GB18030）
struct LocalTextView: View {
    let url: URL
    @State private var text: String?
    @State private var truncated = false

    var body: some View {
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
                    .padding(16)
                }
            } else {
                Spinner(size: 26).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let limit = TextPreviewView.limit
            let data = (try? FileChunks.read(url, offset: 0, length: limit)) ?? Data()
            truncated = FileChunks.size(of: url) > Int64(limit)
            text = TextPreviewView.decode(data)
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

    init(drag: DismissDrag?) { self.drag = drag }

    func attach(to view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    /// 子类可加条件（如图片放大时不响应）
    func canBegin() -> Bool { true }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer, drag != nil, canBegin() else { return false }
        let v = pan.velocity(in: pan.view)
        return v.y > 0 && v.y > abs(v.x) * 1.5
    }

    @objc func handle(_ pan: UIPanGestureRecognizer) {
        let y = max(0, pan.translation(in: pan.view).y)
        switch pan.state {
        case .changed: drag?.onChange(y)
        case .ended: drag?.onEnd(y, pan.velocity(in: pan.view).y)
        case .cancelled, .failed: drag?.onEnd(0, 0)
        default: break
        }
    }
}
