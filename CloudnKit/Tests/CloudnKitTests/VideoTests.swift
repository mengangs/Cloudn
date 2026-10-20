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

    func testBilibiliDashChoices() {
        let dash = JSON(text: #"""
        {"video":[
          {"id":120,"codecid":12,"bandwidth":20000,"baseUrl":"https://v/4k_hevc.m4s"},
          {"id":120,"codecid":13,"bandwidth":15000,"baseUrl":"https://v/4k_av1.m4s"},
          {"id":80,"codecid":12,"bandwidth":3000,"baseUrl":"https://v/1080_hevc.m4s"},
          {"id":80,"codecid":7,"bandwidth":4000,"baseUrl":"https://v/1080_avc.m4s"},
          {"id":64,"codecid":7,"bandwidth":2000,"base_url":"https://v/720_avc.m4s"}
        ],"audio":[{"id":30216,"bandwidth":64000,"baseUrl":"https://a/64.m4s"},{"id":30280,"bandwidth":192000,"baseUrl":"https://a/192.m4s"}]}
        """#)!
        let choices = BilibiliParser.dashChoices(dash)
        XCTAssertEqual(choices.map(\.quality), [120, 80, 64])
        XCTAssertEqual(choices.map(\.video), ["https://v/4k_hevc.m4s", "https://v/1080_avc.m4s", "https://v/720_avc.m4s"])
        XCTAssertEqual(choices.map(\.hevc), [true, false, false])
        XCTAssertEqual(Set(choices.map(\.audio)), ["https://a/192.m4s"])
        XCTAssertTrue(BilibiliParser.dashChoices(JSON(text: #"{"video":[],"audio":[]}"#)!).isEmpty)
    }

    func testDouyinQualities() {
        let list = JSON(text: #"""
        [{"bit_rate":900000,"is_bytevc1":0,"play_addr":{"width":720,"height":1280,"data_size":100,"url_list":["https://v/720.mp4"]}},
         {"bit_rate":2500000,"is_bytevc1":1,"play_addr":{"width":1080,"height":1920,"data_size":300,"url_list":["https://v/1080_hevc.mp4"]}},
         {"bit_rate":2000000,"is_bytevc1":0,"play_addr":{"width":1080,"height":1920,"data_size":400,"url_list":["https://v/playwm/1080.mp4"]}},
         {"bit_rate":1200000,"is_bytevc1":0,"play_addr":{"width":720,"height":1280,"data_size":150,"url_list":["https://v/720_hi.mp4"]}}]
        """#)!
        let q = DouyinParser.qualities(list.array)
        XCTAssertEqual(q.map(\.shortSide), [1080, 720])
        XCTAssertEqual(q.map(\.url), ["https://v/play/1080.mp4", "https://v/720_hi.mp4"])
        XCTAssertEqual(q.first?.label, "1080P")
        XCTAssertEqual(q.first?.size, 400)
        XCTAssertTrue(DouyinParser.qualities([]).isEmpty)
    }
}
