import XCTest
@testable import CloudnKit

/// 分享有效期在各平台字段上的换算（参考 YunX §3.20：各家语义完全不同）
final class ShareExpiryTests: XCTestCase {
    private func days(_ d: Int) -> ShareExpiry { ShareExpiry(days: d) }

    func testOptionsAndLabels() {
        XCTAssertEqual(ShareExpiry.standard.map(\.days), [0, 1, 7, 30])
        XCTAssertEqual(ShareExpiry.pan115.map(\.days), [0, 1, 3, 7, 15])
        XCTAssertEqual(ShareExpiry.forever.label, "永久有效")
        XCTAssertEqual(days(7).label, "7 天")
        XCTAssertNoThrow(try days(3).require(in: ShareExpiry.pan115))
        XCTAssertThrowsError(try days(3).require(in: ShareExpiry.standard))
    }

    func testQuarkExpiredType() throws {
        XCTAssertEqual(try QuarkFamilyResolver.expiredType(.forever), 1)
        XCTAssertEqual(try QuarkFamilyResolver.expiredType(days(1)), 2)
        XCTAssertEqual(try QuarkFamilyResolver.expiredType(days(7)), 3)
        XCTAssertEqual(try QuarkFamilyResolver.expiredType(days(30)), 4)
        // 不认识的档位报错，不悄悄变成永久
        XCTAssertThrowsError(try QuarkFamilyResolver.expiredType(days(3)))
    }

    func testPan115Duration() {
        XCTAssertEqual(Pan115Resolver.shareDuration(.forever), "-1")
        XCTAssertEqual(Pan115Resolver.shareDuration(days(3)), "3")
        XCTAssertEqual(Pan115Resolver.shareDuration(days(15)), "15")
    }

    func testPan123Expiration() {
        XCTAssertEqual(Pan123Resolver.shareExpiration(.forever), "2099-12-12T08:00:00+08:00")
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(Pan123Resolver.shareExpiration(days(7), now: now, timeZone: shanghai), "2023-11-22T06:13:20+08:00")
        XCTAssertEqual(Pan123Resolver.shareExpiration(days(1), now: now, timeZone: TimeZone(identifier: "UTC")!), "2023-11-15T22:13:20+00:00")
    }

    func testC139PeriodOnlyWhenNotForever() {
        let files = [ShareFile(fid: "co1", name: "a", size: 1, isDirectory: false)]
        XCTAssertFalse(C139Resolver.outLinkBody(account: "1", files: files, name: "x").text.contains("\"period\""))
        XCTAssertTrue(C139Resolver.outLinkBody(account: "1", files: files, name: "x", days: 7).text
            .contains(#""periodUnit":1,"period":7,"viewerLst""#))
    }

    func testXunleiAndGuangYaDays() {
        XCTAssertTrue(XunleiResolver.shareBody(ids: ["a"], title: "t", days: 30).text.hasSuffix(#""expiration_days":"30"}"#))
        let files = [ShareFile(fid: "f", name: "a", size: 1, isDirectory: false)]
        XCTAssertTrue(GuangYaResolver.shareBody(files, code: "", days: 1).text.contains(#""validateDuration":1"#))
    }
}
