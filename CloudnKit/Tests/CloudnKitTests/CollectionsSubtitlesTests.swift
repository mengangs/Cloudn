// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 字幕转换 / 字幕轨解析 / 合集（播放列表、多 P、B 站合集、SoundCloud 歌单）的纯逻辑（离线，内联小样本）
final class CollectionsSubtitlesTests: XCTestCase {
    private func json(_ text: String) -> JSON {
        guard let j = JSON(text: text) else {
            XCTFail("fixture 不是合法 JSON")
            return JSON(nil)
        }
        return j
    }

    private func srt(_ text: String, _ format: SubtitleTrack.Format) -> String? {
        SubtitleConverter.toSRT(Data(text.utf8), format: format).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: SubtitleConverter

    func testTimecode() {
        XCTAssertEqual(SubtitleConverter.timecode(0), "00:00:00,000")
        XCTAssertEqual(SubtitleConverter.timecode(1_234), "00:00:01,234")
        XCTAssertEqual(SubtitleConverter.timecode(3_723_045), "01:02:03,045")
        XCTAssertEqual(SubtitleConverter.timecode(-5), "00:00:00,000")
        XCTAssertEqual(SubtitleConverter.timecode(360_000_000), "100:00:00,000")
    }

    func testVTTTime() {
        XCTAssertEqual(SubtitleConverter.vttTime("00:00:01.000"), 1000)
        XCTAssertEqual(SubtitleConverter.vttTime("01:02:03.456"), 3_723_456)
        XCTAssertEqual(SubtitleConverter.vttTime("02:03.5"), 123_500)
        XCTAssertEqual(SubtitleConverter.vttTime(" 00:00:07,250 "), 7250)
        XCTAssertNil(SubtitleConverter.vttTime("abc"))
        XCTAssertNil(SubtitleConverter.vttTime("12"))
        XCTAssertNil(SubtitleConverter.vttTime("00:01.5:02"))
    }

    func testVTTToSRT() {
        let vtt = "\u{FEFF}WEBVTT\nKind: captions\nLanguage: en\n\nSTYLE\n::cue { color: red }\n\nNOTE 这是注释\n\n"
            + "1\n00:00:01.000 --> 00:00:04.000 align:start position:10%\n<v Roger>Hello &amp; <b>welcome</b></v>\nsecond line\n\n"
            + "00:05.500 --> 00:07.250\n<c.colorE5E5E5>Short</c> &lt;form&gt;\n\n"
            + "00:00:08.000 --> 00:00:09.000\n<c> </c>\n"
        XCTAssertEqual(srt(vtt, .vtt),
                       "1\n00:00:01,000 --> 00:00:04,000\nHello & welcome\nsecond line\n\n2\n00:00:05,500 --> 00:00:07,250\nShort <form>\n\n")
    }

    func testVTTCRLFAndNoTrailingBlank() {
        let vtt = "WEBVTT\r\n\r\n00:00:00.500 --> 00:00:01.500\r\nA\r\n\r\n00:00:02.000 --> 00:00:03.000 line:90%\r\nB"
        XCTAssertEqual(srt(vtt, .vtt), "1\n00:00:00,500 --> 00:00:01,500\nA\n\n2\n00:00:02,000 --> 00:00:03,000\nB\n\n")
    }

    /// YouTube 自动字幕：带逐词时间标签的滚动 cue + 10ms 重复条
    func testYouTubeAutoVTTDeduplicated() {
        let vtt = "WEBVTT\nKind: captions\nLanguage: en\n\n"
            + "00:00:00.000 --> 00:00:02.500 align:start position:0%\n \nhello<00:00:00.320><c> world</c>\n\n"
            + "00:00:02.500 --> 00:00:02.510 align:start position:0%\nhello world\n \n\n"
            + "00:00:02.510 --> 00:00:05.000 align:start position:0%\nhello world\nnext<00:00:02.800><c> line</c>\n\n"
        XCTAssertEqual(srt(vtt, .vtt),
                       "1\n00:00:00,000 --> 00:00:02,510\nhello world\n\n2\n00:00:02,510 --> 00:00:05,000\nnext line\n\n")
    }

    func testNonContiguousRepeatsKept() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nSame\n\n00:00:05.000 --> 00:00:06.000\nSame\n"
        XCTAssertEqual(SubtitleConverter.vttCues(vtt).count, 2)
    }

