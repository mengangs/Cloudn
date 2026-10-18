// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Observation

/// 全部偏好设置的唯一入口（UserDefaults），值域在 setter 里兜住
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var maxConcurrentTasks: Int {
        didSet { defaults.set(maxConcurrentTasks, forKey: "maxConcurrentTasks"); publish() }
    }
    var connectionsPerTask: Int {
        didSet { defaults.set(connectionsPerTask, forKey: "connectionsPerTask"); publish() }
    }
    var clipboardHint: Bool {
        didSet { defaults.set(clipboardHint, forKey: "clipboardHint") }
    }
    /// 视频/图片下载完成后自动存入相册
    var autoSaveToPhotos: Bool {
        didSet { defaults.set(autoSaveToPhotos, forKey: "autoSaveToPhotos") }
    }
    var acceptedNotice: Bool {
        didSet { defaults.set(acceptedNotice, forKey: "acceptedNotice") }
    }

    /// 下载引擎在后台线程读取，这里维护一份线程安全快照
    @ObservationIgnored let snapshot = SettingsSnapshot()

    init() {
        defaults.register(defaults: [
            "maxConcurrentTasks": 3,
            "connectionsPerTask": 8,
            "clipboardHint": true,
            "autoSaveToPhotos": false
        ])
        maxConcurrentTasks = min(5, max(1, defaults.integer(forKey: "maxConcurrentTasks")))
        connectionsPerTask = min(16, max(1, defaults.integer(forKey: "connectionsPerTask")))
        clipboardHint = defaults.bool(forKey: "clipboardHint")
        autoSaveToPhotos = defaults.bool(forKey: "autoSaveToPhotos")
        acceptedNotice = defaults.bool(forKey: "acceptedNotice")
        publish()
    }

    private func publish() {
        snapshot.set(DownloadSettings(maxConcurrentTasks: maxConcurrentTasks, connectionsPerTask: connectionsPerTask, retryCount: 3))
    }
}

final class SettingsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value = DownloadSettings()

    func set(_ v: DownloadSettings) { lock.lock(); value = v; lock.unlock() }
    func get() -> DownloadSettings { lock.lock(); defer { lock.unlock() }; return value }
}
