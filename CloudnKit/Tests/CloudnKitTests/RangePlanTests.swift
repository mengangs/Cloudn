import XCTest
@testable import CloudnKit

/// 下载前探测（Range: bytes=0-0）的响应如何定总长度
final class RangePlanTests: XCTestCase {
    func testPartialContentUsesContentRangeTotal() {
        let r = RangeTransfer.planTotal(status: 206, headers: ["content-range": "bytes 0-0/50855936", "content-length": "1"])
        XCTAssertEqual(r.total, 50_855_936)
        XCTAssertTrue(r.ranged)
    }

    /// 光鸭云盘：206 却不给 Content-Range，Content-Length 是这一段的 1 字节，不能当成文件总长
    func testPartialContentWithoutTotalIsUnknown() {
        let missing = RangeTransfer.planTotal(status: 206, headers: ["content-length": "1"])
        XCTAssertEqual(missing.total, -1)
        XCTAssertFalse(missing.ranged)
        let star = RangeTransfer.planTotal(status: 206, headers: ["content-range": "bytes 0-0/*", "content-length": "1"])
        XCTAssertEqual(star.total, -1)
        XCTAssertFalse(star.ranged)
    }

    func testFullResponseUsesContentLength() {
        let r = RangeTransfer.planTotal(status: 200, headers: ["content-length": "1024"])
        XCTAssertEqual(r.total, 1024)
        XCTAssertFalse(r.ranged)
        XCTAssertEqual(RangeTransfer.planTotal(status: 200, headers: [:]).total, -1)
    }

    func testSizeMismatch() {
        XCTAssertNotNil(DownloadEngine.sizeMismatch(expected: 50_855_936, actual: 1))
        XCTAssertNil(DownloadEngine.sizeMismatch(expected: 50_855_936, actual: 50_855_936))
        XCTAssertNil(DownloadEngine.sizeMismatch(expected: -1, actual: 1))
        XCTAssertNil(DownloadEngine.sizeMismatch(expected: 1000, actual: 1))
    }
}
