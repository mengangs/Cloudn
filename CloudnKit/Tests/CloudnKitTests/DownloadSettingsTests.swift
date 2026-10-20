import XCTest
@testable import CloudnKit

final class DownloadSettingsTests: XCTestCase {
    func testRateLimiter() {
        let limiter = RateLimiter()
        let now = Date()
        XCTAssertEqual(limiter.reserve(1_000_000, now: now), 0)   // 不限速
        limiter.setLimit(1000)
        // 1000 B/s：起步有 1 秒额度（1000 字节免等），之后每 500 字节多等 0.5 秒
        XCTAssertEqual(limiter.reserve(500, now: now), 0, accuracy: 0.01)
        XCTAssertEqual(limiter.reserve(500, now: now), 0, accuracy: 0.01)
        XCTAssertEqual(limiter.reserve(500, now: now), 0.5, accuracy: 0.01)
        XCTAssertEqual(limiter.reserve(500, now: now), 1.0, accuracy: 0.01)
        // 空闲很久之后不攒额度：最多只抵扣 1 秒
        XCTAssertEqual(limiter.reserve(1000, now: now.addingTimeInterval(100)), 0, accuracy: 0.01)
        XCTAssertEqual(limiter.reserve(1000, now: now.addingTimeInterval(100)), 1, accuracy: 0.01)
    }

    func testConnectionsBySource() {
        let s = DownloadSettings(connectionsPerTask: 8, connectionsBySource: ["百度网盘": 2])
        XCTAssertEqual(s.connections(for: "百度网盘"), 2)
        XCTAssertEqual(s.connections(for: "夸克网盘"), 8)
        // 没单独设置时百度、115 默认封顶 2 条；用户单独设置优先
        let d = DownloadSettings(connectionsPerTask: 8)
        XCTAssertEqual(d.connections(for: "百度网盘"), 2)
        XCTAssertEqual(d.connections(for: "115 网盘"), 2)
        XCTAssertEqual(DownloadSettings(connectionsPerTask: 1).connections(for: "115 网盘"), 1)
        XCTAssertEqual(DownloadSettings(connectionsPerTask: 8, connectionsBySource: ["115 网盘": 6]).connections(for: "115 网盘"), 6)
    }

    func testResolverOptions() {
        let options = ResolverOptions()
        XCTAssertTrue(options.directFirst)
        options.directFirst = false
        XCTAssertFalse(ShareResolvers(credentials: NoCredentials(), options: options).options.directFirst)
    }

    func testLogRedactsQuery() {
        XCTAssertEqual(Log.redact("开始下载 https://cdn.x.com/a/b.mp4?sign=SECRET&t=1 结束"), "开始下载 https://cdn.x.com/a/b.mp4?… 结束")
        XCTAssertEqual(Log.redact("没有链接"), "没有链接")
    }

    func testOldItemDecodesWithoutNewFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","request":{"url":"https://a","headers":{},"fileName":"a","folder":"","kind":{"file":{}},"expectedSize":-1,"source":"x"},"status":"completed","totalBytes":1,"receivedBytes":1,"createdAt":0,"chunks":[],"phase":0,"segmentsDone":0,"segmentsTotal":0}"#
        let item = try JSONDecoder().decode(DownloadItem.self, from: Data(json.utf8))
        XCTAssertFalse(item.backgrounded)
        XCTAssertNil(item.exportedTo)
        XCTAssertNil(item.request.group)
    }

    func testNetworkProxyValidation() {
        XCTAssertTrue(NetworkProxy(kind: .http, host: "127.0.0.1", port: 7890).isValid)
        XCTAssertFalse(NetworkProxy(kind: .socks5, host: "  ", port: 1080).isValid)
        XCTAssertFalse(NetworkProxy(kind: .http, host: "127.0.0.1", port: 0).isValid)
        XCTAssertFalse(NetworkProxy(kind: .http, host: "127.0.0.1", port: 70000).isValid)
        // 填写不完整的代理不生效，也不触发会话重建
        let before = NetworkProxy.generation
        NetworkProxy.current = NetworkProxy(kind: .http, host: "", port: 7890)
        XCTAssertNil(NetworkProxy.current)
        XCTAssertEqual(NetworkProxy.generation, before)
    }
}
