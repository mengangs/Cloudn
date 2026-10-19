// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import UserNotifications

/// 下载完成 / 失败的本地通知（只在应用不在前台时发）
enum Notifier {
    /// 第一次加入下载时请求权限；系统只会弹一次
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
