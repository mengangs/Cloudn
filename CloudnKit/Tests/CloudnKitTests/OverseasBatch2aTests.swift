import XCTest
@testable import CloudnKit

/// Reddit / Pinterest / Tumblr / Imgur / Bluesky / Snapchat 解析的纯逻辑（离线小样本）
final class OverseasBatch2aTests: XCTestCase {
    private func pairTumblr(_ t: (blog: String, id: String)?) -> [String] { t.map { [$0.blog, $0.id] } ?? [] }
    private func pairImgur(_ t: (kind: String, id: String)?) -> [String] { t.map { [$0.kind, $0.id] } ?? [] }

    // MARK: Reddit

    func testRedditPostID() {
        XCTAssertEqual(RedditParser.postID(from: "https://www.reddit.com/r/videos/comments/6rrwyj/that_small_heart_attack/"), "6rrwyj")
        XCTAssertEqual(RedditParser.postID(from: "https://old.reddit.com/user/someone/comments/abc123/x"), "abc123")
        XCTAssertEqual(RedditParser.postID(from: "https://www.reddit.com/comments/1abcde"), "1abcde")
        XCTAssertEqual(RedditParser.postID(from: "https://redd.it/6rrwyj"), "6rrwyj")
        XCTAssertNil(RedditParser.postID(from: "https://v.redd.it/zv89llsvexdz"))
        XCTAssertNil(RedditParser.postID(from: "https://www.reddit.com/r/pics/s/AbCdEf123"))
    }

