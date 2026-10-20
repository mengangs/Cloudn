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
        // 正式版高于同号的预发布版；预发布版之间按后缀数字比较
        XCTAssertTrue(UpdateChecker.isNewer("1.3.0", than: "1.3.0-beta.2"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.3.0-beta.2", than: "1.3.0-beta.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3.0-beta.1", than: "1.3.0-beta.1"))
        XCTAssertEqual(UpdateChecker.parse(JSON(["tag_name": "v1.3.0-beta.1"])).tag, "1.3.0-beta.1")
    }

    func testParseRelease() {
        let json = JSON(["tag_name": "v1.2.0", "name": "", "body": "修复若干问题", "html_url": "https://github.com/mengangs/Cloudn/releases/tag/v1.2.0",
                         "assets": [["name": "notes.txt", "browser_download_url": "x"], ["name": "Cloudn.IPA", "browser_download_url": "https://e/Cloudn.ipa"]]])
        let r = UpdateChecker.parse(json)
        XCTAssertEqual(r.version, "1.2.0")
        XCTAssertEqual(r.name, "v1.2.0")
        XCTAssertEqual(r.ipaURL, "https://e/Cloudn.ipa")
        XCTAssertEqual(r.notes, "修复若干问题")
        XCTAssertFalse(r.isPrerelease)
    }

    func testNewestRespectsPrerelease() {
        let list = [
            UpdateChecker.parse(JSON(["tag_name": "v1.3.0-beta.1", "prerelease": true])),
            UpdateChecker.parse(JSON(["tag_name": "v1.2.1", "prerelease": false])),
            UpdateChecker.parse(JSON(["tag_name": "v1.10.0", "prerelease": true]))
        ]
        XCTAssertEqual(UpdateChecker.newest(list, includePrerelease: false)?.version, "1.2.1")
        XCTAssertEqual(UpdateChecker.newest(list, includePrerelease: true)?.version, "1.10.0")
    }
}
