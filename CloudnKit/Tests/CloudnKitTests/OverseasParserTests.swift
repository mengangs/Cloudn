import XCTest
@testable import CloudnKit

/// X / TikTok / Instagram / Threads 解析的纯逻辑（离线小样本）
final class OverseasParserTests: XCTestCase {
    // MARK: X（Twitter）

    func testTwitterID() {
        XCTAssertEqual(TwitterParser.tweetID(from: "https://x.com/jack/status/20?s=20"), "20")
        XCTAssertEqual(TwitterParser.tweetID(from: "https://twitter.com/i/web/status/1790000000000000001"), "1790000000000000001")
        XCTAssertNil(TwitterParser.tweetID(from: "https://x.com/jack"))
        XCTAssertTrue(TwitterParser.hasLoginCookie("auth_token=a; ct0=b"))
        XCTAssertFalse(TwitterParser.hasLoginCookie("ct0=b"))
        XCTAssertTrue(TwitterParser.requestURL(id: "123").contains("variables=%7B%22tweetId%22%3A%22123%22"))
    }

    func testTwitterTweetMedias() throws {
        let json = JSON(text: #"""
        {"data":{"tweetResult":{"result":{"__typename":"Tweet","rest_id":"1","core":{"user_results":{"result":{"core":{"screen_name":"alice"},"avatar":{"image_url":"https://pbs.twimg.com/a.jpg"}}}},
        "legacy":{"created_at":"Wed Oct 10 20:19:24 +0000 2018","full_text":"hello https://t.co/abc","extended_entities":{"media":[
          {"type":"photo","media_url_https":"https://pbs.twimg.com/media/P1.png"},
          {"type":"video","media_url_https":"https://pbs.twimg.com/t.jpg","video_info":{"variants":[
            {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/pl.m3u8"},
            {"content_type":"video/mp4","bitrate":256000,"url":"https://video.twimg.com/vid/avc1/480x270/a.mp4"},
            {"content_type":"video/mp4","bitrate":2176000,"url":"https://video.twimg.com/vid/avc1/1280x720/b.mp4"},
            {"content_type":"video/mp4","bitrate":832000,"url":"https://video.twimg.com/vid/avc1/640x360/c.mp4"}]}},
          {"type":"animated_gif","media_url_https":"https://pbs.twimg.com/g.jpg","video_info":{"variants":[{"content_type":"video/mp4","bitrate":0,"url":"https://video.twimg.com/tweet_video/g.mp4"}]}}
        ]}}}}}}
        """#)!
        let tweet = try TwitterParser.parseTweet(json)
        XCTAssertEqual(tweet.author, "alice")
        XCTAssertEqual(tweet.text, "hello")
        XCTAssertEqual(tweet.timestamp, 1539202764)
        XCTAssertEqual(tweet.medias, [
            TwitterParser.Media(kind: .image, url: "https://pbs.twimg.com/media/P1.png?name=orig", quality: "原图"),
            TwitterParser.Media(kind: .video, url: "https://video.twimg.com/vid/avc1/1280x720/b.mp4", quality: "1280x720"),
            TwitterParser.Media(kind: .video, url: "https://video.twimg.com/tweet_video/g.mp4", quality: "GIF")
        ])
        XCTAssertEqual(TwitterParser.imageExtension("https://pbs.twimg.com/media/P1.png?name=orig"), "png")
        XCTAssertEqual(TwitterParser.imageExtension("https://pbs.twimg.com/media/P1?format=jpg&name=orig"), "jpg")
    }

    func testTwitterVisibilityWrapperAndQuote() throws {
        let json = JSON(text: #"""
        {"data":{"tweetResult":{"result":{"__typename":"TweetWithVisibilityResults","tweet":{"rest_id":"2",
          "legacy":{"full_text":"look","entities":{}},
          "quoted_status_result":{"result":{"rest_id":"3","legacy":{"full_text":"q","entities":{"media":[{"type":"photo","media_url_https":"https://pbs.twimg.com/media/Q.jpg"}]}}}}}}}}}
        """#)!
        let tweet = try TwitterParser.parseTweet(json)
        XCTAssertEqual(tweet.text, "look")
        XCTAssertEqual(tweet.medias.map(\.url), ["https://pbs.twimg.com/media/Q.jpg?name=orig"])
    }

    func testTwitterArticle() throws {
        let json = JSON(text: #"""
        {"data":{"tweetResult":{"result":{"rest_id":"4","legacy":{"full_text":""},"article":{"article_results":{"result":{"title":"长文",
          "cover_media":{"media_info":{"original_img_url":"https://pbs.twimg.com/c.jpg"}},
          "media_entities":[{"media_id":"1","media_info":{"__typename":"ApiImage","original_img_url":"https://pbs.twimg.com/i.jpg"}},
            {"media_id":"2","media_info":{"__typename":"ApiVideo","variants":[{"content_type":"video/mp4","bit_rate":100,"url":"https://v/lo.mp4"},{"content_type":"video/mp4","bit_rate":900,"url":"https://v/hi.mp4"}]}}]}}}}}}}
        """#)!
        let tweet = try TwitterParser.parseTweet(json)
        XCTAssertEqual(tweet.title, "长文")
        XCTAssertEqual(tweet.medias.map(\.url), ["https://pbs.twimg.com/c.jpg", "https://pbs.twimg.com/i.jpg", "https://v/hi.mp4"])
    }

    func testTwitterErrors() {
        let tomb = JSON(text: #"{"data":{"tweetResult":{"result":{"__typename":"TweetTombstone","tombstone":{}}}}}"#)!
        XCTAssertThrowsError(try TwitterParser.parseTweet(tomb)) { error in
            XCTAssertTrue((error as? VideoParseError)?.detail.contains("需要登录") ?? false)
        }
        let empty = JSON(text: #"{"data":{"tweetResult":{}}}"#)!
        XCTAssertThrowsError(try TwitterParser.parseTweet(empty)) { error in
            XCTAssertEqual((error as? VideoParseError)?.kind, .notFound)
        }
        let suspended = JSON(text: #"{"data":{"tweetResult":{"result":{"__typename":"TweetUnavailable","reason":"Suspended"}}}}"#)!
        XCTAssertThrowsError(try TwitterParser.parseTweet(suspended)) { error in
            XCTAssertEqual((error as? VideoParseError)?.kind, .notFound)
        }
    }

    // MARK: TikTok

    func testTikTokItemID() {
        XCTAssertEqual(TikTokParser.itemID(from: "https://www.tiktok.com/@user/video/7234567890123456789?is_from_webapp=1"), "7234567890123456789")
        XCTAssertEqual(TikTokParser.itemID(from: "https://www.tiktok.com/@user/photo/7300000000000000001"), "7300000000000000001")
        XCTAssertTrue(TikTokParser.isLoginURL("https://www.tiktok.com/login?redirect_url=x"))
        XCTAssertFalse(TikTokParser.isLoginURL("https://www.tiktok.com/@a/video/1"))
    }

    func testTikTokVideoFromPage() throws {
        let html = #"""
        <html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{"__DEFAULT_SCOPE__":{"webapp.video-detail":{"statusCode":0,"itemInfo":{"itemStruct":{"id":"77","desc":"dance","createTime":"1700000000","author":{"uniqueId":"bob","nickname":"Bob"},
        "video":{"width":576,"height":1024,"playAddr":"https://v16-webapp.tiktok.com/play.mp4","cover":"https://p/cover.jpg",
        "bitrateInfo":[{"Bitrate":500000,"PlayAddr":{"Width":540,"Height":960,"DataSize":100,"UrlList":["https://v19.tiktokcdn.com/lo","https://www.tiktok.com/aweme/v1/play/?lo"]}},
                       {"Bitrate":900000,"PlayAddr":{"Width":1080,"Height":1920,"DataSize":300,"UrlList":["https://v19.tiktokcdn.com/hi"]}}]}}}}}}</script></html>
        """#
        let scope = try XCTUnwrap(TikTokParser.universalData(html))
        let item = try TikTokParser.extractItem(scope)
        XCTAssertEqual(item["desc"].string, "dance")
        XCTAssertEqual(try TikTokParser.medias(item), [TikTokParser.Media(kind: .video, url: "https://v19.tiktokcdn.com/hi", quality: "1080P")])
        XCTAssertEqual(TikTokParser.pickCover(item["video"]), "https://p/cover.jpg")
    }

    func testTikTokFallbacksAndImages() throws {
        let plain = JSON(text: #"{"video":{"width":720,"height":1280,"playAddr":"https://v/play.mp4"}}"#)!
        XCTAssertEqual(try TikTokParser.medias(plain).map(\.url), ["https://v/play.mp4"])
        let preferAweme = JSON(text: #"{"play_addr":{"url_list":["https://cdn/x","https://api/aweme/v1/play"]}}"#)!
        XCTAssertEqual(TikTokParser.preferredVideoURL(preferAweme["play_addr"]), "https://api/aweme/v1/play")
        let photo = JSON(text: #"{"desc":"pics","imagePost":{"images":[{"imageURL":{"urlList":["https://i/1.jpeg","https://i/1b.jpeg"]}},{"imageURL":{"urlList":["//i/2.jpeg"]}}]}}"#)!
        XCTAssertEqual(try TikTokParser.medias(photo).map(\.url), ["https://i/1.jpeg", "https://i/2.jpeg"])
    }

    func testTikTokStatusErrors() {
        let gone = JSON(text: #"{"webapp.video-detail":{"statusCode":10204,"statusMsg":"item doesn't exist"}}"#)!
        XCTAssertThrowsError(try TikTokParser.extractItem(gone)) { XCTAssertEqual(($0 as? VideoParseError)?.kind, .notFound) }
        let login = JSON(text: #"{"webapp.video-detail":{"statusCode":10216}}"#)!
        XCTAssertThrowsError(try TikTokParser.extractItem(login)) {
            XCTAssertTrue((($0 as? VideoParseError)?.detail ?? "").contains("需要登录"))
        }
    }

    /// 期望值由参考实现（Python：json.dumps(separators=(",", ":")) + base64）算出
    func testTikTokChallenge() throws {
        let cs = "eyJ2Ijp7ImEiOiJkR2xyZEc5ckxYTmhiSFE9IiwiYyI6IkxLcnY4c3N5V3NlZzIwVmluZ2o5SEoxSGdzZmtSS3BvazZpSVJoS0pUS0k9In0sInMiOiLDqXgiLCJuIjoxLjUsInQiOnRydWV9"
        let html = #"<div id="cs" class="\#(cs)"></div><p id="wci" class="waf_cookie"></p><p id="rci" class="rci_name"></p><p id="rs" class="rs_value"></p>"#
        XCTAssertEqual(TikTokParser.htmlClass(html, id: "wci"), "waf_cookie")
        let cookies = try XCTUnwrap(TikTokParser.solveChallenge(html))
        XCTAssertEqual(cookies.count, 2)
        XCTAssertEqual(cookies[0].0, "waf_cookie")
        XCTAssertEqual(cookies[0].1, "eyJ2Ijp7ImEiOiJkR2xyZEc5ckxYTmhiSFE9IiwiYyI6IkxLcnY4c3N5V3NlZzIwVmluZ2o5SEoxSGdzZmtSS3BvazZpSVJoS0pUS0k9In0sInMiOiJcdTAwZTl4IiwibiI6MS41LCJ0Ijp0cnVlLCJkIjoiTkRJME1nPT0ifQ==")
        XCTAssertEqual(cookies[1].0, "rci_name")
        XCTAssertEqual(cookies[1].1, "rs_value")
        XCTAssertNil(TikTokParser.solveChallenge("<html>no challenge</html>"))
    }

    func testOrderedValueRoundTrip() {
        let v = OrderedValue.parse(#"{"b":1,"a":[true,null,"x\"y中"],"c":{}}"#)
        // 与 Python json.dumps 默认（ensure_ascii）一致：非 ASCII 转成 \uXXXX
        XCTAssertEqual(v?.text, #"{"b":1,"a":[true,null,"x\"y\u4e2d"],"c":{}}"#)
        XCTAssertEqual(v?.setting("b", .string("z")).text, #"{"b":"z","a":[true,null,"x\"y\u4e2d"],"c":{}}"#)
    }

    // MARK: Instagram

    func testInstagramShortcode() {
        XCTAssertEqual(InstagramParser.shortcode(from: "https://www.instagram.com/p/CuE2WNQs6vH/?igsh=abc"), "CuE2WNQs6vH")
        XCTAssertEqual(InstagramParser.shortcode(from: "https://www.instagram.com/reel/DQx7_-abcde/"), "DQx7_-abcde")
        XCTAssertEqual(InstagramParser.shortcode(from: "https://www.instagram.com/someone/reels/ABC123"), "ABC123")
        // 期望值由参考实现 shortcode_to_media_id 算出
        XCTAssertEqual(MetaShortcode.decimal("CuE2WNQs6vH", truncate: true), "3135870261135649735")
        XCTAssertEqual(MetaShortcode.decimal("DQx7_-abcde", truncate: true), "3761051044917659486")
        XCTAssertEqual(MetaShortcode.decimal("BAAAAAAAAAA" + String(repeating: "x", count: 28), truncate: true), "1152921504606846976")
        XCTAssertNil(MetaShortcode.decimal("bad!"))
    }

    func testInstagramV1Carousel() throws {
        let payload = JSON(text: #"""
        {"data":{"xdt_api__v1__media__shortcode__web_info":{"items":[{"code":"ABC","media_type":8,"taken_at":1700000000,"caption":{"text":"trip"},"user":{"username":"ann"},
          "carousel_media":[{"media_type":1,"image_versions2":{"candidates":[{"url":"https://ig/1.jpg"}]}},
                            {"media_type":2,"image_versions2":{"candidates":[{"url":"https://ig/2.jpg"}]},"video_versions":[{"url":"https://ig/2.mp4"}]}]}]}},"status":"ok"}
        """#)!
        let post = try InstagramParser.extractPost(payload)
        XCTAssertEqual(post.caption, "trip")
        XCTAssertEqual(post.author, "ann")
        XCTAssertEqual(post.medias, [InstagramParser.Media(kind: .image, url: "https://ig/1.jpg"), InstagramParser.Media(kind: .video, url: "https://ig/2.mp4")])
    }

    func testInstagramGraphNodeAndRestricted() throws {
        let payload = JSON(text: #"""
        {"data":{"xdt_shortcode_media":{"__typename":"XDTGraphVideo","shortcode":"V","is_video":true,"video_url":"https://ig/v.mp4","display_url":"https://ig/v.jpg",
          "edge_media_to_caption":{"edges":[{"node":{"text":"cap"}}]},"owner":{"username":"u"}}}}
        """#)!
        let post = try InstagramParser.extractPost(payload)
        XCTAssertEqual(post.caption, "cap")
        XCTAssertEqual(post.medias, [InstagramParser.Media(kind: .video, url: "https://ig/v.mp4")])

        let restricted = JSON(text: #"{"data":{"xdt_shortcode_media":null}}"#)!
        XCTAssertThrowsError(try InstagramParser.extractPost(restricted)) { XCTAssertTrue($0 is InstagramParser.Restricted) }
        let noItems = JSON(text: #"{"data":{"xdt_api__v1__media__shortcode__web_info":{"items":[]}}}"#)!
        XCTAssertThrowsError(try InstagramParser.extractPost(noItems)) { XCTAssertTrue($0 is InstagramParser.Restricted) }
    }

    // MARK: Threads

    func testThreadsCodeAndVariables() {
        XCTAssertEqual(ThreadsParser.postCode(from: "https://www.threads.com/@zuck/post/DQx7_-abcdeZZ?xmt=1"), "DQx7_-abcdeZZ")
        XCTAssertEqual(ThreadsParser.postCode(from: "https://www.threads.net/t/CuXFPIeLLod"), "CuXFPIeLLod")
        // 超出 Int64 的 code 也要按大数算对（期望值由参考实现 shortcode_to_pk 算出）
        XCTAssertEqual(MetaShortcode.decimal("DQx7_-abcdeZZ"), "15405265079982733256281")
        let vars = ThreadsParser.variables(pk: "123")
        XCTAssertTrue(vars.hasPrefix(#"{"postID":"123","__relay_internal__pv__BarcelonaHasPermalinkIndentationrelayprovider":false,"#))
        XCTAssertTrue(vars.hasSuffix(#""__relay_internal__pv__BarcelonaIsInternalUserrelayprovider":false}"#))
        XCTAssertEqual(ThreadsParser.relayProviders.count, 31)
    }

    func testThreadsExtractAndMedias() throws {
        let payload = JSON(text: #"""
        {"data":{"data":{"edges":[{"node":{"thread_items":[
          {"post":{"code":"PARENT","media_type":19,"text_post_app_info":{"linked_inline_media":{"media_type":1,"image_versions2":{"candidates":[{"url":"https://t/l.jpg"}]}}}}},
          {"post":{"code":"MINE","media_type":8,"carousel_media":[
            {"image_versions2":{"candidates":[{"url":"https://t/1.jpg"}]}},
            {"image_versions2":{"candidates":[{"url":"https://t/2.jpg"}]},"video_versions":[{"url":"https://t/2.mp4"}]}]}}]}}]}}}
        """#)!
        let mine = try XCTUnwrap(ThreadsParser.extractPost(payload, code: "MINE"))
        XCTAssertEqual(ThreadsParser.medias(mine), [ThreadsParser.Media(kind: .image, url: "https://t/1.jpg"), ThreadsParser.Media(kind: .video, url: "https://t/2.mp4")])
        let fallback = try XCTUnwrap(ThreadsParser.extractPost(payload, code: "OTHER"))
        XCTAssertEqual(fallback["code"].string, "PARENT")
        XCTAssertEqual(ThreadsParser.medias(fallback).map(\.url), ["https://t/l.jpg"])
    }
}
