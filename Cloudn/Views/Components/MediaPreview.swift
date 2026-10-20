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
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                switch item.kind {
                case .video, .audio:
                    if let failure {
                        // 直链过期、403 等：说清楚，给重试，而不是一块黑屏
                        VStack(spacing: 12) {
                            IconView(.warning, size: 26)
                            Text("无法播放").font(.cardTitle)
                            Text(failure).font(.footnote).opacity(0.7).multilineTextAlignment(.center)
                            Button("重试") { startPlayer() }
                                .buttonStyle(PillButtonStyle(kind: .secondary, height: 38))
                                .padding(.top, 4)
                        }
                        .foregroundStyle(.white)
                        .padding(32)
                    } else if let player {
                        VideoPlayer(player: player)
                            .ignoresSafeArea(edges: .bottom)
                    }
                case .image:
                    ZoomableImage(url: item.url, headers: item.headers)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear(perform: startPlayer)
        .onDisappear { player?.pause() }
    }

    private func startPlayer() {
        guard item.kind != .image, let url = URL(string: item.url) else { return }
        failure = nil
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": item.headers]
        if let ua = item.headers["User-Agent"] { options[AVURLAssetHTTPUserAgentKey] = ua }
        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: playerItem)
        player = p
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        p.play()
        // 盯一会儿播放状态：失败时换成说明 + 重试
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                guard player === p else { return }
                switch playerItem.status {
                case .readyToPlay: return
                case .failed:
                    failure = playerItem.error?.localizedDescription ?? "链接可能已过期，请回到上一页重新获取"
                    return
                default: continue
                }
            }
        }
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
