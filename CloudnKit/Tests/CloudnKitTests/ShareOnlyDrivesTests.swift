import XCTest
@testable import CloudnKit

/// 城通网盘：链接识别、请求构造与响应解析（不联网）
final class ShareOnlyDrivesTests: XCTestCase {
    // MARK: 城通网盘

    func testCtFileLinks() throws {
        let file = try XCTUnwrap(CtFileResolver.shareTarget("https://url94.ctfile.com/f/64115194-17569800420720-06c697?p=7609"))
        XCTAssertEqual(file.id, "64115194-17569800420720-06c697")
        XCTAssertEqual(file.pwd, "7609")
        XCTAssertEqual(CtFileResolver.pathKind("https://url94.ctfile.com/f/64115194-1-a"), "f")

        let dir = try XCTUnwrap(CtFileResolver.shareTarget("https://url94.ctfile.com/d/64115194-164803691-48508c?p=7609&d=164803691&fk=decb36"))
        XCTAssertEqual(dir.id, "64115194-164803691-48508c")
        XCTAssertEqual(CtFileResolver.pathKind("https://url94.ctfile.com/d/64115194-164803691-48508c"), "d")

        XCTAssertEqual(CtFileResolver.shareTarget("https://545c.com/file/12345-67890")?.id, "12345-67890")
        XCTAssertEqual(CtFileResolver.pathKind("https://545c.com/file/12345-67890"), "file")
        XCTAssertNotNil(CtFileResolver.shareTarget("http://u062.com/f/1-2"))
        XCTAssertNotNil(CtFileResolver.shareTarget("https://089u.com/f/1-2"))
        XCTAssertNotNil(CtFileResolver.shareTarget("https://474b.com/f/1-2"))
        XCTAssertNil(CtFileResolver.shareTarget("https://ctfile.com/f/nodash"))
        XCTAssertNil(CtFileResolver.shareTarget("https://notctfile.org/f/1-2"))

        let parsed = try XCTUnwrap(ShareLinkParser.parse("链接：https://url94.ctfile.com/f/64115194-1756-06c697 密码：7609"))
        XCTAssertEqual(parsed.platform, .ctfile)
        XCTAssertEqual(parsed.pwd, "7609")
    }

    func testCtFileDirectoryContextAndToken() {
        let url = "https://url94.ctfile.com/d/64115194-164803691-48508c?p=7609&d=164803691&fk=decb36"
        XCTAssertEqual(CtFileResolver.directoryContext(url: url, dirId: ""), .init(folderId: "164803691", folderKey: "decb36"))
        XCTAssertEqual(CtFileResolver.directoryContext(url: "https://ctfile.com/d/1-2-3", dirId: ""), .init(folderId: "undefined", folderKey: ""))
        XCTAssertEqual(CtFileResolver.directoryContext(url: url, dirId: "777:abc"), .init(folderId: "777", folderKey: "abc"))
        XCTAssertEqual(CtFileResolver.directoryContext(url: url, dirId: "777:"), .init(folderId: "777", folderKey: ""))

        let token = CtFileResolver.encodeToken(pwd: "7609", url: url)
        XCTAssertEqual(CtFileResolver.decodeToken(token).pwd, "7609")
        XCTAssertEqual(CtFileResolver.decodeToken(token).url, url)
        XCTAssertEqual(CtFileResolver.decodeToken(CtFileResolver.encodeToken(pwd: "", url: url)).pwd, "")
    }

    func testCtFileRows() throws {
        let fileRow = JSON(["<input type=\"checkbox\" value=\"f123456\">",
                            "<img alt=\"zip\" src=\"x\"><a href=\"#/f/64115194-17569-abc\">资料 &amp; 说明.zip</a>",
                            "12.5 MB", "2024-05-06"])
        let file = try XCTUnwrap(CtFileResolver.parseRow(fileRow, parent: ""))
        XCTAssertEqual(file.fid, "64115194-17569-abc")
        XCTAssertEqual(file.name, "资料 & 说明.zip")
        XCTAssertEqual(file.size, Int64(12.5 * 1024 * 1024))
        XCTAssertEqual(file.token, "https://ctfile.com/file/64115194-17569-abc")
        XCTAssertFalse(file.isDirectory)

        let folderRow = JSON(["<input value=\"d998\">", "<img alt=\"folder\"><a href=\"javascript:load_subdir(998, 'fk99')\">子目录</a>", "", "2024-05-06"])
        let folder = try XCTUnwrap(CtFileResolver.parseRow(folderRow, parent: ""))
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.fid, "998:fk99")

        let folderNoCall = JSON(["<input value='d42'>", "<img alt='folder'><a href='#'>旧目录</a>"])
        XCTAssertEqual(CtFileResolver.parseRow(folderNoCall, parent: "")?.fid, "42:")
        XCTAssertNil(CtFileResolver.parseRow(JSON(["x"]), parent: ""))

        let params = CtFileResolver.pageParams(start: 200, length: 200)
        XCTAssertTrue(params.contains("iDisplayStart=200&iDisplayLength=200"))
        XCTAssertTrue(params.contains("bSortable_0=false"))
        XCTAssertTrue(params.contains("bSortable_3=true"))
        XCTAssertTrue(params.hasSuffix("iSortingCols=1"))

        XCTAssertEqual(CtFileResolver.fileError(JSON(["code": 423])).message, "城通网盘提取码错误或缺失，请填写后重新解析")
        XCTAssertEqual(CtFileResolver.fileError(JSON(["code": 404])).message, "城通网盘分享不存在或已被删除")
        let headers = Dictionary(uniqueKeysWithValues: CtFileResolver.ajaxHeaders("https://url94.ctfile.com/f/1-2?p=1"))
        XCTAssertEqual(headers["Origin"], "https://url94.ctfile.com")
        XCTAssertEqual(headers["X-Requested-With"], "XMLHttpRequest")
        XCTAssertEqual(CtFileResolver.query([("url", "https://a.com/f/1?p=2")]), "url=https%3A%2F%2Fa.com%2Ff%2F1%3Fp%3D2")
    }
}
