// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import UIKit

/// 应用自己往剪贴板写内容：统一走这里。写完顺带记下这一版剪贴板（changeCount），
/// 解析页就不会把应用刚复制的直链 / 地址当成「剪贴板里有一个链接」再提示一遍
enum Clipboard {
    /// 解析页记录「已处理过的剪贴板版本」用的键（ResolveView 的 @AppStorage 与这里共用）
    static let handledChangeKey = "clipboardHandledChange"

    @MainActor static func copy(_ text: String) {
        UIPasteboard.general.string = text
        markHandled()
    }

    @MainActor static func copy(_ url: URL) {
        UIPasteboard.general.url = url
        markHandled()
    }

    /// 当前这一版剪贴板记为已处理（也可在别处自己写剪贴板后调用）
    @MainActor static func markHandled() {
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: handledChangeKey)
    }
}
