// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit

/// 主屏幕长按图标的快捷操作：粘贴并解析、下载列表、最近收藏的几条链接
@MainActor
enum QuickActions {
    private static let prefix = "com.mengangs.Cloudn.quick."
    private static let paste = prefix + "paste"
    private static let downloads = prefix + "downloads"
    private static let bookmark = prefix + "bookmark"

    /// 系统最多显示 4 个：固定「粘贴并解析」，其余优先放收藏，收藏不够再放「下载列表」
    static func items(bookmarks: [Bookmark]) -> [UIApplicationShortcutItem] {
        var items = [UIApplicationShortcutItem(type: paste, localizedTitle: "粘贴并解析", localizedSubtitle: nil,
                                               icon: UIApplicationShortcutIcon(systemImageName: "doc.on.clipboard"))]
        for b in bookmarks.prefix(3) {
            items.append(UIApplicationShortcutItem(type: bookmark, localizedTitle: b.title.isEmpty ? b.source : b.title,
                                                   localizedSubtitle: b.source,
                                                   icon: UIApplicationShortcutIcon(systemImageName: "star"),
                                                   userInfo: ["text": b.text as NSString]))
        }
        if items.count < 4 {
            items.append(UIApplicationShortcutItem(type: downloads, localizedTitle: "下载列表", localizedSubtitle: nil,
                                                   icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.circle")))
        }
        return items
    }

    static func refresh(_ model: AppModel) {
        UIApplication.shared.shortcutItems = items(bookmarks: model.bookmarks.bookmarks)
    }

    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem, model: AppModel) -> Bool {
        switch item.type {
        case paste:
            // 冷启动时界面还没起来，稍等再读剪贴板（系统的粘贴授权提示要有界面才能弹）
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty {
                    model.selectedTab = .resolve
                    model.show("剪贴板里没有内容")
                } else {
                    model.pendingInput = text
                    model.selectedTab = .resolve
                }
            }
        case downloads:
            model.selectedTab = .downloads
        case bookmark:
            guard let text = item.userInfo?["text"] as? String, !text.isEmpty else { return false }
            model.pendingInput = text
            model.selectedTab = .resolve
        default:
            return false
        }
        return true
    }
}

/// 应用已在运行时，快捷操作从场景代理进来（冷启动的那次在 AppDelegate 的场景配置里处理）
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(MainActor.assumeIsolated { QuickActions.perform(shortcutItem, model: AppModel.shared) })
    }
}
