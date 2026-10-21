import XCTest
@testable import CloudnKit

/// 下载前探测（Range: bytes=0-0）的响应如何定总长度
final class RangePlanTests: XCTestCase {
    func testPartialContentUsesContentRangeTotal() throws {
        let r = try XCTUnwrap(RangeTransfer.planTotal(status: 206, headers: ["content-range": "bytes 0-0/50855936", "content-length": "1"]))
        XCTAssertEqual(r.total, 50_855_936)
        XCTAssertTrue(r.ranged)
    }

    /// 光鸭云盘这类不规范的分段回应都不可信，要不带 Range 再问
    func testUntrustedRangeResponses() {
        XCTAssertNil(RangeTransfer.planTotal(status: 206, headers: ["content-length": "1"]))
        XCTAssertNil(RangeTransfer.planTotal(status: 206, headers: ["content-range": "bytes 0-0/*"]))
        XCTAssertNil(RangeTransfer.planTotal(status: 206, headers: ["content-range": "bytes 0-0/1"]))
        XCTAssertNil(RangeTransfer.planTotal(status: 206, headers: ["content-range": "bytes 0-1023/50855936"]))
        XCTAssertNil(RangeTransfer.planTotal(status: 200, headers: ["content-length": "1"]))
        XCTAssertNil(RangeTransfer.planTotal(status: 206, headers: ["content-range": "bytes 0-0/9999", "content-type": "text/html; charset=utf-8"]))
    }

    func testPlainProbe() {
        XCTAssertEqual(RangeTransfer.plainTotal(status: 200, headers: ["content-length": "50855936"]), 50_855_936)
        XCTAssertEqual(RangeTransfer.plainTotal(status: 200, headers: [:]), -1)
        XCTAssertEqual(RangeTransfer.plainTotal(status: 200, headers: ["content-length": "512", "content-type": "text/html"]), -1)
    }

    func testSizeMismatch() {
        XCTAssertNotNil(DownloadEngine.sizeMismatch(expected: 50_855_936, actual: 1))
        XCTAssertNil(DownloadEngine.sizeMismatch(expected: 50_855_936, actual: 50_855_936))
        XCTAssertNil(DownloadEngine.sizeMismatch(expected: -1, actual: 1))
        XCTAssertNil(DownloadEngine.sizeMismatch(expected: 1000, actual: 1))
    }
}
