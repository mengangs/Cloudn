// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// Vimeo / Dailymotion / Twitch / SoundCloud / Medium / Bangumi 解析的纯逻辑（离线，内联小样本）
final class OverseasBatch2bTests: XCTestCase {
    private func json(_ text: String) -> JSON {
        guard let j = JSON(text: text) else {
            XCTFail("fixture 不是合法 JSON")
            return JSON(nil)
        }
        return j
    }

    // MARK: Vimeo

    func testVimeoIDAndHash() {
        XCTAssertEqual(VimeoParser.videoID(from: "https://vimeo.com/76979871?share=copy"), "76979871")
        XCTAssertEqual(VimeoParser.videoID(from: "https://player.vimeo.com/video/123456789?h=abcdef1234"), "123456789")
        XCTAssertEqual(VimeoParser.videoID(from: "https://vimeo.com/channels/staffpicks/123456789"), "123456789")
        XCTAssertEqual(VimeoParser.videoID(from: "https://vimeo.com/showcase/9876543/video/123456789"), "123456789")
        XCTAssertNil(VimeoParser.videoID(from: "https://vimeo.com/user12345"))
        XCTAssertEqual(VimeoParser.unlistedHash(from: "https://vimeo.com/123456789/abcdef1234"), "abcdef1234")
        XCTAssertEqual(VimeoParser.unlistedHash(from: "https://player.vimeo.com/video/123456789?h=0a1b2c3d4e&badge=0"), "0a1b2c3d4e")
        XCTAssertEqual(VimeoParser.unlistedHash(from: "https://vimeo.com/123456789"), "")
    }

