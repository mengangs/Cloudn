// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// 发布说明这类简单 Markdown：逐行认标题（# / ##）、列表（- / * / 1.）、引用（>），行内的粗体、代码、链接交给 AttributedString。
/// 不做完整的 Markdown，只求更新说明看起来不是一堆符号
struct MarkdownText: View {
    let source: String

    enum Block: Equatable {
        case heading(String, level: Int)
        case bullet(String)
        case numbered(String, number: String)
        case quote(String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            inline(text)
                .font(level == 1 ? .cardTitle : .subheadline.weight(.semibold))
                .foregroundStyle(level == 1 ? Color.ink : Color.ink2)
                .padding(.top, level == 1 ? 0 : 6)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(.callout).foregroundStyle(Color.ink3)
                inline(text).font(.callout).foregroundStyle(Color.ink)
            }
        case .numbered(let text, let number):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number + ".").font(.callout.monospacedDigit()).foregroundStyle(Color.ink3)
                inline(text).font(.callout).foregroundStyle(Color.ink)
            }
        case .quote(let text):
            inline(text)
                .font(.footnote)
                .foregroundStyle(Color.ink2)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(Color.hairline).frame(width: 3) }
        case .paragraph(let text):
            inline(text).font(.callout).foregroundStyle(Color.ink)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) { return Text(attributed) }
        return Text(text)
    }

    /// 按行切成块：连续的普通行合成一段，空行分段
    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let m = line.firstMatch(of: #/^(#{1,6})\s+(.+)$/#) {
                flush()
                blocks.append(.heading(String(m.2), level: m.1.count))
            } else if let m = line.firstMatch(of: #/^[-*+]\s+(.+)$/#) {
                flush()
                blocks.append(.bullet(String(m.1)))
            } else if let m = line.firstMatch(of: #/^(\d+)[.)]\s+(.+)$/#) {
                flush()
                blocks.append(.numbered(String(m.2), number: String(m.1)))
            } else if let m = line.firstMatch(of: #/^>\s?(.*)$/#) {
                flush()
                blocks.append(.quote(String(m.1)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
