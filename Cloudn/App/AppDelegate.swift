// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit
import UserNotifications

/// 只负责系统级回调：后台下载会话事件、通知在前台的展示方式
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // 系统可能为了投递后台下载事件在后台拉起应用：此时界面不一定创建，确保下载引擎与会话已经就位
        _ = AppModel.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransfers.identifier else {
            completionHandler()
            return
        }
        AppModel.shared.background.setSystemCompletion(completionHandler)
    }

    /// 应用在前台时不弹横幅（界面上已有提示）
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        []
    }
}
