// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 国内平台的多清晰度（同一视频的各档合成一个清晰度组）：公共换算 + 各解析器的纯逻辑（离线，内联小样本）
final class DomesticVariantsTests: XCTestCase {
    private func json(_ text: String) -> JSON {
        guard let j = JSON(text: text) else {
            XCTFail("fixture 不是合法 JSON")
            return JSON(nil)
        }
        return j
    }

    // MARK: 公共换算

    func testVariantLabels() {
        XCTAssertEqual(DomesticVariant.label(width: 1920, height: 1080), "1080P")
        XCTAssertEqual(DomesticVariant.label(width: 720, height: 1280, hevc: true), "720P · H.265")
        XCTAssertEqual(DomesticVariant.label(width: 0, height: 540), "540P")
        XCTAssertEqual(DomesticVariant.label(width: 0, height: 0, fallback: "超清"), "超清")
        XCTAssertEqual(DomesticVariant.label(width: 0, height: 0, hevc: true), "H.265")
        XCTAssertTrue(DomesticVariant.isHEVC("bytevc1"))
        XCTAssertTrue(DomesticVariant.isHEVC("hev1.1.6.L120"))
        XCTAssertFalse(DomesticVariant.isHEVC("h264"))
        XCTAssertEqual(DomesticVariant.fileSuffix("720P · H.265"), "720P_H.265")
        XCTAssertEqual(DomesticVariant.fileSuffix("高清 1080P"), "高清_1080P")
    }

