// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import ActivityKit
import Foundation

/// 下载进度实时活动（锁屏 / 灵动岛）。主应用与小组件扩展各有一份同名定义，字段必须保持一致
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 进行中的任务数
        var active: Int
        /// 本轮已完成的任务数
        var finished: Int
        /// 总体进度 0...1（未知为 -1）
        var fraction: Double
        /// 总速度（字节 / 秒）
        var speed: Int64
        /// 当前主要任务的文件名
        var title: String
        /// 补充说明（「正在获取种子信息」「已暂停，回到应用继续」等）；为空不显示
        var note: String = ""
    }
}