    func testBiliJSONToSRT() {
        let bili = #"{"font_size":0.4,"body":[{"from":1.2,"to":3.4,"location":2,"content":"第一句"},{"from":3.4,"to":5,"content":"  "},{"from":61.005,"to":62.5,"content":"多行\n第二行"}]}"#
        XCTAssertEqual(srt(bili, .biliJSON),
                       "1\n00:00:01,200 --> 00:00:03,400\n第一句\n\n2\n00:01:01,005 --> 00:01:02,500\n多行\n第二行\n\n")
        XCTAssertNil(srt(#"{"body":[]}"#, .biliJSON))
        XCTAssertNil(srt("not json", .biliJSON))
    }

    func testYouTubeJSON3ToSRT() {
        let j3 = #"""
        {"wireMagic":"pb3","events":[
          {"tStartMs":0,"dDurationMs":5000,"id":1,"wpWinPosId":1,"wsWinStyleId":1},
          {"tStartMs":100,"dDurationMs":2000,"segs":[{"utf8":"Hello"},{"utf8":" world","tOffsetMs":400}]},
          {"tStartMs":2100,"dDurationMs":10,"aAppend":1,"segs":[{"utf8":"\n"}]},
          {"tStartMs":2500,"segs":[{"utf8":"No duration"}]},
          {"tStartMs":4000,"dDurationMs":1000,"segs":[{"utf8":"Last"}]}
        ]}
        """#
        XCTAssertEqual(srt(j3, .youtubeJSON3),
                       "1\n00:00:00,100 --> 00:00:02,100\nHello world\n\n2\n00:00:02,500 --> 00:00:04,000\nNo duration\n\n3\n00:00:04,000 --> 00:00:05,000\nLast\n\n")
    }

    func testSRTPassThroughAndEmpty() {
        let s = "1\n00:00:01,000 --> 00:00:02,000\nHi\n\n"
        XCTAssertEqual(srt(s, .srt), s)
        XCTAssertNil(SubtitleConverter.toSRT(Data(), format: .srt))
        XCTAssertNil(srt("WEBVTT\n\n", .vtt))
    }

    // MARK: YouTube 字幕轨

    func testYouTubeCaptionTracks() {
        let pr = json(#"""
        {"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
          {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&ei=x&lang=en&xosf=1&fmt=srv3","name":{"simpleText":"English (auto-generated)"},"vssId":"a.en","languageCode":"en","kind":"asr","isTranslatable":true},
          {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&lang=zh-Hans&name=CC","name":{"runs":[{"text":"Chinese (Simplified)"}]},"vssId":".zh-Hans","languageCode":"zh-Hans"},
          {"baseUrl":"/api/timedtext?v=abc&lang=ja","name":{"simpleText":"Japanese"},"vssId":".ja","languageCode":"ja"},
          {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&lang=ja","name":{"simpleText":"Japanese dup"},"vssId":".ja","languageCode":"ja"},
          {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&lang=fr&exp=xpe","name":{"simpleText":"French"},"vssId":".fr","languageCode":"fr"},
          {"name":{"simpleText":"No URL"},"languageCode":"de"},
          {"baseUrl":"https://www.youtube.com/api/timedtext?v=abc&lang=ko&kind=asr","name":{"simpleText":"Korean"},"vssId":"a.ko","kind":"asr"}
        ]}}}
        """#)
        let subs = YouTubeParser.subtitles(pr)
        XCTAssertEqual(subs.map { $0.language }, ["zh-Hans", "ja", "en", "ko"])
        XCTAssertEqual(subs.map { $0.automatic }, [false, false, true, true])
        XCTAssertEqual(subs[0].name, "Chinese (Simplified)")
        XCTAssertEqual(subs[0].url, "https://www.youtube.com/api/timedtext?v=abc&lang=zh-Hans&name=CC&fmt=vtt")
        XCTAssertEqual(subs[1].url, "https://www.youtube.com/api/timedtext?v=abc&lang=ja&fmt=vtt")
        XCTAssertEqual(subs[1].name, "Japanese")
        XCTAssertEqual(subs[2].url, "https://www.youtube.com/api/timedtext?v=abc&ei=x&lang=en&fmt=vtt")
        XCTAssertEqual(subs[2].name, "English (auto-generated)")
        XCTAssertEqual(subs[3].name, "Korean（自动生成）")
        XCTAssertTrue(subs.allSatisfy { $0.format == .vtt })
        XCTAssertTrue(YouTubeParser.subtitles(json("{}")).isEmpty)
    }

    func testCaptionURLAndPOToken() {
        XCTAssertEqual(YouTubeParser.captionURL("https://www.youtube.com/api/timedtext?v=a&fmt=json3&xosf=&lang=en#x"),
                       "https://www.youtube.com/api/timedtext?v=a&lang=en&fmt=vtt")
        XCTAssertEqual(YouTubeParser.captionURL("https://www.youtube.com/api/timedtext", format: "json3"),
                       "https://www.youtube.com/api/timedtext?fmt=json3")
        XCTAssertTrue(YouTubeParser.captionRequiresPOToken("https://x/api/timedtext?v=a&exp=xpv&lang=en"))
        XCTAssertTrue(YouTubeParser.captionRequiresPOToken("https://x/api/timedtext?exp=foo&exp=xpe"))
        XCTAssertFalse(YouTubeParser.captionRequiresPOToken("https://x/api/timedtext?v=a&exp=xpex&lang=en"))
        XCTAssertFalse(YouTubeParser.captionRequiresPOToken("https://x/api/timedtext?v=a"))
    }

    // MARK: YouTube 播放列表

    private let browseFirst = #"""
    {"responseContext":{"visitorData":"VIS"},
     "alerts":[{"alertWithButtonRenderer":{"type":"INFO","text":{"simpleText":"Unavailable videos are hidden"}}}],
     "metadata":{"playlistMetadataRenderer":{"title":"My List","description":"desc"}},
     "header":{"playlistHeaderRenderer":{"title":{"simpleText":"Header title"},"ownerText":{"runs":[{"text":"Alice"}]}}},
     "contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"selected":true,"content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[{"playlistVideoListRenderer":{"contents":[
       {"playlistVideoRenderer":{"videoId":"aaaaaaaaaaa","title":{"runs":[{"text":"First"}]},"lengthSeconds":"125","isPlayable":true,
         "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/a1.jpg","width":168},{"url":"https://i.ytimg.com/a2.jpg","width":336}]}}},
       {"playlistVideoRenderer":{"videoId":"bbbbbbbbbbb","title":{"simpleText":"Second"},"lengthText":{"simpleText":"1:02:03"},"isPlayable":true}},
       {"playlistVideoRenderer":{"videoId":"ccccccccccc","title":{"runs":[{"text":"[Private video]"}]},"isPlayable":false}},
       {"continuationItemRenderer":{"trigger":"CONTINUATION_TRIGGER_ON_ITEM_SHOWN","continuationEndpoint":{"commandExecutorCommand":{"commands":[
         {"clickTrackingParams":"x","playlistVotingRefreshPopupCommand":{}},
         {"continuationCommand":{"token":"TOKEN1","request":"CONTINUATION_REQUEST_TYPE_BROWSE"}}]}}}}
     ]}}]}}]}}}}]}},
     "microformat":{"microformatDataRenderer":{"title":"Micro","thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/pl_s.jpg","width":120},{"url":"https://i.ytimg.com/pl.jpg","width":480}]}}}}
    """#

    func testPlaylistFirstPage() {
        let first = json(browseFirst)
        let page = YouTubeParser.playlistPage(first)
        XCTAssertEqual(page.continuation, "TOKEN1")
        XCTAssertEqual(page.entries.map { $0.url }, ["https://www.youtube.com/watch?v=aaaaaaaaaaa", "https://www.youtube.com/watch?v=bbbbbbbbbbb"])
        XCTAssertEqual(page.entries[0].title, "First")
        XCTAssertEqual(page.entries[0].duration, 125)
        XCTAssertEqual(page.entries[0].cover, "https://i.ytimg.com/a2.jpg")
        XCTAssertEqual(page.entries[1].title, "Second")
        XCTAssertEqual(page.entries[1].duration, 3723)
        XCTAssertEqual(page.entries[1].cover, "https://i.ytimg.com/vi/bbbbbbbbbbb/hqdefault.jpg")
        for e in page.entries {
            XCTAssertEqual(VideoLinkParser.parse(e.url)?.platform, .youtube)
            XCTAssertEqual(VideoLinkParser.parse(e.url)?.kind, "video")
        }

        let info = YouTubeParser.playlistInfo(first)
        XCTAssertEqual(info.title, "My List")
        XCTAssertEqual(info.author, "Alice")
        XCTAssertEqual(info.description, "desc")
        XCTAssertEqual(info.cover, "https://i.ytimg.com/pl.jpg")
        XCTAssertNil(YouTubeParser.alertError(first))
    }

    func testPlaylistContinuationPage() {
        let next = json(#"""
        {"onResponseReceivedActions":[{"appendContinuationItemsAction":{"targetId":"pl","continuationItems":[
          {"playlistVideoRenderer":{"videoId":"ddddddddddd","title":{"runs":[{"text":"Fourth"}]},"lengthSeconds":"59"}},
          {"lockupViewModel":{"contentId":"eeeeeeeeeee","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
            "metadata":{"lockupMetadataViewModel":{"title":{"content":"Fifth"}}},
            "contentImage":{"thumbnailViewModel":{"image":{"sources":[{"url":"https://i.ytimg.com/e.jpg","width":360}]},
              "overlays":[{"thumbnailOverlayBadgeViewModel":{"thumbnailBadges":[{"thumbnailBadgeViewModel":{"text":"4:05"}}]}}]}}}},
          {"lockupViewModel":{"contentId":"PLxyz","contentType":"LOCKUP_CONTENT_TYPE_PLAYLIST"}},
          {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"TOKEN2"}}}}
        ]}}]}
        """#)
        let page = YouTubeParser.playlistPage(next)
        XCTAssertEqual(page.entries.map { $0.title }, ["Fourth", "Fifth"])
        XCTAssertEqual(page.entries[1].url, "https://www.youtube.com/watch?v=eeeeeeeeeee")
        XCTAssertEqual(page.entries[1].duration, 245)
        XCTAssertEqual(page.entries[1].cover, "https://i.ytimg.com/e.jpg")
        XCTAssertEqual(page.continuation, "TOKEN2")

        let last = json(#"{"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[{"playlistVideoRenderer":{"videoId":"fffffffffff","title":{"simpleText":"F"}}}]}}]}"#)
        XCTAssertEqual(YouTubeParser.playlistPage(last).continuation, "")
        XCTAssertNil(YouTubeParser.playlistPage(last).entries[0].duration)
    }

    func testPlaylistInfoFallbacksAndAlerts() {
        let pageHeader = json(#"""
        {"header":{"pageHeaderRenderer":{"pageTitle":"New layout","content":{"pageHeaderViewModel":{"metadata":{"contentMetadataViewModel":{"metadataRows":[
          {"metadataParts":[{"text":{"content":"by Bob and 2 others"}}]},{"metadataParts":[{"text":{"content":"12 videos"}}]}]}}}}}}}
        """#)
        let info = YouTubeParser.playlistInfo(pageHeader)
        XCTAssertEqual(info.title, "New layout")
        XCTAssertEqual(info.author, "Bob")

        let sidebar = json(#"{"header":{"playlistHeaderRenderer":{"title":{"runs":[{"text":"Old"}]}}},"sidebar":{"playlistSidebarRenderer":{"items":[{"playlistSidebarPrimaryInfoRenderer":{}},{"playlistSidebarSecondaryInfoRenderer":{"videoOwner":{"videoOwnerRenderer":{"title":{"runs":[{"text":"Carol"}]}}}}}]}}}"#)
        XCTAssertEqual(YouTubeParser.playlistInfo(sidebar).title, "Old")
        XCTAssertEqual(YouTubeParser.playlistInfo(sidebar).author, "Carol")

        let missing = json(#"{"alerts":[{"alertRenderer":{"type":"ERROR","text":{"runs":[{"text":"The playlist does not exist."}]}}}]}"#)
        let error = YouTubeParser.alertError(missing)
        XCTAssertEqual(error?.kind, .notFound)
        XCTAssertTrue(error?.detail.contains("The playlist does not exist.") ?? false)
    }

    func testPlaylistHelpers() {
        XCTAssertEqual(YouTubeParser.playlistID(from: "https://www.youtube.com/playlist?list=PLabc_DEF-123&si=x"), "PLabc_DEF-123")
        XCTAssertEqual(YouTubeParser.playlistID(from: "https://music.youtube.com/playlist?feature=share&list=OLAK5uy_abc"), "OLAK5uy_abc")
        XCTAssertNil(YouTubeParser.playlistID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertTrue(YouTubeParser.isMixPlaylist("RDdQw4w9WgXcQ"))
        XCTAssertFalse(YouTubeParser.isMixPlaylist("PLxyz"))
        XCTAssertEqual(YouTubeParser.parseClock("4:05"), 245)
        XCTAssertEqual(YouTubeParser.parseClock("1:00:00"), 3600)
        XCTAssertNil(YouTubeParser.parseClock("LIVE"))
        XCTAssertNil(YouTubeParser.parseClock("SHORTS"))
        XCTAssertNil(YouTubeParser.parseClock(""))

        let body = YouTubeParser.browseRequestBody(["browseId": "VLPLx"])
        XCTAssertEqual(body["browseId"] as? String, "VLPLx")
        let client = (body["context"] as? [String: Any])?["client"] as? [String: Any]
        XCTAssertEqual(client?["clientName"] as? String, "WEB")
        XCTAssertEqual(YouTubeParser.browseHeaders(visitorData: "V")["X-Goog-Visitor-Id"], "V")
        XCTAssertEqual(YouTubeParser.browseHeaders(visitorData: "")["X-YouTube-Client-Name"], "1")
        XCTAssertNil(YouTubeParser.browseHeaders(visitorData: "")["X-Goog-Visitor-Id"])
    }

    // MARK: B 站字幕 / WBI

    func testBiliSubtitleTracks() {
        let j = json(#"""
        {"code":0,"data":{"need_login_subtitle":false,"subtitle":{"subtitles":[
          {"id":1,"lan":"ai-zh","lan_doc":"中文（自动生成）","subtitle_url":"//aisubtitle.hdslb.com/bfs/ai_subtitle/prod/x.json?auth_key=1"},
          {"id":2,"lan":"zh-CN","lan_doc":"中文（中国）","subtitle_url":"https://i0.hdslb.com/bfs/subtitle/y.json"},
          {"id":3,"lan":"en-US","lan_doc":"English","subtitle_url":""},
          {"id":4,"lan":"ai-en","lan_doc":"English","subtitle_url":"http://aisubtitle.hdslb.com/z.json"}
        ]}}}
        """#)
        let subs = BilibiliParser.subtitleTracks(j)
        XCTAssertEqual(subs.map { $0.language }, ["zh-CN", "ai-zh", "ai-en"])
        XCTAssertEqual(subs.map { $0.automatic }, [false, true, true])
        XCTAssertEqual(subs[0].name, "中文（中国）")
        XCTAssertEqual(subs[1].url, "https://aisubtitle.hdslb.com/bfs/ai_subtitle/prod/x.json?auth_key=1")
        XCTAssertEqual(subs[1].name, "中文（自动生成）")
        XCTAssertEqual(subs[2].url, "https://aisubtitle.hdslb.com/z.json")
        XCTAssertEqual(subs[2].name, "English（AI 生成）")
        XCTAssertTrue(subs.allSatisfy { $0.format == .biliJSON && $0.headers["Referer"] == "https://www.bilibili.com/" })
        XCTAssertTrue(BilibiliParser.subtitleTracks(json(#"{"code":0,"data":{"subtitle":{"subtitles":[]}}}"#)).isEmpty)
    }

    /// 期望值用 yt-dlp bilibili.py 的 _get_wbi_key / _sign_wbi 算法在 Python 里算出
    func testWbiSign() {
        let img = BilibiliWbi.key(fromURL: "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png")
        let sub = BilibiliWbi.key(fromURL: "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png")
        XCTAssertEqual(img, "7cd084941338484aae1ad9425b84077c")
        let key = BilibiliWbi.mixinKey(imgKey: img, subKey: sub)
        XCTAssertEqual(key, "ea1db124af3c7062474693fa704f4ff8")
        XCTAssertEqual(BilibiliWbi.sign(["bvid": "BV1GJ411x7h7", "cid": "137649199"], mixinKey: key, timestamp: 1_700_000_000),
                       "bvid=BV1GJ411x7h7&cid=137649199&wts=1700000000&w_rid=901e03bc9e7b896058c8b28b96ae2c7e")
        XCTAssertEqual(BilibiliWbi.sign(["foo": "one two!", "bar": "五一四", "baz": "(x)*'"], mixinKey: key, timestamp: 1_702_204_169),
                       "bar=%E4%BA%94%E4%B8%80%E5%9B%9B&baz=x&foo=one+two&wts=1702204169&w_rid=01d7c1f0f34beb9e4a5db04f0bc92d98")
    }

    // MARK: B 站多 P / 合集

    private let biliView = #"""
    {"bvid":"BV1xx411c7mD","title":"总标题","pic":"http://i0.hdslb.com/p.jpg",
     "pages":[{"cid":1,"page":1,"part":"开头","duration":61},{"cid":2,"page":2,"part":"","duration":30,"first_frame":"//i0.hdslb.com/f.jpg"}],
     "ugc_season":{"id":9,"title":"合集X","sections":[
       {"episodes":[{"bvid":"BV1aa411c7aa","title":"E1","arc":{"duration":100,"pic":"https://i0.hdslb.com/e1.jpg"}},
                    {"bvid":"BV1bb411c7bb","title":"E2","arc":{"duration":0},"page":{"duration":50}}]},
       {"episodes":[{"bvid":"BV1aa411c7aa","title":"dup"},{"bvid":"BV1cc411c7cc","arc":{"title":"E3"}}]}]}}
    """#

    func testBiliMultiPageEntries() {
        let c = BilibiliParser.collection(json(biliView), explicitPage: false)
        XCTAssertEqual(c.title, "总标题")
        XCTAssertTrue(c.notice.contains("2 个分 P"))
        XCTAssertEqual(c.entries.map { $0.url }, ["https://www.bilibili.com/video/BV1xx411c7mD?p=1", "https://www.bilibili.com/video/BV1xx411c7mD?p=2"])
        XCTAssertEqual(c.entries.map { $0.title }, ["P1 开头", "P2"])
        XCTAssertEqual(c.entries[0].duration, 61)
        XCTAssertEqual(c.entries[0].cover, "https://i0.hdslb.com/p.jpg")
        XCTAssertEqual(c.entries[1].cover, "https://i0.hdslb.com/f.jpg")
        for e in c.entries {
            XCTAssertEqual(VideoLinkParser.parse(e.url)?.platform, .bilibili)
            XCTAssertEqual(VideoLinkParser.parse(e.url)?.id, "BV1xx411c7mD")
        }
    }

    func testBiliSeasonEntries() {
        // 链接指定了 ?p= 时不展开分 P，退回合集
        let c = BilibiliParser.collection(json(biliView), explicitPage: true)
        XCTAssertNil(c.title)
        XCTAssertTrue(c.notice.contains("合集X"))
        XCTAssertEqual(c.entries.map { $0.url }, ["https://www.bilibili.com/video/BV1aa411c7aa", "https://www.bilibili.com/video/BV1bb411c7bb",
                                                  "https://www.bilibili.com/video/BV1cc411c7cc"])
        XCTAssertEqual(c.entries.map { $0.title }, ["E1", "E2", "E3"])
        XCTAssertEqual(c.entries[0].duration, 100)
        XCTAssertEqual(c.entries[1].duration, 50)
        XCTAssertNil(c.entries[2].duration)
        XCTAssertEqual(VideoLinkParser.parse(c.entries[0].url)?.kind, "video")

        let single = json(#"{"bvid":"BV1xx411c7mD","title":"T","pages":[{"cid":1,"page":1,"part":"p"}]}"#)
        XCTAssertTrue(BilibiliParser.collection(single, explicitPage: false).entries.isEmpty)
        XCTAssertEqual(BilibiliParser.collection(single, explicitPage: false).notice, "")
        XCTAssertNil(BilibiliParser.collection(single, explicitPage: false).title)
    }

    // MARK: SoundCloud 歌单

    func testSoundCloudSetEntries() {
        let set = json(#"""
        {"id":123,"kind":"playlist","title":"Set","tracks":[
          {"id":1,"kind":"track","title":"A","permalink_url":"https://soundcloud.com/u/a","duration":61000,"artwork_url":"https://i1.sndcdn.com/artworks-x-large.jpg"},
          {"id":2,"kind":"track","monetization_model":"NOT_APPLICABLE"},
          {"id":3,"kind":"track"}]}
        """#)
        XCTAssertEqual(SoundCloudParser.stubTrackIDs(set), ["2", "3"])
        let fetched = ["2": json(#"{"id":2,"title":"B","permalink_url":"https://soundcloud.com/u/b","duration":1500,"artwork_url":null,"user":{"avatar_url":"https://i1.sndcdn.com/avatars-y-large.jpg"}}"#)]
        let entries = SoundCloudParser.setEntries(set, fetched: fetched)
        XCTAssertEqual(entries.map { $0.url }, ["https://soundcloud.com/u/a", "https://soundcloud.com/u/b", "https://api-v2.soundcloud.com/tracks/3"])
        XCTAssertEqual(entries.map { $0.title }, ["A", "B", "SoundCloud 3"])
        XCTAssertEqual(entries[0].duration, 61)
        XCTAssertEqual(entries[1].duration, 1.5)
        XCTAssertNil(entries[2].duration)
        XCTAssertEqual(entries[0].cover, "https://i1.sndcdn.com/artworks-x-t500x500.jpg")
        XCTAssertEqual(entries[1].cover, "https://i1.sndcdn.com/avatars-y-t500x500.jpg")
        XCTAssertEqual(entries[2].cover, "")
        XCTAssertEqual(VideoLinkParser.parse(entries[0].url)?.kind, "track")
        XCTAssertEqual(VideoLinkParser.parse(entries[2].url)?.kind, "api")
        XCTAssertEqual(VideoLinkParser.parse(entries[2].url)?.id, "3")

        let secret = json(#"{"id":5,"secret_token":"s-abc","tracks":[{"id":9}]}"#)
        XCTAssertEqual(SoundCloudParser.setEntries(secret, fetched: [:]).first?.url, "https://api-v2.soundcloud.com/tracks/9?secret_token=s-abc")
    }

    func testSoundCloudBatches() {
        let ids = (1...120).map { String($0) }
        let batches = SoundCloudParser.batches(ids, size: 50)
        XCTAssertEqual(batches.map { $0.count }, [50, 50, 20])
        XCTAssertEqual(batches[1].first, "51")
        XCTAssertTrue(SoundCloudParser.batches([], size: 50).isEmpty)
    }
}
