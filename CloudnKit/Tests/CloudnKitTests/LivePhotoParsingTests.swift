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

    func testDouyinLiveVideoSearch() throws {
        let item = try XCTUnwrap(JSON(text: #"{"url_list":["https://p9-pc-sign.douyinpic.com/tos-cn-i-0813c000-ce/abc~noop.jpeg?x=1"],"download_url_list":["https://p3.douyinpic.com/abc~tplv-dy-aweme-images:q75.jpeg"],"clip_type":5,"video":{"cover":{"url_list":["https://p3.douyinpic.com/cover.jpeg"]},"play_addr":{"uri":"v0d00","url_list":["https://v3-web.douyinvod.com/abc/video/tos/cn/mp4?a=1"]}}}"#))
        XCTAssertEqual(DouyinParser.liveVideoURL(in: item), "https://v3-web.douyinvod.com/abc/video/tos/cn/mp4?a=1")
        let other = try XCTUnwrap(JSON(text: #"{"urlList":["https://p3.douyinpic.com/a.webp"],"liveVideo":{"playAddr":[{"src":"https://www.douyin.com/aweme/v1/play/?video_id=v1&ratio=1080p"}]}}"#))
        XCTAssertEqual(DouyinParser.liveVideoURL(in: other), "https://www.douyin.com/aweme/v1/play/?video_id=v1&ratio=1080p")
        let plain = try XCTUnwrap(JSON(text: #"{"url_list":["https://p3.douyinpic.com/a~noop.jpeg"]}"#))
        XCTAssertEqual(DouyinParser.liveVideoURL(in: plain), "")
    }
}

/// 抖音原画：只在比列表最高档大（或那档大小未知）时提到最前
final class DouyinOriginalTests: XCTestCase {
    func testShouldPromote() {
        XCTAssertTrue(DouyinParser.shouldPromote(original: 120_000_000, top: 30_000_000))
        XCTAssertTrue(DouyinParser.shouldPromote(original: 30_000_000, top: -1))
        // 超分档比原文件大（jiji262 记录的反例）：不提
        XCTAssertFalse(DouyinParser.shouldPromote(original: 31_700_000, top: 47_400_000))
        XCTAssertFalse(DouyinParser.shouldPromote(original: 0, top: -1))
    }
}

/// 抖音按「昵称_抖音号_发布时间」命名：只替换文件名开头的主干，后缀保留
final class AuthorStyledNameTests: XCTestCase {
    func testRename() {
        let r = VideoParseResult(platform: .douyin, title: "下雨落叶", author: "小米粒", timestamp: 1_792_540_748,
                                 authorID: "xmlsy123", fileBase: "下雨落叶")
        XCTAssertEqual(r.authorStyledName("下雨落叶.mp4"), "小米粒_xmlsy123_2026-10-21_07-59-08.mp4")
        XCTAssertEqual(r.authorStyledName("下雨落叶_2_live.mp4"), "小米粒_xmlsy123_2026-10-21_07-59-08_2_live.mp4")
        XCTAssertEqual(r.authorStyledName("别的.mp4"), "别的.mp4")
        let noTime = VideoParseResult(platform: .douyin, title: "t", author: "a", fileBase: "t")
        XCTAssertEqual(noTime.authorStyledName("t.mp4"), "t.mp4")
    }
}
