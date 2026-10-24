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
        /// 没有进行中、也没有暂停的任务时，下载失败的个数（大于 0 表示这一轮以失败告终）。
        /// 可选：旧版本写的状态里没有这个字段，解码时为 nil，照样能读
        var failed: Int? = nil
        /// 进行中任务还剩的字节数（有任务不知道大小时为 nil）：和速度一起算剩余时间。可选，旧版本的状态里没有
        var remaining: Int64? = nil
        /// 主题色「浅色 RRGGBB,深色 RRGGBB」；nil 表示默认的陶土色。可选，旧版本的状态里没有
        var accent: String? = nil
    }
}