    func testVimeoProgressivePreferred() throws {
        let config = json(#"""
        {"request":{"files":{"progressive":[
            {"url":"https://vod/360.mp4","height":360,"quality":"360p"},
            {"url":"https://vod/1080.mp4","height":1080,"quality":"1080p"},
            {"url":"https://vod/720.mp4","height":720,"quality":"720p"}],
          "hls":{"default_cdn":"akfire","cdns":{"akfire":{"url":"https://hls/sep/video/a/playlist.m3u8"}}}}},
         "video":{"title":"T","owner":{"name":"Alice"},"thumbs":{"640":"https://i/640.jpg","1280":"https://i/1280.jpg","base":"https://i/base"}}}
        """#)
        XCTAssertNoThrow(try VimeoParser.checkConfig(config))
        XCTAssertEqual(VimeoParser.bestStream(config), VimeoParser.Stream(url: "https://vod/1080.mp4", isHLS: false, quality: "1080p"))
        XCTAssertEqual(VimeoParser.thumbnail(config["video"]), "https://i/1280.jpg")
    }

    func testVimeoHLSFallbackUsesMuxedManifest() {
        let config = json(#"""
        {"request":{"files":{"progressive":[],"hls":{"default_cdn":"fastly_skyfire","cdns":{
            "akfire_interconnect_quic":{"url":"https://a/x/sep/video/1/playlist.m3u8"},
            "fastly_skyfire":{"url":"https://f/x/sep/video/2/playlist.m3u8","avc_url":"https://f/x/sep/video/2/avc.m3u8"}}}}},
         "video":{"title":"T"}}
        """#)
        XCTAssertEqual(VimeoParser.bestStream(config), VimeoParser.Stream(url: "https://f/x/video/2/avc.m3u8", isHLS: true, quality: "HLS"))
        XCTAssertNil(VimeoParser.bestStream(json(#"{"request":{"files":{}},"video":{}}"#)))
    }

    func testVimeoConfigErrorsAndPlayerPage() {
        XCTAssertThrowsError(try VimeoParser.checkConfig(json(#"{"view":4,"video":{}}"#))) { error in
            XCTAssertTrue((error as? VideoParseError)?.detail.contains("密码") ?? false)
        }
        XCTAssertThrowsError(try VimeoParser.checkConfig(json(#"{"message":"Sorry"}"#)))
        let html = #"<script>var x = 1; window.playerConfig = {"request":{"files":{"progressive":[{"url":"https://v/1.mp4","height":540}]}},"video":{"title":"页内"}}; var y;</script>"#
        let config = VimeoParser.playerConfig(in: html)
        XCTAssertEqual(config?["video"]["title"].string, "页内")
        XCTAssertTrue(VimeoParser.isPrivacyBlocked("Because of its privacy settings, this video cannot be played here."))
    }

    // MARK: Dailymotion

    func testDailymotionID() {
        XCTAssertEqual(DailymotionParser.videoID(from: "https://www.dailymotion.com/video/x8abcd1_some-title_news"), "x8abcd1")
        XCTAssertEqual(DailymotionParser.videoID(from: "https://dai.ly/x8abcd1"), "x8abcd1")
        XCTAssertEqual(DailymotionParser.videoID(from: "https://geo.dailymotion.com/player/xid0t.html?video=x8abcd1"), "x8abcd1")
        XCTAssertEqual(DailymotionParser.videoID(from: "https://www.dailymotion.com/embed/video/x8abcd1?autoplay=1"), "x8abcd1")
    }

    func testDailymotionMetadata() throws {
        let metadata = json(#"""
        {"title":"DM","created_time":1493651285,"owner":{"screenname":"Bob"},
         "posters":{"60":"https://s/60.jpg","720":"https://s/720.jpg","1080":"https://s/1080.jpg"},
         "qualities":{"auto":[{"type":"application/x-mpegURL","url":"https://www.dailymotion.com/cdn/manifest/video/x8abcd1.m3u8?sec=abc#cell=x"}]}}
        """#)
        XCTAssertNoThrow(try DailymotionParser.checkError(metadata))
        let stream = DailymotionParser.bestStream(metadata)
        XCTAssertEqual(stream?.url, "https://www.dailymotion.com/cdn/manifest/video/x8abcd1.m3u8?sec=abc")
        XCTAssertEqual(stream?.isHLS, true)
        XCTAssertEqual(DailymotionParser.poster(metadata), "https://s/1080.jpg")

        let mp4Only = json(#"{"qualities":{"380":[{"type":"video/mp4","url":"https://v/H264-512x384/a.mp4"}],"720":[{"type":"video/mp4","url":"https://v/H264-1280x720/b.mp4"}]}}"#)
        XCTAssertEqual(DailymotionParser.bestStream(mp4Only)?.url, "https://v/H264-1280x720/b.mp4")
        XCTAssertEqual(DailymotionParser.bestStream(mp4Only)?.quality, "720p")

        let geo = json(#"{"error":{"code":"DM007","title":"Video geo-restricted by the owner."}}"#)
        XCTAssertThrowsError(try DailymotionParser.checkError(geo)) { error in
            XCTAssertTrue((error as? VideoParseError)?.detail.contains("地区") ?? false)
        }
        let headers = DailymotionParser.randomHeaders()
        XCTAssertTrue((2...8).contains(headers.count))
        XCTAssertTrue(headers.keys.allSatisfy { $0.count >= 8 && $0.count <= 24 })
    }

    // MARK: Twitch

    func testTwitchClipStream() {
        let clip = json(#"""
        {"id":"1","title":"Clip","playbackAccessToken":{"signature":"sig123","value":"{\"a\":1}"},
         "assets":[{"videoQualities":[
            {"quality":"480","frameRate":30,"sourceURL":"https://production.assets.clips.twitchcdn.net/480.mp4"},
            {"quality":"1080","frameRate":60,"sourceURL":"https://production.assets.clips.twitchcdn.net/1080.mp4"},
            {"quality":"720","frameRate":60,"sourceURL":"https://production.assets.clips.twitchcdn.net/720.mp4"}]}]}
        """#)
        let stream = TwitchParser.bestClipStream(clip)
        XCTAssertEqual(stream?.url, "https://production.assets.clips.twitchcdn.net/1080.mp4?sig=sig123&token=%7B%22a%22%3A1%7D")
        XCTAssertEqual(stream?.quality, "1080p60")

        let legacy = json(#"{"playbackAccessToken":{"signature":"s","value":"v"},"videoQualities":[{"quality":"360","frameRate":30,"sourceURL":"https://c/360.mp4?x=1"}]}"#)
        XCTAssertEqual(TwitchParser.bestClipStream(legacy)?.url, "https://c/360.mp4?x=1&sig=s&token=v")
        XCTAssertNil(TwitchParser.bestClipStream(json(#"{"assets":[{"videoQualities":[]}]}"#)))
    }

    func testTwitchQueriesAndUsher() {
        XCTAssertEqual(TwitchParser.gqlString(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertTrue(TwitchParser.clipQuery(slug: "Slug").contains(#"clip(slug: "Slug")"#))
        let vod = TwitchParser.vodQuery(id: "6528877")
        XCTAssertTrue(vod.contains(#"video(id: "6528877")"#))
        XCTAssertTrue(vod.contains(#"videoPlaybackAccessToken(id: "6528877", params: {platform: "web""#))
        let usher = TwitchParser.usherURL(id: "6528877", token: #"{"x":1}"#, signature: "abc", random: 1234567)
        XCTAssertTrue(usher.hasPrefix("https://usher.ttvnw.net/vod/6528877.m3u8?allow_source=true"))
        XCTAssertTrue(usher.contains("supported_codecs=h264"))
        XCTAssertTrue(usher.contains("p=1234567"))
        XCTAssertTrue(usher.hasSuffix("sig=abc&token=%7B%22x%22%3A1%7D"))

        let restricted = TwitchParser.usherError(status: 403, body: json(#"[{"error":"No access","error_code":"vod_manifest_restricted"}]"#))
        XCTAssertTrue(restricted.detail.contains("订阅者"))
        XCTAssertEqual(TwitchParser.usherError(status: 404, body: JSON(nil)).kind, .notFound)
        XCTAssertEqual(TwitchParser.vodThumbnail(json(#"{"previewThumbnailURL":"https://s/404_processing_320x180.png"}"#)), "")
        XCTAssertEqual(TwitchParser.parseISO8601("2015-06-24T07:42:14Z"), 1435131734)
        XCTAssertEqual(TwitchParser.parseISO8601("2015-06-24T07:42:14.123Z"), 1435131734)
    }

    // MARK: SoundCloud

    func testSoundCloudClientIDAndURLs() {
        let html = #"<script>window.__sc_hydration = [{"hydratable":"anonymousId","data":"x"},{"hydratable":"apiClient","data":{"id":"AbCdEfGhIjKlMnOpQrStUvWxYz012345","isExpiring":false}}];</script>"#
        XCTAssertEqual(SoundCloudParser.clientID(inHydration: html), "AbCdEfGhIjKlMnOpQrStUvWxYz012345")
        XCTAssertEqual(SoundCloudParser.clientID(inScript: #"...{client_id:"0123456789abcdefABCDEF0123456789",env:"production"}"#),
                       "0123456789abcdefABCDEF0123456789")
        XCTAssertNil(SoundCloudParser.clientID(inScript: "nothing here"))
        let page = #"<script crossorigin src="https://a-v2.sndcdn.com/assets/0-abc.js"></script><script src="https://evil.example.com/x.js"></script><script src="https://a-v2.sndcdn.com/assets/50-def.js"></script>"#
        XCTAssertEqual(SoundCloudParser.scriptURLs(in: page), ["https://a-v2.sndcdn.com/assets/0-abc.js", "https://a-v2.sndcdn.com/assets/50-def.js"])
        XCTAssertEqual(SoundCloudParser.infoURL(kind: "track", id: "ethmusic/lostin-powers"),
                       "https://api-v2.soundcloud.com/resolve?url=https%3A%2F%2Fsoundcloud.com%2Fethmusic%2Flostin-powers")
        XCTAssertEqual(SoundCloudParser.infoURL(kind: "api", id: "123"), "https://api-v2.soundcloud.com/tracks/123")
        XCTAssertEqual(SoundCloudParser.secretToken(in: "user/track/s-AbCdE"), "s-AbCdE")
        XCTAssertEqual(SoundCloudParser.secretToken(in: "user/track"), "")
    }

    func testSoundCloudPrefersProgressiveMP3() throws {
        let info = json(#"""
        {"kind":"track","media":{"transcodings":[
          {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1/a/stream/hls","preset":"aac_160k","snipped":false,"format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""}},
          {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1/b/stream/hls","preset":"mp3_1_0","snipped":false,"format":{"protocol":"hls","mime_type":"audio/mpeg"}},
          {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1/c/stream/progressive","preset":"mp3_1_0","snipped":false,"format":{"protocol":"progressive","mime_type":"audio/mpeg"}},
          {"url":"https://api-v2.soundcloud.com/media/soundcloud:tracks:1/d/stream/hls","preset":"abr_sq","snipped":false,"format":{"protocol":"hls","mime_type":"audio/mp4"}}]}}
        """#)
        let t = try SoundCloudParser.pickTranscoding(info)
        XCTAssertEqual(t.protocolName, "progressive")
        XCTAssertFalse(t.isHLS)
        XCTAssertEqual(SoundCloudParser.fileExtension(t), "mp3")
        XCTAssertEqual(SoundCloudParser.qualityLabel(t), "MP3")
    }

    func testSoundCloudHLSFallbackAndDRM() throws {
        let info = json(#"""
        {"media":{"transcodings":[
          {"url":"https://api-v2.soundcloud.com/media/x/ctr/stream/hls","preset":"aac_160k","format":{"protocol":"ctr-encrypted-hls","mime_type":"audio/mp4"}},
          {"url":"https://api-v2.soundcloud.com/media/x/opus/stream/hls","preset":"opus_0_0","format":{"protocol":"hls","mime_type":"audio/ogg; codecs=\"opus\""}},
          {"url":"https://api-v2.soundcloud.com/media/x/aac/stream/hls","preset":"aac_160k","format":{"protocol":"hls","mime_type":"audio/mp4; codecs=\"mp4a.40.2\""}}]}}
        """#)
        let t = try SoundCloudParser.pickTranscoding(info)
        XCTAssertEqual(t.url, "https://api-v2.soundcloud.com/media/x/aac/stream/hls")
        XCTAssertTrue(t.isHLS)
        XCTAssertEqual(SoundCloudParser.fileExtension(t), "m4a")
        XCTAssertEqual(SoundCloudParser.qualityLabel(t), "AAC 160k（HLS）")

        let drmOnly = json(#"{"media":{"transcodings":[{"url":"https://a/x/stream/hls","preset":"aac_160k","format":{"protocol":"cbc-encrypted-hls"}}]}}"#)
        XCTAssertThrowsError(try SoundCloudParser.pickTranscoding(drmOnly)) { error in
            XCTAssertTrue((error as? VideoParseError)?.detail.contains("DRM") ?? false)
        }
    }

    func testSoundCloudSnippedIsRejected() {
        let info = json(#"""
        {"policy":"SNIP","media":{"transcodings":[
          {"url":"https://api-v2.soundcloud.com/media/x/preview/stream/progressive","preset":"mp3_0_0","snipped":true,"format":{"protocol":"progressive","mime_type":"audio/mpeg"}},
          {"url":"https://api-v2.soundcloud.com/media/x/p2/stream/hls","preset":"mp3_0_0","snipped":true,"format":{"protocol":"hls","mime_type":"audio/mpeg"}}]}}
        """#)
        XCTAssertThrowsError(try SoundCloudParser.pickTranscoding(info)) { error in
            XCTAssertTrue((error as? VideoParseError)?.detail.contains("Go+") ?? false)
        }
        XCTAssertThrowsError(try SoundCloudParser.pickTranscoding(json(#"{"policy":"BLOCK","media":{"transcodings":[]}}"#))) { error in
            XCTAssertTrue((error as? VideoParseError)?.detail.contains("地区") ?? false)
        }
    }

    func testSoundCloudArtworkAndTime() {
        let info = json(#"{"artwork_url":"https://i1.sndcdn.com/artworks-abc-large.jpg"}"#)
        XCTAssertEqual(SoundCloudParser.artwork(info), "https://i1.sndcdn.com/artworks-abc-t500x500.jpg")
        let avatarOnly = json(#"{"artwork_url":null,"user":{"avatar_url":"https://i1.sndcdn.com/avatars-x-large.png"}}"#)
        XCTAssertEqual(SoundCloudParser.artwork(avatarOnly), "https://i1.sndcdn.com/avatars-x-t500x500.png")
        XCTAssertEqual(SoundCloudParser.parseTime("2012-10-11T02:16:38Z"), 1349921798)
    }

    // MARK: Medium

    func testMediumPostID() {
        XCTAssertEqual(MediumParser.postID(from: "https://medium.com/@user/some-title-1a2b3c4d5e6f?source=x"), "1a2b3c4d5e6f")
        XCTAssertEqual(MediumParser.postID(from: "https://medium.com/p/1a2b3c4d5e6f"), "1a2b3c4d5e6f")
        XCTAssertEqual(MediumParser.postID(from: "https://user.medium.com/hello-world-abcdef123456/"), "abcdef123456")
        XCTAssertNil(MediumParser.postID(from: "https://medium.com/@user"))
        XCTAssertEqual(MediumParser.canonicalURL("https://medium.com/p/1a2b3c4d5e6f?source=x#y"), "https://medium.com/p/1a2b3c4d5e6f")
    }

    func testMediumParsePost() throws {
        let response = json(#"""
        [{"data":{"post":{"title":"标题","isLocked":true,"firstPublishedAt":1700000000123,"creator":{"name":"Carol","imageId":"1*avatar.png"},
          "content":{"bodyModel":{"paragraphs":[
            {"type":"H3","text":"标题","metadata":null},
            {"type":"P","text":"第一段","metadata":null},
            {"type":"IMG","text":"图注","metadata":{"id":"1*abc.png","originalWidth":800,"originalHeight":600}},
            {"type":"IMG","text":"","metadata":{"id":"0*def"}},
            {"type":"IMG","text":"","metadata":{"id":"1*abc.png"}},
            {"type":"P","text":"  ","metadata":null}]}}}}}]
        """#)
        XCTAssertFalse(MediumParser.hasErrors(response))
        let post = try MediumParser.parsePost(response)
        XCTAssertEqual(post.title, "标题")
        XCTAssertTrue(post.isLocked)
        XCTAssertEqual(post.author, "Carol")
        XCTAssertEqual(post.avatar, "https://miro.medium.com/v2/resize:fill:176:176/1*avatar.png")
        XCTAssertEqual(post.timestamp, 1700000000)
        XCTAssertEqual(post.text, "第一段")
        XCTAssertEqual(post.images, ["https://miro.medium.com/v2/1*abc.png", "https://miro.medium.com/v2/0*def"])
    }

    func testMediumErrors() {
        let errors = json(#"[{"errors":[{"message":"Cannot query field \"creator\""}]}]"#)
        XCTAssertTrue(MediumParser.hasErrors(errors))
        XCTAssertThrowsError(try MediumParser.parsePost(errors))
        XCTAssertThrowsError(try MediumParser.parsePost(json(#"[{"data":{"post":null}}]"#))) { error in
            XCTAssertEqual((error as? VideoParseError)?.kind, .notFound)
        }
    }

    // MARK: Bangumi

    func testBangumiBBCodeImages() {
        let content = "开头[b]粗体[/b]\r\n[img]https://lain.bgm.tv/pic/a.jpg[/img][url=https://x.com][IMG]http://i.example.com/b.png[/IMG][/url]\n"
            + "[photo]/2024/01/c.jpg[/photo][img=300,200] https://lain.bgm.tv/pic/a.jpg [/img]结尾"
        XCTAssertEqual(BangumiParser.bbcodeImages(content), [
            "https://lain.bgm.tv/pic/a.jpg",
            "http://i.example.com/b.png",
            "https://lain.bgm.tv/pic/photo/l/2024/01/c.jpg"
        ])
        XCTAssertEqual(BangumiParser.plainText(content), "开头粗体\n\n结尾")
        XCTAssertEqual(BangumiParser.bbcodeImages("纯文字[b]没有图[/b]"), [])
    }

    func testBangumiPhotosAndHelpers() {
        let photos = json(#"{"data":[{"target":"/2024/02/d.jpg"},{"target":""},{"target":"2024/01/c.jpg"}],"total":3}"#)
        let urls = BangumiParser.photoURLs(photos)
        XCTAssertEqual(urls, ["https://lain.bgm.tv/pic/photo/l/2024/02/d.jpg", "https://lain.bgm.tv/pic/photo/l/2024/01/c.jpg"])
        XCTAssertEqual(BangumiParser.merge(["https://lain.bgm.tv/pic/photo/l/2024/01/c.jpg"], urls),
                       ["https://lain.bgm.tv/pic/photo/l/2024/01/c.jpg", "https://lain.bgm.tv/pic/photo/l/2024/02/d.jpg"])
        XCTAssertEqual(BangumiParser.avatar(json(#"{"avatar":{"small":"s","medium":"m","large":"l"}}"#)), "l")
        XCTAssertEqual(BangumiParser.trimLeadingSlashes("//a/b"), "a/b")
    }
}