    func testVariantMediasGroupDedupAndNames() {
        let list = [
            DomesticVariant(url: "https://v/1080", label: "1080P", size: 300),
            DomesticVariant(url: "https://v/720", label: "720P · H.265"),
            DomesticVariant(url: "https://v/1080", label: "重复"),
            DomesticVariant(url: "", label: "空"),
            DomesticVariant(url: "https://v/720b", label: "720P · H.265"),
            DomesticVariant(url: "https://v/x", label: "")
        ]
        let medias = DomesticVariant.medias(list, base: "t", headers: ["A": "1"])
        XCTAssertEqual(medias.map(\.url), ["https://v/1080", "https://v/720", "https://v/720b", "https://v/x"])
        XCTAssertEqual(medias.map(\.fileName), ["t.mp4", "t_720P_H.265.mp4", "t_720P_H.265_3.mp4", "t_v4.mp4"])
        XCTAssertEqual(Set(medias.map(\.fileName)).count, medias.count)
        XCTAssertEqual(Set(medias.map(\.variantGroup)), ["video"])
        XCTAssertEqual(medias.map(\.quality), ["1080P", "720P · H.265", "720P · H.265", ""])
        XCTAssertEqual(medias.map(\.size), [300, -1, -1, -1])
        XCTAssertEqual(medias[0].headers, ["A": "1"])

        // 只剩一档：不设清晰度组，文件名不加后缀
        let single = DomesticVariant.medias([DomesticVariant(url: "https://v/a", label: ""),
                                             DomesticVariant(url: "https://v/a", label: "dup")], base: "s", headers: [:])
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].fileName, "s.mp4")
        XCTAssertEqual(single[0].variantGroup, "")

        // 最多 6 档；单独的请求头覆盖调用方的；默认下载每组只取第一档
        let many = (1...9).map { DomesticVariant(url: "https://v/\($0)", label: "\($0)P", headers: $0 == 2 ? ["B": "2"] : nil) }
        let capped = DomesticVariant.medias(many, base: "m", ext: "mov", group: "g", headers: ["A": "1"])
        XCTAssertEqual(capped.count, DomesticVariant.maxCount)
        XCTAssertEqual(capped[1].headers, ["B": "2"])
        XCTAssertEqual(capped[1].fileName, "m_2P.mov")
        let result = VideoParseResult(platform: .weibo, title: "t", medias: capped)
        XCTAssertEqual(result.defaultDownloads.map(\.url), ["https://v/1"])
    }

    // MARK: 快手

    func testKuaishouManifestVariants() {
        let photo = json(#"""
        {"caption":"c","mainMvUrls":[{"url":"https://v2.kwaicdn.com/upic/a_1080.mp4?tag=1"}],
         "manifest":{"adaptationSet":[{"representation":[
           {"url":"https://v1.kwaicdn.com/upic/a_720.mp4","width":720,"height":1280,"qualityType":"720p","fileSize":2000,"avgBitrate":1000},
           {"url":"https://v1.kwaicdn.com/upic/a_1080.mp4?tag=2","width":1080,"height":1920,"fileSize":5000,"avgBitrate":3000},
           {"url":"https://v1.kwaicdn.com/upic/a_540.mp4","width":540,"height":960,"avgBitrate":500}]}]},
         "manifestH265":{"adaptationSet":[{"representation":[
           {"url":"https://v1.kwaicdn.com/upic/a_720_hevc.mp4","width":720,"height":1280,"avgBitrate":700}]}]}}
        """#)
        let main = "https://v2.kwaicdn.com/upic/a_1080.mp4?tag=1"
        let variants = KuaishouParser.videoVariants(photo, main: main)
        // 默认档仍是 mainMvUrls；manifest 里同一文件（换了域名 / 参数）不重复列
        XCTAssertEqual(variants.map(\.url), [main, "https://v1.kwaicdn.com/upic/a_720.mp4",
                                             "https://v1.kwaicdn.com/upic/a_720_hevc.mp4", "https://v1.kwaicdn.com/upic/a_540.mp4"])
        XCTAssertEqual(variants.map(\.label), ["1080P", "720P", "720P · H.265", "540P"])
        XCTAssertEqual(variants.map(\.size), [5000, 2000, -1, -1])
        let medias = DomesticVariant.medias(variants, base: "k", headers: [:])
        XCTAssertEqual(medias.map(\.fileName), ["k.mp4", "k_720P.mp4", "k_720P_H.265.mp4", "k_540P.mp4"])
        XCTAssertEqual(medias[0].size, 5000)
        XCTAssertEqual(medias[2].size, -1)

        // 没有 manifest：和以前一样只有一条，无标签
        let plain = KuaishouParser.videoVariants(json(#"{"mainMvUrls":[{"url":"https://v/a.mp4"}]}"#), main: "https://v/a.mp4")
        XCTAssertEqual(plain, [DomesticVariant(url: "https://v/a.mp4", label: "")])

        // manifest 偶尔是 JSON 字符串；对不上默认地址时默认档标「默认」
        let stringy = json(#"""
        {"manifest":"{\"adaptationSet\":[{\"representation\":[{\"url\":\"https://v/b_720.mp4\",\"width\":720,\"height\":1280}]}]}"}
        """#)
        let mixed = KuaishouParser.videoVariants(stringy, main: "https://v/a.mp4")
        XCTAssertEqual(mixed.map(\.url), ["https://v/a.mp4", "https://v/b_720.mp4"])
        XCTAssertEqual(mixed.map(\.label), ["默认", "720P"])
    }

    // MARK: 微博

    func testWeiboMobileQualities() {
        let data = json(#"""
        {"page_info":{"urls":{"mp4_1080p_mp4":"http://f.video.weibocdn.com/1080.mp4","mp4_720p_mp4":"https://f/720.mp4",
          "mp4_hd_mp4":"https://f/hd.mp4","mp4_ld_mp4":"https://f/hd.mp4"}}}
        """#)
        let refs = WeiboParser.mobileMedias(data)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].url, "http://f.video.weibocdn.com/1080.mp4")
        XCTAssertEqual(refs[0].quality, "1080P")
        XCTAssertEqual(refs[0].variants.map(\.url), ["https://f/720.mp4", "https://f/hd.mp4"])
        let medias = WeiboParser.medias(refs, base: "v", headers: [:])
        XCTAssertEqual(medias.map(\.fileName), ["v.mp4", "v_720P.mp4", "v_高清.mp4"])
        XCTAssertEqual(medias.map(\.quality), ["1080P", "720P", "高清"])
        XCTAssertEqual(Set(medias.map(\.variantGroup)), ["video1"])
    }

    func testWeiboAjaxPlaybackList() {
        let data = json(#"""
        {"page_info":{"object_type":"video","media_info":{"mp4_hd_url":"https://f/hd.mp4","playback_list":[
          {"meta":{"quality_label":"720P"},"play_info":{"url":"https://f/720.mp4","width":1280,"height":720,"size":100}},
          {"meta":{"quality_label":"1080P"},"play_info":{"url":"https://f/1080.mp4","width":1920,"height":1080,"size":300,"video_codecs":"h264"}},
          {"meta":{"quality_label":"1080P"},"play_info":{"url":"https://f/1080_265.mp4","width":1920,"height":1080,"size":200,"video_codecs":"h265"}},
          {"meta":{"label":"audio"},"play_info":{"url":"https://f/a.m4a","mime":"audio/mp4"}}]}}}
        """#)
        let refs = WeiboParser.ajaxMedias(data)
        XCTAssertEqual(refs.map(\.url), ["https://f/1080.mp4"])
        XCTAssertEqual(WeiboParser.pageVideoURL(data["page_info"]), "https://f/1080.mp4")
        let medias = WeiboParser.medias(refs, base: "w", headers: [:])
        XCTAssertEqual(medias.map(\.url), ["https://f/1080.mp4", "https://f/1080_265.mp4", "https://f/720.mp4"])
        XCTAssertEqual(medias.map(\.quality), ["1080P", "1080P · H.265", "720P"])
        XCTAssertEqual(medias.map(\.fileName), ["w.mp4", "w_1080P_H.265.mp4", "w_720P.mp4"])
        XCTAssertEqual(medias.map(\.size), [300, 200, 100])

        // 没有 playback_list：mp4_* 各档
        let legacy = json(#"{"media_info":{"mp4_720p_mp4":"https://f/720.mp4","mp4_hd_url":"https://f/hd.mp4","mp4_sd_url":"https://f/sd.mp4"}}"#)
        let ref = WeiboParser.pageVideoRef(legacy)
        XCTAssertEqual(ref?.url, "https://f/720.mp4")
        XCTAssertEqual(ref?.quality, "720P")
        XCTAssertEqual(ref?.variants.map(\.label), ["高清", "标清"])
    }

    func testWeiboFidVariants() {
        let data = json(#"""
        {"urls":{"高清 1080P":"//f/1080.mp4","标清 480P":"https://f/480.mp4","高清 720P":"https://f/720.mp4","流畅 360P":""}}
        """#)
        let variants = WeiboParser.fidVariants(data)
        XCTAssertEqual(variants.map(\.url), ["https://f/1080.mp4", "https://f/720.mp4", "https://f/480.mp4"])
        XCTAssertEqual(variants.map(\.label), ["高清 1080P", "高清 720P", "标清 480P"])
        XCTAssertEqual(WeiboParser.fidVariants(json(#"{"stream_url":"https://f/s.mp4"}"#)).map(\.url), ["https://f/s.mp4"])
        XCTAssertTrue(WeiboParser.fidVariants(json("{}")).isEmpty)
    }

    // MARK: AcFun

    func testAcFunVariants() {
        let info = json(#"""
        {"currentVideoInfo":{"ksPlayJson":{"adaptationSet":[{"representation":[
          {"url":"https://x/1080.m3u8","qualityLabel":"1080P"},{"url":"https://x/720.m3u8","qualityLabel":"720P"},
          {"url":"https://x/720.m3u8","qualityLabel":"720P"},{"url":"","qualityLabel":"540P"},{"url":"https://x/360.m3u8","qualityType":"360p"}]}]}}}
        """#)
        let variants = AcFunParser.variants(info)
        XCTAssertEqual(variants.map(\.url), ["https://x/1080.m3u8", "https://x/720.m3u8", "https://x/360.m3u8"])
        XCTAssertEqual(AcFunParser.pickM3U8(info)?.url, "https://x/1080.m3u8")
        let medias = DomesticVariant.medias(variants, base: "a", headers: [:])
        XCTAssertEqual(medias.map(\.quality), ["1080P", "720P", "360p"])
        XCTAssertEqual(medias.map(\.fileName), ["a.mp4", "a_720P.mp4", "a_360p.mp4"])
        XCTAssertTrue(medias.allSatisfy(\.isHLS))
    }

    // MARK: 西瓜视频

    func testIxiguaVariants() {
        let resource = json(#"""
        {"vid":"v0","normal":{
          "video_list":{
            "video_1":{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL3Byb2c0ODAubXA0","vheight":480,"vwidth":854,"size":100,"definition":"480p"},
            "video_2":{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL3Byb2c3MjAubXA0","vheight":720,"vwidth":1280,"size":200,"definition":"720p"},
            "video_3":{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL3Byb2c3MjBfaGV2Yy5tcDQ=","vheight":720,"vwidth":1280,"size":150,"codec_type":"bytevc1"}
          },
          "dynamic_video":{
            "dynamic_video_list":[{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL2Rhc2gxMDgwLm1wNA==","vheight":1080,"vwidth":1920,"size":900}],
            "dynamic_audio_list":[{"main_url":"aHR0cHM6Ly92My14Zy5peGlndWEuY29tL2F1ZGlvX2hpLm00YQ==","bitrate":128000,"size":20}]
          }}}
        """#)
        XCTAssertEqual(IxiguaParser.bestMedia(resource)?.url, "https://v3-xg.ixigua.com/dash1080.mp4")
        let variants = IxiguaParser.variants(resource)
        XCTAssertEqual(variants.map(\.url), ["https://v3-xg.ixigua.com/dash1080.mp4", "https://v3-xg.ixigua.com/prog720.mp4",
                                             "https://v3-xg.ixigua.com/prog720_hevc.mp4", "https://v3-xg.ixigua.com/prog480.mp4"])
        XCTAssertEqual(variants.map(\.label), ["1080P", "720P", "720P · H.265", "480P"])
        XCTAssertEqual(variants.map(\.audioURL), ["https://v3-xg.ixigua.com/audio_hi.m4a", "", "", ""])
        // DASH 分轨的体积只算视频，不报
        XCTAssertEqual(variants.map(\.size), [-1, 200, 150, 100])
        XCTAssertTrue(IxiguaParser.variants(json("{}")).isEmpty)
    }

    // MARK: 今日头条

    func testToutiaoPlayVariants() {
        let list = json(#"""
        [{"Height":720,"Width":1280,"Size":100,"Codec":"h264","Definition":"720p","MainPlayUrl":"https://v/720"},
         {"Height":1080,"Width":1920,"Size":300,"Codec":"h264","Definition":"1080p","MainPlayUrl":"https://v/1080"},
         {"Height":1080,"Width":1920,"Size":200,"Codec":"bytevc1","Definition":"1080p","MainPlayUrl":"https://v/1080h"},
         {"Height":480,"Width":854,"Size":50,"Codec":"h264","Definition":"480p","MainPlayUrl":"https://v/720"},
         {"Height":2160,"Width":3840,"Size":900,"MainPlayUrl":""}]
        """#).array
        let variants = ToutiaoParser.playVariants(list)
        XCTAssertEqual(variants.map(\.url), ["https://v/1080", "https://v/1080h", "https://v/720"])
        XCTAssertEqual(variants.map(\.label), ["1080P", "1080P · H.265", "720P"])
        XCTAssertEqual(variants.map(\.size), [300, 200, 100])
        XCTAssertTrue(ToutiaoParser.playVariants([]).isEmpty)
    }

    // MARK: 小红书

    func testXiaohongshuVariants() {
        let note = json(#"""
        {"video":{"media":{"stream":{
          "h264":[{"masterUrl":"https://x/264_1080.mp4","width":1080,"height":1920,"size":500},
                  {"masterUrl":"https://x/264_720.mp4","width":720,"height":1280,"size":300}],
          "h265":[{"masterUrl":"https://x/265_1080.mp4","width":1080,"height":1920,"size":250}],
          "av1":[{"masterUrl":"https://x/av1.mp4","width":1080,"height":1920}],
          "h266":[]}}}}
        """#)
        XCTAssertEqual(XiaohongshuParser.pickVideo(note)?.url, "https://x/265_1080.mp4")
        let variants = XiaohongshuParser.videoVariants(note)
        XCTAssertEqual(variants.map(\.url), ["https://x/265_1080.mp4", "https://x/264_1080.mp4", "https://x/264_720.mp4"])
        XCTAssertEqual(variants.map(\.label), ["1080P · H.265", "1080P", "720P"])
        XCTAssertEqual(variants.map(\.size), [250, 500, 300])

        let only264 = json(#"{"video":{"media":{"stream":{"h264":[{"masterUrl":"https://x/a.mp4"}]}}}}"#)
        XCTAssertEqual(XiaohongshuParser.videoVariants(only264), [DomesticVariant(url: "https://x/a.mp4", label: "H.264")])
    }

    // MARK: 知乎

    func testZhihuPlaylistVariants() {
        let pin = json(#"""
        {"content":[{"type":"video","video_info":{"playlist":{
           "ld":{"url":"https://vdn/ld.mp4","width":640,"height":360,"size":10},
           "fhd":{"url":"https://vdn/fhd.mp4","width":1920,"height":1080,"size":90},
           "hd":{"url":"https://vdn/hd.mp4","width":1280,"height":720}}}}]}
        """#)
        let map = ZhihuParser.pinVideoVariants(pin)
        XCTAssertEqual(Array(map.keys), ["https://vdn/fhd.mp4"])
        XCTAssertEqual(ZhihuParser.pinMedias(pin).map(\.url), ["https://vdn/fhd.mp4"])
        let list = map["https://vdn/fhd.mp4"] ?? []
        XCTAssertEqual(list.map(\.url), ["https://vdn/fhd.mp4", "https://vdn/hd.mp4", "https://vdn/ld.mp4"])
        XCTAssertEqual(list.map(\.label), ["1080P", "720P", "360P"])
        XCTAssertEqual(list.map(\.size), [90, -1, 10])

        let noSize = json(#"{"playlist":{"sd":{"url":"//a/sd.mp4"},"hd":{"url":"//a/hd.mp4"}}}"#)
        let named = ZhihuParser.playlistVariants(noSize)
        XCTAssertEqual(named.map(\.url), ["https://a/hd.mp4", "https://a/sd.mp4"])
        XCTAssertEqual(named.map(\.label), ["高清", "标清"])
    }

    // MARK: 好看视频

    func testHaokanVariants() {
        let meta = json(#"""
        {"title":"t","playurl":"https://vd3.bdstatic.com/default.mp4","clarityUrl":[
          {"key":"sd","rank":0,"title":"标清","url":"https://vd3.bdstatic.com/sd.mp4"},
          {"key":"hd","rank":1,"title":"高清","url":"https://vd3.bdstatic.com/hd.mp4"},
          {"key":"sc","rank":2,"title":"超清","url":"https://vd3.bdstatic.com/sc.mp4"},
          {"key":"1080p","rank":3,"title":"蓝光","url":""}]}
        """#)
        let variants = HaokanParser.variants(meta)
        XCTAssertEqual(variants.map(\.url), ["https://vd3.bdstatic.com/sc.mp4", "https://vd3.bdstatic.com/hd.mp4", "https://vd3.bdstatic.com/sd.mp4"])
        XCTAssertEqual(variants.map(\.label), ["超清", "高清", "标清"])
        XCTAssertEqual(HaokanParser.variants(json(#"{"playurl":"https://x/p.mp4"}"#)).map(\.url), ["https://x/p.mp4"])
    }

    // MARK: 虎牙

    func testHuyaVariants() {
        let list = json(#"""
        [{"defName":"标清","height":540,"width":960,"size":10,"url":"https://huya/540.mp4","m3u8":"https://huya/540.m3u8"},
         {"defName":"原画","height":1080,"width":1920,"size":30,"url":"https://huya/1080.mp4","m3u8":"https://huya/1080.m3u8"},
         {"defName":"高清","height":720,"width":1280,"size":20,"url":"https://huya/720.mp4","m3u8":""}]
        """#).array
        let variants = HuyaParser.variants(list)
        XCTAssertEqual(variants.map(\.url), ["https://huya/1080.mp4", "https://huya/720.mp4", "https://huya/540.mp4"])
        XCTAssertEqual(variants.map(\.label), ["原画 1080P", "高清 720P", "标清 540P"])
        XCTAssertEqual(variants.map(\.size), [30, 20, 10])
        XCTAssertFalse(variants.contains(where: \.isHLS))

        let m3u8Only = HuyaParser.variants(json(#"[{"height":1080,"m3u8":"https://huya/a.m3u8"},{"height":720,"m3u8":"https://huya/b.m3u8"}]"#).array)
        XCTAssertEqual(m3u8Only.map(\.url), ["https://huya/a.m3u8", "https://huya/b.m3u8"])
        XCTAssertTrue(m3u8Only.allSatisfy(\.isHLS))
        XCTAssertTrue(HuyaParser.variants([]).isEmpty)
    }

    // MARK: 梨视频

    func testLishipinPageVariants() {
        let html = #"""
        <script>var contId="1076290",ldUrl="",sdUrl="//video.pearvideo.com/sd.mp4",hdUrl="https://video.pearvideo.com/hd.mp4",
        hdflvUrl="https://video.pearvideo.com/hd.flv",srcUrl="";</script>
        """#
        let variants = LishipinParser.pageVariants(html)
        XCTAssertEqual(variants.map(\.url), ["https://video.pearvideo.com/hd.mp4", "https://video.pearvideo.com/sd.mp4"])
        XCTAssertEqual(variants.map(\.label), ["高清", "标清"])
        XCTAssertEqual(LishipinParser.pageVideoURL(html), "https://video.pearvideo.com/hd.mp4")

        let single = LishipinParser.pageVariants(#"<script>var hdUrl="https://video.pearvideo.com/hd.mp4";</script>"#)
        XCTAssertEqual(single, [DomesticVariant(url: "https://video.pearvideo.com/hd.mp4", label: "")])
        XCTAssertTrue(LishipinParser.pageVariants("<html></html>").isEmpty)
    }

    // MARK: 新片场

    func testXinpianchangVariants() {
        let resource = json(#"""
        {"progressive":[{"url":"https://x/540.mp4","height":540,"width":960,"filesize":10,"profile":"标清"},
                        {"url":"https://x/1080.mp4","height":1080,"width":1920,"filesize":30,"profile":"超清"},
                        {"url":"https://x/720.mp4","height":720,"width":1280,"filesize":20,"profile":"高清"}],"hls":{"url":"https://x/m.m3u8"}}
        """#)
        let variants = XinpianchangParser.variants(resource)
        XCTAssertEqual(variants.map(\.url), ["https://x/1080.mp4", "https://x/720.mp4", "https://x/540.mp4"])
        XCTAssertEqual(variants.map(\.label), ["1080P", "720P", "540P"])
        XCTAssertEqual(variants.map(\.size), [30, 20, 10])

        let hlsOnly = XinpianchangParser.variants(json(#"{"progressive":[],"hls":{"url":"https://x/m.m3u8"}}"#))
        XCTAssertEqual(hlsOnly.map(\.url), ["https://x/m.m3u8"])
        XCTAssertEqual(hlsOnly.first?.isHLS, true)
    }

    // MARK: 公众号

    func testWeixinVideoVariants() {
        let data = json(#"""
        {"video_page_infos":[{"video_id":"wxv_1","mp_video_trans_info":[
          {"url":"https://mpvideo.qpic.cn/v1.f10002.mp4?dis_k=a&amp;dis_t=1","filesize":"100","width":640,"height":360,"video_quality_wording":"流畅"},
          {"url":"https://mpvideo.qpic.cn/v1.f10003.mp4?dis_k=b","filesize":"900","width":1280,"height":720,"video_quality_wording":"高清"}]},
          {"video_id":"wxv_2","mp_video_trans_info":[{"url":"https://mpvideo.qpic.cn/v2.f10002.mp4","filesize":"50","width":640,"height":360}]}]}
        """#)
        let groups = WeixinParser.videoVariants(data, html: "")
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].map(\.url), ["https://mpvideo.qpic.cn/v1.f10003.mp4?dis_k=b", "https://mpvideo.qpic.cn/v1.f10002.mp4?dis_k=a&dis_t=1"])
        XCTAssertEqual(groups[0].map(\.label), ["高清 720P", "流畅 360P"])
        XCTAssertEqual(groups[0].map(\.size), [900, 100])
        XCTAssertEqual(groups[1].map(\.url), ["https://mpvideo.qpic.cn/v2.f10002.mp4"])
        XCTAssertEqual(WeixinParser.videos(data, html: ""), ["https://mpvideo.qpic.cn/v1.f10003.mp4?dis_k=b", "https://mpvideo.qpic.cn/v2.f10002.mp4"])
    }

    // MARK: 视频号

    func testWxChannelsVariants() {
        let both = json(#"{"videoUrl":"https://v/plain","h264VideoInfo":{"videoUrl":"https://v/264"},"h265VideoInfo":{"videoUrl":"https://v/265","fileSize":80}}"#)
        let variants = WxChannelsParser.videoVariants(both)
        XCTAssertEqual(variants.map(\.url), ["https://v/264", "https://v/265"])
        XCTAssertEqual(variants.map(\.label), ["H.264", "H.265"])
        XCTAssertEqual(variants.map(\.size), [-1, 80])

        let plain = json(#"{"videoUrl":"https://v/plain","h265VideoInfo":{"videoUrl":"https://v/265"}}"#)
        XCTAssertEqual(WxChannelsParser.videoVariants(plain).map(\.label), ["默认", "H.265"])
        let onlyH265 = json(#"{"h265VideoInfo":{"videoUrl":"https://v/265"}}"#)
        XCTAssertEqual(WxChannelsParser.videoVariants(onlyH265), [DomesticVariant(url: "https://v/265", label: "H.265")])
    }
}
