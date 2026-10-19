import XCTest
@testable import CloudnKit

final class PixivTests: XCTestCase {
    func testLinks() {
        XCTAssertEqual(VideoLinkParser.parse("https://www.pixiv.net/artworks/12345678")?.id, "12345678")
        XCTAssertEqual(VideoLinkParser.parse("https://www.pixiv.net/en/artworks/987")?.platform, .pixiv)
        XCTAssertEqual(VideoLinkParser.parse("https://www.pixiv.net/member_illust.php?mode=medium&illust_id=555")?.id, "555")
        XCTAssertEqual(VideoPlatform.pixiv.accountKind, .pixiv)
        XCTAssertFalse(AccountKind.pixiv.isDrive)
    }

    func testHelpers() {
        XCTAssertEqual(PixivParser.ext("https://i.pximg.net/img-original/img/2024/01/01/00/00/00/123_p0.png"), "png")
        XCTAssertEqual(PixivParser.ext("https://i.pximg.net/x/123_p0"), "jpg")
        XCTAssertEqual(PixivParser.timestamp("2024-01-01T12:00:00+09:00"), 1_704_078_000)
        XCTAssertEqual(PixivParser.stripHTML("第一行<br />第二行 &amp; <a href=\"x\">链接</a>"), "第一行\n第二行 & 链接")
        XCTAssertEqual(PixivParser.mapError("Work not found", hasCookie: false).kind, .notFound)
        XCTAssertEqual(PixivParser.mapError("restricted", hasCookie: false).kind, .unsupported)
        XCTAssertEqual(PixivParser.mapError("restricted", hasCookie: true).kind, .blocked)
    }
}
