// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import UserNotifications

/// 下载完成 / 失败的本地通知（只在应用不在前台时发）。
/// 后台期间完成（或失败）多个任务时合并成一条汇总（「12 个下载完成」），后来的替换先前的，不刷屏；
/// 回到前台时计数清零。点通知打开应用后切到「下载」页
enum Notifier {
    /// 通知分组：系统通知中心里归在一起
    static let threadIdentifier = "downloads"
    /// 汇总通知的固定标识：同一标识再发会替换已送达的那条
    static let finishedIdentifier = "downloads.finished"
    static let failedIdentifier = "downloads.failed"

    /// 这次在后台期间完成 / 失败的任务（名称；失败的带原因）
    @MainActor private static var finished: [String] = []
    @MainActor private static var failed: [(name: String, message: String)] = []
    /// 上次响铃时间：替换汇总时短时间内不再响铃
    @MainActor private static var lastSound = Date.distantPast

    /// 第一次加入下载时请求权限；系统只会弹一次
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// 一个任务下载完成（调用方已判断应用不在前台、用户打开了通知）
    @MainActor static func downloadFinished(_ name: String) {
        finished.append(name)
        let (title, body) = summary(count: finished.count, names: finished, noun: "下载完成")
        post(title: title, body: body, identifier: finishedIdentifier)
    }

    /// 一个任务下载失败
    @MainActor static func downloadFailed(_ name: String, message: String) {
        failed.append((name, message))
        if failed.count == 1 {
            post(title: "下载失败", body: "\(name)：\(message)", identifier: failedIdentifier)
        } else {
            let (title, body) = summary(count: failed.count, names: failed.map(\.name), noun: "下载失败")
            post(title: title, body: body, identifier: failedIdentifier)
        }
    }

    /// 回到前台：重新开始计数（已送达的通知留在通知中心）
    @MainActor static func resetSummary() {
        finished = []
        failed = []
    }

    /// 1 个：标题「下载完成」、正文为文件名；多个：标题「12 个下载完成」、正文列出最近几个
    static func summary(count: Int, names: [String], noun: String) -> (title: String, body: String) {
        guard count > 1 else { return (noun, names.last ?? "") }
        let recent = names.suffix(3).reversed().joined(separator: "、")
        let body = count > 3 ? "\(recent) 等 \(count) 个文件" : recent
        return ("\(count) 个\(noun)", body)
    }

    @MainActor private static func post(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = threadIdentifier
        // 连续替换汇总时只在隔了一会儿才响铃，避免一批任务完成时连响
        let now = Date()
        if now.timeIntervalSince(lastSound) > 30 {
            content.sound = .default
            lastSound = now
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadIdentifier
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// 点了下载通知：打开应用后切到「下载」页。
/// AppDelegate 在启动时把自己设为通知中心代理（见 AppDelegate.swift），这里补上点通知的回调
extension AppDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isDownload = response.notification.request.content.threadIdentifier == Notifier.threadIdentifier
        DispatchQueue.main.async {
            if isDownload {
                MainActor.assumeIsolated { AppModel.shared.selectedTab = .downloads }
            }
            completionHandler()
        }
    }
}
