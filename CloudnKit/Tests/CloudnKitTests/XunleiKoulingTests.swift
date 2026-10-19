import XCTest
@testable import CloudnKit

final class XunleiKoulingTests: XCTestCase {
    func testLooksLikeKouling() {
        XCTAssertTrue(XunleiKouling.looksLikeKouling("张三丰资源"))
        XCTAssertTrue(XunleiKouling.looksLikeKouling("「张三丰资源2024」"))
        XCTAssertTrue(XunleiKouling.looksLikeKouling("  【口令】 "))
        // 纯英文 / 数字、带空格的整段文案、过长文本都不是口令
        XCTAssertFalse(XunleiKouling.looksLikeKouling("abc123"))
        XCTAssertFalse(XunleiKouling.looksLikeKouling("我用迅雷分享了 一个文件"))
        XCTAssertFalse(XunleiKouling.looksLikeKouling(String(repeating: "资", count: 65)))
        XCTAssertFalse(XunleiKouling.looksLikeKouling(""))
        XCTAssertEqual(XunleiKouling.normalize("「张三丰资源」！"), "张三丰资源")
    }

    func testJumpURLEncodesChinese() {
        let url = XunleiKouling.jumpURL("张三")
        XCTAssertTrue(url.contains("wd=%E5%BC%A0%E4%B8%89&"), url)
        XCTAssertNotNil(URL(string: url))
    }

    func testShareURLFromLocation() {
        let loc = "https://pan.xunlei.com/s/VNabc_12-x?pwd=k9zq&channel=x&from=kouling&wd=%E5%BC%A0"
        XCTAssertEqual(XunleiKouling.shareURL(fromLocation: loc), "https://pan.xunlei.com/s/VNabc_12-x?pwd=k9zq")
        XCTAssertEqual(XunleiKouling.shareURL(fromLocation: "https://pan.xunlei.com/s/VNabc"), "https://pan.xunlei.com/s/VNabc")
        XCTAssertNil(XunleiKouling.shareURL(fromLocation: "https://www.baidu.com/s?wd=x"))
        // 换出来的链接能被分享识别，且带上提取码
        let parsed = ShareLinkParser.parse(XunleiKouling.shareURL(fromLocation: loc)!)
        XCTAssertEqual(parsed?.platform, .xunlei)
        XCTAssertEqual(parsed?.pwd, "k9zq")
    }
}

