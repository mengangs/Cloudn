import XCTest
@testable import CloudnKit

/// Facebook / 小黑盒 解析的纯逻辑（离线小样本）
final class FacebookXiaoheiheTests: XCTestCase {
    private func classify(_ url: String) -> [String] {
        FacebookParser.classify(url).map { [$0.kind, $0.id] } ?? []
    }

    // MARK: Facebook 链接

    func testFacebookClassify() {
        XCTAssertEqual(classify("https://fb.watch/abcD_12/"), ["share", "abcD_12"])
        XCTAssertEqual(classify("https://www.facebook.com/share/v/1AbCdEf/"), ["share", "1AbCdEf"])
        XCTAssertEqual(classify("https://www.facebook.com/share/r/1XyZ/"), ["share", "1XyZ"])
        XCTAssertEqual(classify("https://m.facebook.com/share/p/18abc/"), ["share", "18abc"])
        XCTAssertEqual(classify("https://www.facebook.com/reel/1195289147628387"), ["video", "1195289147628387"])
        XCTAssertEqual(classify("https://www.facebook.com/watch/?v=10153231379946729"), ["video", "10153231379946729"])
        XCTAssertEqual(classify("https://m.facebook.com/watch/?ref=x&v=456"), ["video", "456"])
        XCTAssertEqual(classify("https://www.facebook.com/radiokicksfm/videos/3676516585958356/"), ["video", "3676516585958356"])
        XCTAssertEqual(classify("https://www.facebook.com/a/videos/vb.1/789/?type=3"), ["video", "789"])
        XCTAssertEqual(classify("https://www.facebook.com/video.php?v=274175099429670"), ["video", "274175099429670"])
        XCTAssertEqual(classify("https://www.facebook.com/photo/?fbid=1234&set=a.1"), ["photo", "1234"])
        XCTAssertEqual(classify("https://www.facebook.com/photo.php?fbid=55&set=x"), ["photo", "55"])
        XCTAssertEqual(classify("https://www.facebook.com/page/photos/a.123/456/"), ["photo", "456"])
        XCTAssertEqual(classify("https://www.facebook.com/user/posts/pfbid02abcDEF"), ["post", "pfbid02abcDEF"])
        XCTAssertEqual(classify("https://www.facebook.com/groups/123/permalink/456/"), ["post", "456"])
        XCTAssertEqual(classify("https://m.facebook.com/story.php?story_fbid=999&id=1"), ["post", "999"])
        XCTAssertEqual(classify("https://www.facebook.com/someone"), [])
    }

    func testFacebookPageURLAndRedirects() {
        XCTAssertEqual(FacebookParser.pageURL(kind: "video", id: "42", url: "https://www.facebook.com/reel/42"),
                       "https://www.facebook.com/watch/?v=42&_rdr")
        XCTAssertEqual(FacebookParser.pageURL(kind: "video", id: "7", url: "https://m.facebook.com/watch/?v=7"),
                       "https://www.facebook.com/watch/?v=7")
        XCTAssertEqual(FacebookParser.pageURL(kind: "photo", id: "5", url: "https://web.facebook.com/photo/?fbid=5"),
                       "https://www.facebook.com/photo/?fbid=5")
        XCTAssertEqual(FacebookParser.unwrapLogin("https://www.facebook.com/login/?next=https%3A%2F%2Fwww.facebook.com%2Freel%2F99"),
                       "https://www.facebook.com/reel/99")
        XCTAssertEqual(FacebookParser.unwrapLogin("https://www.facebook.com/watch/?v=1"), "https://www.facebook.com/watch/?v=1")
        let html = #"<html><head><meta property="og:url" content="https://www.facebook.com/watch/?v=31&amp;x=1" /></head></html>"#
        XCTAssertEqual(FacebookParser.canonicalURL(html), "https://www.facebook.com/watch/?v=31&x=1")
        let canonical = #"<link rel="canonical" href="https://www.facebook.com/reel/77" />"#
        XCTAssertEqual(FacebookParser.canonicalURL(canonical), "https://www.facebook.com/reel/77")
    }

