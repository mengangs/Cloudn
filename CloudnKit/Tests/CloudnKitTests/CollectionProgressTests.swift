// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 批量解析的实时进度：接收方本身、任务局部值的传递、各平台翻页循环（离线，假数据源）
final class CollectionProgressTests: XCTestCase {
    private func json(_ text: String) -> JSON {
        guard let j = JSON(text: text) else {
            XCTFail("fixture 不是合法 JSON")
            return JSON(nil)
        }
        return j
    }

    // MARK: 接收方

    func testReportIsMonotonicAndKeepsTotal() {
        let progress = CollectionProgress()
        XCTAssertNil(progress.latest)
        progress.report(fetched: 10)
        XCTAssertEqual(progress.latest, .init(fetched: 10))
        // 换一种取法重来时不倒退
        progress.report(fetched: 4)
        XCTAssertEqual(progress.latest, .init(fetched: 10))
        progress.report(fetched: 20, total: 356)
        XCTAssertEqual(progress.latest, .init(fetched: 20, total: 356))
        // 没带总数沿用上次的；0 不算总数
        progress.report(fetched: 30)
        XCTAssertEqual(progress.latest, .init(fetched: 30, total: 356))
        progress.report(fetched: 31, total: 0)
        XCTAssertEqual(progress.latest, .init(fetched: 31, total: 356))
        // 实际拿到的比报告的总数多（总数不含隐藏项等）：总数跟上
        progress.report(fetched: 400)
        XCTAssertEqual(progress.latest, .init(fetched: 400, total: 400))
    }

    func testUpdatesKeepNewestAndFinish() async {
        let progress = CollectionProgress()
        for n in 1...50 { progress.report(fetched: n, total: 50) }
        progress.report(fetched: 50, total: 50) // 没有变化不发
        progress.finish()
        var received: [CollectionProgress.Snapshot] = []
        for await s in progress.updates { received.append(s) }
        // 消费者没跟上：只留下最新一条，流在 finish 后结束
        XCTAssertEqual(received, [.init(fetched: 50, total: 50)])
        // 结束后的报告仍记录，但不再发出
        progress.report(fetched: 60)
        XCTAssertEqual(progress.latest?.fetched, 60)
    }

    func testUpdatesDeliverIncreasingCountsToLiveConsumer() async {
        let progress = CollectionProgress()
        let consumer = Task { () -> [Int] in
            var seen: [Int] = []
            for await s in progress.updates { seen.append(s.fetched) }
            return seen
        }
        for n in stride(from: 18, through: 180, by: 18) {
            progress.report(fetched: n)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        progress.finish()
        let seen = await consumer.value
        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(Set(seen).count, seen.count)
        XCTAssertEqual(seen.last, 180)
    }

    func testCancelledConsumerDoesNotHang() async {
        let progress = CollectionProgress()
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in progress.updates { count += 1 }
            return count
        }
        progress.report(fetched: 1)
        consumer.cancel()
        // 没有 finish：取消消费者本身就能让 for await 结束
        _ = await consumer.value
        progress.report(fetched: 2)
        XCTAssertEqual(progress.latest?.fetched, 2)
    }

    func testTaskLocalReachesChildTasksAndIsOptional() async {
        // 没有接收方时报告是空操作
        CollectionProgress.report(fetched: 5)
        XCTAssertFalse(CollectionProgress.isStopRequested)

        let progress = CollectionProgress()
        await CollectionProgress.$current.withValue(progress) {
            await withTaskGroup(of: Void.self) { group in
                for n in [3, 9, 6] {
                    group.addTask { CollectionProgress.report(fetched: n, total: 12) }
                }
            }
            XCTAssertFalse(CollectionProgress.isStopRequested)
            progress.requestStop()
            XCTAssertTrue(CollectionProgress.isStopRequested)
        }
        XCTAssertEqual(progress.latest, .init(fetched: 9, total: 12))
        XCTAssertNil(CollectionProgress.current)
    }

