// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 网页源码里直接写着的音视频地址（离线，内联小样本）
final class PageMediaScannerTests: XCTestCase {
    private let base = "https://example.com/watch/1"

    func testMetaTagsInEitherAttributeOrder() {
        let html = """
        <meta property="og:title" content="山间晨雾 &amp; 延时">
        <meta content="https://cdn.example.com/v/1080.mp4?sig=a&amp;t=1" property="og:video:secure_url">
        <meta name="twitter:player:stream" content='https://cdn.example.com/v/720.mp4'>
        """
        let scan = PageMediaScanner.scan(html: html, baseURL: base)
        XCTAssertEqual(scan.title, "山间晨雾 & 延时")
        XCTAssertEqual(scan.urls, ["https://cdn.example.com/v/1080.mp4?sig=a&t=1", "https://cdn.example.com/v/720.mp4"])
    }

    func testPlayerPageInOgVideoIsSkipped() {
        let html = #"<meta property="og:video" content="https://player.example.com/embed/abc">"#
        XCTAssertEqual(PageMediaScanner.scan(html: html, baseURL: base).urls, [])
    }

    func testMediaTagsResolveRelativeAndSkipImagesAndBlobs() {
        let html = """
        <title> 页面标题 </title>
        <video src="/media/a.mp4" controls></video>
        <video src="blob:https://example.com/123"></video>
        <picture><source type="image/webp" src="/img/a.webp"></picture>
        <audio><source src="//static.example.com/b" type="audio/mpeg"></audio>
        """
        let scan = PageMediaScanner.scan(html: html, baseURL: base)
        XCTAssertEqual(scan.title, "页面标题")
        XCTAssertEqual(scan.urls, ["https://example.com/media/a.mp4", "https://static.example.com/b"])
    }

    func testEscapedURLsInScriptsAndJSONLD() {
        let html = #"""
        <script type="application/ld+json">{"@type":"VideoObject","contentUrl":"https:\/\/cdn.example.com\/v\/full.mp4","thumbnailUrl":"https:\/\/cdn.example.com\/c.jpg"}</script>
        <script>window.__DATA__={"hls":"https:\u002F\u002Fcdn.example.com\u002Fhls\u002Fmaster.m3u8?token=x\u0026e=1"}</script>
        """#
        let scan = PageMediaScanner.scan(html: html, baseURL: base)
        XCTAssertEqual(scan.urls, ["https://cdn.example.com/v/full.mp4", "https://cdn.example.com/hls/master.m3u8?token=x&e=1"])
    }

    func testBareURLsNeedARealMediaExtension() {
        let html = """
        <a href="https://example.com/video.mp4.html">页面</a>
        <a href="https://example.com/a.mp4x">不是</a>
        var u = "https://cdn.example.com/x/clip.webm";
        var u2 = 'https://cdn.example.com/x/clip.webm';
        """
        XCTAssertEqual(PageMediaScanner.scan(html: html, baseURL: base).urls, ["https://cdn.example.com/x/clip.webm"])
    }

    func testResultCountIsCapped() {
        let html = (1...50).map { "\"https://cdn.example.com/\($0).mp4\"" }.joined(separator: ",")
        XCTAssertEqual(PageMediaScanner.scan(html: html, baseURL: base).urls.count, PageMediaScanner.maxResults)
    }

    func testNothingFound() {
        let scan = PageMediaScanner.scan(html: "<html><body>没有视频</body></html>", baseURL: base)
        XCTAssertEqual(scan.urls, [])
        XCTAssertEqual(scan.title, "")
    }
}
