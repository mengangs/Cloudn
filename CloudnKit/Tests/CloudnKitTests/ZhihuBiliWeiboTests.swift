import XCTest
@testable import CloudnKit

final class ZhihuBiliWeiboTests: XCTestCase {
    // MARK: 知乎 x-zse-96（期望值由 ParseHub 的 Python 参考实现以固定 IV 算出）

    func testZhihuSignPath() {
        XCTAssertEqual(ZhihuParser.signPath(url: "https://www.zhihu.com/api/v4/answers/123456789", query: [("include", "data[*].content")]),
                       "/api/v4/answers/123456789?include=data[*].content")
        XCTAssertEqual(ZhihuParser.signPath(url: "https://zhuanlan.zhihu.com/api/articles/1234567", query: []), "/api/articles/1234567")
        XCTAssertEqual(ZhihuParser.signPath(url: "https://www.zhihu.com/api/v4/questions/1/answers",
                                            query: [("offset", ""), ("limit", "1"), ("sort_by", "default")]),
                       "/api/v4/questions/1/answers?offset=&limit=1&sort_by=default")
        XCTAssertEqual(ZhihuParser.encodedQuery([("include", "data[*].content")]), "?include=data%5B*%5D.content")
        XCTAssertEqual(ZhihuParser.encodedQuery([]), "")
    }

    func testZhihuMD5Source() {
        XCTAssertEqual(Crypto.md5Hex("101_3_3.0+/api/v4/answers/123456789?include=data[*].content+AFBSabc123|1700000000"),
                       "54ca623ff458499b544188a205e84f00")
    }

