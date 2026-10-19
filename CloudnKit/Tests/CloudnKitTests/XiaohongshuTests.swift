import XCTest
@testable import CloudnKit

final class XiaohongshuTests: XCTestCase {
    func testLinkDetection() {
        let note = VideoLinkParser.parse("看看这篇 https://www.xiaohongshu.com/explore/66a1b2c3d4e5f6a7b8c9d0e1?xsec_token=AB12&xsec_source=pc_share 复制打开")
        XCTAssertEqual(note?.platform, .xiaohongshu)
        XCTAssertEqual(note?.id, "66a1b2c3d4e5f6a7b8c9d0e1")
        XCTAssertEqual(VideoLinkParser.parse("https://www.xiaohongshu.com/discovery/item/66a1b2c3d4e5f6a7b8c9d0e1")?.id,
                       "66a1b2c3d4e5f6a7b8c9d0e1")
        let short = VideoLinkParser.parse("【小红书】好看 http://xhslink.com/a/AbCdEf，复制本条信息")
        XCTAssertEqual(short?.platform, .xiaohongshu)
        XCTAssertTrue(short?.isShortLink ?? false)
        XCTAssertEqual(short?.url, "https://xhslink.com/a/AbCdEf")
        XCTAssertEqual(VideoPlatform.xiaohongshu.accountKind, .xiaohongshu)
        XCTAssertFalse(AccountKind.xiaohongshu.isDrive)
    }

    func testQueryAndLoginWall() {
        XCTAssertEqual(XiaohongshuParser.query(of: "https://www.xiaohongshu.com/explore/abc?xsec_token=T&x=1#frag"), "?xsec_token=T&x=1")
        XCTAssertEqual(XiaohongshuParser.query(of: "https://www.xiaohongshu.com/explore/abc"), "")
        XCTAssertTrue(XiaohongshuParser.isLoginWall("https://www.xiaohongshu.com/login?redirectPath=x"))
        XCTAssertTrue(XiaohongshuParser.isLoginWall("https://www.xiaohongshu.com/website-login/captcha?x=1"))
        XCTAssertFalse(XiaohongshuParser.isLoginWall("https://www.xiaohongshu.com/explore/abc"))
    }

    func testInitialStateWithUndefined() throws {
        let html = """
        <html><script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"abc":{"note":{"title":"标题","desc":"undefined 是正文",
        "video":undefined,"imageList":[{"urlDefault":"http://sns-webpic-qc.xhscdn.com/202501011200/0f5e9a/1040g2sg31abc!nd_dft_wlteh_webp_3"}],
        "user":{"nickname":"作者"}}}}},"extra":[undefined, 1]}</script></html>
        """
        let state = try XiaohongshuParser.initialState(html)
        let note = state["note"]["noteDetailMap"]["abc"]["note"]
        XCTAssertEqual(note["title"].string, "标题")
        // 字符串里的 undefined 不能被替换
        XCTAssertEqual(note["desc"].string, "undefined 是正文")
        XCTAssertTrue(note["video"].isNull)
        XCTAssertNil(XiaohongshuParser.pickVideo(note))
        XCTAssertEqual(XiaohongshuParser.rawImageURL(note["imageList"][0]),
                       "http://sns-webpic-qc.xhscdn.com/202501011200/0f5e9a/1040g2sg31abc!nd_dft_wlteh_webp_3")
        XCTAssertThrowsError(try XiaohongshuParser.initialState("<html>没有数据</html>"))
    }

    func testWatermarkFree() {
        XCTAssertEqual(XiaohongshuParser.watermarkFree("http://sns-webpic-qc.xhscdn.com/202501011200/0f5e9a/1040g2sg31abc!nd_dft_wlteh_webp_3"),
                       "https://sns-img-bd.xhscdn.com/1040g2sg31abc")
        XCTAssertEqual(XiaohongshuParser.watermarkFree("https://sns-webpic.xhscdn.com/202501/abcd/spectrum/1040g0k0xyz!nd_dft"),
                       "https://sns-img-bd.xhscdn.com/spectrum/1040g0k0xyz")
        // 没有足够的路径段：原样返回
        XCTAssertEqual(XiaohongshuParser.watermarkFree("https://a.com/x"), "https://a.com/x")
        XCTAssertEqual(XiaohongshuParser.watermarkFree(""), "")
    }

    func testPickVideoPriority() {
        let note = JSON(text: #"{"video":{"media":{"stream":{"h264":[{"masterUrl":"https://v/264.mp4"}],"h265":[{"master_url":"https://v/265.mp4"}]}}}}"#)!
        let v = XiaohongshuParser.pickVideo(note)
        XCTAssertEqual(v?.url, "https://v/265.mp4")
        XCTAssertEqual(v?.quality, "H.265")
        let only264 = JSON(text: #"{"video":{"media":{"stream":{"h265":[],"h264":[{"masterUrl":"https://v/264.mp4"}]}}}}"#)!
        XCTAssertEqual(XiaohongshuParser.pickVideo(only264)?.quality, "H.264")
    }
}
