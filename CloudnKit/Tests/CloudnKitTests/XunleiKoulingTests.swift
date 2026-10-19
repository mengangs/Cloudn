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

final class QuarkCommandTests: XCTestCase {
    func testLooksLikeCommand() {
        XCTAssertTrue(QuarkCommand.looksLikeCommand("绝对有效 咐置松君杂货铺叩苓"))
        XCTAssertFalse(QuarkCommand.looksLikeCommand("  "))
        XCTAssertFalse(QuarkCommand.looksLikeCommand("看这个 https://example.com/a"))
        XCTAssertFalse(QuarkCommand.looksLikeCommand(String(repeating: "字", count: 121)))
    }

    func testShareURL() {
        XCTAssertEqual(QuarkCommand.shareURL(platform: "uc", pwdId: "abc"), "https://drive.uc.cn/s/abc")
        XCTAssertEqual(QuarkCommand.shareURL(platform: "qk", pwdId: "abc"), "https://pan.quark.cn/s/abc")
        XCTAssertEqual(ShareLinkParser.parse(QuarkCommand.shareURL(platform: "UC", pwdId: "abc123"))?.platform, .uc)
        XCTAssertEqual(QuarkCommand.failureMessage(status: 429, server: ""), "口令解析服务繁忙，请稍后再试")
        XCTAssertEqual(QuarkCommand.failureMessage(status: 500, server: "口令已过期"), "口令已过期")
    }
}
