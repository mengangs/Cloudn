// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

/// 公告列表（「我的」页进入）
struct AnnouncementListView: View {
    @Environment(AppModel.self) private var app

    private var store: AnnouncementStore { app.announcements }

    var body: some View {
        List {
            if store.items.isEmpty {
                if let error = store.errorMessage {
                    EmptyStateCard(icon: .warning, title: "公告加载失败", detail: error, actionTitle: "重试") {
                        Task { await store.refresh() }
                    }
                    .inList()
                } else if !store.loading {
                    EmptyStateCard(icon: .doc, title: "暂无公告").inList()
                }
            }
            ForEach(store.items) { a in
                NavigationLink { AnnouncementDetailView(announcement: a) } label: { row(a) }
                    .paperRow()
            }
        }
        .paperList()
        .overlay { if store.loading && store.items.isEmpty { Spinner(size: 28) } }
        .refreshable { await store.refresh() }
        .navigationTitle("公告")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.unreadCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("全部已读") { store.markAllRead() }
                }
            }
        }
        .task { if store.items.isEmpty { await store.refresh() } }
    }

    private func row(_ a: Announcement) -> some View {
        let unread = !store.isRead(a)
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(unread ? Color.clayInk : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if a.pinned { AnnouncementTag(text: "置顶") }
                    Text(a.title)
                        .font(.subheadline.weight(unread ? .semibold : .regular))
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                }
                if !a.preview.isEmpty {
                    Text(a.preview).font(.footnote).foregroundStyle(Color.ink2).lineLimit(2)
                }
                if let date = a.publishedAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Color.ink3)
                }
            }
            Spacer(minLength: 0)
            if !a.cover.isEmpty {
                RemoteImage(url: a.cover)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel((unread ? "未读，" : "") + (a.pinned ? "置顶，" : "") + a.title)
    }
}

struct AnnouncementTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.clayInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.claySoft, in: Capsule())
    }
}

/// 公告详情：标题、时间、正文（Markdown 的常用写法）、图集
struct AnnouncementDetailView: View {
    @Environment(AppModel.self) private var app
    let announcement: Announcement
    @State private var preview: MediaPreviewItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    if announcement.pinned { AnnouncementTag(text: "置顶") }
                    if let date = announcement.publishedAt {
                        Text(date.formatted(date: .long, time: .shortened)).font(.footnote).foregroundStyle(Color.ink3)
                    }
                }
                Text(announcement.title)
                    .font(.serif(24, relativeTo: .title))
                    .foregroundStyle(Color.ink)
                    .textSelection(.enabled)
                if !announcement.summary.isEmpty && announcement.content.isEmpty {
                    Text(announcement.summary).font(.body).foregroundStyle(Color.ink2)
                }
                MarkdownBlocks(text: announcement.content) { url in
                    preview = MediaPreviewItem(url: url, headers: [:], title: announcement.title, kind: .image)
                }
                if !announcement.gallery.isEmpty { gallery }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.paper)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $preview) { MediaPreviewView(item: $0) }
        .onAppear { app.announcements.markRead(announcement.id) }
    }

    /// 只有一张图时铺满宽度；多张横向滑动
    @ViewBuilder
    private var gallery: some View {
        let images = announcement.gallery
        if images.count == 1 {
            Button { preview = MediaPreviewItem(url: images[0], headers: [:], title: announcement.title, kind: .image) } label: {
                RemoteImage(url: images[0], contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images, id: \.self) { url in
                        Button { preview = MediaPreviewItem(url: url, headers: [:], title: announcement.title, kind: .image) } label: {
                            Color.fillMuted
                                .frame(width: 132, height: 132)
                                .overlay { RemoteImage(url: url) }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

/// 启动弹窗：封面固定高度，摘要最多几行，「查看详情」进详情页
struct AnnouncementPopup: View {
    let announcement: Announcement
    let onDetail: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !announcement.cover.isEmpty {
                Color.fillMuted
                    .frame(height: 160)
                    .overlay { RemoteImage(url: announcement.cover) }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(spacing: 6) {
                IconView(.doc, size: 14)
                Text("公告")
                if announcement.pinned { AnnouncementTag(text: "置顶") }
            }
            .font(.footnote)
            .foregroundStyle(Color.ink2)
            Text(announcement.title)
                .font(.serif(22, relativeTo: .title2))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !announcement.preview.isEmpty {
                Text(announcement.preview)
                    .font(.callout)
                    .foregroundStyle(Color.ink2)
                    .lineLimit(5)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(action: onClose) { Text("知道了").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Button(action: onDetail) { Text("查看详情").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        }
        .padding(20)
        .background(Color.paper)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 公告正文的轻量 Markdown：标题、列表、引用、图片、分隔线、段落（行内粗体 / 链接 / 代码交给系统解析）
struct MarkdownBlocks: View {
    let text: String
    var onImage: (String) -> Void = { _ in }

    enum Block: Hashable {
        case heading(Int, String)
        case bullet(String)
        case quote(String)
        case image(String)
        case rule
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let s):
                    inline(s).font(level <= 1 ? .title3.weight(.semibold) : .headline).foregroundStyle(Color.ink).padding(.top, 4)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Color.ink3)
                        inline(s).foregroundStyle(Color.ink)
                    }
                case .quote(let s):
                    inline(s)
                        .foregroundStyle(Color.ink2)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.hairline).frame(width: 3) }
                case .image(let url):
                    Button { onImage(url) } label: {
                        RemoteImage(url: url, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                case .rule:
                    Divider()
                case .paragraph(let s):
                    inline(s).foregroundStyle(Color.ink)
                }
            }
        }
        .font(.body)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: options) { return Text(a) }
        return Text(s)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let m = line.range(of: #"^!\[[^\]]*\]\(([^)\s]+)[^)]*\)$"#, options: .regularExpression) {
                flush()
                let inner = String(line[m])
                if let open = inner.lastIndex(of: "("), let url = inner[inner.index(after: open)...].split(separator: " ").first {
                    out.append(.image(url.trimmingCharacters(in: CharacterSet(charactersIn: ")"))))
                }
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix(">") {
                flush()
                out.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                flush()
                out.append(.rule)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }
}