    func testZhihuSignatureVectors() {
        let a = ZhihuParser.xZse96(path: "/api/v4/answers/123456789?include=data[*].content", dC0: "AFBSabc123|1700000000",
                                   iv: (0..<16).map { UInt8($0) })
        XCTAssertEqual(a, "2.0_wex5YNxWyqfNAWGywb/JzV8A543fa+MTwF6Da9zYqjSjnd6LtWxp8dmfqxxnpR66")

        let b = ZhihuParser.xZse96(path: "/api/v4/questions/987654321/answers?offset=&limit=1&sort_by=default&include=data[*].content",
                                   dC0: #""AJCkABCDEFG-aBcDeFgH1234567890=|1700000000""#, iv: [UInt8](repeating: 0xff, count: 16))
        XCTAssertEqual(b, "2.0_Ib+0AxqSzyQl2i/hlnh=Z/G11OKRURJMplrlBfvKFkxtggggqggggZNggg=tgggg")

        let c = ZhihuParser.xZse96(path: "/api/articles/1234567", dC0: "AFBSabc123|1700000000", iv: [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(c, "2.0_M4=xNaPKbNn1BHFUaA1TL6Wr+XCnOUX5IxTgZsK=yuDn6666+6666WL6665n6666")

        XCTAssertEqual(ZhihuParser.encryptMD5("101_3_3.0+/api/v4/pins/1+x", iv: (16..<32).map { UInt8($0) }),
                       "KGAo+INB2M23PKACtUtTlDA8o=fpMHg/ymu1leORzYGMHdfOvWFJId0qCxF/kRfR")
    }

    func testZhihuRandomIVShape() {
        let sig = ZhihuParser.xZse96(path: "/api/v4/me", dC0: "x|1")
        XCTAssertTrue(sig.hasPrefix("2.0_"))
        XCTAssertEqual(sig.count, 68)
        XCTAssertEqual(ZhihuParser.sm4ZK[3], 3951632832)
        XCTAssertEqual(ZhihuParser.sm4ZB.count, 256)
    }

    func testZhihuCookieAndTargets() {
        XCTAssertNil(ZhihuParser.dC0(in: ""))
        XCTAssertNil(ZhihuParser.dC0(in: "z_c0=abc; _xsrf=1"))
        XCTAssertEqual(ZhihuParser.dC0(in: "_xsrf=1; d_c0=AFBS|170; z_c0=2|1:0"), "AFBS|170")

        XCTAssertEqual(ZhihuParser.target(of: "https://www.zhihu.com/question/123/answer/456?utm_id=0"), .answer("456"))
        XCTAssertEqual(ZhihuParser.target(of: "https://www.zhihu.com/question/123"), .question("123"))
        XCTAssertEqual(ZhihuParser.target(of: "https://zhuanlan.zhihu.com/p/789"), .article("789"))
        XCTAssertEqual(ZhihuParser.target(of: "https://www.zhihu.com/pin/1234567890"), .pin("1234567890"))
        XCTAssertEqual(ZhihuParser.target(of: "https://daily.zhihu.com/story/9770000"), .story("9770000"))
        XCTAssertNil(ZhihuParser.target(of: "https://example.com/p/1"))
        XCTAssertEqual(ZhihuParser.target(kind: "answer", id: "9"), .answer("9"))
        XCTAssertNil(ZhihuParser.target(kind: "answer", id: ""))
    }

    func testZhihuLoginRequired() async {
        let link = DetectedVideoLink(platform: .zhihu, kind: "answer", id: "1", url: "https://www.zhihu.com/answer/1")
        do {
            _ = try await ZhihuParser().parse(link, cookie: "z_c0=abc")
            XCTFail("应当要求登录")
        } catch let e as VideoParseError {
            XCTAssertEqual(e.detail, "知乎需要登录：请先到「我的」页登录知乎")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }

    func testZhihuContentImages() {
        let html = """
        <p>正文</p><figure><noscript><img src="https://pic1.zhimg.com/v2-aaa_b.jpg" data-original="https://pic1.zhimg.com/v2-aaa_r.jpg"/></noscript>
        <img src="data:image/svg+xml;utf8,&lt;svg xmlns='http://www.w3.org/2000/svg'&gt;" data-rawwidth="1080" class="origin_image" data-original="https://pic1.zhimg.com/v2-aaa_r.jpg" data-actualsrc="https://pic1.zhimg.com/v2-aaa_b.jpg"/></figure>
        <img src="https://www.zhihu.com/equation?tex=x%5E2" alt="x^2" eeimg="1"/>
        <img src="//pic3.zhimg.com/v2-bbb_720w.png?source=1&amp;x=2"/>
        <img src="data:image/svg+xml;utf8,&lt;svg&gt;"/>
        """
        XCTAssertEqual(ZhihuParser.contentImages(html), [
            "https://pic1.zhimg.com/v2-aaa_r.jpg",
            "https://pic3.zhimg.com/v2-bbb_720w.png?source=1&x=2"
        ])
        XCTAssertEqual(ZhihuParser.imageExt("https://pic3.zhimg.com/v2-bbb_720w.png?source=1"), "png")
        XCTAssertEqual(ZhihuParser.imageExt("https://pic3.zhimg.com/v2-bbb"), "jpg")
    }

    func testZhihuPinMedias() {
        let pin = JSON(text: """
        {"content":[{"type":"text","title":"","content":"想法<br>正文"},
          {"type":"image","url":"https://pic1.zhimg.com/v2-t.jpg","original_url":"https://pic1.zhimg.com/v2-o.jpg","width":100,"height":100},
          {"type":"image","url":"https://pic1.zhimg.com/v2-t2.jpg"},
          {"type":"video","video_info":{"thumbnail":"https://t","duration":10,"playlist":{
             "ld":{"url":"https://vdn/ld.mp4","width":640,"height":360},
             "fhd":{"url":"https://vdn/fhd.mp4","width":1920,"height":1080},
             "hd":{"url":"https://vdn/hd.mp4","width":1280,"height":720}}}}]}
        """)!
        let refs = ZhihuParser.pinMedias(pin)
        XCTAssertEqual(refs.map { $0.url }, ["https://pic1.zhimg.com/v2-o.jpg", "https://pic1.zhimg.com/v2-t2.jpg", "https://vdn/fhd.mp4"])
        XCTAssertEqual(refs.map { $0.kind }, [.image, .image, .video])
        XCTAssertEqual(ZhihuParser.pinText(pin), "想法\n正文")
        let arrayList = JSON(text: #"{"playlist":[{"url":"https://a","width":10,"height":10},{"url":"https://b","width":20,"height":20}]}"#)!
        XCTAssertEqual(ZhihuParser.bestPlaylistURL(arrayList), "https://b")
    }

    func testZhihuStoryOrigin() {
        let body = """
        <div class="view-more"><a href="https://www.zhihu.com/question/111/answer/222?utm=1&amp;x=2">查看知乎讨论</a></div>
        <div class="view-more"><a class="x" href="http://www.zhihu.com/question/333/answer/444"><span>查看知乎原文</span></a></div>
        """
        XCTAssertEqual(ZhihuParser.storyOriginURL(body), "http://www.zhihu.com/question/333/answer/444")
        XCTAssertNil(ZhihuParser.storyOriginURL("<a href=\"x\">别的</a>"))
    }

    func testZhihuErrorMapping() {
        XCTAssertEqual(ZhihuParser.mapError(status: 401, code: 100, message: "请登录").kind, .unsupported)
        XCTAssertEqual(ZhihuParser.mapError(status: 404, code: 4041, message: "").kind, .notFound)
        XCTAssertEqual(ZhihuParser.mapError(status: 403, code: 10003, message: "").kind, .blocked)
    }

    // MARK: B 站动态

    func testBiliDynamicOpus() {
        let item = JSON(text: """
        {"modules":{"module_author":{"name":"UP","face":"https://f","pub_ts":1700000000},
          "module_dynamic":{"desc":null,"major":{"type":"MAJOR_TYPE_OPUS","opus":{"title":"标题","summary":{"text":"正文"},
            "pics":[{"url":"http://i0.hdslb.com/bfs/new_dyn/a.jpg","live_url":null,"width":1,"height":1},
                    {"url":"http://i0.hdslb.com/bfs/new_dyn/b.png","live_url":"https://upos/live.mp4","width":1,"height":1}]}}}}}
        """)!
        let content = BilibiliParser.dynamicContent(item)
        XCTAssertEqual(content, .pictures([
            BiliDynamicPic(url: "http://i0.hdslb.com/bfs/new_dyn/a.jpg", liveURL: ""),
            BiliDynamicPic(url: "http://i0.hdslb.com/bfs/new_dyn/b.png", liveURL: "https://upos/live.mp4")
        ]))
        XCTAssertEqual(BilibiliParser.dynamicTitle(item), "标题")
        XCTAssertEqual(BilibiliParser.dynamicText(item), "正文")
        guard case .pictures(let pics) = content else { return XCTFail() }
        let medias = BilibiliParser.dynamicMedias(pics, base: "t", headers: [:])
        XCTAssertEqual(medias.map { $0.fileName }, ["t_1.jpg", "t_2.png", "t_2_live.mp4"])
        XCTAssertEqual(medias.map { $0.kind }, [.image, .image, .video])
    }

    func testBiliDynamicArchiveAndForward() {
        let archive = JSON(text: #"{"modules":{"module_dynamic":{"major":{"type":"MAJOR_TYPE_ARCHIVE","archive":{"bvid":"BV1xx411c7mD","aid":"2"}}}}}"#)!
        XCTAssertEqual(BilibiliParser.dynamicContent(archive), .video("BV1xx411c7mD"))
        let aidOnly = JSON(text: #"{"modules":{"module_dynamic":{"major":{"type":"MAJOR_TYPE_ARCHIVE","archive":{"aid":170001}}}}}"#)!
        XCTAssertEqual(BilibiliParser.dynamicContent(aidOnly), .video("av170001"))
        let forward = JSON(text: #"{"modules":{"module_dynamic":{"desc":{"text":"转发"},"major":null}},"orig":{"modules":{"module_dynamic":{"major":{"type":"MAJOR_TYPE_DRAW","draw":{"items":[{"src":"https://i0.hdslb.com/x.jpg"}]}}}}}}"#)!
        XCTAssertEqual(BilibiliParser.dynamicContent(forward), .pictures([BiliDynamicPic(url: "https://i0.hdslb.com/x.jpg", liveURL: "")]))
        XCTAssertEqual(BilibiliParser.dynamicText(forward), "转发")
        let text = JSON(text: #"{"modules":{"module_dynamic":{"desc":{"text":"纯文字"},"major":null}}}"#)!
        XCTAssertEqual(BilibiliParser.dynamicContent(text), .nothing)
        XCTAssertEqual(BilibiliParser.dynamicError(code: -352, message: "").kind, .blocked)
        XCTAssertEqual(BilibiliParser.dynamicError(code: 4101152, message: "").kind, .notFound)
    }

    /// opus 详情（专栏迁移后的长图文）：段落按序拼成全文，图片全部保留、去重、去缩略后缀、转 https
    func testBiliOpusDetailFullArticle() {
        let item = JSON(text: """
        {"basic":{"title":"basic 标题","rid_str":"27380000"},"id_str":"857123456789012345",
         "modules":[
          {"module_type":"MODULE_TYPE_TITLE","module_title":{"text":"【steam版】职场女友带回家 v1.02通关心得（含图文全流程）"}},
          {"module_type":"MODULE_TYPE_AUTHOR","module_author":{"name":"变成一条咸鱼了呀","face":"//i1.hdslb.com/bfs/face/f.jpg","pub_ts":1698300000}},
          {"module_type":"MODULE_TYPE_CONTENT","module_content":{"paragraphs":[
            {"para_type":1,"text":{"nodes":[{"type":"TEXT_NODE_TYPE_WORD","word":{"words":"第一段，","style":{}}},
                                            {"type":"TEXT_NODE_TYPE_RICH","rich":{"text":"@某人","type":"RICH_TEXT_NODE_TYPE_AT"}},
                                            {"type":"TEXT_NODE_TYPE_WORD","word":{"words":" 结尾  "}}]}},
            {"para_type":2,"pic":{"pics":[{"url":"http://i0.hdslb.com/bfs/article/a.jpg@1256w_706h_!web-article-pic.webp","width":1,"height":1}]}},
            {"para_type":1,"text":{"nodes":[{"word":{"words":""}}]}},
            {"para_type":8,"heading":{"level":2,"nodes":[{"word":{"words":"第二章"}}]}},
            {"para_type":5,"list":{"style":1,"items":[{"level":1,"order":1,"nodes":[{"word":{"words":"甲"}}]},
                                                      {"level":1,"order":2,"nodes":[{"word":{"words":"乙"}}]}]}},
            {"para_type":4,"text":{"nodes":[{"word":{"words":"引用"}}]}},
            {"para_type":3,"line":{"pic":{"url":"https://i0.hdslb.com/bfs/article/line.png"}}},
            {"para_type":2,"pic":{"pics":[{"url":"//i0.hdslb.com/bfs/article/b.png"},{"url":"https://i0.hdslb.com/bfs/article/a.jpg"}]}},
            {"para_type":1,"text":{"nodes":[{"word":{"words":"最后一段"}}]}}
          ]}},
          {"module_type":"MODULE_TYPE_STAT","module_stat":{}}
         ]}
        """)!
        let a = BilibiliParser.opusArticle(item)
        XCTAssertEqual(a.title, "【steam版】职场女友带回家 v1.02通关心得（含图文全流程）")
        XCTAssertEqual(a.author, "变成一条咸鱼了呀")
        XCTAssertEqual(a.timestamp, 1698300000)
        XCTAssertEqual(a.text, "第一段，@某人 结尾\n第二章\n1. 甲\n2. 乙\n> 引用\n————\n最后一段")
        XCTAssertEqual(a.pics.map(\.url), ["https://i0.hdslb.com/bfs/article/a.jpg", "https://i0.hdslb.com/bfs/article/b.png"])
        XCTAssertFalse(a.text.hasSuffix("…"))

        // 动态摘要（截断 + 1 张图）与完整内容合并：完整的覆盖摘要
        let summary = BiliOpusArticle(title: "", author: "UP", face: "", timestamp: 1, text: "第一段…",
                                      pics: [BiliDynamicPic(url: "https://i0.hdslb.com/bfs/article/a.jpg", liveURL: "")])
        let merged = BilibiliParser.merge(summary: summary, full: a)
        XCTAssertEqual(merged.text, a.text)
        XCTAssertEqual(merged.pics.count, 2)
        XCTAssertEqual(BilibiliParser.merge(summary: summary, full: nil), summary)

        // 图文动态的顶部图集 + 正文
        let album = JSON(text: """
        {"modules":[{"module_type":"MODULE_TYPE_TOP","module_top":{"display":{"album":{"pics":[{"url":"http://i0.hdslb.com/bfs/new_dyn/x.jpg","live_url":"https://upos/l.mp4"}]}}}},
                    {"module_type":"MODULE_TYPE_CONTENT","module_content":{"paragraphs":[{"para_type":1,"text":{"nodes":[{"word":{"words":"长文字"}}]}}]}}]}
        """)!
        let b = BilibiliParser.opusArticle(album)
        XCTAssertEqual(b.pics, [BiliDynamicPic(url: "https://i0.hdslb.com/bfs/new_dyn/x.jpg", liveURL: "https://upos/l.mp4")])
        XCTAssertEqual(b.text, "长文字")
    }

    func testBiliCVArticleView() {
        // 旧版 HTML 正文
        let html = JSON(text: #"""
        {"title":"专栏","author":{"name":"作者","face":"https://f"},"publish_time":1698300000,
         "content":"<p>第一段&amp;</p><figure><img data-src=\"//i0.hdslb.com/bfs/article/a.jpg@progressive.webp\" src=\"\"/></figure><p>第二段<br/>换行</p><img src=\"//i0.hdslb.com/bfs/emote/e.png\"/><p>&nbsp;</p><figure><img data-src=\"//i0.hdslb.com/bfs/article/b.jpg\"/></figure>",
         "origin_image_urls":["https://i0.hdslb.com/bfs/article/banner.jpg"]}
        """#)!
        let a = BilibiliParser.cvArticle(html)
        XCTAssertEqual(a.title, "专栏")
        XCTAssertEqual(a.author, "作者")
        XCTAssertEqual(a.text, "第一段&\n第二段\n换行")
        XCTAssertEqual(a.pics.map(\.url), ["https://i0.hdslb.com/bfs/article/a.jpg", "https://i0.hdslb.com/bfs/article/b.jpg"])

        // 新版：opus.content.paragraphs
        let opus = JSON(text: #"""
        {"title":"新","content":"","opus":{"content":{"paragraphs":[{"para_type":1,"text":{"nodes":[{"word":{"words":"段落"}}]}},
          {"para_type":2,"pic":{"pics":[{"url":"https://i0.hdslb.com/bfs/new_dyn/p.jpg"}]}}]}}}
        """#)!
        let b = BilibiliParser.cvArticle(opus)
        XCTAssertEqual(b.text, "段落")
        XCTAssertEqual(b.pics.map(\.url), ["https://i0.hdslb.com/bfs/new_dyn/p.jpg"])

        // Quill delta
        let delta = JSON(text: #"""
        {"title":"d","content":"{\"ops\":[{\"insert\":\"一\\n\"},{\"insert\":{\"native-image\":{\"url\":\"//i0.hdslb.com/bfs/article/q.png\"}}},{\"insert\":\"二\\n\"}]}"}
        """#)!
        let c = BilibiliParser.cvArticle(delta)
        XCTAssertEqual(c.text, "一\n二")
        XCTAssertEqual(c.pics.map(\.url), ["https://i0.hdslb.com/bfs/article/q.png"])
    }

    func testBiliArticleLinksAndIDs() {
        for url in ["https://www.bilibili.com/read/cv27380000", "https://www.bilibili.com/read/mobile?id=27380000",
                    "https://m.bilibili.com/read/cv27380000?from=share"] {
            let l = VideoLinkParser.parse(url)
            XCTAssertEqual(l?.kind, "article", url)
            XCTAssertEqual(l?.id, "27380000", url)
        }
        XCTAssertEqual(VideoLinkParser.parse("https://m.bilibili.com/opus/857123456789012345")?.kind, "dynamic")
        let articleDyn = JSON(text: #"{"type":"DYNAMIC_TYPE_ARTICLE","basic":{"rid_str":"123"},"modules":{"module_dynamic":{"major":{"type":"MAJOR_TYPE_OPUS","opus":{"jump_url":"//www.bilibili.com/opus/1"}}}}}"#)!
        XCTAssertEqual(BilibiliParser.articleID(articleDyn), "123")
        let oldArticle = JSON(text: #"{"modules":{"module_dynamic":{"major":{"type":"MAJOR_TYPE_ARTICLE","article":{"id":456,"title":"T","desc":"D","covers":["https://i0.hdslb.com/c.jpg"]}}}}}"#)!
        XCTAssertEqual(BilibiliParser.articleID(oldArticle), "456")
        XCTAssertEqual(BilibiliParser.dynamicContent(oldArticle), .pictures([BiliDynamicPic(url: "https://i0.hdslb.com/c.jpg", liveURL: "")]))
        XCTAssertEqual(BilibiliParser.dynamicTitle(oldArticle), "T")
        XCTAssertEqual(BilibiliParser.dynamicText(oldArticle), "D")
    }

    // MARK: 微博

    func testWeiboMobileLivephotoAndGif() {
        let data = JSON(text: """
        {"pics":[{"url":"https://wx1.sinaimg.cn/orj360/a.jpg","large":{"url":"https://wx1.sinaimg.cn/large/a.jpg"}},
                 {"url":"https://wx1.sinaimg.cn/orj360/b.jpg","large":{"url":"https://wx1.sinaimg.cn/large/b.jpg"},"type":"livephoto","videoSrc":"https://livephoto.us.sinaimg.cn/b.mov"},
                 {"url":"https://wx1.sinaimg.cn/orj360/c.gif","large":{"url":"https://wx1.sinaimg.cn/large/c.gif"},"type":"gifvideos","videoSrc":"//f.video.weibocdn.com/c.mp4"}]}
        """)!
        let refs = WeiboParser.mobileMedias(data)
        XCTAssertEqual(refs.map { $0.url }, ["https://wx1.sinaimg.cn/large/a.jpg", "https://wx1.sinaimg.cn/large/b.jpg",
                                         "https://livephoto.us.sinaimg.cn/b.mov", "https://f.video.weibocdn.com/c.mp4"])
        XCTAssertEqual(refs.map { $0.kind }, [.image, .image, .video, .video])
        let medias = WeiboParser.medias(refs, base: "w", headers: [:])
        XCTAssertEqual(medias.map { $0.fileName }, ["w_1.jpg", "w_2.jpg", "w_2_live.mov", "w_3.mp4"])
    }

    func testWeiboMobileVideoUnchanged() {
        let data = JSON(text: #"{"page_info":{"urls":{"mp4_720p_mp4":"http://f.video.weibocdn.com/720.mp4","mp4_hd_mp4":"https://hd.mp4"}}}"#)!
        let refs = WeiboParser.mobileMedias(data)
        // 默认档不变（720P），其余清晰度挂在 variants 上
        XCTAssertEqual(refs, [WeiboMediaRef(url: "http://f.video.weibocdn.com/720.mp4", kind: .video, ext: "mp4", quality: "720P",
                                            variants: [DomesticVariant(url: "https://hd.mp4", label: "高清")])])
        let medias = WeiboParser.medias(refs, base: "v", headers: [:])
        XCTAssertEqual(medias.map { $0.fileName }, ["v.mp4", "v_高清.mp4"])
        XCTAssertEqual(medias.first?.url, "http://f.video.weibocdn.com/720.mp4")
    }

    func testWeiboAjaxPicInfos() {
        let data = JSON(text: """
        {"pic_ids":["p2","p1","p3"],
         "pic_infos":{
           "p1":{"type":"pic","thumbnail":{"url":"https://t/p1.jpg"},"large":{"url":"https://l/p1.jpg"},"largest":{"url":"https://wx1.sinaimg.cn/large/p1.jpg"}},
           "p2":{"type":"livephoto","largest":{"url":"https://wx1.sinaimg.cn/large/p2.jpg"},"video":"https://video.weibo.com/media/play?livephoto=https%3A%2F%2Flivephoto.us.sinaimg.cn%2Fp2.mov"},
           "p3":{"type":"gif","largest":{"url":"https://wx1.sinaimg.cn/large/p3.gif"},"video":"https://f.video.weibocdn.com/p3.mp4"}}}
        """)!
        let refs = WeiboParser.ajaxMedias(data)
        XCTAssertEqual(refs.map { $0.url }, ["https://wx1.sinaimg.cn/large/p2.jpg",
                                         "https://video.weibo.com/media/play?livephoto=https%3A%2F%2Flivephoto.us.sinaimg.cn%2Fp2.mov",
                                         "https://wx1.sinaimg.cn/large/p1.jpg", "https://f.video.weibocdn.com/p3.mp4"])
        XCTAssertEqual(refs.map { $0.ext }, ["jpg", "mov", "jpg", "mp4"])
        XCTAssertEqual(WeiboParser.medias(refs, base: "w", headers: [:]).map { $0.fileName }, ["w_1.jpg", "w_1_live.mov", "w_2.jpg", "w_3.mp4"])
    }

    func testWeiboAjaxMixAndVideo() {
        let mix = JSON(text: """
        {"mix_media_info":{"items":[
          {"type":"pic","data":{"type":"pic","largest":{"url":"https://wx1.sinaimg.cn/large/m1.jpg"}}},
          {"type":"video","data":{"object_type":"video","media_info":{"mp4_hd_url":"https://hd.mp4",
            "playback_list":[{"play_info":{"url":"https://720.mp4","width":1280,"height":720}},{"play_info":{"url":"https://1080.mp4","width":1920,"height":1080}}]}}}]}}
        """)!
        XCTAssertEqual(WeiboParser.ajaxMedias(mix).map { $0.url }, ["https://wx1.sinaimg.cn/large/m1.jpg", "https://1080.mp4"])

        let video = JSON(text: #"{"page_info":{"object_type":"video","media_info":{"mp4_sd_url":"https://sd.mp4","mp4_hd_url":"https://hd.mp4"}}}"#)!
        XCTAssertEqual(WeiboParser.ajaxMedias(video).map { $0.url }, ["https://hd.mp4"])
        let article = JSON(text: #"{"page_info":{"object_type":"article"}}"#)!
        XCTAssertTrue(WeiboParser.ajaxMedias(article).isEmpty)
    }
}
