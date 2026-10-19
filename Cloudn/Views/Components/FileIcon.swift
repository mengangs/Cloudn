// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

struct FileIcon: View {
    let name: String
    var isDirectory = false
    var size: CGFloat = 36

    var body: some View {
        let style = Self.style(FileNames.kind(of: name, isDirectory: isDirectory))
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(style.color.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: style.symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(style.color)
            }
    }

    static func style(_ kind: FileNames.Kind) -> (symbol: String, color: Color) {
        switch kind {
        case .folder: return ("folder.fill", .blue)
        case .video: return ("play.rectangle.fill", .purple)
        case .audio: return ("music.note", .pink)
        case .image: return ("photo.fill", .orange)
        case .archive: return ("archivebox.fill", .brown)
        case .document: return ("doc.richtext.fill", .indigo)
        case .text: return ("doc.text.fill", .gray)
        case .apk: return ("shippingbox.fill", .green)
        case .other: return ("doc.fill", .secondary)
        }
    }
}

extension SharePlatform {
    var symbol: String {
        switch self {
        case .quark: return "q.circle.fill"
        case .uc: return "u.circle.fill"
        case .lanzou, .ilanzou: return "l.circle.fill"
        case .baidu: return "b.circle.fill"
        case .xunlei: return "x.circle.fill"
        default: return "externaldrive.fill.badge.icloud"
        }
    }
}

extension VideoPlatform {
    var symbol: String {
        switch self {
        case .douyin: return "music.note.tv"
        case .kuaishou: return "video.fill"
        case .weibo: return "text.bubble.fill"
        case .acfun: return "a.circle.fill"
        case .xiaohongshu: return "book.closed.fill"
        case .pixiv: return "paintpalette.fill"
        case .bilibili: return "play.tv.fill"
        }
    }
}
