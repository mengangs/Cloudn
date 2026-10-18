import XCTest
@testable import CloudnKit

final class VideoTests: XCTestCase {
    func testMid2id() {
        XCTAssertEqual(WeiboParser.mid2id("3501756485200075"), "z0JH2lOMb")
    }

    func testKuaishouAtlas() {
        let atlas = JSON(text: #"{"cdnList":[{"cdn":"p1.a.yximgs.com"}],"list":["/ufile/atlas/a.jpg","/ufile/atlas/b.jpg"]}"#)!
        XCTAssertEqual(KuaishouParser.atlasImages(atlas).count, 2)
        let state = JSON(text: #"{"x":{"foo":1},"y":{"photo":{"caption":"hi","mainMvUrls":[{"url":"https://v/a.mp4"}]}}}"#)!
        XCTAssertEqual(KuaishouParser.findPhoto(state)?["caption"].string, "hi")
    }

    func testInlineJSON() {
        let html = "<script>window.INIT_STATE = {\"a\":1};</script>"
        XCTAssertEqual(VideoHTTP.extractInlineJSON(html, key: "window.INIT_STATE"), "{\"a\":1}")
    }

    func testAcFunDecode() {
        let info = JSON(text: #"{"title":"t","currentVideoInfo":{"ksPlayJson":"{\"adaptationSet\":[{\"representation\":[{\"url\":\"https://x/1080.m3u8\",\"qualityLabel\":\"1080P\"},{\"url\":\"https://x/720.m3u8\"}]}]}"}}"#)!
        XCTAssertEqual(AcFunParser.pickM3U8(info)?.url, "https://x/1080.m3u8")
        XCTAssertEqual(AcFunParser.pickM3U8(info)?.quality, "1080P")
    }

    func testSecureURL() {
        XCTAssertEqual(VideoHTTP.secureURL("http://a/b"), "https://a/b")
        XCTAssertEqual(VideoHTTP.secureURL("//a/b"), "https://a/b")
    }

    func testWeiboRank() {
        XCTAssertGreaterThan(WeiboParser.resolutionRank("高清 1080P"), WeiboParser.resolutionRank("标清 480P"))
    }
}
