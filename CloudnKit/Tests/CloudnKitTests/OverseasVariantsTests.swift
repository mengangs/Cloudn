// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 海外平台的多清晰度：同一视频的各档共用 variantGroup，最高画质在前，文件名互不相同（离线小样本）
final class OverseasVariantsTests: XCTestCase {
    private func json(_ text: String) -> JSON {
        guard let j = JSON(text: text) else {
            XCTFail("fixture 不是合法 JSON")
            return JSON(nil)
        }
        return j
    }

    private typealias Option = OverseasVariants.Option

    // MARK: 共用整理逻辑

    func testHelperGroupsDedupesAndNames() {
        let options = [
            Option(url: "https://v/1080.mp4", quality: "1080P", size: 900),
            Option(url: "https://v/720.mp4", quality: "720P"),
            Option(url: "https://v/1080.mp4", quality: "1080P"),        // 重复直链
            Option(url: "https://v/720b.mp4", quality: "720P"),         // 重复标签
            Option(url: "", quality: "480P"),                           // 空链接
            Option(url: "https://v/720h.mp4", quality: "720P · H.265"),
            Option(url: "https://v/x.mp4", quality: "")
        ]
        let medias = OverseasVariants.medias(options, stem: "clip", group: "video", headers: ["Referer": "r"])
        XCTAssertEqual(medias.map(\.url), ["https://v/1080.mp4", "https://v/720.mp4", "https://v/720h.mp4", "https://v/x.mp4"])
        XCTAssertEqual(medias.map(\.quality), ["1080P", "720P", "720P · H.265", ""])
        XCTAssertEqual(medias.map(\.fileName), ["clip.mp4", "clip_720P.mp4", "clip_720P_H.265.mp4", "clip_v4.mp4"])
        XCTAssertEqual(Set(medias.map(\.variantGroup)), ["video"])
        XCTAssertEqual(medias[0].size, 900)
        XCTAssertEqual(medias[1].size, -1)
        XCTAssertEqual(medias[1].headers, ["Referer": "r"])

        // 只剩一档：不分组，文件名与以前一致
        let single = OverseasVariants.medias([Option(url: "https://v/a.m3u8", quality: "HLS", isHLS: true),
                                              Option(url: "https://v/a.m3u8", quality: "HLS")], stem: "s", group: "video")
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].fileName, "s.mp4")
        XCTAssertEqual(single[0].variantGroup, "")
        XCTAssertTrue(single[0].isHLS)

        // 最多 6 档
        let many = (1...9).map { Option(url: "https://v/\($0).mp4", quality: "\(1000 - $0)P") }
        XCTAssertEqual(OverseasVariants.medias(many, stem: "m", group: "g").count, OverseasVariants.maxOptions)
    }

    func testHelperLabels() {
        XCTAssertEqual(OverseasVariants.label(width: 1920, height: 1080), "1080P")
        XCTAssertEqual(OverseasVariants.label(width: 720, height: 1280), "720P")
        XCTAssertEqual(OverseasVariants.label(width: 0, height: 480), "480P")
        XCTAssertEqual(OverseasVariants.label(width: 0, height: 0), "")
        XCTAssertEqual(OverseasVariants.label(bitrate: 2_176_000), "2.2 Mbps")
        XCTAssertEqual(OverseasVariants.label(bitrate: 832_000), "832 kbps")
        XCTAssertEqual(OverseasVariants.label(bitrate: 0), "")
        XCTAssertEqual(OverseasVariants.label(fromPath: "https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/720x1280/a.mp4?tag=12"), "720P")
        XCTAssertEqual(OverseasVariants.label(fromPath: "https://video.twimg.com/tweet_video/g.mp4"), "")
        XCTAssertEqual(OverseasVariants.fileTag("720P · H.265"), "720P_H.265")
        XCTAssertEqual(OverseasVariants.fileTag("2.1 Mbps"), "2.1Mbps")
    }

    // MARK: X（Twitter）

    func testTwitterTwoVideosEachWithVersions() throws {
        let tweetJSON = json(#"""
        {"data":{"tweetResult":{"result":{"__typename":"Tweet","rest_id":"9","core":{"user_results":{"result":{"core":{"screen_name":"bob"}}}},
        "legacy":{"full_text":"two videos https://t.co/xyz","extended_entities":{"media":[
          {"type":"video","video_info":{"variants":[
            {"content_type":"application/x-mpegURL","url":"https://video.twimg.com/a/pl.m3u8"},
            {"content_type":"video/mp4","bitrate":256000,"url":"https://video.twimg.com/a/vid/avc1/480x270/a1.mp4"},
            {"content_type":"video/mp4","bitrate":2176000,"url":"https://video.twimg.com/a/vid/avc1/1280x720/b1.mp4"},
            {"content_type":"video/mp4","bitrate":832000,"url":"https://video.twimg.com/a/vid/avc1/640x360/c1.mp4"},
            {"content_type":"video/mp4","bitrate":832000,"url":"https://video.twimg.com/a/vid/avc1/640x360/c1.mp4"}]}},
          {"type":"video","video_info":{"variants":[
            {"content_type":"video/mp4","bitrate":950000,"url":"https://video.twimg.com/b/lo.mp4"},
            {"content_type":"video/mp4","bitrate":2500000,"url":"https://video.twimg.com/b/hi.mp4"}]}},
          {"type":"animated_gif","video_info":{"variants":[{"content_type":"video/mp4","bitrate":0,"url":"https://video.twimg.com/tweet_video/g.mp4"}]}}
        ]}}}}}}
        """#)
        let tweet = try TwitterParser.parseTweet(tweetJSON)
        let link = DetectedVideoLink(platform: .twitter, kind: "status", id: "9", url: "https://x.com/bob/status/9")
        let result = TwitterParser().build(link, id: "9", tweet: tweet)
        XCTAssertEqual(result.medias.map(\.url), [
            "https://video.twimg.com/a/vid/avc1/1280x720/b1.mp4", "https://video.twimg.com/a/vid/avc1/640x360/c1.mp4",
            "https://video.twimg.com/a/vid/avc1/480x270/a1.mp4",
            "https://video.twimg.com/b/hi.mp4", "https://video.twimg.com/b/lo.mp4",
            "https://video.twimg.com/tweet_video/g.mp4"
        ])
        XCTAssertEqual(result.medias.map(\.quality), ["720P", "360P", "270P", "2.5 Mbps", "950 kbps", "GIF"])
        XCTAssertEqual(result.medias.map(\.variantGroup), ["video1", "video1", "video1", "video2", "video2", ""])
        XCTAssertEqual(result.medias.map(\.fileName), [
            "two videos_1.mp4", "two videos_1_360P.mp4", "two videos_1_270P.mp4",
            "two videos_2.mp4", "two videos_2_950kbps.mp4", "two videos_3.mp4"
        ])
        XCTAssertEqual(Set(result.medias.map(\.fileName)).count, result.medias.count)
        XCTAssertEqual(result.defaultDownloads.map(\.url), [
            "https://video.twimg.com/a/vid/avc1/1280x720/b1.mp4", "https://video.twimg.com/b/hi.mp4", "https://video.twimg.com/tweet_video/g.mp4"
        ])
    }

    func testTwitterSingleVariantStaysUngrouped() throws {
        let tweetJSON = json(#"""
        {"data":{"tweetResult":{"result":{"rest_id":"8","legacy":{"full_text":"one","extended_entities":{"media":[
          {"type":"video","video_info":{"variants":[{"content_type":"video/mp4","bitrate":632000,"url":"https://video.twimg.com/vid/avc1/320x568/only.mp4"}]}}]}}}}}}
        """#)
        let tweet = try TwitterParser.parseTweet(tweetJSON)
        let result = TwitterParser().build(DetectedVideoLink(platform: .twitter, kind: "status", id: "8", url: ""), id: "8", tweet: tweet)
        XCTAssertEqual(result.medias.count, 1)
        XCTAssertEqual(result.medias[0].fileName, "one.mp4")
        XCTAssertEqual(result.medias[0].quality, "320P")
        XCTAssertEqual(result.medias[0].variantGroup, "")
    }

    // MARK: TikTok

    func testTikTokBitrateLadder() throws {
        let item = json(#"""
        {"id":"77","desc":"dance","author":{"uniqueId":"bob","nickname":"Bob"},"video":{"width":1080,"height":1920,"bitrateInfo":[
          {"Bitrate":1000000,"CodecType":"h264","PlayAddr":{"Width":720,"Height":1280,"DataSize":300,"UrlList":["https://v/720"]}},
          {"Bitrate":2000000,"CodecType":"h265_hvc1","PlayAddr":{"Width":1080,"Height":1920,"DataSize":500,"UrlList":["https://v/1080h265"]}},
          {"Bitrate":900000,"CodecType":"h264","PlayAddr":{"Width":720,"Height":1280,"DataSize":250,"UrlList":["https://v/720b"]}},
          {"Bitrate":1500000,"CodecType":"h264","PlayAddr":{"Width":1080,"Height":1920,"DataSize":700,"UrlList":["https://v/1080h264"]}},
          {"Bitrate":800000,"CodecType":"h264","PlayAddr":{"Width":540,"Height":960,"UrlList":["https://v/720"]}}]}}
        """#)
        let list = try TikTokParser.medias(item)
        XCTAssertEqual(list.count, 1)
        // 默认档与以前一致：(分辨率, 码率, 体积) 最大的那一档
        XCTAssertEqual(list[0].url, "https://v/1080h265")
        let link = DetectedVideoLink(platform: .tiktok, kind: "video", id: "77", url: "https://www.tiktok.com/@bob/video/77")
        let result = TikTokParser().build(link, id: "77", item: item, list: list, cookie: "tt_chain_token=x")
        XCTAssertEqual(result.medias.map(\.url), ["https://v/1080h265", "https://v/1080h264", "https://v/720"])
        XCTAssertEqual(result.medias.map(\.quality), ["1080P · H.265", "1080P", "720P"])
        XCTAssertEqual(result.medias.map(\.fileName), ["dance.mp4", "dance_1080P.mp4", "dance_720P.mp4"])
        XCTAssertEqual(result.medias.map(\.size), [500, 700, 300])
        XCTAssertEqual(Set(result.medias.map(\.variantGroup)), ["video1"])
        XCTAssertEqual(result.medias[2].headers["Cookie"], "tt_chain_token=x")
    }

    // MARK: Instagram / Threads

    func testInstagramVideoVersions() throws {
        let payload = json(#"""
        {"data":{"xdt_api__v1__media__shortcode__web_info":{"items":[{"code":"R1","media_type":2,"caption":{"text":"reel"},"user":{"username":"ann"},
          "image_versions2":{"candidates":[{"url":"https://ig/c.jpg"}]},
          "video_versions":[{"type":101,"width":720,"height":1280,"url":"https://ig/720.mp4"},
                            {"type":102,"width":480,"height":854,"url":"https://ig/480.mp4"},
                            {"type":103,"width":640,"height":1138,"url":"https://ig/640.mp4"},
                            {"type":104,"width":720,"height":1280,"url":"https://ig/720b.mp4"},
                            {"type":105,"width":480,"height":854,"url":"https://ig/720.mp4"}]}]}},"status":"ok"}
        """#)
        let post = try InstagramParser.extractPost(payload)
        XCTAssertEqual(post.medias.first?.url, "https://ig/720.mp4")
        let link = DetectedVideoLink(platform: .instagram, kind: "reel", id: "R1", url: "https://www.instagram.com/reel/R1/")
        let result = InstagramParser().build(link, code: "R1", post: post)
        XCTAssertEqual(result.medias.map(\.url), ["https://ig/720.mp4", "https://ig/640.mp4", "https://ig/480.mp4"])
        XCTAssertEqual(result.medias.map(\.quality), ["720P", "640P", "480P"])
        XCTAssertEqual(result.medias.map(\.fileName), ["reel.mp4", "reel_640P.mp4", "reel_480P.mp4"])
        XCTAssertEqual(Set(result.medias.map(\.variantGroup)), ["video1"])
    }

    func testThreadsVideoVersions() {
        let post = json(#"""
        {"code":"T1","media_type":2,"video_versions":[{"width":1080,"height":1920,"url":"https://t/hi.mp4"},{"width":360,"height":640,"url":"https://t/lo.mp4"}]}
        """#)
        let medias = ThreadsParser.medias(post)
        XCTAssertEqual(medias.map(\.url), ["https://t/hi.mp4"])
        XCTAssertEqual(medias[0].quality, "1080P")
        XCTAssertEqual(medias[0].alternatives, [Option(url: "https://t/lo.mp4", quality: "360P")])
    }

    // MARK: Facebook

    func testFacebookStreams() {
        var v = FacebookParser.Video()
        v.hd = ["https://f/hd.mp4"]
        v.sd = ["https://f/sd.mp4"]
        v.manifests = [#"<MPD><AdaptationSet mimeType="video/mp4"><Representation height="1080" bandwidth="3000"><BaseURL>https://f/1080.mp4</BaseURL></Representation><Representation height="1080" bandwidth="2000"><BaseURL>https://f/1080lo.mp4</BaseURL></Representation><Representation height="480" bandwidth="800"><BaseURL>https://f/480.mp4</BaseURL></Representation></AdaptationSet><AdaptationSet mimeType="audio/mp4"><Representation bandwidth="64"><BaseURL>https://f/a64.mp4</BaseURL></Representation><Representation bandwidth="128"><BaseURL>https://f/a128.mp4</BaseURL></Representation></AdaptationSet></MPD>"#]
        let streams = FacebookParser.streams(v)
        XCTAssertEqual(streams.first, FacebookParser.bestStream(v))
        XCTAssertEqual(streams.map(\.url), ["https://f/1080.mp4", "https://f/hd.mp4", "https://f/480.mp4", "https://f/sd.mp4"])
        XCTAssertEqual(streams.map(\.quality), ["1080P", "HD", "480P", "SD"])
        XCTAssertEqual(streams.map(\.audioURL), ["https://f/a128.mp4", "", "https://f/a128.mp4", ""])

        // 没有分轨音频：DASH 视频轨不列出，只剩渐进式 HD / SD
        var silentDash = FacebookParser.Video()
        silentDash.hd = ["https://f/hd.mp4"]
        silentDash.sd = ["https://f/sd.mp4"]
        silentDash.manifests = [#"<MPD><AdaptationSet mimeType="video/mp4"><Representation height="1080" bandwidth="1"><BaseURL>https://f/1080.mp4</BaseURL></Representation></AdaptationSet></MPD>"#]
        XCTAssertEqual(FacebookParser.streams(silentDash).map(\.quality), ["HD", "SD"])

        var hlsOnly = FacebookParser.Video()
        hlsOnly.hls = ["https://f/x.m3u8"]
        XCTAssertEqual(FacebookParser.streams(hlsOnly).count, 1)
        XCTAssertTrue(FacebookParser.streams(FacebookParser.Video()).isEmpty)
    }

    // MARK: Reddit

    func testRedditDashVideos() {
        let mpd = """
        <MPD><Period>
        <AdaptationSet contentType="video" mimeType="video/mp4">
          <Representation id="1" bandwidth="1200000" height="480"><BaseURL>DASH_480.mp4</BaseURL></Representation>
          <Representation id="2" bandwidth="4800000" height="1080"><BaseURL>DASH_1080.mp4</BaseURL></Representation>
          <Representation id="3" bandwidth="2400000" height="720"><BaseURL>DASH_720.mp4</BaseURL></Representation>
          <Representation id="6" bandwidth="2000000" height="720"><BaseURL>DASH_720_low.mp4</BaseURL></Representation>
        </AdaptationSet>
        <AdaptationSet contentType="audio" mimeType="audio/mp4">
          <Representation id="4" bandwidth="128000"><BaseURL>DASH_AUDIO_128.mp4</BaseURL></Representation>
        </AdaptationSet>
        </Period></MPD>
        """
        let videos = RedditParser.dashVideos(mpd, baseURL: "https://v.redd.it/abc/DASHPlaylist.mpd")
        XCTAssertEqual(videos.map { $0.url }, ["https://v.redd.it/abc/DASH_1080.mp4", "https://v.redd.it/abc/DASH_720.mp4",
                                           "https://v.redd.it/abc/DASH_480.mp4"])
        XCTAssertEqual(videos.map { $0.height }, [1080, 720, 480])
        XCTAssertEqual(videos.first?.url, RedditParser.dashTracks(mpd, baseURL: "https://v.redd.it/abc/DASHPlaylist.mpd").video)
    }

    // MARK: Pinterest

    func testPinterestVideoList() {
        let list = json(#"""
        {"V_HLSV4":{"url":"https://v1.pinimg.com/videos/hls/a.m3u8","width":720,"height":1280},
         "V_720P":{"url":"https://v1.pinimg.com/videos/720p/a.mp4","width":720,"height":1280},
         "V_EXP4":{"url":"https://v1.pinimg.com/videos/exp4/a.mp4","width":360,"height":640},
         "V_EXP7":{"url":"https://v1.pinimg.com/videos/exp7/a.mp4","width":720,"height":1280},
         "V_EXP6":{"url":"https://v1.pinimg.com/videos/exp6/a.mp4","width":540,"height":960}}
        """#)
        let video = PinterestParser.bestVideo(list)
        XCTAssertEqual(video?.url, "https://v1.pinimg.com/videos/720p/a.mp4")
        let options = [Option(url: video?.url ?? "", quality: video?.quality ?? "")] + (video?.alternatives ?? [])
        let medias = OverseasVariants.medias(options, stem: "pin", group: "video1")
        // V_EXP7 与 V_720P 同为 720P，只留一个
        XCTAssertEqual(medias.map(\.quality), ["720P", "540P", "360P"])
        XCTAssertEqual(medias.map(\.fileName), ["pin.mp4", "pin_540P.mp4", "pin_360P.mp4"])
        XCTAssertFalse(medias.contains { $0.isHLS })
    }

    // MARK: Vimeo / Dailymotion / Twitch

    func testVimeoProgressiveLadder() {
        let config = json(#"""
        {"request":{"files":{"progressive":[
            {"url":"https://vod/360.mp4","height":360,"quality":"360p"},
            {"url":"https://vod/1080.mp4","height":1080,"quality":"1080p","bitrate":100},
            {"url":"https://vod/1080b.mp4","height":1080,"quality":"1080p","bitrate":200},
            {"url":"https://vod/720.mp4","height":720,"quality":"720p"}],
          "hls":{"default_cdn":"akfire","cdns":{"akfire":{"url":"https://hls/sep/video/a/playlist.m3u8"}}}}},"video":{"title":"T"}}
        """#)
        let streams = VimeoParser.streams(config)
        XCTAssertEqual(streams.map(\.url), ["https://vod/1080b.mp4", "https://vod/1080.mp4", "https://vod/720.mp4", "https://vod/360.mp4"])
        XCTAssertEqual(streams.first, VimeoParser.bestStream(config))
        let medias = OverseasVariants.medias(streams.map { Option(url: $0.url, quality: $0.quality, isHLS: $0.isHLS) }, stem: "T", group: "video")
        XCTAssertEqual(medias.map(\.quality), ["1080P", "720P", "360P"])

        let hlsOnly = json(#"{"request":{"files":{"progressive":[],"hls":{"default_cdn":"a","cdns":{"a":{"url":"https://hls/sep/video/b/playlist.m3u8"}}}}},"video":{"title":"H"}}"#)
        XCTAssertEqual(VimeoParser.streams(hlsOnly).map(\.isHLS), [true])
    }

    func testDailymotionMP4Ladder() {
        let mp4Only = json(#"{"qualities":{"380":[{"type":"video/mp4","url":"https://v/H264-512x384/a.mp4"}],"720":[{"type":"video/mp4","url":"https://v/H264-1280x720/b.mp4"}],"1080":[{"type":"video/mp4","url":"https://v/H264-1920x1080/c.mp4"}]}}"#)
        let streams = DailymotionParser.streams(mp4Only)
        XCTAssertEqual(streams.map { $0.url }, ["https://v/H264-1920x1080/c.mp4", "https://v/H264-1280x720/b.mp4", "https://v/H264-512x384/a.mp4"])
        XCTAssertEqual(streams.map { $0.quality }, ["1080P", "720P", "384P"])
        XCTAssertEqual(DailymotionParser.bestStream(mp4Only)?.url, streams.first?.url)

        // 有 HLS 主播放列表时只给它（由 HLS 拆分清晰度）
        let mixed = json(#"{"qualities":{"auto":[{"type":"application/x-mpegURL","url":"https://dm/m.m3u8"}],"720":[{"type":"video/mp4","url":"https://v/H264-1280x720/b.mp4"}]}}"#)
        XCTAssertEqual(DailymotionParser.streams(mixed).map { $0.url }, ["https://dm/m.m3u8"])
    }

    func testTwitchClipLadder() {
        let clip = json(#"""
        {"playbackAccessToken":{"signature":"s","value":"v"},"assets":[{"videoQualities":[
          {"quality":"480","frameRate":30,"sourceURL":"https://c/480.mp4"},
          {"quality":"1080","frameRate":60,"sourceURL":"https://c/1080.mp4"},
          {"quality":"720","frameRate":30,"sourceURL":"https://c/720_30.mp4"},
          {"quality":"720","frameRate":60,"sourceURL":"https://c/720.mp4"}]}]}
        """#)
        let streams = TwitchParser.clipStreams(clip)
        XCTAssertEqual(streams.map(\.quality), ["1080P60", "720P60", "720P", "480P"])
        XCTAssertEqual(streams.first, TwitchParser.bestClipStream(clip))
        XCTAssertTrue(streams.allSatisfy { $0.url.hasSuffix("?sig=s&token=v") })
        let medias = OverseasVariants.medias(streams.map { Option(url: $0.url, quality: $0.quality) }, stem: "clip", group: "video")
        XCTAssertEqual(medias.map(\.fileName), ["clip.mp4", "clip_720P60.mp4", "clip_720P.mp4", "clip_480P.mp4"])
    }
}
