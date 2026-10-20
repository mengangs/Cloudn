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

    /// 挂上场景代理以接收主屏幕快捷操作；冷启动时快捷操作只在这里给一次
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { QuickActions.perform(item, model: AppModel.shared) }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QuickActionSceneDelegate.self
        return config
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
