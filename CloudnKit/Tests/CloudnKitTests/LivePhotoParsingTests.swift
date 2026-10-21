import XCTest
@testable import CloudnKit

/// 实况图：视频部分与图片同名加 _live 后缀（离线）
final class LivePhotoParsingTests: XCTestCase {
    func testXiaohongshuLiveVideoURL() throws {
        let item = try XCTUnwrap(JSON(text: #"{"urlDefault":"http://sns-webpic-qc.xhscdn.com/a/b!nd_dft","livePhoto":true,"stream":{"h265":[{"masterUrl":"http://sns-video-bd.xhscdn.com/h265.mp4"}],"h264":[{"masterUrl":"http://sns-video-bd.xhscdn.com/h264.mp4"}]}}"#))
        XCTAssertEqual(XiaohongshuParser.liveVideoURL(item), "http://sns-video-bd.xhscdn.com/h264.mp4")
        let plain = try XCTUnwrap(JSON(text: #"{"urlDefault":"http://sns-webpic-qc.xhscdn.com/a/c!nd_dft","livePhoto":false}"#))
        XCTAssertEqual(XiaohongshuParser.liveVideoURL(plain), "")
    }

    func testDouyinLiveMedia() throws {
        let media = try XCTUnwrap(DouyinParser.liveMedia("https://aweme.snssdk.com/aweme/v1/playwm/?video_id=v1", stem: "作品_2", headers: [:]))
        XCTAssertEqual(media.fileName, "作品_2_live.mp4")
        XCTAssertEqual(media.kind, .video)
        XCTAssertEqual(media.quality, "实况")
        XCTAssertFalse(media.url.contains("playwm"))
        XCTAssertNil(DouyinParser.liveMedia("", stem: "x", headers: [:]))
    }
}
