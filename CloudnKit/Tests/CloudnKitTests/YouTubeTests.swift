import XCTest
@testable import CloudnKit

/// YouTube 解析的纯逻辑（离线小样本）；JS 求解部分只在有 JavaScriptCore 的平台上跑
final class YouTubeTests: XCTestCase {
    // MARK: 链接

    func testVideoID() {
        let id = "dQw4w9WgXcQ"
        let ok = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10s",
            "https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?app=desktop&v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ?si=abc",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://youtube.com/live/dQw4w9WgXcQ?feature=share",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
            "https://www.youtube.com/embed/dQw4w9WgXcQ?start=3",
            "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVM"
        ]
        for url in ok { XCTAssertEqual(YouTubeParser.videoID(from: url), id, url) }
        XCTAssertNil(YouTubeParser.videoID(from: "https://www.youtube.com/@channel"))
        XCTAssertNil(YouTubeParser.videoID(from: "https://notyoutube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubeParser.videoID(from: "https://www.youtube.com/watch?v=short"))
        XCTAssertNil(YouTubeParser.videoID(from: "https://www.youtube.com/watch?vi=dQw4w9WgXcQ"))
        XCTAssertTrue(YouTubeParser.isVideoID(id))
        XCTAssertFalse(YouTubeParser.isVideoID("dQw4w9WgXc"))
        XCTAssertFalse(YouTubeParser.isVideoID("dQw4w9WgXc!"))
    }

    // MARK: 页面

    func testWatchPageExtraction() {
        let html = #"""
        <html><script>ytcfg.set({"VISITOR_DATA":"Cgt2aXM%3D","STS":20345,"PLAYER_JS_URL":"/s/player/1a2b3c4d/player_ias.vflset/en_US/base.js","X":"a})b"});ytcfg.set({"WEB_PLAYER_CONTEXT_CONFIGS":{"WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER":{"jsUrl":"/s/player/1a2b3c4d/player_ias.vflset/en_US/base.js","encryptedHostFlags":"flg"}}});</script>
        <script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"dQw4w9WgXcQ","title":"T \"q\" {x}"}};var meta = 1;</script></html>
        """#
        let cfg = YouTubeParser.ytcfg(in: html)
        XCTAssertEqual(cfg["STS"].int, 20345)
        XCTAssertEqual(cfg["X"].string, "a})b")
        XCTAssertEqual(YouTubeParser.visitorData(cfg), "Cgt2aXM%3D")
        XCTAssertEqual(cfg["WEB_PLAYER_CONTEXT_CONFIGS"]["WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER"]["encryptedHostFlags"].string, "flg")
        XCTAssertEqual(YouTubeParser.playerID(inConfig: cfg), "1a2b3c4d")

        let pr = YouTubeParser.initialPlayerResponse(in: html)
        XCTAssertEqual(pr["videoDetails"]["title"].string, #"T "q" {x}"#)
        XCTAssertNil(YouTubeParser.playability(pr))
        XCTAssertTrue(YouTubeParser.initialPlayerResponse(in: "<html></html>").isNull)
    }

    func testPlayerScriptHelpers() {
        let iframe = #"var scriptUrl = 'https:\/\/www.youtube.com\/s\/player\/0ab1c2d3\/www-widgetapi.vflset\/www-widgetapi.js';"#
        XCTAssertEqual(YouTubeParser.playerID(inIframeAPI: iframe), "0ab1c2d3")
        XCTAssertEqual(YouTubeParser.playerURL(id: "0ab1c2d3"),
                       "https://www.youtube.com/s/player/0ab1c2d3/player_ias.vflset/en_US/base.js")
        XCTAssertEqual(YouTubeParser.signatureTimestamp(in: "var x={a:1,signatureTimestamp:20345,b:2}"), 20345)
        XCTAssertEqual(YouTubeParser.signatureTimestamp(in: "f({sts:19999})"), 19999)
        XCTAssertEqual(YouTubeParser.signatureTimestamp(in: "nothing"), 0)
    }

    // MARK: 请求

    func testPlayerRequest() {
        // 走一遍序列化，与真正发出去的请求体一致
        func roundTrip(_ dict: [String: Any]) -> JSON { JSON(data: JSON.serialize(dict)) ?? JSON(nil) }
        let body = roundTrip(YouTubeParser.playerRequestBody(client: .visionOS, version: "1.02", videoID: "dQw4w9WgXcQ",
                                                             signatureTimestamp: 0, encryptedHostFlags: ""))
        XCTAssertEqual(body["videoId"].string, "dQw4w9WgXcQ")
        XCTAssertEqual(body["context"]["client"]["clientName"].string, "VISIONOS")
        XCTAssertEqual(body["context"]["client"]["deviceModel"].string, "RealityDevice17,1")
        XCTAssertEqual(body["context"]["client"]["hl"].string, "en")
        XCTAssertTrue(body["contentCheckOk"].bool)
        XCTAssertTrue(body["playbackContext"]["contentPlaybackContext"]["signatureTimestamp"].isNull)
        XCTAssertTrue(body["context"]["thirdParty"].isNull)

        let embedded = roundTrip(YouTubeParser.playerRequestBody(client: .webEmbedded, version: "2.1", videoID: "dQw4w9WgXcQ",
                                                                 signatureTimestamp: 20345, encryptedHostFlags: "flg"))
        XCTAssertEqual(embedded["context"]["thirdParty"]["embedUrl"].string, "https://www.reddit.com/")
        XCTAssertEqual(embedded["context"]["client"]["clientVersion"].string, "2.1")
        XCTAssertEqual(embedded["playbackContext"]["contentPlaybackContext"]["signatureTimestamp"].int, 20345)
        XCTAssertEqual(embedded["playbackContext"]["contentPlaybackContext"]["encryptedHostFlags"].string, "flg")

        let headers = YouTubeParser.apiHeaders(client: .tvSamsung, version: "5.20260707", visitorData: "VD")
        XCTAssertEqual(headers["X-YouTube-Client-Name"], "7")
        XCTAssertEqual(headers["X-YouTube-Client-Version"], "5.20260707")
        XCTAssertEqual(headers["X-Goog-Visitor-Id"], "VD")
        XCTAssertTrue(headers["User-Agent"]?.contains("Tizen") ?? false)
        XCTAssertNil(YouTubeParser.apiHeaders(client: .visionOS, version: "1.02", visitorData: "")["X-Goog-Visitor-Id"])
    }

    // MARK: 可播放状态

    func testPlayability() {
        func pr(_ text: String) -> JSON { JSON(text: text)! }
        XCTAssertNil(YouTubeParser.playability(pr(#"{"playabilityStatus":{"status":"OK"}}"#)))

        let bot = YouTubeParser.playability(pr(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you’re not a bot"}}"#))
        XCTAssertEqual(bot?.botCheck, true)
        XCTAssertEqual(bot?.definitive, false)

        let age = YouTubeParser.playability(pr(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm your age","desktopLegacyAgeGateReason":1}}"#))
        XCTAssertEqual(age?.tryEmbedded, true)
        XCTAssertTrue(age?.error.detail.contains("年龄") ?? false)

        let priv = YouTubeParser.playability(pr(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"This video is private"}}"#))
        XCTAssertEqual(priv?.definitive, true)
        XCTAssertTrue(priv?.error.detail.contains("私享") ?? false)

        let gone = YouTubeParser.playability(pr(#"{"playabilityStatus":{"status":"ERROR","reason":"Video unavailable","errorScreen":{"playerErrorMessageRenderer":{"reason":{"simpleText":"Video unavailable"},"subreason":{"runs":[{"text":"This video has been "},{"text":"removed"}]}}}}}"#))
        XCTAssertEqual(gone?.definitive, true)
        XCTAssertEqual(gone?.error.kind, .notFound)
        XCTAssertTrue(gone?.error.detail.contains("This video has been removed") ?? false)

        let region = YouTubeParser.playability(pr(#"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"The uploader has not made this video available in your country"}}"#))
        XCTAssertTrue(region?.error.detail.contains("地区") ?? false)

        let kids = YouTubeParser.playability(pr(#"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"This video is made for kids"}}"#))
        XCTAssertEqual(kids?.tryEmbedded, true)
        XCTAssertEqual(kids?.definitive, false)

        let limited = YouTubeParser.playability(pr(#"{"playabilityStatus":{"status":"ERROR","reason":"This content isn't available, try again later."}}"#))
        XCTAssertEqual(limited?.botCheck, true)
        XCTAssertEqual(limited?.definitive, false)

        XCTAssertNotNil(YouTubeParser.liveError(pr(#"{"videoDetails":{"isLive":true}}"#)))
        XCTAssertNotNil(YouTubeParser.liveError(pr(#"{"videoDetails":{"isUpcoming":true}}"#)))
        XCTAssertNil(YouTubeParser.liveError(pr(#"{"videoDetails":{"isLiveContent":true}}"#)))
    }

    // MARK: 格式

    static let streamingData = #"""
    {"formats":[
      {"itag":18,"url":"https://rr1.googlevideo.com/videoplayback?itag=18&n=AAA&x=1","mimeType":"video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"","width":640,"height":360,"fps":30,"bitrate":500000,"contentLength":"1000"}
    ],
    "adaptiveFormats":[
      {"itag":137,"signatureCipher":"s=ABCDEFGH&sp=sig&url=https%3A%2F%2Frr1.googlevideo.com%2Fvideoplayback%3Fitag%3D137%26n%3DBBB","mimeType":"video/mp4; codecs=\"avc1.640028\"","width":1920,"height":1080,"fps":30,"bitrate":4000000,"contentLength":"50000"},
      {"itag":248,"url":"https://rr1.googlevideo.com/videoplayback?itag=248","mimeType":"video/webm; codecs=\"vp9\"","width":1920,"height":1080,"fps":30,"bitrate":3000000},
      {"itag":401,"url":"https://rr1.googlevideo.com/videoplayback?itag=401","mimeType":"video/mp4; codecs=\"av01.0.12M.08\"","width":3840,"height":2160,"fps":30,"bitrate":18000000},
      {"itag":136,"url":"https://rr1.googlevideo.com/videoplayback?itag=136","mimeType":"video/mp4; codecs=\"avc1.4d401f\"","width":1280,"height":720,"fps":30,"bitrate":2000000},
      {"itag":140,"url":"https://rr1.googlevideo.com/videoplayback?itag=140&lang=fr","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":135000,"audioTrack":{"displayName":"French","id":"fr.3","audioIsDefault":false}},
      {"itag":140,"url":"https://rr1.googlevideo.com/videoplayback?itag=140&lang=en","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":130000,"contentLength":"3000","audioTrack":{"displayName":"English original","id":"en.4","audioIsDefault":true}},
      {"itag":251,"url":"https://rr1.googlevideo.com/videoplayback?itag=251","mimeType":"audio/webm; codecs=\"opus\"","bitrate":160000},
      {"itag":299,"url":"https://rr1.googlevideo.com/videoplayback?itag=299&live=1","mimeType":"video/mp4; codecs=\"avc1.64002a\"","width":1920,"height":1080,"fps":60,"targetDurationSec":5},
      {"itag":298,"mimeType":"video/mp4; codecs=\"avc1.4d4020\"","width":1280,"height":720},
      {"itag":399,"url":"https://rr1.googlevideo.com/videoplayback?itag=399","mimeType":"video/mp4; codecs=\"avc1.640028\"","width":1920,"height":1080,"drmFamilies":["WIDEVINE"]}
    ]}
    """#

    func testFormatParsing() throws {
        let parsed = YouTubeParser.formats(try XCTUnwrap(JSON(text: Self.streamingData)))
        XCTAssertEqual(parsed.list.count, 8)
        XCTAssertEqual(parsed.missingURL, 1)
        XCTAssertEqual(parsed.drm, 1)

        let f137 = try XCTUnwrap(parsed.list.first { $0.itag == 137 })
        XCTAssertEqual(f137.url, "https://rr1.googlevideo.com/videoplayback?itag=137&n=BBB")
        XCTAssertEqual(f137.sigChallenge, "ABCDEFGH")
        XCTAssertEqual(f137.sigParam, "sig")
        XCTAssertEqual(f137.nChallenge, "BBB")
        XCTAssertEqual(f137.codecs, "avc1.640028")
        XCTAssertTrue(f137.isMP4Video && f137.isH264 && f137.needsJS)

        let f18 = try XCTUnwrap(parsed.list.first { $0.itag == 18 })
        XCTAssertTrue(f18.progressive)
        XCTAssertEqual(f18.nChallenge, "AAA")
        XCTAssertEqual(f18.contentLength, 1000)
        XCTAssertFalse(try XCTUnwrap(parsed.list.first { $0.itag == 401 }).isMP4Video)
    }

    func testChooseAndResolve() throws {
        let parsed = YouTubeParser.formats(try XCTUnwrap(JSON(text: Self.streamingData)))
        let choices = YouTubeParser.choose(parsed.list)
        XCTAssertEqual(choices.map { $0.quality }, ["1080p", "720p", "2160p · AV1（需 A17 Pro / M3 及以上机型）", "360p（音视频合一）", "仅音频"])
        XCTAssertEqual(choices.map { $0.suffix }, ["", "_720p", "_2160p_av1", "_360p", ""])
        XCTAssertEqual(choices[0].main.itag, 137)
        // 原声音轨优先于码率更高的配音轨
        XCTAssertEqual(choices[0].audio?.url, "https://rr1.googlevideo.com/videoplayback?itag=140&lang=en")
        XCTAssertEqual(choices[2].main.itag, 401)
        XCTAssertEqual(choices[4].kind, .audio)
        // 更高档已以 AV1 提供，不再提示
        XCTAssertEqual(YouTubeParser.notice(parsed.list, choices: choices), "")

        let solution = YouTubeSignature.Solution(sig: ["ABCDEFGH": "HG/FE"], n: ["BBB": "b-b", "AAA": "zz"])
        XCTAssertEqual(YouTubeParser.resolvedURL(choices[0].main, solution),
                       "https://rr1.googlevideo.com/videoplayback?itag=137&n=b-b&sig=HG%2FFE")
        XCTAssertEqual(YouTubeParser.resolvedURL(choices[3].main, solution),
                       "https://rr1.googlevideo.com/videoplayback?itag=18&n=zz&x=1")
        XCTAssertNil(YouTubeParser.resolvedURL(choices[0].main, YouTubeSignature.Solution()))

        let medias = YouTubeParser.medias(choices, solution: solution, base: "Song")
        XCTAssertEqual(medias.map { $0.fileName }, ["Song.mp4", "Song_720p.mp4", "Song_2160p_av1.mp4", "Song_360p.mp4", "Song.m4a"])
        XCTAssertEqual(Set(medias.map { $0.variantGroup }), ["video"])
        XCTAssertEqual(medias[0].audioURL, "https://rr1.googlevideo.com/videoplayback?itag=140&lang=en")
        XCTAssertEqual(medias[3].size, 1000)
        XCTAssertEqual(medias[4].kind, .audio)
        XCTAssertEqual(medias[4].size, 3000)
        XCTAssertEqual(medias[0].headers["User-Agent"], VideoHTTP.uaChrome)

        // 没解出 n 的分轨直接丢掉
        let partial = YouTubeParser.medias(choices, solution: YouTubeSignature.Solution(sig: ["ABCDEFGH": "x"], n: [:]), base: "S")
        XCTAssertEqual(partial.map { $0.fileName }, ["S_720p.mp4", "S_2160p_av1.mp4", "S.m4a"])
    }

    func testChooseVerticalAndHEVC() throws {
        let data = JSON(text: #"""
        {"adaptiveFormats":[
          {"itag":1,"url":"https://a/v?i=1","mimeType":"video/mp4; codecs=\"avc1.640028\"","width":1080,"height":1920,"fps":30,"bitrate":3},
          {"itag":2,"url":"https://a/v?i=2","mimeType":"video/mp4; codecs=\"hvc1.2.4.L153\"","width":2160,"height":3840,"fps":60,"bitrate":9},
          {"itag":3,"url":"https://a/v?i=3","mimeType":"video/mp4; codecs=\"hvc1.1.6.L120\"","width":1080,"height":1920,"fps":30,"bitrate":5},
          {"itag":4,"url":"https://a/v?i=4","mimeType":"audio/mp4; codecs=\"mp4a.40.2\"","bitrate":128000}
        ]}
        """#)!
        let choices = YouTubeParser.choose(YouTubeParser.formats(data).list)
        XCTAssertEqual(choices.map { $0.quality }, ["2160p60 · HEVC", "1080p", "仅音频"])
        XCTAssertEqual(choices[0].main.itag, 2)
        XCTAssertEqual(choices[0].suffix, "")
        XCTAssertEqual(choices[1].main.itag, 1)
        XCTAssertEqual(choices[1].suffix, "_1080p")
        XCTAssertEqual(YouTubeParser.notice(YouTubeParser.formats(data).list, choices: choices), "")

        // 没有 m4a 音轨：分轨合并不了，只剩合一流 / 什么都没有
        let noAudio = JSON(text: #"{"adaptiveFormats":[{"itag":1,"url":"https://a/v","mimeType":"video/mp4; codecs=\"avc1.640028\"","width":1920,"height":1080}]}"#)!
        XCTAssertTrue(YouTubeParser.choose(YouTubeParser.formats(noAudio).list).isEmpty)
    }

    func testQueryHelpers() {
        let q = YouTubeParser.parseQuery("s=a%2Bb%3D&sp=sig&url=https%3A%2F%2Fx%2Fy%3Fa%3D1+2")
        XCTAssertEqual(q["s"], "a+b=")
        XCTAssertEqual(q["sp"], "sig")
        XCTAssertEqual(q["url"], "https://x/y?a=1 2")
        XCTAssertEqual(YouTubeParser.queryValue("https://x/y?a=1&n=Q-w_e#frag", "n"), "Q-w_e")
        XCTAssertNil(YouTubeParser.queryValue("https://x/y", "n"))
        XCTAssertEqual(YouTubeParser.replacingQuery("https://x/y?n=old&nn=keep&b=2", name: "n", value: "new"),
                       "https://x/y?n=new&nn=keep&b=2")
        XCTAssertEqual(YouTubeParser.manifestNChallenge("https://manifest.googlevideo.com/api/manifest/hls_variant/expire/1/n/abcXYZ/file/index.m3u8"),
                       "abcXYZ")
        XCTAssertNil(YouTubeParser.manifestNChallenge("https://manifest.googlevideo.com/api/manifest/hls_variant/expire/1/file/index.m3u8"))
    }

    func testMetadataHelpers() {
        let details = JSON(text: #"{"thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/a.jpg","width":120},{"url":"https://i.ytimg.com/b.jpg","width":1280},{"url":"https://i.ytimg.com/c.jpg","width":480}]}}"#)!
        XCTAssertEqual(YouTubeParser.thumbnail(details, id: "dQw4w9WgXcQ"), "https://i.ytimg.com/b.jpg")
        XCTAssertEqual(YouTubeParser.thumbnail(JSON(nil), id: "dQw4w9WgXcQ"), "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        XCTAssertEqual(YouTubeParser.parseDate("2009-10-25T00:00:00-07:00"), 1256454000)
        XCTAssertEqual(YouTubeParser.parseDate("2009-10-25"), 1256428800)
        XCTAssertEqual(YouTubeParser.parseDate(""), 0)
    }

    // MARK: 签名求解

    func testSolverRequestAndOutput() throws {
        let (request, types) = YouTubeSignature.requestJSON(sig: ["s1"], n: ["n1", "n2"])
        XCTAssertEqual(types, ["sig", "n"])
        let json = try XCTUnwrap(JSON(text: request))
        XCTAssertEqual(json["requests"][0]["type"].string, "sig")
        XCTAssertEqual(json["requests"][1]["challenges"].array.map { $0.string }, ["n1", "n2"])

        let output = #"{"type":"result","responses":[{"type":"result","data":{"abc":"cba"}},{"type":"error","error":"x"}],"preprocessed_player":"P"}"#
        let parsed = try YouTubeSignature.parseOutput(output, types: ["sig", "n"])
        XCTAssertEqual(parsed.solution.sig, ["abc": "cba"])
        XCTAssertEqual(parsed.solution.n, [:])
        XCTAssertEqual(parsed.preprocessed, "P")
        XCTAssertThrowsError(try YouTubeSignature.parseOutput(#"{"type":"error","error":"boom"}"#, types: ["n"]))
    }

    func testPlayerCache() {
        let cache = YouTubePlayerCache()
        cache.storePlayer("JS", timestamp: 20001, for: "aaaa0001")
        XCTAssertEqual(cache.playerJS(for: "aaaa0001"), "JS")
        XCTAssertNil(cache.playerJS(for: "bbbb0002"))
        cache.storePreprocessed("PRE", for: "aaaa0001")
        XCTAssertNil(cache.playerJS(for: "aaaa0001"))
        XCTAssertEqual(cache.preprocessed(for: "aaaa0001"), "PRE")
        XCTAssertEqual(cache.signatureTimestamp(for: "aaaa0001"), 20001)
        cache.storePlayer("JS2", timestamp: 20002, for: "bbbb0002")
        XCTAssertNil(cache.preprocessed(for: "aaaa0001"))
        XCTAssertNil(cache.preprocessed(for: "bbbb0002"))
    }

    /// 结构与真实 base.js 相同的迷你播放器：IIFE 包裹、顶层有副作用调用、URL 处理函数里有 `X.set("alr","yes")`
    static let syntheticPlayer = #"""
    var _yt_player={};(function(g){var window=this;
    var Rv=function(a){return a.split("").reverse().join("")};
    function Sw(a,b){a=a.split("");var c=a[0];a[0]=a[b%a.length];a[b%a.length]=c;return a.join("")}
    var NT=function(a){return a.slice(2)+a.slice(0,2)};
    function YU(u){this.p={};this.u=u}
    YU.prototype.set=function(k,v){this.p[k]=v};
    YU.prototype.get=function(k){return this.p[k]};
    YU.prototype.clone=function(){return new YU(this.u)};
    YU.prototype.tr=function(){var s=this.p.s;if(s){this.p.s=encodeURIComponent(Sw(Rv(decodeURIComponent(s)),3))}var n=this.p.n;if(n){this.p.n=NT(n)}};
    g.mk=function(u,sp,sig){var r=new YU(u);r.set("alr","yes");if(sig)r.set(sp,sig);return r};
    document.body.appendChild(null);
    g.sts={signatureTimestamp:20345};
    })(_yt_player);
    """#

    #if canImport(JavaScriptCore)
    func testSolveSyntheticPlayerWithJavaScriptCore() async throws {
        XCTAssertTrue(YouTubeSignature.isSupported)
        XCTAssertEqual(YouTubeParser.signatureTimestamp(in: Self.syntheticPlayer), 20345)
        // 期望值用 yt-dlp/ejs 0.8.0 在 node（去掉 URL 全局，模拟 JavaScriptCore）里算出
        let first = try await YouTubeSignature.solve(playerID: "feedf00d", playerJS: Self.syntheticPlayer,
                                                     sig: ["ABCDEFGH"], n: ["xyz123"])
        XCTAssertEqual(first.sig, ["ABCDEFGH": "EGFHDCBA"])
        XCTAssertEqual(first.n, ["xyz123": "z123xy"])
        // 第二次走缓存的预处理播放器，不再需要原始脚本
        XCTAssertNotNil(YouTubeSignature.cache.preprocessed(for: "feedf00d"))
        let second = try await YouTubeSignature.solve(playerID: "feedf00d", playerJS: nil, sig: ["0123456789"], n: ["abcd"])
        XCTAssertEqual(second.sig, ["0123456789": "6879543210"])
        XCTAssertEqual(second.n, ["abcd": "cdab"])
    }
    #endif
}
