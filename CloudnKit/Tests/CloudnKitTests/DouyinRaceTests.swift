// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 抖音两条路线同时跑（隐藏浏览器 / 分享页）的取舍：离线，用延时模拟快慢
final class DouyinRaceTests: XCTestCase {
    private static func result(_ title: String, media: Bool = true) -> VideoParseResult {
        VideoParseResult(platform: .douyin, title: title,
                         medias: media ? [VideoMedia(url: "https://example.com/\(title).mp4", kind: .video, fileName: "\(title).mp4")] : [])
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testShareWinsWhenFaster() async throws {
        let web = Self.result("web"), share = Self.result("share")
        let start = Date()
        let r = try await DouyinParser.race(web: { await Self.sleep(5); return Task.isCancelled ? nil : web },
                                            share: { share })
        XCTAssertEqual(r.title, "share")
        // 浏览器那条被取消，不会等满 5 秒
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testWebWinsWhenFaster() async throws {
        let web = Self.result("web")
        let r = try await DouyinParser.race(web: { web },
                                            share: { await Self.sleep(5); try Task.checkCancellation(); return Self.result("share") })
        XCTAssertEqual(r.title, "web")
    }

    func testShareFailureWaitsForWeb() async throws {
        let web = Self.result("web")
        let r = try await DouyinParser.race(web: { await Self.sleep(0.2); return web },
                                            share: { throw VideoParseError(.blocked, "挑战页") })
        XCTAssertEqual(r.title, "web")
    }

    func testShareWithoutMediaWaitsForWeb() async throws {
        let web = Self.result("web")
        let r = try await DouyinParser.race(web: { await Self.sleep(0.2); return web },
                                            share: { Self.result("share", media: false) })
        XCTAssertEqual(r.title, "web")
    }

    func testWebFailureFallsBackToShareResult() async throws {
        let r = try await DouyinParser.race(web: { nil }, share: { await Self.sleep(0.2); return Self.result("share", media: false) })
        XCTAssertEqual(r.title, "share")
    }

    func testBothFailThrowsShareError() async {
        do {
            _ = try await DouyinParser.race(web: { nil }, share: { throw VideoParseError(.notFound, "已删除") })
            XCTFail("应该报错")
        } catch let error as VideoParseError {
            XCTAssertEqual(error.kind, .notFound)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
