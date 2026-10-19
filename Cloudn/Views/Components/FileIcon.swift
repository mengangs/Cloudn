// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import SwiftUI

struct FileIcon: View {
    let name: String
    var isDirectory = false
    var size: CGFloat = 38

    var body: some View {
        let style = Self.style(FileNames.kind(of: name, isDirectory: isDirectory))
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(style.media ? Color.claySoft : Color.fillMuted)
            .frame(width: size, height: size)
            .overlay {
                IconView(style.icon, size: size * 0.55)
                    .foregroundStyle(style.media ? Color.clayInk : Color.ink)
            }
            .accessibilityHidden(true)
    }

    /// 视频 / 音频 / 图片用陶土浅底，其余暖灰底
    static func style(_ kind: FileNames.Kind) -> (icon: Icon, media: Bool) {
        switch kind {
        case .folder: return (.folder, false)
        case .video: return (.video, true)
        case .audio: return (.music, true)
        case .image: return (.image, true)
        case .archive: return (.archive, false)
        case .document: return (.doc, false)
        case .text: return (.text, false)
        case .apk: return (.archive, false)
        case .other: return (.file, false)
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
