import SwiftUI
import UniformTypeIdentifiers

/// 把链接、文字或 .torrent 文件拖进 App（iPad 分屏、台前调度，或从别的 App 拖过来）：交给解析页，和粘贴一样处理
struct LinkDropModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false

    private static let types: [UTType] = [.torrent, .url, .plainText]

    func body(content: Content) -> some View {
        content
            .onDrop(of: Self.types, isTargeted: $targeted) { providers in
                guard providers.contains(where: { p in Self.types.contains { p.hasItemConformingToTypeIdentifier($0.identifier) } })
                else { return false }
                receive(providers)
                return true
            }
            .overlay {
                if targeted { hint.transition(.opacity) }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: targeted)
    }

    private var hint: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                Label { Text("松开即可解析") } icon: { Image(icon: .link) }
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.surface, in: Capsule())
                    .floatingShadow()
            }
            .padding(12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 有种子文件就只开第一个种子；否则把拖进来的链接和文字合在一起（多个链接会走批量解析）
    private func receive(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            if let torrent = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.torrent.identifier) }) {
                guard let copy = await Self.copyTorrent(from: torrent) else { return }
                app.openTorrentFile(copy)
                try? FileManager.default.removeItem(at: copy)
                return
            }
            var texts: [String] = []
            for provider in providers {
                if let text = await Self.text(from: provider) { texts.append(text) }
            }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            app.pendingInput = text
            app.selectedTab = .resolve
        }
    }

    /// 回调返回后系统就删掉临时文件，先拷一份出来
    private static func copyTorrent(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.torrent.identifier) { url, _ in
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".torrent")
                guard let url, (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: copy)
            }
        }
    }

    /// 网址优先（从 Safari 拖出的链接同时带网址和文字）；本地文件地址不要
    private static func text(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    cont.resume(returning: url.flatMap { $0.isFileURL ? nil : $0.absoluteString })
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in cont.resume(returning: text) }
            } else {
                cont.resume(returning: nil)
            }
        }
    }
}

extension View {
    func acceptsLinkDrop() -> some View { modifier(LinkDropModifier()) }
}
