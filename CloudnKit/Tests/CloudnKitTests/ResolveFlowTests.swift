import XCTest
@testable import CloudnKit

/// 解析流程的小修正：大小探测、短链展开失败的分类、取消的传递、批量去重、实况照片配对
final class ResolveFlowTests: XCTestCase {
    func testRangeProbeSize() {
        XCTAssertEqual(MediaProbe.sizeFromRangeProbe(status: 206, headers: ["content-range": "bytes 0-0/12345", "content-length": "1"]), 12345)
        // 服务端忽略 Range：整个文件的长度
        XCTAssertEqual(MediaProbe.sizeFromRangeProbe(status: 200, headers: ["content-length": "999"]), 999)
        // 206 却没给总长：Content-Length 只是这一段，不能当大小
        XCTAssertNil(MediaProbe.sizeFromRangeProbe(status: 206, headers: ["content-range": "bytes 0-0/*", "content-length": "1"]))
        XCTAssertNil(MediaProbe.sizeFromRangeProbe(status: 200, headers: [:]))
        XCTAssertNil(MediaProbe.sizeFromRangeProbe(status: 404, headers: ["content-length": "999"]))
        XCTAssertNil(MediaProbe.sizeFromRangeProbe(status: 0, headers: [:]))
    }

    func testUnexpandedShortLink() {
        let short = DetectedVideoLink(platform: .douyin, kind: "short", id: "", url: "https://v.douyin.com/AbCd/")
        // 没展开出新地址：仍是「展开失败」
        let same = VideoParseService.unexpandedError(original: short, resolved: short)
        XCTAssertEqual(same?.kind, .unsupported)
        XCTAssertTrue(same?.detail.contains("短链展开失败") ?? false)
        XCTAssertNil(same?.sniffURL)

        // 展开到认不出的页面：不支持，附上终址供网页嗅探
        let landed = DetectedVideoLink(platform: .douyin, kind: "short", id: "", url: "https://live.douyin.com/123456")
        let other = VideoParseService.unexpandedError(original: short, resolved: landed)
        XCTAssertEqual(other?.kind, .unsupported)
        XCTAssertTrue(other?.detail.hasPrefix("暂不支持这类链接") ?? false)
        XCTAssertEqual(other?.sniffURL, "https://live.douyin.com/123456")
        XCTAssertEqual(other?.errorDescription, other?.detail)

        // 展开成功 / 快手短链交给解析器
        let video = DetectedVideoLink(platform: .douyin, kind: "video", id: "7300000000000000000", url: "https://www.douyin.com/video/7300000000000000000")
        XCTAssertNil(VideoParseService.unexpandedError(original: short, resolved: video))
        let ks = DetectedVideoLink(platform: .kuaishou, kind: "short", id: "", url: "https://v.kuaishou.com/abc")
        XCTAssertNil(VideoParseService.unexpandedError(original: ks, resolved: ks))
    }

    func testVideoHTTPPropagatesCancellation() async {
        let task = Task { () -> Error? in
            do {
                _ = try await VideoHTTP.send(.get("https://10.255.255.1/never"))
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let error = await task.value
        XCTAssertTrue(error is CancellationError, "取消应原样抛出，实际：\(String(describing: error))")
    }

    func testVideoHTTPKeepsErrorDetail() async {
        do {
            _ = try await VideoHTTP.send(.get(""))
            XCTFail("无效地址应当失败")
        } catch let error as VideoParseError {
            XCTAssertEqual(error.kind, .network)
            XCTAssertTrue(error.detail.contains("无效的地址"), error.detail)
        } catch {
            XCTFail("应当包装成 VideoParseError：\(error)")
        }
    }

    func testDedupeLinks() {
        let urls = [
            "https://twitter.com/jack/status/20",
            "https://x.com/jack/status/20?s=46&t=abc",
            "https://www.bilibili.com/video/BV1xx411c7mD",
            "https://m.bilibili.com/video/BV1xx411c7mD?share_source=copy",
            "https://v.douyin.com/AbCd/",
            "https://v.douyin.com/EfGh/",
            "https://v.douyin.com/AbCd/",
            "https://example.com/not-a-video",
        ]
        XCTAssertEqual(VideoLinkParser.uniqueLinks(urls), [
            "https://twitter.com/jack/status/20",
            "https://www.bilibili.com/video/BV1xx411c7mD",
            "https://v.douyin.com/AbCd/",
            "https://v.douyin.com/EfGh/",
        ])
        // 同一 id 不同类型不算重复
        let a = DetectedVideoLink(platform: .bangumi, kind: "subject", id: "1", url: "a")
        let b = DetectedVideoLink(platform: .bangumi, kind: "group", id: "1", url: "b")
        XCTAssertNotEqual(VideoLinkParser.dedupeKey(a), VideoLinkParser.dedupeKey(b))
    }

    func testLivePairs() {
        let img1 = VideoMedia(url: "https://i/1.jpg", kind: .image, fileName: "作品_1.jpg")
        let live1 = VideoMedia(url: "https://v/1.mp4", kind: .video, fileName: "作品_1_live.mp4", quality: "实况")
        let img2 = VideoMedia(url: "https://i/2.webp", kind: .image, fileName: "作品_2.webp")
        let live2 = VideoMedia(url: "https://v/2.mov", kind: .video, fileName: "作品_2_live.mov", quality: "实况")
        // 没有同名图片的 _live 视频照常列为视频
        let orphan = VideoMedia(url: "https://v/3.mp4", kind: .video, fileName: "作品_3_live.mp4", quality: "实况")
        let video = VideoMedia(url: "https://v/main.mp4", kind: .video, fileName: "作品.mp4")
        let result = VideoParseResult(platform: .xiaohongshu, title: "作品", medias: [img1, live1, img2, live2, orphan, video])
        let pairs = result.livePairs
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[img1.id]?.id, live1.id)
        XCTAssertEqual(pairs[img2.id]?.id, live2.id)
        XCTAssertFalse(pairs.values.contains { $0.id == orphan.id || $0.id == video.id })
    }
}
