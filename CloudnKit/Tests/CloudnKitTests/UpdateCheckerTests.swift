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

/// 「网盘更新」：从发布说明里认出网盘分享、在分享里找安装包
final class UpdatePackageTests: XCTestCase {
    func testSharesInReleaseNotes() {
        let notes = """
        ## 更新内容
        - 修复若干问题
        夸克网盘：https://pan.quark.cn/s/abc123def 提取码：x1y2
        百度 https://pan.baidu.com/s/1AbCdEf?pwd=ab12 ｜ 蓝奏 https://wwi.lanzoup.com/iXyz123
        提取码：9z9z 迅雷：https://pan.xunlei.com/s/VNabcdef
        重复：https://pan.quark.cn/s/abc123def
        """
        let shares = UpdatePackage.shares(in: notes)
        XCTAssertEqual(shares.map(\.platform), [.quark, .baidu, .lanzou, .xunlei])
        XCTAssertEqual(shares[0].pwd, "x1y2")
        XCTAssertEqual(shares[1].pwd, "ab12")
        XCTAssertNil(shares[2].pwd)
        XCTAssertEqual(shares[3].pwd, "9z9z")
        XCTAssertTrue(UpdatePackage.shares(in: "只有 GitHub：https://github.com/mengangs/Cloudn").isEmpty)
    }

    func testFindLargestIPAAcrossFolders() async throws {
        let resolver = FakeTreeResolver(tree: [
            "0": [ShareFile(fid: "readme", name: "说明.txt", size: 10, isDirectory: false),
                  ShareFile(fid: "d1", name: "旧版本", size: 0, isDirectory: true),
                  ShareFile(fid: "d2", name: "1.4.0", size: 0, isDirectory: true)],
            "d1": [ShareFile(fid: "old", name: "Cloudn-1.3.ipa", size: 900, isDirectory: false)],
            "d2": [ShareFile(fid: "new", name: "Cloudn-1.4.IPA", size: 1000, isDirectory: false),
                   ShareFile(fid: "apk", name: "other.apk", size: 5000, isDirectory: false)]
        ])
        let session = ShareSession(platform: .quark, shareId: "s", stoken: "", title: "t")
        let found = try await UpdatePackage.findPackage(resolver: resolver, session: session)
        XCTAssertEqual(found?.fid, "new")
        let none = try await UpdatePackage.findPackage(resolver: FakeTreeResolver(tree: ["0": []]), session: session)
        XCTAssertNil(none)
    }
}

private struct FakeTreeResolver: ShareResolver {
    let tree: [String: [ShareFile]]
    var platform: SharePlatform { .quark }
    var supportsGuestDownload: Bool { true }
    func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        ShareSession(platform: .quark, shareId: share.shareId, stoken: "", title: "")
    }
    func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] { tree[dirId] ?? [] }
    func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink { throw CloudnError("unused") }
}
