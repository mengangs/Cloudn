import XCTest
@testable import CloudnKit

final class LinkParserTests: XCTestCase {
    func testQuarkWithPwdInText() {
        let p = ShareLinkParser.parse("我用夸克网盘分享了「资料」，链接：https://pan.quark.cn/s/abc123XYZ 提取码：k9Fz")
        XCTAssertEqual(p?.platform, .quark)
        XCTAssertEqual(p?.shareId, "abc123XYZ")
        XCTAssertEqual(p?.pwd, "k9Fz")
    }

    func testUCWithPwdInURL() {
        let p = ShareLinkParser.parse("https://drive.uc.cn/s/0a1b2c3d?pwd=1234。")
        XCTAssertEqual(p?.platform, .uc)
        XCTAssertEqual(p?.shareId, "0a1b2c3d")
        XCTAssertEqual(p?.pwd, "1234")
    }

    func testBaiduStripsLeadingOne() {
        let p = ShareLinkParser.parse("https://pan.baidu.com/s/1AbCdEf_g?pwd=xy12")
        XCTAssertEqual(p?.platform, .baidu)
        XCTAssertEqual(p?.shareId, "AbCdEf_g")
    }

    func testILanzouNotConfusedWithLanzou() {
        XCTAssertEqual(ShareLinkParser.parse("https://www.ilanzou.com/s/AbC12")?.platform, .ilanzou)
        let l = ShareLinkParser.parse("https://wwi.lanzoui.com/iAbC12de 密码:ab12")
        XCTAssertEqual(l?.platform, .lanzou)
        XCTAssertEqual(l?.shareId, "iAbC12de")
        XCTAssertEqual(l?.pwd, "ab12")
    }

    func test115Command() {
        let p = ShareLinkParser.parse("https://115.com/sws8lxs36jf-n307/")
        XCTAssertEqual(p?.platform, .pan115)
        XCTAssertEqual(p?.shareId, "sws8lxs36jf")
        XCTAssertEqual(p?.pwd, "n307")
    }

    func test123() {
        XCTAssertEqual(ShareLinkParser.parse("https://www.123pan.com/s/2785Vv-T4Ded")?.shareId, "2785Vv-T4Ded")
    }

    func testNoURL() {
        XCTAssertNil(ShareLinkParser.parse("没有链接 提取码：1234"))
    }

    func testVideoDetection() {
        let d = VideoLinkParser.parse("7.94 复制打开抖音 https://v.douyin.com/iRNBho6u/ 看看")
        XCTAssertEqual(d?.platform, .douyin)
        XCTAssertTrue(d?.isShortLink ?? false)

        let b = VideoLinkParser.parse("https://www.bilibili.com/video/BV1GJ411x7h7?p=1")
        XCTAssertEqual(b?.platform, .bilibili)
        XCTAssertEqual(b?.id, "BV1GJ411x7h7")

        XCTAssertEqual(VideoLinkParser.parse("https://www.acfun.cn/v/ac12345678")?.id, "12345678")
        XCTAssertEqual(VideoLinkParser.parse("https://weibo.com/1234567/P5kWdcfDe")?.kind, "status")
        XCTAssertEqual(VideoLinkParser.parse("https://video.weibo.com/show?fid=1034:5145615399845897")?.id, "1034:5145615399845897")
    }

    func testDetectedInputRouting() {
        if case .video = DetectedInput.detect("https://b23.tv/abcDEF") {} else { XCTFail() }
        if case .share = DetectedInput.detect("https://pan.quark.cn/s/abc") {} else { XCTFail() }
        if case .direct(let u) = DetectedInput.detect("https://example.com/a.zip") { XCTAssertEqual(u, "https://example.com/a.zip") } else { XCTFail() }
    }

    func testCookieUtil() {
        let merged = CookieUtil.merge("a=1; __puus=old; __pus=p", with: [("__puus", "new"), ("x", "y")], tracked: ["__puus", "__pus"])
        XCTAssertEqual(merged, "a=1; __puus=new; __pus=p")
        XCTAssertEqual(CookieUtil.removing("__puus", from: merged), "a=1; __pus=p")
        let split = CookieUtil.splitSetCookieHeader("__pugs=abc; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT, b=2; Domain=.quark.cn")
        XCTAssertEqual(split.map { $0.0 }, ["__pugs", "b"])
        XCTAssertEqual(split.first?.1, "abc")
    }

    func testFileNames() {
        XCTAssertEqual(FileNames.sanitize("a/b:c?.mp4"), "a_b_c_.mp4")
        XCTAssertNil(FileNames.sanitizeRelativePath("../x"))
        XCTAssertEqual(FileNames.sanitizeRelativePath("dir/sub/f?.txt"), "dir/sub/f_.txt")
        XCTAssertEqual(ByteFormat.parseDisplay("1.5 M"), 1_572_864)
    }

    func testJSON() {
        let j = JSON(text: #"{"a":{"b":[1,"2",null]},"n":null,"t":true,"big":1234567890123}"#)!
        XCTAssertEqual(j["a"]["b"][0].int, 1)
        XCTAssertEqual(j["a"]["b"][1].string, "2")
        XCTAssertEqual(j["a"]["b"][2].string, "")
        XCTAssertEqual(j["n"].string, "")
        XCTAssertEqual(j["t"].string, "true")
        XCTAssertEqual(j["big"].string, "1234567890123")
        XCTAssertTrue(j["t"].bool)
    }
}
