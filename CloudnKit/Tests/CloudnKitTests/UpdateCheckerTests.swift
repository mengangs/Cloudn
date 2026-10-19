import XCTest
@testable import CloudnKit

final class UpdateCheckerTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.10.0", than: "1.9.3"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.0-beta", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "1.0.0"))
    }

    func testParseRelease() {
        let json = JSON(["tag_name": "v1.2.0", "name": "", "body": "修复若干问题", "html_url": "https://github.com/mengangs/Cloudn/releases/tag/v1.2.0",
                         "assets": [["name": "notes.txt", "browser_download_url": "x"], ["name": "Cloudn.IPA", "browser_download_url": "https://e/Cloudn.ipa"]]])
        let r = UpdateChecker.parse(json)
        XCTAssertEqual(r.version, "1.2.0")
        XCTAssertEqual(r.name, "v1.2.0")
        XCTAssertEqual(r.ipaURL, "https://e/Cloudn.ipa")
        XCTAssertEqual(r.notes, "修复若干问题")
    }
}
