// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 国内短视频平台第二批（西瓜/好看/微视/全民K歌/火山/梨视频/绿洲/美拍/皮皮搞笑/新片场/虎牙/央视网）的纯逻辑测试（离线，内联小样本）
final class DomesticBatch2Tests: XCTestCase {
    private func json(_ text: String) -> JSON {
        guard let j = JSON(text: text) else {
            XCTFail("fixture 不是合法 JSON")
            return JSON(nil)
        }
        return j
    }

    // MARK: 西瓜视频

    func testIxiguaIDRegex() {
        XCTAssertEqual(IxiguaParser.idRx.first(in: "https://www.ixigua.com/6996881461559165471?logTag=x"), "6996881461559165471")
        XCTAssertEqual(IxiguaParser.idRx.first(in: "https://www.ixigua.com/video/6996881461559165471"), "6996881461559165471")
        XCTAssertEqual(IxiguaParser.idRx.first(in: "https://m.ixigua.com/douyin/share/video/7123456789012345678?app=aweme"), "7123456789012345678")
        XCTAssertEqual(IxiguaParser.idRx.first(in: "https://www.douyin.com/video/7123456789012345678"), "7123456789012345678")
        XCTAssertNil(IxiguaParser.idRx.first(in: "https://v.ixigua.com/iRzAbCd/"))
    }

    func testIxiguaDecodeMainURL() {
        XCTAssertEqual(IxiguaParser.decodeMainURL("aHR0cHM6Ly92My14Zy5peGlndWEuY29tL3Byb2c3MjAubXA0"), "https://v3-xg.ixigua.com/prog720.mp4")
        XCTAssertEqual(IxiguaParser.decodeMainURL("https://already/plain.mp4"), "https://already/plain.mp4")
    }

