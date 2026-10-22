// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 批量解析（抖音 / 快手主页、YouTube 播放列表、SoundCloud 歌单…）的实时进度。
/// 翻页可能要几十秒：调用方用 `CollectionProgress.$current.withValue(reporter) { … }` 包住解析，
/// 各平台的翻页循环每拿到一页就报一次「已获取多少个（接口给了就带上总数）」，不用改解析器签名。
/// 界面从 `updates` 读进度（只留最新一条，消费慢了自动合并）；也可以 `requestStop()` 让循环提前收手、用已拿到的部分。
public final class CollectionProgress: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        /// 已获取的条目数（去重后）
        public let fetched: Int
        /// 总数：接口报告了才有
        public let total: Int?

        public init(fetched: Int, total: Int? = nil) {
            self.fetched = fetched
            self.total = total
        }
    }

    /// 当前解析任务的进度接收方；没有人关心进度时为 nil，报告即空操作
    @TaskLocal public static var current: CollectionProgress?

    /// 进度更新流：只缓存最新一条，单个消费者。`finish()` 后结束
    public let updates: AsyncStream<Snapshot>
    private let continuation: AsyncStream<Snapshot>.Continuation
    private let lock = NSLock()
    private var last: Snapshot?
    private var stopped = false

    public init() {
        (updates, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit { continuation.finish() }

    /// 最近一次报告的进度
    public var latest: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// 用户要求提前停止（翻页循环看到后不再取下一页，用已拿到的部分出结果）
    public var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    public func requestStop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    /// 报告进度。已获取数只增不减（换一种取法重来时不倒退）；总数缺省沿用上次的；没有变化不发
    public func report(fetched: Int, total: Int? = nil) {
        lock.lock()
        let count = max(fetched, last?.fetched ?? 0, 0)
        let known = total.flatMap { $0 > 0 ? $0 : nil } ?? last?.total
        let snapshot = Snapshot(fetched: count, total: known.map { max($0, count) })
        let changed = snapshot != last
        if changed { last = snapshot }
        lock.unlock()
        if changed { continuation.yield(snapshot) }
    }

    /// 解析结束：结束更新流（之后的报告仍记录在 latest，但不再发出）
    public func finish() {
        continuation.finish()
    }

    // MARK: 给翻页循环用的便捷入口（读当前任务的接收方）

    /// 向当前任务的接收方报告进度；没有接收方时什么也不做
    public static func report(fetched: Int, total: Int? = nil) {
        current?.report(fetched: fetched, total: total)
    }

    /// 当前任务的用户是否要求提前停止
    public static var isStopRequested: Bool {
        current?.isStopRequested ?? false
    }

    /// 隐藏浏览器里进度脚本（`ProfileCollectionJS.progressScript`）的返回值：
    /// 数字即已获取数；或 `{"fetched":N,"total":M}` 形式的 JSON 文本 / 字典。认不出就忽略
    public static func report(scriptValue value: Any?) {
        guard let progress = current, let snapshot = snapshot(fromScriptValue: value) else { return }
        progress.report(fetched: snapshot.fetched, total: snapshot.total)
    }

    static func snapshot(fromScriptValue value: Any?) -> Snapshot? {
        switch value {
        case let n as Int:
            return Snapshot(fetched: n)
        case let d as Double:
            return d.isFinite ? Snapshot(fetched: JSON(NSNumber(value: d)).int) : nil
        case let n as NSNumber:
            return n.doubleValue.isFinite ? Snapshot(fetched: JSON(n).int) : nil
        case let s as String:
            if let n = Int(s.trimmingCharacters(in: .whitespaces)) { return Snapshot(fetched: n) }
            guard let json = JSON(text: s), json.isObject else { return nil }
            return snapshot(json)
        case let dict as [String: Any]:
            return snapshot(JSON(dict))
        default:
            return nil
        }
    }

    private static func snapshot(_ json: JSON) -> Snapshot? {
        guard json.has("fetched") else { return nil }
        let total = json["total"].int
        return Snapshot(fetched: json["fetched"].int, total: total > 0 ? total : nil)
    }
}