    func testScriptValues() {
        XCTAssertEqual(CollectionProgress.snapshot(fromScriptValue: 12), .init(fetched: 12))
        XCTAssertEqual(CollectionProgress.snapshot(fromScriptValue: 12.0), .init(fetched: 12))
        XCTAssertEqual(CollectionProgress.snapshot(fromScriptValue: NSNumber(value: 7)), .init(fetched: 7))
        XCTAssertNil(CollectionProgress.snapshot(fromScriptValue: Double.infinity))
        XCTAssertEqual(CollectionProgress.snapshot(fromScriptValue: " 40 "), .init(fetched: 40))
        XCTAssertEqual(CollectionProgress.snapshot(fromScriptValue: #"{"fetched":3,"total":9}"#), .init(fetched: 3, total: 9))
        XCTAssertEqual(CollectionProgress.snapshot(fromScriptValue: ["fetched": 4, "total": 0] as [String: Any]), .init(fetched: 4))
        XCTAssertNil(CollectionProgress.snapshot(fromScriptValue: nil))
        XCTAssertNil(CollectionProgress.snapshot(fromScriptValue: "abc"))
        XCTAssertNil(CollectionProgress.snapshot(fromScriptValue: #"{"total":9}"#))
    }

    // MARK: 快手主页翻页

    /// 第 i 页（从 0 起）：每页 size 个作品，最后一页 pcursor 为 no_more；第二页带一个与第一页重复的作品
    private func kuaishouPage(_ i: Int, pages: Int, size: Int = 18) -> JSON {
        var ids = (0..<size).map { "3x\(i)_\($0)" }
        if i == 1 { ids[0] = "3x0_0" }
        let feeds = ids.map { #"{"photo":{"id":"\#($0)","caption":"c","duration":1000,"coverUrl":"u"},"author":{"name":"作者"}}"# }
        let cursor = i == pages - 1 ? "no_more" : "cursor\(i + 1)"
        return json(#"{"data":{"visionProfilePhotoList":{"result":1,"pcursor":"\#(cursor)","feeds":[\#(feeds.joined(separator: ","))]}}}"#)
    }

    func testKuaishouPagingReportsIncreasingCounts() async {
        let progress = CollectionProgress()
        var cursors: [String] = []
        var seenBeforeFetch: [Int] = []
        let pages = await CollectionProgress.$current.withValue(progress) {
            await KuaishouParser.collectProfilePages { cursor in
                cursors.append(cursor)
                seenBeforeFetch.append(progress.latest?.fetched ?? 0)
                let index = cursors.count - 1
                return self.kuaishouPage(index, pages: 4)
            }
        }
        XCTAssertEqual(pages.count, 4)
        XCTAssertEqual(cursors, ["", "cursor1", "cursor2", "cursor3"])
        // 每页报一次去重后的数（第二页有一个重复）
        XCTAssertEqual(seenBeforeFetch, [0, 18, 35, 53])
        XCTAssertEqual(progress.latest, .init(fetched: 71))
        XCTAssertEqual(KuaishouParser.profilePosts(pages).entries.count, 71)
    }

    func testKuaishouPagingStopsOnRequestAndFailure() async {
        let progress = CollectionProgress()
        var calls = 0
        let pages = await CollectionProgress.$current.withValue(progress) {
            await KuaishouParser.collectProfilePages { _ in
                calls += 1
                if calls == 2 { progress.requestStop() }
                return self.kuaishouPage(calls - 1, pages: 10)
            }
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(progress.latest?.fetched, 35)
        XCTAssertTrue(KuaishouParser.profilePosts(pages).hasMore)

        // 请求失败 / 要求验证即停，没有接收方也照常工作
        var failing = 0
        let partial = await KuaishouParser.collectProfilePages { _ in
            failing += 1
            return failing == 1 ? self.kuaishouPage(0, pages: 3)
                : self.json(#"{"errors":[{"message":"Need captcha"}],"data":{"visionProfilePhotoList":null}}"#)
        }
        XCTAssertEqual(failing, 2)
        XCTAssertEqual(partial.count, 1)
    }

    func testKuaishouPagingStopsAtLimit() async {
        let progress = CollectionProgress()
        var calls = 0
        let pages = await CollectionProgress.$current.withValue(progress) {
            await KuaishouParser.collectProfilePages { _ in
                calls += 1
                return self.kuaishouPage(calls - 1 + 10, pages: 1000, size: 100)
            }
        }
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(progress.latest?.fetched, ProfileCollectionJS.maxItems)
    }

    // MARK: 抖音主页（隐藏浏览器）

    /// 假的隐藏浏览器：带进度的版本按顺序报几次脚本返回值，再返回汇总好的作品列表
    private struct FakeExtractor: WebPageExtractor {
        let scriptValues: [Int]
        let payload: String
        let recorder: Recorder

        final class Recorder: @unchecked Sendable {
            var progressScript: String?
            var stopSeen = false
        }

        func extract(url: String, userAgent: String, cookie: String, documentStartScripts: [String],
                     readyScript: String, extractScript: String, timeout: TimeInterval) async -> String? {
            XCTFail("批量应走带进度的 extract")
            return nil
        }

        func extract(url: String, userAgent: String, cookie: String, documentStartScripts: [String],
                     readyScript: String, progressScript: String, extractScript: String, timeout: TimeInterval) async -> String? {
            recorder.progressScript = progressScript
            for value in scriptValues {
                CollectionProgress.report(scriptValue: value)
                if CollectionProgress.isStopRequested {
                    recorder.stopSeen = true
                    break
                }
            }
            return payload
        }
    }

    private let secUID = "MS4wLjABAAAAv7iSuuXDJGDvJkmH_vz1qkDZYo1apxgzaxdBSeIuPiM"

    private func douyinPayload(count: Int, hasMore: Bool) -> String {
        let list = (0..<count).map { #"{"aweme_id":"73012345678901\#(String(format: "%05d", $0))","desc":"作品\#($0)","author":{"nickname":"测试用户"}}"# }
        return #"{"aweme_list":[\#(list.joined(separator: ","))],"has_more":\#(hasMore ? 1 : 0),"pages":3,"nickname":"测试用户","pageTitle":""}"#
    }

    func testDouyinUserReportsBrowserProgress() async throws {
        let recorder = FakeExtractor.Recorder()
        let extractor = FakeExtractor(scriptValues: [0, 18, 36, 54], payload: douyinPayload(count: 54, hasMore: false),
                                      recorder: recorder)
        let link = DetectedVideoLink(platform: .douyin, kind: "user", id: secUID, url: DouyinParser.userPageURL(secUID))
        let progress = CollectionProgress()
        let result = try await CollectionProgress.$current.withValue(progress) {
            try await DouyinParser(extractor: extractor).parseUser(link, cookie: "")
        }
        XCTAssertEqual(recorder.progressScript, ProfileCollectionJS.progressScript)
        XCTAssertEqual(progress.latest, .init(fetched: 54))
        XCTAssertEqual(result.entries.count, 54)
        XCTAssertEqual(result.notice, "")
    }

    func testDouyinUserStoppedEarlyKeepsWhatWasFetched() async throws {
        let recorder = FakeExtractor.Recorder()
        let extractor = FakeExtractor(scriptValues: [18, 36, 54], payload: douyinPayload(count: 36, hasMore: true), recorder: recorder)
        let link = DetectedVideoLink(platform: .douyin, kind: "user", id: secUID, url: DouyinParser.userPageURL(secUID))
        let progress = CollectionProgress()
        progress.requestStop()
        let result = try await CollectionProgress.$current.withValue(progress) {
            try await DouyinParser(extractor: extractor).parseUser(link, cookie: "")
        }
        XCTAssertTrue(recorder.stopSeen)
        XCTAssertEqual(result.entries.count, 36)
        XCTAssertEqual(result.notice, ProfileCollectionJS.stoppedNotice(36))
        XCTAssertEqual(result.title, "测试用户 的作品")
    }

    // MARK: YouTube 播放列表总数

    func testYouTubePlaylistVideoCount() {
        let oldHeader = json(#"{"header":{"playlistHeaderRenderer":{"numVideosText":{"runs":[{"text":"1,234"},{"text":" videos"}]}}}}"#)
        XCTAssertEqual(YouTubeParser.playlistVideoCount(oldHeader), 1234)
        let stats = json(#"{"header":{"playlistHeaderRenderer":{"stats":[{"runs":[{"text":"356"},{"text":" videos"}]},{"simpleText":"1,000 views"}]}}}"#)
        XCTAssertEqual(YouTubeParser.playlistVideoCount(stats), 356)
        let sidebar = json(#"{"sidebar":{"playlistSidebarRenderer":{"items":[{"playlistSidebarPrimaryInfoRenderer":{"stats":[{"runs":[{"text":"1"},{"text":" video"}]}]}}]}}}"#)
        XCTAssertEqual(YouTubeParser.playlistVideoCount(sidebar), 1)
        let pageHeader = json(#"""
        {"header":{"pageHeaderRenderer":{"content":{"pageHeaderViewModel":{"metadata":{"contentMetadataViewModel":{"metadataRows":[
          {"metadataParts":[{"text":{"content":"by Bob"}}]},{"metadataParts":[{"text":{"content":"Playlist"}},{"text":{"content":"12 videos"}},{"text":{"content":"3 views"}}]}]}}}}}}}
        """#)
        XCTAssertEqual(YouTubeParser.playlistVideoCount(pageHeader), 12)
        XCTAssertNil(YouTubeParser.playlistVideoCount(json(#"{"header":{"playlistHeaderRenderer":{"title":{"simpleText":"x"}}}}"#)))
        XCTAssertNil(YouTubeParser.playlistVideoCount(json(#"{"header":{"playlistHeaderRenderer":{"numVideosText":{"simpleText":"No videos"}}}}"#)))
    }

    // MARK: SoundCloud 歌单提前停止

    func testSoundCloudSetEntriesResolvedOnly() {
        let set = json(#"""
        {"tracks":[{"id":1,"title":"Full","permalink_url":"https://soundcloud.com/a/full"},{"id":2},{"id":3}]}
        """#)
        let fetched = ["2": json(#"{"id":2,"title":"Two","permalink_url":"https://soundcloud.com/a/two"}"#)]
        XCTAssertEqual(SoundCloudParser.setEntries(set, fetched: fetched).count, 3)
        XCTAssertEqual(SoundCloudParser.setEntries(set, fetched: fetched, resolvedOnly: true).map(\.title), ["Full", "Two"])
    }
}