    func testIxiguaSSRPrefersHigherDashWithAudio() {
        let html = ##"""
        <html><script id="SSR_HYDRATED_DATA">window._SSR_HYDRATED_DATA={"anyVideo":{"gidInformation":{"packerData":{"video":{
          "title":"盲目涉水风险大","video_abstract":"简介","video_publish_time":1629088414,"poster_url":"https://p.x/c.jpg",
          "user_info":{"name":"懂车帝原创","avatar_url":"https://p.x/a.jpg"},
          "videoResource":{"vid":"v0","normal":{
            "video_list":{
              "video_1":{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL3Byb2c0ODAubXA0","vheight":480,"size":100,"definition":"480p"},
              "video_2":{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL3Byb2c3MjAubXA0","vheight":720,"size":200,"definition":"720p"}
            },
            "dynamic_video":{
              "dynamic_video_list":[{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL2Rhc2gxMDgwLm1wNA==","vheight":1080,"size":900}],
              "dynamic_audio_list":[
                {"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL2F1ZGlvX2xvLm00YQ==","bitrate":64000,"size":10},
                {"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL2F1ZGlvX2hpLm00YQ==","bitrate":128000,"size":20}
              ]
            }
          }, "extra": undefined}
        }}}}}</script></html>
        """##
        guard let video = IxiguaParser.packerVideo(fromHTML: html) else { return XCTFail("没抠到 packerData.video") }
        XCTAssertEqual(video["title"].string, "盲目涉水风险大")
        XCTAssertEqual(video["user_info"]["name"].string, "懂车帝原创")
        guard let best = IxiguaParser.bestMedia(video["videoResource"]) else { return XCTFail("没有可用档位") }
        XCTAssertEqual(best.url, "https://v3-xg.ixigua.com/dash1080.mp4")
        XCTAssertEqual(best.audioURL, "https://v3-xg.ixigua.com/audio_hi.m4a")
        XCTAssertEqual(best.quality, "1080p")
    }

    func testIxiguaProgressiveWhenNoHigherDash() {
        let resource = json(#"""
        {"normal":{"video_list":{"video_1":{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL3Byb2c3MjAubXA0","vheight":720}},
                   "dynamic_video":{"dynamic_video_list":[{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL2Rhc2gxMDgwLm1wNA==","vheight":720}],
                                    "dynamic_audio_list":[]}}}
        """#)
        let best = IxiguaParser.bestMedia(resource)
        XCTAssertEqual(best?.url, "https://v3-xg.ixigua.com/prog720.mp4")
        XCTAssertEqual(best?.audioURL, "")
        XCTAssertNil(IxiguaParser.bestMedia(json("{}")))
    }

    func testIxiguaRouterFallback() {
        let html = #"""
        <script>window._ROUTER_DATA = {"loaderData":{"video_(id)/page":{"videoInfoRes":{"item_list":[{"desc":"标题",
        "author":{"nickname":"作者","avatar_thumb":{"url_list":["https://p/a.jpg"]}},
        "video":{"play_addr":{"url_list":["https://aweme.snssdk.com/aweme/v1/playwm/?video_id=v0200"]},"cover":{"url_list":["https://p/c.jpg"]}}}]}}}}</script>
        """#
        guard let item = IxiguaParser.routerItem(fromHTML: html) else { return XCTFail("没抠到 item") }
        XCTAssertEqual(item["desc"].string, "标题")
        XCTAssertEqual(IxiguaParser.routerPlayURL(item), "https://aweme.snssdk.com/aweme/v1/play/?video_id=v0200")
    }

    // MARK: 好看视频

    func testHaokanBestPlay() {
        let meta = json(#"""
        {"title":"t","playurl":"https://vd3.bdstatic.com/default.mp4","clarityUrl":[
          {"key":"sd","rank":0,"title":"标清","url":"https://vd3.bdstatic.com/sd.mp4"},
          {"key":"hd","rank":1,"title":"高清","url":"https://vd3.bdstatic.com/hd.mp4"},
          {"key":"sc","rank":2,"title":"超清","url":"https://vd3.bdstatic.com/sc.mp4"},
          {"key":"1080p","rank":3,"title":"蓝光","url":""}]}
        """#)
        let best = HaokanParser.bestPlay(meta)
        XCTAssertEqual(best?.url, "https://vd3.bdstatic.com/sc.mp4")
        XCTAssertEqual(best?.quality, "超清")
        XCTAssertEqual(HaokanParser.bestPlay(json(#"{"playurl":"https://x/p.mp4"}"#))?.url, "https://x/p.mp4")
        XCTAssertNil(HaokanParser.bestPlay(json("{}")))
    }

    // MARK: 微视

    func testWeishiFeed() throws {
        let ok = json(#"{"ret":0,"data":{"feeds":[{"video_url":"https://v.weishi.qq.com/a.mp4","feed_desc_withat":"desc"}]}}"#)
        XCTAssertEqual(try WeishiParser.feed(ok)["video_url"].string, "https://v.weishi.qq.com/a.mp4")
        XCTAssertThrowsError(try WeishiParser.feed(json(#"{"ret":-1,"msg":"bad"}"#)))
        XCTAssertThrowsError(try WeishiParser.feed(json(#"{"ret":0,"data":{"errmsg":"视频已删除"}}"#)))
        XCTAssertThrowsError(try WeishiParser.feed(json(#"{"ret":0,"data":{"feeds":[]}}"#)))
    }

    // MARK: 全民K歌

    func testKgeDetailAndMedia() {
        let html = #"""
        <script>window.__DATA__ = {"detail":{"content":"唱着玩; 别笑","song_name":"晴天","nick":"歌手","avatar":"https://a/x.jpg",
        "cover":"https://c/y.jpg","playurl":"https://ws.stream.kg.qq.com/szkge/abc.m4a?fname=1","playurl_video":""}}; window.x = 1;</script>
        """#
        guard let detail = KgeParser.detail(fromHTML: html) else { return XCTFail("没抠到 detail") }
        XCTAssertEqual(detail["content"].string, "唱着玩; 别笑")
        XCTAssertEqual(KgeParser.title(detail), "晴天")
        let audio = KgeParser.media(detail, headers: [:], fallbackName: "kge")
        XCTAssertEqual(audio?.kind, .audio)
        XCTAssertEqual(audio?.fileName, "晴天.m4a")

        let mv = json(#"{"song_name":"","content":"MV","playurl":"https://a/x.m4a","playurl_video":"https://v/x.mp4"}"#)
        let video = KgeParser.media(mv, headers: [:], fallbackName: "kge")
        XCTAssertEqual(video?.kind, .video)
        XCTAssertEqual(video?.url, "https://v/x.mp4")
        XCTAssertEqual(video?.fileName, "MV.mp4")

        XCTAssertEqual(KgeParser.audioExtension("https://x/a.mp3?k=1"), "mp3")
        XCTAssertEqual(KgeParser.audioExtension("https://x/noext?k=1"), "m4a")
        XCTAssertNil(KgeParser.detail(fromHTML: "<html></html>"))
    }

    // MARK: 抖音火山版

    func testHuoshanItemInfo() {
        XCTAssertEqual(HuoshanParser.itemRx.first(in: "https://share.huoshan.com/pages/item/index.html?item_id=6856280234519399694&tag=0"),
                       "6856280234519399694")
        XCTAssertEqual(HuoshanParser.douyinRx.first(in: "https://www.iesdouyin.com/share/video/7123456789012345678/?region="),
                       "7123456789012345678")
        let info = HuoshanParser.itemInfo(json(#"{"data":{"item_info":{"url":"https://api.huoshan.com/hotsoon/item/video/_playback/?video_id=v1","cover":"https://c/1.jpg"}}}"#))
        XCTAssertEqual(info?.url, "https://api.huoshan.com/hotsoon/item/video/_playback/?video_id=v1")
        XCTAssertEqual(info?.cover, "https://c/1.jpg")
        XCTAssertNil(HuoshanParser.itemInfo(json(#"{"data":{}}"#)))
    }

    // MARK: 梨视频

    func testLishipinStatusURL() {
        let payload = json(#"""
        {"resultCode":"1","systemTime":"1700000000000","videoInfo":{"video_image":"https://image.pearvideo.com/c.jpg",
         "videos":{"hdUrl":"","srcUrl":"https://video.pearvideo.com/mp4/third/20231115/1700000000000-11778041-hd.mp4"}}}
        """#)
        XCTAssertEqual(LishipinParser.statusVideoURL(payload, id: "1789012"),
                       "https://video.pearvideo.com/mp4/third/20231115/cont-1789012-11778041-hd.mp4")
        XCTAssertNil(LishipinParser.statusVideoURL(json("{}"), id: "1"))
    }

    func testLishipinPage() {
        let html = #"""
        <h1 class="video-tt">小浣熊在主人家玻璃上滚石头</h1><div class="summary">简介&amp;说明</div>
        <script>var contId="1076290",ldUrl="",sdUrl="//video.pearvideo.com/sd.mp4",hdUrl="https://video.pearvideo.com/hd.mp4",srcUrl="";</script>
        """#
        XCTAssertEqual(LishipinParser.title(html), "小浣熊在主人家玻璃上滚石头")
        XCTAssertEqual(LishipinParser.summary(html), "简介&说明")
        XCTAssertEqual(LishipinParser.pageVideoURL(html), "https://video.pearvideo.com/hd.mp4")
        XCTAssertNil(LishipinParser.pageVideoURL("<html></html>"))
    }

    // MARK: 绿洲

    func testLvzhouPage() {
        let html = #"""
        <div class="user"><a class="avatar" href="#"><img src="https://tvax1.sinaimg.cn/crop.0.0.100.100.180/abc.jpg"></a>
        <div class="nickname">绿洲用户</div></div>
        <div class="status-title">今天的晚霞</div>
        <div class="video-cover" style="background-image:url(https://wx1.sinaimg.cn/orj360/cover.jpg)"></div>
        <video class="v" src="https://f.video.weibocdn.com/o0/abc.mp4?label=mp4_720p"></video>
        <img src="https://wx3.sinaimg.cn/orj360/pic1.jpg"><img src="https://wx3.sinaimg.cn/mw690/pic2.jpg">
        """#
        let page = LvzhouParser.page(html)
        XCTAssertEqual(page.title, "今天的晚霞")
        XCTAssertEqual(page.author, "绿洲用户")
        XCTAssertEqual(page.avatar, "https://tvax1.sinaimg.cn/crop.0.0.100.100.180/abc.jpg")
        XCTAssertEqual(page.cover, "https://wx1.sinaimg.cn/orj360/cover.jpg")
        XCTAssertEqual(page.video, "https://f.video.weibocdn.com/o0/abc.mp4?label=mp4_720p")
        XCTAssertEqual(page.images, ["https://wx3.sinaimg.cn/large/pic1.jpg", "https://wx3.sinaimg.cn/large/pic2.jpg"])
    }

    // MARK: 美拍

    func testMeipaiDecode() {
        // 由 parse-video 算法的 Python 移植反向构造：n = 0x0caa = 3242 → pre [3,2]、tail [4,2]
        let encoded = "aac0Ly9~!tdnZpZGVvMTAubWVpdHVkYXRhLmNvbS81ZjFhMmIzYzRkNWU2Lm1w#$NA=="
        XCTAssertEqual(MeipaiParser.decodeVideo(encoded), "https://mvvideo10.meitudata.com/5f1a2b3c4d5e6.mp4")
        XCTAssertEqual(MeipaiParser.decodeVideo("//mvvideo10.meitudata.com/a.mp4"), "https://mvvideo10.meitudata.com/a.mp4")
        XCTAssertNil(MeipaiParser.decodeVideo("zz"))
        XCTAssertNil(MeipaiParser.decodeVideo("1000abcdef"))
    }

    func testMeipaiPageBits() {
        let html = #"""
        <meta property="og:title" content="og 标题"><meta property="og:image" content="//mvimg10.meitudata.com/c.jpg">
        <h1 class="detail-cover-title">  美拍标题 </h1>
        <img class="detail-avatar" alt="她她-TATA" src="//mvavatar1.meitudata.com/a.jpg">
        <a id="shareMediaBtn" data-video="aac0Ly9~!tdnZpZGVvMTAubWVpdHVkYXRhLmNvbS81ZjFhMmIzYzRkNWU2Lm1w#$NA==">分享</a>
        """#
        XCTAssertEqual(MeipaiParser.title(html), "美拍标题")
        XCTAssertEqual(MeipaiParser.meta("og:image", in: html), "//mvimg10.meitudata.com/c.jpg")
        XCTAssertEqual(MeipaiParser.dataVideo(html), "aac0Ly9~!tdnZpZGVvMTAubWVpdHVkYXRhLmNvbS81ZjFhMmIzYzRkNWU2Lm1w#$NA==")
        XCTAssertNil(MeipaiParser.replayM3U8(html))
        XCTAssertEqual(MeipaiParser.replayM3U8("player({file: encodeURIComponent('https://live.meipai.com/r.m3u8')})"),
                       "https://live.meipai.com/r.m3u8")
    }

    // MARK: 皮皮搞笑

    func testPipigaoxiaoMediaItems() throws {
        let payload = json(#"""
        {"ret":1,"data":{"post":{"content":"好笑","imgs":[{"id":111},{"id":222}],
         "videos":{"111":{"url":"https://video.ippzone.com/zyvd/111.mp4"}}}}}
        """#)
        let post = try PipigaoxiaoParser.post(payload)
        let items = PipigaoxiaoParser.mediaItems(post)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].url, "https://video.ippzone.com/zyvd/111.mp4")
        XCTAssertTrue(items[0].isVideo)
        XCTAssertEqual(items[1].url, "https://file.ippzone.com/img/view/id/222")
        XCTAssertFalse(items[1].isVideo)
        XCTAssertThrowsError(try PipigaoxiaoParser.post(json(#"{"ret":-1,"msg":"帖子不存在"}"#)))
    }

    // MARK: 新片场

    func testXinpianchangDetailAndResource() {
        let html = #"""
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"detail":{"title":"冰墩墩下班了",
        "author":{"userinfo":{"username":"正时文创"}},"video":{"vid":"8Ok3Ab","appKey":"61a2f329348b3bf77",
        "content":{"progressive":[{"url":"https://qiniu-xpc0.xpccdn.com/inline.mp4","height":540}]}}}}}}</script>
        """#
        guard let detail = XinpianchangParser.detail(fromHTML: html) else { return XCTFail("没抠到 detail") }
        XCTAssertEqual(detail["title"].string, "冰墩墩下班了")
        XCTAssertEqual(detail["video"]["vid"].string, "8Ok3Ab")
        XCTAssertEqual(XinpianchangParser.bestResource(detail["video"]["content"])?.url, "https://qiniu-xpc0.xpccdn.com/inline.mp4")

        let resource = json(#"""
        {"progressive":[{"url":"https://x/540.mp4","height":540,"filesize":10},{"url":"https://x/1080.mp4","height":1080,"filesize":30},
                        {"url":"https://x/720.mp4","height":720,"filesize":20}],"hls":{"url":"https://x/m.m3u8"}}
        """#)
        let best = XinpianchangParser.bestResource(resource)
        XCTAssertEqual(best?.url, "https://x/1080.mp4")
        XCTAssertEqual(best?.isHLS, false)
        XCTAssertEqual(best?.quality, "1080p")
        let hlsOnly = XinpianchangParser.bestResource(json(#"{"progressive":[],"hls":{"url":"https://x/m.m3u8"}}"#))
        XCTAssertEqual(hlsOnly?.url, "https://x/m.m3u8")
        XCTAssertEqual(hlsOnly?.isHLS, true)
    }

    // MARK: 虎牙

    func testHuyaBestDefinition() {
        let list = json(#"""
        [{"defName":"标清","height":540,"size":10,"url":"https://huya/540.mp4","m3u8":"https://huya/540.m3u8"},
         {"defName":"原画","height":1080,"size":30,"url":"https://huya/1080.mp4","m3u8":"https://huya/1080.m3u8"},
         {"defName":"高清","height":720,"size":20,"url":"https://huya/720.mp4","m3u8":""}]
        """#).array
        let best = HuyaParser.bestDefinition(list)
        XCTAssertEqual(best?.url, "https://huya/1080.mp4")
        XCTAssertEqual(best?.isHLS, false)
        XCTAssertEqual(best?.quality, "原画")
        let m3u8Only = HuyaParser.bestDefinition(json(#"[{"height":1080,"m3u8":"https://huya/a.m3u8"}]"#).array)
        XCTAssertEqual(m3u8Only?.url, "https://huya/a.m3u8")
        XCTAssertEqual(m3u8Only?.isHLS, true)
        XCTAssertNil(HuyaParser.bestDefinition([]))
    }

    // MARK: 央视网

    func testCctvGuid() {
        XCTAssertEqual(CctvParser.guid(fromHTML: #"<script>var guid = "68c27e1af8cc47f79000ca944432b0e6";</script>"#),
                       "68c27e1af8cc47f79000ca944432b0e6")
        XCTAssertEqual(CctvParser.guid(fromHTML: #"fo.addVariable("videoCenterId","5ecdbeab623f4973b40ff25f18b174e8");"#),
                       "5ecdbeab623f4973b40ff25f18b174e8")
        XCTAssertEqual(CctvParser.guid(fromHTML: #"loadvideo('b15f009ff45c43968b9af583fc2e04b2')"#), "b15f009ff45c43968b9af583fc2e04b2")
        XCTAssertNil(CctvParser.guid(fromHTML: #"<script>var guid = "";</script>"#))
        XCTAssertNil(CctvParser.guid(fromHTML: "<html>no guid</html>"))
    }

    func testCctvChapters() {
        let video = json(#"{"chapters":[{"url":"https://a/1.mp4"},{"url":"https://a/2.mp4"}],"lowChapters":[{"url":"https://a/low.mp4"}]}"#)
        XCTAssertEqual(CctvParser.chapterURLs(video), ["https://a/1.mp4", "https://a/2.mp4"])
        XCTAssertEqual(CctvParser.chapterURLs(json("{}")), [])
    }
}