    // MARK: Facebook 页面数据

    private let videoPage = #"""
    <html><head><meta property="og:title" content="Cool clip | Facebook" />
    <meta property="og:image" content="https://scontent.xx.fbcdn.net/v/t15/thumb.jpg?a=1&amp;b=2" /></head><body>
    <form id="login_form"></form>
    <script type="application/json" data-content-len="10" data-sjs>{"require":[["ScheduledServerJS","handle",null,[{"__bbox":{"require":[["RelayPrefetchedStreamCache","next",[],["adp",{"__bbox":{"result":{"data":{
      "related":{"__typename":"Video","id":"222","playable_url":"https://video.xx.fbcdn.net/other.mp4"},
      "video":{"__typename":"Video","id":"111","videoId":"111","owner":{"name":"Alice"},"publish_time":1700000000,"name":"Cool clip",
        "preferred_thumbnail":{"image":{"uri":"https://scontent.xx.fbcdn.net/cover.jpg"}},
        "videoDeliveryLegacyFields":{"browser_native_hd_url":"https://video.xx.fbcdn.net/hd.mp4?a=1","browser_native_sd_url":"https://video.xx.fbcdn.net/sd.mp4"},
        "videoDeliveryResponseFragment":{"videoDeliveryResponseResult":{
          "progressive_urls":[{"progressive_url":"https://video.xx.fbcdn.net/p_hd.mp4","metadata":{"quality":"HD"}},{"progressive_url":"https://video.xx.fbcdn.net/p_sd.mp4","metadata":{"quality":"SD"}}],
          "dash_manifests":[{"manifest_xml":"<MPD><Period><AdaptationSet contentType=\"video\"><Representation id=\"v1\" mimeType=\"video/mp4\" height=\"1080\" bandwidth=\"3000000\"><BaseURL>https://video.xx.fbcdn.net/v1080.mp4?x=1&amp;y=2</BaseURL></Representation><Representation id=\"v2\" mimeType=\"video/mp4\" height=\"480\" bandwidth=\"800000\"><BaseURL>https://video.xx.fbcdn.net/v480.mp4</BaseURL></Representation></AdaptationSet><AdaptationSet contentType=\"audio\"><Representation id=\"a1\" mimeType=\"audio/mp4\" bandwidth=\"64000\"><BaseURL>https://video.xx.fbcdn.net/a64.mp4</BaseURL></Representation><Representation id=\"a2\" mimeType=\"audio/mp4\" bandwidth=\"128000\"><BaseURL>https://video.xx.fbcdn.net/a128.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>"}]
        }}
      }}}}}]]]}}]]]}</script>
    </body></html>
    """#

    func testFacebookCollectVideo() throws {
        let blobs = FacebookParser.sjsBlobs(in: videoPage)
        XCTAssertEqual(blobs.count, 1)
        let collector = FacebookCollector()
        for b in blobs { collector.add(b) }
        XCTAssertEqual(collector.videos.map(\.id), ["222", "111"])

        let items = FacebookParser.select(kind: "video", id: "111", collector: collector)
        XCTAssertEqual(items.count, 1)
        guard case .video(let v) = items[0] else { return XCTFail("应为视频") }
        XCTAssertEqual(v.hd, ["https://video.xx.fbcdn.net/hd.mp4?a=1", "https://video.xx.fbcdn.net/p_hd.mp4"])
        XCTAssertEqual(v.sd, ["https://video.xx.fbcdn.net/sd.mp4", "https://video.xx.fbcdn.net/p_sd.mp4"])
        XCTAssertEqual(v.owner, "Alice")
        XCTAssertEqual(v.timestamp, 1700000000)
        XCTAssertEqual(v.thumbnail, "https://scontent.xx.fbcdn.net/cover.jpg")
        XCTAssertEqual(v.manifests.count, 1)

        // DASH 1080p + 最高码率音轨胜过 720p 渐进式
        let s = try XCTUnwrap(FacebookParser.bestStream(v))
        XCTAssertEqual(s.url, "https://video.xx.fbcdn.net/v1080.mp4?x=1&y=2")
        XCTAssertEqual(s.audioURL, "https://video.xx.fbcdn.net/a128.mp4")
        XCTAssertEqual(s.quality, "1080p")

        // 没有 id 匹配时取第一个视频
        let fallback = FacebookParser.select(kind: "video", id: "999", collector: collector)
        guard case .video(let first)? = fallback.first else { return XCTFail("应有兜底视频") }
        XCTAssertEqual(first.id, "222")

        let meta = FacebookParser.pageMeta(videoPage)
        XCTAssertEqual(FacebookParser.cleanTitle(meta.title), "Cool clip")
        XCTAssertEqual(meta.image, "https://scontent.xx.fbcdn.net/v/t15/thumb.jpg?a=1&b=2")
        XCTAssertTrue(meta.loginWall)
    }

    func testFacebookBestStreamProgressive() throws {
        var v = FacebookParser.Video()
        v.hd = ["https://video.xx.fbcdn.net/hd.mp4"]
        v.sd = ["https://video.xx.fbcdn.net/sd.mp4"]
        // DASH 只有 720p：不比渐进式 HD 好，直接用渐进式
        v.manifests = [#"<MPD><AdaptationSet mimeType="video/mp4"><Representation height="720" bandwidth="1"><BaseURL>https://v/720.mp4</BaseURL></Representation></AdaptationSet><AdaptationSet mimeType="audio/mp4"><Representation bandwidth="2"><BaseURL>https://v/a.mp4</BaseURL></Representation></AdaptationSet></MPD>"#]
        var s = try XCTUnwrap(FacebookParser.bestStream(v))
        XCTAssertEqual(s.url, "https://video.xx.fbcdn.net/hd.mp4")
        XCTAssertEqual(s.audioURL, "")
        XCTAssertEqual(s.quality, "HD")

        // 只有 HLS
        var hlsOnly = FacebookParser.Video()
        hlsOnly.hls = ["https://video.xx.fbcdn.net/x.m3u8"]
        s = try XCTUnwrap(FacebookParser.bestStream(hlsOnly))
        XCTAssertTrue(s.isHLS)
        XCTAssertNil(FacebookParser.bestStream(FacebookParser.Video()))
    }

    func testFacebookDashURLEncoded() {
        let encoded = "%3CMPD%3E%3CAdaptationSet+mimeType%3D%22video%2Fmp4%22%3E%3CRepresentation+height%3D%22540%22+bandwidth%3D%2210%22%3E%3CBaseURL%3Ehttps%3A%2F%2Fv%2F540.mp4%3C%2FBaseURL%3E%3C%2FRepresentation%3E%3C%2FAdaptationSet%3E%3C%2FMPD%3E"
        let reps = FacebookParser.dashRepresentations(encoded)
        XCTAssertEqual(reps, [FacebookParser.DashRep(isAudio: false, height: 540, bandwidth: 10, url: "https://v/540.mp4")])
    }

    func testFacebookPhotoPost() {
        let blob = #"""
        {"require":[["x",{"data":{"node":{"comet_sections":{"content":{"story":{"attachments":[{"styles":{"attachment":{
          "all_subattachments":{"count":2,"nodes":[
            {"media":{"__typename":"Photo","id":"p2","image":{"uri":"https://scontent.xx.fbcdn.net/p2_small.jpg","width":100,"height":100}}},
            {"media":{"__typename":"Photo","id":"p1","image":{"uri":"https://scontent.xx.fbcdn.net/p1.jpg","width":100,"height":100}}}
          ]}}}}]}}}},
          "extra":{"__typename":"Photo","id":"p2","viewer_image":{"uri":"https://scontent.xx.fbcdn.net/p2_big.jpg","width":2000,"height":1500},
                   "image":{"uri":"https://scontent.xx.fbcdn.net/p2_mid.jpg","width":600,"height":400}},
          "comment":{"attachment":{"media":{"__typename":"Photo","id":"c1","image":{"uri":"https://scontent.xx.fbcdn.net/c1.jpg"}}}}
        }}]]}
        """#
        let collector = FacebookCollector()
        collector.add(blob)
        XCTAssertEqual(collector.attachmentIDs, ["p2", "p1"])
        let items = FacebookParser.select(kind: "post", id: "pfbid0x", collector: collector)
        let urls: [String] = items.compactMap { item in
            if case .photo(let p) = item { return p.url }
            return nil
        }
        XCTAssertEqual(urls, ["https://scontent.xx.fbcdn.net/p2_big.jpg", "https://scontent.xx.fbcdn.net/p1.jpg"])

        // 单图页按 fbid 取
        let single = FacebookParser.select(kind: "photo", id: "p1", collector: collector)
        guard case .photo(let p)? = single.first else { return XCTFail("应为图片") }
        XCTAssertEqual(p.url, "https://scontent.xx.fbcdn.net/p1.jpg")

        XCTAssertTrue(FacebookParser.usableImage("https://scontent.xx.fbcdn.net/a.jpg"))
        XCTAssertFalse(FacebookParser.usableImage("https://lookaside.fbsbx.com/lookaside/crawler/media/?media_id=1"))
    }

    func testFacebookInterstitial() {
        let html = #"<div class="x uiInterstitialContent y"><div>This video is unavailable</div></div>"#
        XCTAssertEqual(FacebookParser.pageMeta(html).interstitial, "This video is unavailable")
        XCTAssertFalse(FacebookParser.pageMeta(html).loginWall)
    }

    // MARK: 小黑盒

    func testXiaoheiheSign() {
        // 期望值由 ParseHub 的 XiaoHeiHeSign._ov(path, _time + 1, nonce) 计算
        XCTAssertEqual(XiaoheiheParser.hkey(path: "/bbs/app/link/tree", time: 1700000000, nonce: "0123456789ABCDEF0123456789ABCDEF"), "YT27P47")
        XCTAssertEqual(XiaoheiheParser.hkey(path: "/bbs/app/link/tree", time: 1760000000, nonce: "D41D8CD98F00B204E9800998ECF8427E"), "IVSV124")
        XCTAssertEqual(XiaoheiheParser.hkey(path: "bbs/app//link/tree", time: 1700000000, nonce: "0123456789ABCDEF0123456789ABCDEF"), "YT27P47")
        XCTAssertEqual(XiaoheiheParser.mixColumns([97, 98, 99, 100, 101, 102]), [63, 5, 99, 89, 101, 102])
        XCTAssertEqual(XiaoheiheParser.interleave(["ABC", "12", "XY"]), "A1XB2YC")

        let q = XiaoheiheParser.query(linkID: "174972336", hkey: "YT27P47", time: 1700000000, nonce: "N")
        XCTAssertEqual(q.first(where: { $0.0 == "link_id" })?.1, "174972336")
        XCTAssertEqual(q.first(where: { $0.0 == "_time" })?.1, "1700000000")
        XCTAssertEqual(q.first(where: { $0.0 == "x_app" })?.1, "heybox_website")
    }

    func testXiaoheiheLinkID() {
        XCTAssertEqual(XiaoheiheParser.linkID(from: "https://www.xiaoheihe.cn/app/bbs/link/174972336"), "174972336")
        XCTAssertEqual(XiaoheiheParser.linkID(from: "https://www.xiaoheihe.cn/v3/bbs/app/api/web/share?link_id=174972336"), "174972336")
        XCTAssertEqual(XiaoheiheParser.linkID(from: "https://api.xiaoheihe.cn/v3/bbs/app/link?h_src=x&link_id=abc12"), "abc12")
        XCTAssertNil(XiaoheiheParser.linkID(from: "https://www.xiaoheihe.cn/home"))
        XCTAssertEqual(XiaoheiheParser.originalImageURL("https://imgheybox.max-c.com/web/bbs/2024/01/01/abc/thumb.png?imageMogr2/format/webp"),
                       "https://imgheybox.max-c.com/web/bbs/2024/01/01/abc.png")
        XCTAssertEqual(XiaoheiheParser.originalImageURL("https://imgheybox.max-c.com/x/y.jpeg?a=1"), "https://imgheybox.max-c.com/x/y.jpeg")
    }

    func testXiaoheihePostImage() throws {
        let text = #"[{"type":"html","text":"<p>第一段</p><p><img data-original=\"https://imgheybox.max-c.com/a/thumb.png?x=1\" src=\"data:x\"></p>"},{"type":"img","url":"https://imgheybox.max-c.com/b/thumb.jpeg?imageMogr2","width":"100.0","height":"200"},{"type":"img","url":"https://imgheybox.max-c.com/a/thumb.png"}]"#
        let link = JSON.object(["title": "标题", "text": text, "has_video": 0, "create_at": 1700000000,
                                "user": ["username": "作者", "avartar": "https://imgheybox.max-c.com/avatar.png"]])
        let post = try XCTUnwrap(XiaoheiheParser.post(fromLink: link))
        XCTAssertEqual(post.title, "标题")
        XCTAssertEqual(post.text, "第一段")
        XCTAssertEqual(post.author, "作者")
        XCTAssertEqual(post.avatar, "https://imgheybox.max-c.com/avatar.png")
        XCTAssertEqual(post.timestamp, 1700000000)
        XCTAssertTrue(post.videos.isEmpty)
        XCTAssertEqual(post.images, ["https://imgheybox.max-c.com/a.png", "https://imgheybox.max-c.com/b.jpeg"])
    }

    func testXiaoheihePostVideo() throws {
        let link = JSON.object(["title": "视频帖", "text": "说明文字", "has_video": true,
                                "video_url": "https://video.max-c.com/a/index.m3u8", "video_thumb": "https://imgheybox.max-c.com/t.jpg"])
        let post = try XCTUnwrap(XiaoheiheParser.post(fromLink: link))
        XCTAssertEqual(post.videos, ["https://video.max-c.com/a/index.m3u8"])
        XCTAssertEqual(post.cover, "https://imgheybox.max-c.com/t.jpg")
        XCTAssertEqual(post.text, "说明文字")
        XCTAssertNil(XiaoheiheParser.post(fromLink: JSON(nil)))
    }

    func testXiaoheiheStatusAndDOM() {
        XCTAssertNoThrow(try XiaoheiheParser.checkStatus(JSON.object(["status": "ok"])))
        XCTAssertThrowsError(try XiaoheiheParser.checkStatus(JSON.object(["status": "lack_token", "msg": "x"]))) { error in
            XCTAssertEqual((error as? VideoParseError)?.kind, .blocked)
        }
        XCTAssertThrowsError(try XiaoheiheParser.checkStatus(JSON.object(["status": "failed", "msg": "帖子已删除"]))) { error in
            XCTAssertEqual((error as? VideoParseError)?.kind, .notFound)
        }
        let dom = JSON(text: #"{"title":"帖子 - 小黑盒","images":["https://imgheybox.max-c.com/a/thumb.jpg?x","https://imgheybox.max-c.com/a.jpg"],"videos":["blob:x"]}"#)!
        let post = XiaoheiheParser.post(fromDOM: dom)
        XCTAssertEqual(post?.title, "帖子")
        XCTAssertEqual(post?.images, ["https://imgheybox.max-c.com/a.jpg"])
        XCTAssertEqual(post?.videos, [])
        XCTAssertNil(XiaoheiheParser.post(fromDOM: JSON(text: #"{"images":[],"videos":[]}"#)!))
    }
}