    func testRedditPostDataErrors() throws {
        let quarantined = JSON(text: #"{"reason":"quarantined","message":"Forbidden","error":403}"#)!
        XCTAssertThrowsError(try RedditParser.postData(quarantined)) { error in
            XCTAssertTrue((error as? VideoParseError)?.detail.contains("隔离") ?? false)
        }
        let listing = JSON(text: #"[{"kind":"Listing","data":{"children":[{"kind":"t3","data":{"id":"abc","title":"T"}}]}},{}]"#)!
        XCTAssertEqual(try RedditParser.postData(listing)["title"].string, "T")
        XCTAssertThrowsError(try RedditParser.postData(JSON(text: "[]")!))
    }

    func testRedditVideo() {
        let post = JSON(text: #"""
        {"url":"https://v.redd.it/zv89llsvexdz","secure_media":{"reddit_video":{
          "fallback_url":"https://v.redd.it/zv89llsvexdz/DASH_720.mp4?source=fallback","height":720,"has_audio":true,
          "hls_url":"https://v.redd.it/zv89llsvexdz/HLSPlaylist.m3u8?a=1&amp;v=1&amp;f=sd","dash_url":null}}}
        """#)!
        let items = RedditParser.items(post)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .redditVideo)
        XCTAssertEqual(items[0].url, "https://v.redd.it/zv89llsvexdz/DASH_720.mp4?source=fallback")
        XCTAssertEqual(items[0].hls, "https://v.redd.it/zv89llsvexdz/HLSPlaylist.m3u8?a=1&v=1&f=sd")
        XCTAssertEqual(items[0].dash, "https://v.redd.it/zv89llsvexdz/DASHPlaylist.mpd")
        XCTAssertEqual(items[0].height, 720)
        XCTAssertEqual(items[0].hasAudio, true)

        // 转帖：自己没有媒体，取原帖；is_gif 视为无声
        let cross = JSON(text: #"""
        {"url":"/r/x/comments/1/","crosspost_parent_list":[{"media":{"reddit_video":{"fallback_url":"https://v.redd.it/aaa/DASH_480.mp4","is_gif":true}}}]}
        """#)!
        let crossItems = RedditParser.items(cross)
        XCTAssertEqual(crossItems.first?.hls, "https://v.redd.it/aaa/HLSPlaylist.m3u8")
        XCTAssertEqual(crossItems.first?.hasAudio, false)
    }

    func testRedditGallery() {
        let post = JSON(text: #"""
        {"url":"https://www.reddit.com/gallery/abc","is_gallery":true,
         "gallery_data":{"items":[{"media_id":"zzz"},{"media_id":"aaa"},{"media_id":"gif1"},{"media_id":"bad"}]},
         "media_metadata":{
           "aaa":{"status":"valid","e":"Image","m":"image/png","id":"aaa","s":{"u":"https://preview.redd.it/aaa.png?width=1&amp;s=x"}},
           "zzz":{"status":"valid","e":"Image","m":"image/jpg","id":"zzz","s":{"u":"https://preview.redd.it/zzz.jpg?s=y"}},
           "gif1":{"status":"valid","e":"AnimatedImage","m":"image/gif","id":"gif1","s":{"gif":"https://i.redd.it/gif1.gif","mp4":"https://preview.redd.it/gif1.gif?format=mp4&amp;s=z"}},
           "bad":{"status":"failed"}}}
        """#)!
        let items = RedditParser.items(post)
        XCTAssertEqual(items.map(\.url), [
            "https://i.redd.it/zzz.jpg", "https://i.redd.it/aaa.png", "https://preview.redd.it/gif1.gif?format=mp4&s=z"
        ])
        XCTAssertEqual(items.map(\.kind), [.image, .image, .video])
    }

    func testRedditInlineAndDirect() {
        let post = JSON(text: #"""
        {"url":"https://www.reddit.com/r/x/comments/abc/t/","is_self":true,"selftext":"intro ![img](second) then ![img](first)",
         "media_metadata":{
           "first":{"status":"valid","e":"Image","m":"image/webp","id":"first"},
           "second":{"status":"valid","e":"Image","m":"image/jpeg","id":"second"}}}
        """#)!
        XCTAssertEqual(RedditParser.items(post).map(\.url), ["https://i.redd.it/second.jpg", "https://i.redd.it/first.webp"])

        XCTAssertEqual(RedditParser.directItem("https://i.imgur.com/AbCdE.gifv"), RedditParser.Item(kind: .video, url: "https://i.imgur.com/AbCdE.mp4"))
        XCTAssertEqual(RedditParser.directItem("https://i.redd.it/xyz.jpeg")?.kind, .image)
        XCTAssertNil(RedditParser.directItem("https://www.youtube.com/watch?v=1"))
        XCTAssertNil(RedditParser.directItem("https://imgur.com/a/AbCdE"))
    }

    func testRedditHLSAndDASH() {
        let muxed = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nHLS_720.m3u8\n"
        let split = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"Audio\",URI=\"HLS_AUDIO_160_K.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO=\"a\"\nHLS_720.m3u8\n"
        XCTAssertFalse(RedditParser.hlsHasSeparateAudio(muxed))
        XCTAssertTrue(RedditParser.hlsHasSeparateAudio(split))

        let mpd = """
        <MPD><Period>
        <AdaptationSet contentType="video" mimeType="video/mp4">
          <Representation id="1" bandwidth="1200000" height="480" width="854"><BaseURL>DASH_480.mp4</BaseURL></Representation>
          <Representation id="2" bandwidth="4800000" height="1080" width="1920"><BaseURL>DASH_1080.mp4</BaseURL></Representation>
          <Representation id="3" bandwidth="2400000" height="720" width="1280"><BaseURL>DASH_720.mp4</BaseURL></Representation>
        </AdaptationSet>
        <AdaptationSet contentType="audio" mimeType="audio/mp4">
          <Representation id="4" bandwidth="64000"><BaseURL>DASH_AUDIO_64.mp4</BaseURL></Representation>
          <Representation id="5" bandwidth="128000"><BaseURL>DASH_AUDIO_128.mp4</BaseURL></Representation>
        </AdaptationSet>
        </Period></MPD>
        """
        let tracks = RedditParser.dashTracks(mpd, baseURL: "https://v.redd.it/abc/DASHPlaylist.mpd?a=1")
        XCTAssertEqual(tracks.video, "https://v.redd.it/abc/DASH_1080.mp4")
        XCTAssertEqual(tracks.height, 1080)
        XCTAssertEqual(tracks.audio, "https://v.redd.it/abc/DASH_AUDIO_128.mp4")

        // 老格式：音频只在 Representation 上标 mimeType
        let old = """
        <MPD><Period><AdaptationSet><Representation bandwidth="900" height="360" mimeType="video/mp4"><BaseURL>DASH_360</BaseURL></Representation>
        <Representation bandwidth="100" mimeType="audio/mp4"><BaseURL>audio</BaseURL></Representation></AdaptationSet></Period></MPD>
        """
        let oldTracks = RedditParser.dashTracks(old, baseURL: "https://v.redd.it/abc/DASHPlaylist.mpd")
        XCTAssertEqual(oldTracks.video, "https://v.redd.it/abc/DASH_360")
        XCTAssertEqual(oldTracks.audio, "https://v.redd.it/abc/audio")
    }

    // MARK: Pinterest

    func testPinterestVideoAndImage() {
        let video = JSON(text: #"""
        {"id":"1","domain":"Uploaded by user","videos":{"video_list":{
          "V_HLSV4":{"url":"https://v1.pinimg.com/videos/hls/a.m3u8","width":720,"height":1280},
          "V_720P":{"url":"https://v1.pinimg.com/videos/720p/a.mp4","width":720,"height":1280},
          "V_EXP4":{"url":"https://v1.pinimg.com/videos/exp4/a.mp4","width":360,"height":640}}},
         "images":{"orig":{"url":"https://i.pinimg.com/originals/a.jpg","width":720}}}
        """#)!
        XCTAssertEqual(PinterestParser.items(video), [PinterestParser.Item(kind: .video, url: "https://v1.pinimg.com/videos/720p/a.mp4", quality: "720p")])
        XCTAssertFalse(PinterestParser.isExternalEmbed(video))

        let hlsOnly = JSON(text: #"{"V_HLSV3_MOBILE":{"url":"https://v1.pinimg.com/videos/hls/b.m3u8"}}"#)!
        XCTAssertEqual(PinterestParser.bestVideo(hlsOnly), PinterestParser.Item(kind: .video, url: "https://v1.pinimg.com/videos/hls/b.m3u8", isHLS: true, quality: "HLS"))

        let image = JSON(text: #"""
        {"id":"2","images":{"236x":{"url":"https://i.pinimg.com/236x/a/b/c.jpg","width":236},"736x":{"url":"https://i.pinimg.com/736x/a/b/c.jpg","width":736},
          "orig":{"url":"https://i.pinimg.com/originals/a/b/c.png","width":1500}}}
        """#)!
        XCTAssertEqual(PinterestParser.items(image).map(\.url), ["https://i.pinimg.com/originals/a/b/c.png"])

        let external = JSON(text: #"{"domain":"youtube.com","embed":{"src":"https://www.youtube.com/embed/x"}}"#)!
        XCTAssertTrue(PinterestParser.isExternalEmbed(external))
    }

    func testPinterestStoryAndCarousel() {
        let story = JSON(text: #"""
        {"story_pin_data":{"pages":[
          {"blocks":[{"block_type":2,"image":{"images":{"originals":{"url":"https://i.pinimg.com/originals/p1.jpg"},"736x":{"url":"https://i.pinimg.com/736x/p1.jpg","width":736}}}}]},
          {"blocks":[{"block_type":3,"video":{"video_list":{"V_EXP7":{"url":"https://v1.pinimg.com/videos/exp7/p2.mp4","width":720,"height":1280}}}}]}]},
         "images":{"orig":{"url":"https://i.pinimg.com/originals/cover.jpg"}}}
        """#)!
        let items = PinterestParser.items(story)
        XCTAssertEqual(items.map(\.url), ["https://i.pinimg.com/originals/p1.jpg", "https://v1.pinimg.com/videos/exp7/p2.mp4"])
        XCTAssertEqual(items.map(\.kind), [.image, .video])

        let carousel = JSON(text: #"""
        {"carousel_data":{"carousel_slots":[{"images":{"736x":{"url":"https://i.pinimg.com/736x/c1.jpg","width":736},"236x":{"url":"https://i.pinimg.com/236x/c1.jpg","width":236}}},
          {"images":{"orig":{"url":"https://i.pinimg.com/originals/c2.jpg"}}}]}}
        """#)!
        XCTAssertEqual(PinterestParser.items(carousel).map(\.url), ["https://i.pinimg.com/736x/c1.jpg", "https://i.pinimg.com/originals/c2.jpg"])
    }

    func testPinterestHelpers() {
        XCTAssertEqual(PinterestParser.pinRx.first(in: "https://www.pinterest.com/pin/664281013778109217/"), "664281013778109217")
        XCTAssertEqual(PinterestParser.pinRx.first(in: "https://jp.pinterest.com/pin/some-title--1234567890/"), "1234567890")
        XCTAssertEqual(PinterestParser.pinRx.first(in: "https://www.pinterest.co.uk/pin/987/sent/?invite_code=x"), "987")
        XCTAssertEqual(PinterestParser.originalImage("https://i.pinimg.com/736x/ab/cd/ef/x.jpg"), "https://i.pinimg.com/originals/ab/cd/ef/x.jpg")
        XCTAssertEqual(PinterestParser.originalImage("https://i.pinimg.com/1200x/ab/x.jpg"), "https://i.pinimg.com/originals/ab/x.jpg")
        XCTAssertEqual(PinterestParser.parseTime("Sat, 13 Jan 2024 05:42:11 +0000"), 1705124531)

        let html = #"<html><script id="__PWS_DATA__" type="application/json">{"props":{"initialReduxState":{"pins":{"55":{"id":"55","images":{"orig":{"url":"https://i.pinimg.com/originals/z.jpg"}}}}}}}</script></html>"#
        let pin = PinterestParser.pinFromPage(html, id: "55")
        XCTAssertEqual(pin.map { PinterestParser.items($0).map(\.url) }, ["https://i.pinimg.com/originals/z.jpg"])
        XCTAssertNil(PinterestParser.pinFromPage(html, id: "56"))
    }

    // MARK: Tumblr

    func testTumblrBlogAndID() {
        XCTAssertEqual(pairTumblr(TumblrParser.blogAndID("https://tatianamaslanydaily.tumblr.com/post/54196191430/orphan-black")), ["tatianamaslanydaily", "54196191430"])
        XCTAssertEqual(pairTumblr(TumblrParser.blogAndID("https://www.tumblr.com/someblog/731234567890/slug")), ["someblog", "731234567890"])
        XCTAssertEqual(pairTumblr(TumblrParser.blogAndID("https://tumblr.com/some-blog/731234567890")), ["some-blog", "731234567890"])
        XCTAssertEqual(pairTumblr(TumblrParser.blogAndID("https://www.tumblr.com/blog/view/foo/123")), ["foo", "123"])
        XCTAssertEqual(pairTumblr(TumblrParser.blogAndID("https://maskofthedragon.tumblr.com/video/maskofthedragon/23011/")), ["maskofthedragon", "23011"])
        XCTAssertNil(TumblrParser.blogAndID("https://www.tumblr.com/explore"))
    }

    func testTumblrNPF() {
        let post = JSON(text: #"""
        {"blog_name":"reblogger","summary":"Hello","timestamp":200,
         "trail":[{"post":{"timestamp":100},"content":[
           {"type":"text","text":"original words"},
           {"type":"image","media":[{"url":"https://64.media.tumblr.com/a/s640x960/x.jpg","width":640},
                                    {"url":"https://64.media.tumblr.com/a/s2048x3072/x.jpg","width":1280,"has_original_dimensions":true}]}]}],
         "content":[
           {"type":"video","provider":"tumblr","media":{"url":"https://va.media.tumblr.com/tumblr_v.mp4","type":"video/mp4"}},
           {"type":"video","provider":"youtube","url":"https://www.youtube.com/watch?v=1"},
           {"type":"audio","provider":"tumblr","media":{"url":"https://a.tumblr.com/tumblr_a.mp3"}},
           {"type":"image","media":[{"url":"https://64.media.tumblr.com/b/s500x750/y.png","width":500},{"url":"https://64.media.tumblr.com/b/s1280x1920/y.png","width":1280}]}]}
        """#)!
        XCTAssertEqual(TumblrParser.items(post), [
            TumblrParser.Item(kind: .image, url: "https://64.media.tumblr.com/a/s2048x3072/x.jpg"),
            TumblrParser.Item(kind: .video, url: "https://va.media.tumblr.com/tumblr_v.mp4"),
            TumblrParser.Item(kind: .audio, url: "https://a.tumblr.com/tumblr_a.mp3"),
            TumblrParser.Item(kind: .image, url: "https://64.media.tumblr.com/b/s1280x1920/y.png")
        ])
        XCTAssertTrue(TumblrParser.hasExternalVideo(post))
        XCTAssertEqual(TumblrParser.text(post), "original words")
        XCTAssertEqual(TumblrParser.audioExtension("https://a.tumblr.com/tumblr_a.mp3?play_key=1"), "mp3")
    }

    func testTumblrPageFallback() {
        let html = """
        <html><head><title>Cute cat | Tumblr</title>
        <meta property="og:image" content="https://64.media.tumblr.com/c/s1280x1920/cat.jpg">
        <meta property="og:image" content="https://assets.tumblr.com/logo.png">
        <meta property="og:video" content="https://va.media.tumblr.com/tumblr_cat.mp4"></head></html>
        """
        XCTAssertEqual(TumblrParser.pageItems(html), [
            TumblrParser.Item(kind: .video, url: "https://va.media.tumblr.com/tumblr_cat.mp4"),
            TumblrParser.Item(kind: .image, url: "https://64.media.tumblr.com/c/s1280x1920/cat.jpg")
        ])
        XCTAssertEqual(TumblrParser.pageTitle(html), "Cute cat")
    }

    // MARK: Imgur

    func testImgurDetect() {
        XCTAssertEqual(pairImgur(ImgurParser.detect("https://imgur.com/a/AbCdEfG")), ["album", "AbCdEfG"])
        XCTAssertEqual(pairImgur(ImgurParser.detect("https://imgur.com/a/funny-cats-AbCdEfG")), ["album", "AbCdEfG"])
        XCTAssertEqual(pairImgur(ImgurParser.detect("https://imgur.com/gallery/some-title-XyZ12")), ["gallery", "XyZ12"])
        XCTAssertEqual(pairImgur(ImgurParser.detect("https://imgur.com/t/funny/XyZ12")), ["gallery", "XyZ12"])
        XCTAssertEqual(pairImgur(ImgurParser.detect("https://i.imgur.com/A1b2C3d.gifv")), ["media", "A1b2C3d"])
        XCTAssertEqual(pairImgur(ImgurParser.detect("https://imgur.com/A1b2C3d")), ["media", "A1b2C3d"])
        XCTAssertNil(ImgurParser.detect("https://imgur.com/user/someone"))
        XCTAssertNil(ImgurParser.detect("https://notimgur.com/A1b2C3d"))
    }

    func testImgurItems() {
        let data = JSON(text: #"""
        {"id":"AbCdEfG","title":"Album","is_album":true,"created_at":"2019-01-28T23:06:10Z","media":[
          {"id":"a1","type":"image","url":"https://i.imgur.com/a1.jpeg","ext":"jpeg","metadata":{"is_animated":false}},
          {"id":"a2","type":"video","url":"https://i.imgur.com/a2.mp4","ext":"mp4","metadata":{"is_animated":true,"has_sound":false}},
          {"id":"a3","type":"image","url":"https://i.imgur.com/a3.png","ext":"png"},
          {"id":"a4","type":"image","url":""}]}
        """#)!
        XCTAssertEqual(ImgurParser.items(data), [
            ImgurParser.Item(kind: .image, url: "https://i.imgur.com/a1.jpeg", ext: "jpg"),
            ImgurParser.Item(kind: .video, url: "https://i.imgur.com/a2.mp4", ext: "mp4"),
            ImgurParser.Item(kind: .image, url: "https://i.imgur.com/a3.png", ext: "png")
        ])
        XCTAssertEqual(ImgurParser.parseTime("2019-01-28T23:06:10Z"), 1548716770)
        XCTAssertEqual(ImgurParser.parseTime("2019-01-28T23:06:10.123Z"), 1548716770)
    }

    // MARK: Bluesky

    func testBlueskyLinks() {
        let t = BlueskyParser.handleAndID("https://bsky.app/profile/blu3blue.bsky.social/post/3l4omssdl632g")
        XCTAssertEqual(t?.handle, "blu3blue.bsky.social")
        XCTAssertEqual(t?.id, "3l4omssdl632g")
        XCTAssertEqual(BlueskyParser.handleAndID("https://bsky.app/profile/did%3Aplc%3Aabc/post/3xyz")?.handle, "did:plc:abc")
        XCTAssertNil(BlueskyParser.handleAndID("https://bsky.app/profile/someone"))
    }

    func testBlueskyItems() throws {
        let images = JSON(text: #"""
        {"thread":{"$type":"app.bsky.feed.defs#threadViewPost","post":{"author":{"did":"did:plc:a","handle":"a.bsky.social"},
          "record":{"text":"hi","createdAt":"2024-09-01T00:00:00.000Z"},
          "embed":{"$type":"app.bsky.embed.images#view","images":[
            {"thumb":"https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:a/c1@jpeg","fullsize":"https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:a/c1@jpeg"},
            {"thumb":"https://cdn.bsky.app/img/feed_thumbnail/plain/did:plc:a/c2@png","fullsize":"https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:a/c2@png"}]}}}}
        """#)!
        let post = try BlueskyParser.threadPost(images)
        let items = BlueskyParser.items(post)
        XCTAssertEqual(items.map(\.url), ["https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:a/c1@jpeg",
                                          "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:a/c2@png"])
        XCTAssertEqual(BlueskyParser.imageExtension(items[0].url), "jpg")
        XCTAssertEqual(BlueskyParser.imageExtension(items[1].url), "png")

        let video = JSON(text: #"""
        {"author":{"did":"did:plc:v"},"record":{"text":"v","embed":{"$type":"app.bsky.embed.recordWithMedia","media":{"$type":"app.bsky.embed.video",
           "video":{"ref":{"$link":"bafyvid"},"mimeType":"video/mp4","size":100}}}},
         "embed":{"$type":"app.bsky.embed.recordWithMedia#view","record":{"record":{}},"media":{"$type":"app.bsky.embed.video#view",
           "cid":"bafyvid","playlist":"https://video.bsky.app/watch/did%3Aplc%3Av/bafyvid/playlist.m3u8"}}}
        """#)!
        XCTAssertEqual(BlueskyParser.items(video), [BlueskyParser.Item(kind: .video, url: "https://video.bsky.app/watch/did%3Aplc%3Av/bafyvid/playlist.m3u8",
                                                                       did: "did:plc:v", cid: "bafyvid", mimeType: "video/mp4")])

        // 引用帖里的图片
        let quote = JSON(text: #"""
        {"author":{"did":"did:plc:me"},"record":{"text":"look"},"embed":{"$type":"app.bsky.embed.record#view","record":{"$type":"app.bsky.embed.record#viewRecord",
          "author":{"did":"did:plc:q"},"value":{},"embeds":[{"$type":"app.bsky.embed.images#view","images":[{"fullsize":"https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:q/c9@jpeg"}]}]}}}
        """#)!
        XCTAssertEqual(BlueskyParser.items(quote).map(\.url), ["https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:q/c9@jpeg"])

        let notFound = JSON(text: #"{"thread":{"$type":"app.bsky.feed.defs#notFoundPost","uri":"at://x","notFound":true}}"#)!
        XCTAssertThrowsError(try BlueskyParser.threadPost(notFound))
    }

    func testBlueskyPDS() {
        let doc = JSON(text: ##"{"id":"did:plc:a","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://morel.us-east.host.bsky.network"}]}"##)!
        XCTAssertEqual(BlueskyParser.pdsEndpoint(fromDIDDocument: doc), "https://morel.us-east.host.bsky.network")
        XCTAssertEqual(BlueskyParser.pdsEndpoint(fromDIDDocument: JSON(text: "{}")!), "https://bsky.social")
        XCTAssertEqual(BlueskyParser.blobURL(endpoint: "https://pds.example", did: "did:plc:a", cid: "bafy"),
                       "https://pds.example/xrpc/com.atproto.sync.getBlob?did=did%3Aplc%3Aa&cid=bafy")
        XCTAssertEqual(BlueskyParser.blobExtension("video/mp4"), "mp4")
        XCTAssertNil(BlueskyParser.blobExtension("video/webm"))
    }

    // MARK: Snapchat

    func testSnapchatSpotlight() {
        let html = #"""
        <html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"spotlightFeed":{"spotlightStories":[
          {"story":{"storyId":{"value":"OTHER"}},"metadata":{"videoMetadata":{"contentUrl":"https://cf-st.sc-cdn.net/d/other.27.IRZXSOY"}}},
          {"story":{"storyId":{"value":"W7_EDlXW"}},"metadata":{"description":"tags #a","videoMetadata":{"name":"Views","contentUrl":"https://cf-st.sc-cdn.net/d/abc.27.IRZXSOY?mo=x",
            "thumbnailUrl":"https://cf-st.sc-cdn.net/d/abc.256.IRZXSOY","uploadDateMs":1637777831369,"creator":{"personCreator":{"username":"shreypatel57"}}}}}]}}}}</script></html>
        """#
        let snap = SnapchatParser.parsePage(html, id: "W7_EDlXW")
        XCTAssertEqual(snap.items, [SnapchatParser.Item(kind: .video, url: "https://cf-st.sc-cdn.net/d/abc.27.IRZXSOY?mo=x")])
        XCTAssertEqual(snap.title, "Views")
        XCTAssertEqual(snap.text, "tags #a")
        XCTAssertEqual(snap.author, "shreypatel57")
        XCTAssertEqual(snap.timestamp, 1637777831)
        XCTAssertEqual(SnapchatParser.spotlightRx.first(in: "https://www.snapchat.com/@user.name/spotlight/W7_EDlXW-AA"), "W7_EDlXW-AA")
    }

    func testSnapchatStoryAndJSONLD() {
        let story = #"""
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"story":{"storyTitle":{"value":"Trip"},"snapList":[
          {"snapMediaType":0,"snapUrls":{"mediaUrl":"https://cf-st.sc-cdn.net/i/one"}},{"snapMediaType":1,"snapUrls":{"mediaUrl":"https://cf-st.sc-cdn.net/d/two"}}]},
          "userProfile":{"publicProfileInfo":{"username":"bob"}}}}}</script>
        """#
        let snap = SnapchatParser.parsePage(story, id: "")
        XCTAssertEqual(snap.items.map(\.kind), [.image, .video])
        XCTAssertEqual(snap.title, "Trip")
        XCTAssertEqual(snap.author, "bob")

        let ld = #"<script type="application/ld+json">{"@type":"VideoObject","contentUrl":"https:\/\/cf-st.sc-cdn.net\/d\/ld.mp4"}</script>"#
        XCTAssertEqual(SnapchatParser.parsePage(ld, id: "x").items, [SnapchatParser.Item(kind: .video, url: "https://cf-st.sc-cdn.net/d/ld.mp4")])
    }
}
