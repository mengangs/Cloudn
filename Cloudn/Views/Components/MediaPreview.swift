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
    /// 下滑关闭：手指往下拖的距离
    @State private var dragY: CGFloat = 0

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
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                // 与左侧按钮等宽，标题保持居中
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .opacity(dragY > 0 ? 0 : 1)
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
                    ZoomableImage(url: item.url, headers: item.headers, drag: dismissDrag)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dismissDragEffect(dragY)
        }
        .background(Color.black.opacity(DismissDrag.backdrop(dragY)).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        .onAppear(perform: startPlayer)
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

struct ZoomableImage: View {
    let url: String
    var headers: [String: String] = [:]
    /// 未放大时往下拖关闭
    var drag: DismissDrag?
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
                            guard scale > 1 else {
                                if v.translation.height > 0 && v.translation.height > abs(v.translation.width) { drag?.onChange(v.translation.height) }
                                return
                            }
                            offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { v in
                            guard scale > 1 else {
                                let velocity = (v.predictedEndTranslation.height - v.translation.height) * 4
                                drag?.onEnd(max(0, v.translation.height), velocity)
                                return
                            }
                            lastOffset = offset
                        })
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring) {
                    if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; lastScale = 2.5 }
                }
            }
    }
}
