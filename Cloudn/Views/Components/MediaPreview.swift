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
    /// 图集：同一组图片，预览时左右滑动切换（为空表示只有这一张）
    var gallery: [GalleryImage] = []

    struct GalleryImage: Identifiable, Equatable {
        let url: String
        let headers: [String: String]
        let title: String
        var id: String { url }
    }
}

/// 在线预览：视频/音频用 AVPlayer（逐请求带上直链要求的请求头），图片可缩放
struct MediaPreviewView: View {
    let item: MediaPreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failure: String?
    /// 下滑关闭：手指往下拖的距离
    @State private var dragY: CGFloat = 0
    /// 图集当前页
    @State private var page = ""
    @State private var chromeVisible = true

    private var pages: [MediaPreviewItem.GalleryImage] {
        item.gallery.isEmpty ? [.init(url: item.url, headers: item.headers, title: item.title)] : item.gallery
    }

    private var pageIndex: Int { pages.firstIndex { $0.id == page } ?? 0 }

    private var title: String {
        guard item.kind == .image, pages.count > 1 else { return item.title }
        return "\(pageIndex + 1) / \(pages.count)"
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: { IconView(.close, size: 15) }
                    .buttonStyle(PreviewBarButtonStyle(dark: true))
                    .accessibilityLabel("关闭")
                Text(title)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                if item.kind == .video {
                    RotateButton()
                } else {
                    // 与左侧按钮等宽，标题保持居中
                    Color.clear.frame(width: 38, height: 38)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .opacity(dragY > 0 || !chromeVisible ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: chromeVisible)
            ZStack {
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
                        PlayerController(player: player, drag: dismissDrag).ignoresSafeArea(edges: .bottom)
                    }
                case .image:
                    if pages.count > 1 {
                        // 图集：左右滑动翻页，每页可单独缩放；放大后先在图内平移，到边缘再翻页
                        TabView(selection: $page) {
                            ForEach(pages) { image in
                                ZoomableImageFile(source: .remote(image.url, headers: image.headers),
                                                  onTap: { chromeVisible.toggle() }, drag: dismissDrag)
                                    .tag(image.id)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .ignoresSafeArea(edges: .bottom)
                    } else {
                        ZoomableImageFile(source: .remote(item.url, headers: item.headers),
                                          onTap: { chromeVisible.toggle() }, drag: dismissDrag)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dismissDragEffect(dragY)
        }
        .background(Color.black.opacity(DismissDrag.backdrop(dragY)).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        // onAppear 可能不止一次（画中画回来等）：已有播放器就不重建，免得从头播放
        .onAppear {
            if page.isEmpty { page = item.url }
            if player == nil && failure == nil { startPlayer() }
        }
        .sensoryFeedback(.selection, trigger: page)
        .onDisappear { player?.pause() }
    }

    private func startPlayer() {
        guard item.kind != .image, let url = URL(string: item.url) else { return }
        failure = nil
        let p = PlayerController.makePlayer(url, headers: item.headers)
        guard let playerItem = p.currentItem else { return }
        player = p
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
