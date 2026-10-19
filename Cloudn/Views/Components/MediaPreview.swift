// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import AVKit
import QuickLook
import SwiftUI

struct MediaPreviewItem: Identifiable {
    enum Kind { case video, audio, image }
    let id = UUID()
    let url: String
    let headers: [String: String]
    let title: String
    let kind: Kind
}

/// 在线预览：视频/音频用 AVPlayer（逐请求带上直链要求的请求头），图片可缩放
struct MediaPreviewView: View {
    let item: MediaPreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch item.kind {
                case .video, .audio:
                    if let player {
                        VideoPlayer(player: player)
                            .ignoresSafeArea(edges: .bottom)
                    }
                case .image:
                    ZoomableImage(url: item.url, headers: item.headers)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            guard item.kind != .image, let url = URL(string: item.url) else { return }
            var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": item.headers]
            if let ua = item.headers["User-Agent"] { options[AVURLAssetHTTPUserAgentKey] = ua }
            let asset = AVURLAsset(url: url, options: options)
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = p
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}

struct ZoomableImage: View {
    let url: String
    var headers: [String: String] = [:]
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        RemoteImage(url: url, headers: headers, contentMode: .fit)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = max(1, min(6, lastScale * $0.magnification)) }
                    .onEnded { _ in lastScale = scale; if scale == 1 { offset = .zero; lastOffset = .zero } }
                    .simultaneously(with: DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset })
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring) {
                    if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; lastScale = 2.5 }
                }
            }
    }
}

/// 本地文件预览（QuickLook：视频、图片、PDF、文本、Office 文档等）
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
