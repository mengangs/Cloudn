// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 国内平台（头条/贴吧/公众号/豆瓣/酷安/皮皮虾/最右）解析器的纯逻辑测试（离线，内联小样本）
final class DomesticParserTests: XCTestCase {
    private func json(_ text: String) -> JSON {
        guard let j = JSON(text: text) else {
            XCTFail("fixture 不是合法 JSON")
            return JSON(nil)
        }
        return j
    }

    // MARK: 共用工具

    func testHTMLUnescape() {
        XCTAssertEqual(DomesticHTML.unescape("a&amp;b&lt;c&gt;&quot;&#39;&#x4e2d;&#25991;&unknown;"), "a&b<c>\"'中文&unknown;")
        XCTAssertEqual(DomesticHTML.unescape("no entities"), "no entities")
    }

    func testHTMLAttributeDoesNotConfuseDataSrc() {
        let tag = #"<img data-src="https://a/1.jpg?x=1&amp;y=2" src='https://a/thumb.jpg' class=pic>"#
        XCTAssertEqual(DomesticHTML.attribute("src", in: tag), "https://a/thumb.jpg")
        XCTAssertEqual(DomesticHTML.attribute("data-src", in: tag), "https://a/1.jpg?x=1&y=2")
        XCTAssertEqual(DomesticHTML.attribute("class", in: tag), "pic")
        XCTAssertNil(DomesticHTML.attribute("alt", in: tag))
    }

    func testHTMLElementByClassHandlesNesting() {
        let html = #"<div class="feed-message-title">x</div><div class="a message-title b"><div>in</div>ner</div><p>after</p>"#
        XCTAssertEqual(DomesticHTML.element(class: "message-title", in: html), "<div>in</div>ner")
        XCTAssertNil(DomesticHTML.element(class: "missing", in: html))
    }

    func testHTMLText() {
        XCTAssertEqual(DomesticHTML.text("<p>第一段</p><p>第二&amp;段<br/>换行</p>"), "第一段\n第二&段\n换行")
    }

    func testImageExtension() {
        XCTAssertEqual(DomesticHTML.imageExtension("https://a.com/x/y.PNG?z=1"), "png")
        XCTAssertEqual(DomesticHTML.imageExtension("https://a.com/x/y.jpeg"), "jpg")
        XCTAssertEqual(DomesticHTML.imageExtension("https://a.com/x/noext"), "jpg")
    }

    func testJSLiteralLooseSyntax() {
        let text = """
        { a: 1, 'b': 'x\\x3cy\\u4e2d', "c": [1, 2.5, -3,], d: '8' * 1, e: true, f: null, g: undefined,
          /* 注释 */ h: ('http://x').replace(/^http/, 'https'), // 行注释
          i: '' || 'fallback', nested: { k: "v" }, }; 后面还有别的
        """
        guard let lit = JSLiteral.parse(text) else { return XCTFail("解析失败") }
        let j = lit.json
        XCTAssertEqual(j["a"].int, 1)
        XCTAssertEqual(j["b"].string, "x<y中")
        XCTAssertEqual(j["c"].array.count, 3)
        XCTAssertEqual(j["c"][1].double, 2.5)
        XCTAssertEqual(j["c"][2].int, -3)
        XCTAssertEqual(j["d"].int, 8)
        XCTAssertTrue(j["e"].bool)
        XCTAssertTrue(j["f"].isNull)
        XCTAssertTrue(j["g"].isNull)
        XCTAssertEqual(j["h"].string, "http://x")
        XCTAssertEqual(j["i"].string, "fallback")
        XCTAssertEqual(j["nested"]["k"].string, "v")
    }

    func testJSLiteralKeepsKeyOrderAndSurrogates() {
        guard let lit = JSLiteral.parse(#"{"z": 1, "a": 2, "m": "😀"}"#) else { return XCTFail("解析失败") }
        XCTAssertEqual(lit.orderedValues.map(\.stringValue), ["1", "2", "😀"])
    }

    // MARK: 今日头条

    func testToutiaoPlayInfoQuery() {
        // base64url（无填充）的 {"GetPlayInfoToken": "...", "TokenVersion": "V2"}，由 Python 生成
        let token = "eyJHZXRQbGF5SW5mb1Rva2VuIjogIkFjdGlvbj1HZXRQbGF5SW5mbyZWZXJzaW9uPTIwMjAtMDgtMDEmVmlkPXYwZCIsICJUb2tlblZlcnNpb24iOiAiVjIifQ"
        XCTAssertEqual(ToutiaoParser.playInfoQuery(token: token), "Action=GetPlayInfo&Version=2020-08-01&Vid=v0d")
        XCTAssertNil(ToutiaoParser.playInfoQuery(token: "!!!"))
    }

    func testToutiaoBestPlayInfo() {
        let list = json(#"""
        [{"Height": 720, "Size": 100, "MainPlayUrl": "https://v/720a"},
         {"Height": 1080, "Size": 50, "MainPlayUrl": "https://v/1080a"},
         {"Height": 1080, "Size": 90, "MainPlayUrl": "https://v/1080b"},
         {"Height": 2160, "Size": 900, "MainPlayUrl": ""}]
        """#).array
        let best = ToutiaoParser.bestPlayInfo(list)
        XCTAssertEqual(best?.url, "https://v/1080b")
        XCTAssertEqual(best?.quality, "1080p")
        XCTAssertNil(ToutiaoParser.bestPlayInfo([]))
    }

    func testToutiaoArticleMedia() {
        let html = #"""
        <p>正文</p><img src="https://p3.toutiaoimg.com/a.jpg?x=1&amp;y=2" alt=""><img src="//p3.toutiaoimg.com/b.png">
        <img src="https://p3.toutiaoimg.com/a.jpg?x=1&amp;y=2">
        <div class="tt-video-box" data-token="TOKEN1"></div><div class="other" data-token="NO"></div>
        """#
        XCTAssertEqual(ToutiaoParser.articleImages(html), ["https://p3.toutiaoimg.com/a.jpg?x=1&y=2", "https://p3.toutiaoimg.com/b.png"])
        XCTAssertEqual(ToutiaoParser.articleVideoTokens(html), ["TOKEN1"])
    }

    func testToutiaoMicroPost() {
        let thread = json(#"{"thread_base": {"content": "hi", "large_image_list": [{"url": "https://p/1.jpg"}, {"url": ""}, {"url": "https://p/2.jpg"}]}}"#)
        XCTAssertEqual(ToutiaoParser.microPostImages(thread), ["https://p/1.jpg", "https://p/2.jpg"])
        XCTAssertEqual(ToutiaoParser.idRx.first(in: "https://www.toutiao.com/article/7400000000000000001/?log_from=x"), "7400000000000000001")
        XCTAssertEqual(ToutiaoParser.idRx.first(in: "https://m.toutiao.com/i7400000000000000002/"), "7400000000000000002")
        XCTAssertNil(ToutiaoParser.idRx.first(in: "https://m.toutiao.com/is/AbCdEf/"))
    }

    // MARK: 百度贴吧

    func testTiebaSignVector() {
        // 期望值由参考实现（Python hashlib）计算
        let form = TiebaParser.signedForm(kz: "9123456789", tbs: "abc123def456")
        XCTAssertEqual(form.last?.0, "sign")
        XCTAssertEqual(form.last?.1, "515a33fff101e768aff29b310386c738")
        XCTAssertEqual(form.count, 12)
    }

    func testTiebaMapping() {
        let data = json(#"""
        {"thread": {"origin_thread_info": {"title": "标题", "content": [{"type": 0, "text": "一"}, {"type": 3, "src": "x"}, {"type": 0, "text": "二"}],
          "media": [{"big_pic": "http://tiebapic.baidu.com/1.jpg", "small_pic": "s1"}, {"big_pic": "", "small_pic": "http://t/2.jpg"}]},
          "video_info": {"video_url": "http://tb-video.bdstatic.com/v.mp4", "thumbnail_url": "http://t/c.jpg"}}}
        """#)
        let origin = data["thread"]["origin_thread_info"]
        XCTAssertEqual(TiebaParser.contentText(origin["content"]), "一\n二")
        XCTAssertEqual(TiebaParser.photos(origin), ["http://tiebapic.baidu.com/1.jpg", "http://t/2.jpg"])
        XCTAssertEqual(TiebaParser.video(data["thread"])?.url, "http://tb-video.bdstatic.com/v.mp4")
        XCTAssertNil(TiebaParser.video(json("{}")))
    }

    // MARK: 微信公众号

    func testWeixinArticlePayload() {
        let html = #"""
        <html><script>var x = 1;</script><script type="text/javascript">
        window.cgiDataNew = {
          item_show_type: '0' * 1,
          title: '文章\x26标题',
          nick_name: "公众号",
          content_noencode: '\x3cp\x3e正文\x3c/p\x3e\x3cimg class="rich_pages" data-src="https://mmbiz.qpic.cn/mmbiz_jpg/abc/640?wx_fmt=jpeg&amp;from=appmsg" /\x3e\x3cimg data-src="https://mmbiz.qpic.cn/mmbiz_png/def/0?wx_fmt=png"\x3e',
          video_page_infos: [{ video_id: 'wxv_1', mp_video_trans_info: [
            { url: 'https://mpvideo.qpic.cn/v1.f10002.mp4?dis_k=a&amp;dis_t=1', filesize: '100', width: 640, height: 360 },
            { url: 'https://mpvideo.qpic.cn/v1.f10003.mp4?dis_k=b', filesize: '900', width: 1280, height: 720 },
          ]}],
        };
        try { foo(); } catch (e) {}
        </script></html>
        """#
        guard let data = WeixinParser.payload(html) else { return XCTFail("没取到 cgiDataNew") }
        XCTAssertEqual(data["item_show_type"].int, 0)
        XCTAssertEqual(data["title"].string, "文章&标题")
        XCTAssertEqual(WeixinParser.articleImages(data["content_noencode"].string), [
            "https://mmbiz.qpic.cn/mmbiz_jpg/abc/0?wx_fmt=jpeg&from=appmsg",
            "https://mmbiz.qpic.cn/mmbiz_png/def/0?wx_fmt=png"
        ])
        XCTAssertEqual(WeixinParser.videos(data, html: html), ["https://mpvideo.qpic.cn/v1.f10003.mp4?dis_k=b"])
    }

    func testWeixinImagePost() {
        let data = json(#"""
        {"item_show_type": 8, "picture_page_info_list": [
          {"cdn_url": "https://mmbiz.qpic.cn/a/1?wx_fmt=png", "watermark_info": {"cdn_url": "https://mmbiz.qpic.cn/a/orig1?wx_fmt=png"}},
          {"cdn_url": "https://mmbiz.qpic.cn/a/2?wx_fmt=gif&amp;x=1"},
          {"cdn_url": ""}]}
        """#)
        XCTAssertEqual(WeixinParser.photos(data), ["https://mmbiz.qpic.cn/a/orig1?wx_fmt=png", "https://mmbiz.qpic.cn/a/2?wx_fmt=gif&x=1"])
        XCTAssertEqual(WeixinParser.imageExtension("https://mmbiz.qpic.cn/a/2?wx_fmt=gif&x=1"), "gif")
        XCTAssertEqual(WeixinParser.imageExtension("https://mmbiz.qpic.cn/a/2?wx_fmt=jpeg"), "jpg")
        XCTAssertEqual(WeixinParser.imageExtension("https://mmbiz.qpic.cn/a/2"), "jpg")
    }

    func testWeixinOriginalImageAndPageVideos() {
        XCTAssertEqual(WeixinParser.originalImage("https://mmbiz.qpic.cn/sz_mmbiz_png/xyz/640?wx_fmt=png"), "https://mmbiz.qpic.cn/sz_mmbiz_png/xyz/0?wx_fmt=png")
        XCTAssertEqual(WeixinParser.originalImage("https://mmbiz.qpic.cn/sz_mmbiz_png/xyz/300"), "https://mmbiz.qpic.cn/sz_mmbiz_png/xyz/0")
        XCTAssertEqual(WeixinParser.originalImage("https://other.com/a/640?x=1"), "https://other.com/a/640?x=1")
        let page = #"url: 'http:\/\/mpvideo.qpic.cn\/0b2abc.f10002.mp4?dis_k=1\x26amp;dis_t=2', x: 'https://mpvideo.qpic.cn/0b2abc.f10004.mp4?a=1'"#
        XCTAssertEqual(WeixinParser.pageVideoURLs(page), ["http://mpvideo.qpic.cn/0b2abc.f10002.mp4?dis_k=1&dis_t=2"])
    }

    // MARK: 豆瓣

    func testDoubanTopicID() {
        XCTAssertEqual(DoubanParser.topicID(in: "https://www.douban.com/group/topic/312345678/?_i=1"), "312345678")
        XCTAssertEqual(DoubanParser.topicID(in: "https://m.douban.com/topic/312345678"), "312345678")
        XCTAssertEqual(DoubanParser.topicID(in: "https://www.douban.com/doubanapp/dispatch?uri=%2Fgroup%2Ftopic%2F312345678%2F&dt_dapp=1"), "312345678")
        XCTAssertNil(DoubanParser.topicID(in: "https://www.douban.com/gallery/topic/123/"))
    }

    func testDoubanPhotos() {
        let data = json(#"""
        {"photos": [
          {"image": {"large": {"url": "https://img1.doubanio.com/l/p1.jpg"}, "normal": {"url": "https://img1.doubanio.com/m/p1.jpg"}}},
          {"image": {"is_animated": true, "large": {"url": "https://img1.doubanio.com/l/p2.gif"}, "video": {"url": "https://img1.doubanio.com/v/p2.mp4"}}},
          {"image": {"normal": {"url": "https://img1.doubanio.com/m/p3.webp"}}},
          {"image": {}}]}
        """#)
        XCTAssertEqual(DoubanParser.photos(data), [
            DoubanParser.Photo(url: "https://img1.doubanio.com/l/p1.jpg", ext: "jpg", animated: false),
            DoubanParser.Photo(url: "https://img1.doubanio.com/v/p2.mp4", ext: "mp4", animated: true),
            DoubanParser.Photo(url: "https://img1.doubanio.com/m/p3.webp", ext: "webp", animated: false)
        ])
    }

    func testDoubanAPIError() {
        let e = DoubanParser.apiError(status: 403, body: json(#"{"msg": "need_permission", "localized_message": "该话题仅小组成员可见"}"#))
        XCTAssertEqual(e.detail, "豆瓣：该话题仅小组成员可见")
        XCTAssertEqual(DoubanParser.apiError(status: 404, body: nil).kind, .notFound)
        XCTAssertEqual(DoubanParser.apiError(status: 400, body: json(#"{"msg": "bad"}"#)).detail, "获取豆瓣话题失败：bad")
    }

    // MARK: 酷安

    func testCoolapkPageURL() {
        let link = DetectedVideoLink(platform: .coolapk, kind: "feed", id: "61234567",
                                     url: "https://www.coolapk1s.com/feed/61234567?shareKey=ABC123&shareUid=1&shareFrom=x")
        XCTAssertEqual(CoolapkParser.pageURL(link), "https://www.coolapk.com/feed/61234567?shareKey=ABC123")
        let pic = DetectedVideoLink(platform: .coolapk, kind: "picture", id: "1", url: "https://www.coolapk.com/picture/1")
        XCTAssertEqual(CoolapkParser.pageURL(pic), "https://www.coolapk.com/picture/1")
    }

    func testCoolapkArticle() {
        let html = #"""
        <div class="message-title"> 图文标题 </div>
        <div class="feed-article-message"><p>正文<img class="message-image" src="//image.coolapk.com/feed/a.jpg.m.jpg"></p>
        <div><img class="avatar" src="//avatar.coolapk.com/x.jpg"></div><img class="message-image big" src="https://image.coolapk.com/feed/b.png"></div>
        <img class="message-image" src="//image.coolapk.com/outside.jpg">
        """#
        let page = CoolapkParser.extract(html)
        XCTAssertEqual(page?.title, "图文标题")
        XCTAssertEqual(page?.images, ["https://image.coolapk.com/feed/a.jpg", "https://image.coolapk.com/feed/b.png"])
    }

    func testCoolapkFeed() {
        let html = #"""
        <div class="feed-message">动态 <a href="#">#话题#</a> 内容</div>
        <div class="message-image-group"><img src="//image.coolapk.com/feed/1.jpg.s.jpg"><img src="//image.coolapk.com/feed/2.gif"></div>
        """#
        let page = CoolapkParser.extract(html)
        XCTAssertEqual(page?.title, "")
        XCTAssertEqual(page?.text, "动态 #话题# 内容")
        XCTAssertEqual(page?.images, ["https://image.coolapk.com/feed/1.jpg", "https://image.coolapk.com/feed/2.gif"])
        XCTAssertNil(CoolapkParser.extract("<html><body>请登录</body></html>"))
    }

    // MARK: 皮皮虾

    func testPipixRenderData() {
        let encoded = "%7B%22ppxItemDetail%22%3A%7B%22item%22%3A%7B%22item_type%22%3A2%2C%22content%22%3A%22%E6%B5%8B%E8%AF%95%20%E8%A7%86%E9%A2%91%22%2C%22item_id_str%22%3A%227001%22%2C%22video%22%3A%7B%22video_download%22%3A%7B%22url_list%22%3A%5B%7B%22url%22%3A%22https%3A//v.pipix.com/wm.mp4%22%7D%5D%2C%22cover_image%22%3A%7B%22download_list%22%3A%5B%7B%22url%22%3A%22https%3A//p.pipix.com/c.jpg%22%7D%5D%7D%2C%22duration%22%3A3.2%2C%22width%22%3A720%2C%22height%22%3A1280%7D%7D%2C%22origin_video_download%22%3A%7B%22url_list%22%3A%5B%7B%22url%22%3A%22https%3A//v.pipix.com/origin.mp4%22%7D%5D%7D%7D%7D%7D"
        let html = "<html><script id=\"RENDER_DATA\" type=\"application/json\">\(encoded)</script></html>"
        guard let item = PipixParser.item(fromHTML: html) else { return XCTFail("没取到 RENDER_DATA") }
        XCTAssertEqual(item["content"].string, "测试 视频")
        let video = PipixParser.video(item)
        XCTAssertEqual(video?.url, "https://v.pipix.com/origin.mp4")
        XCTAssertEqual(video?.cover, "https://p.pipix.com/c.jpg")
        XCTAssertNil(PipixParser.item(fromHTML: "<html></html>"))
    }

    func testPipixImagesAndFallbackVideo() {
        let image = json(#"{"item_type": 1, "cover": {"download_list": [{"url": "https://p/1.webp"}, {"url": ""}]}}"#)
        XCTAssertNil(PipixParser.video(image))
        XCTAssertEqual(PipixParser.images(image), ["https://p/1.webp"])
        let video = json(#"{"item_type": 2, "video": {"video_download": {"url_list": [{"url": "https://v/d.mp4"}]}}}"#)
        XCTAssertEqual(PipixParser.video(video)?.url, "https://v/d.mp4")
    }

    // MARK: 最右

    func testZuiyouMediasFollowKeyOrder() {
        let text = #"""
        {"ret": 1, "data": {"post": {"content": "帖子", "imgs": [
          {"id": 11, "video": 0, "urls": {"origin": {"urls": ["https://img/o1a", "https://img/o1b"]}, "360": {"urls": ["https://img/s1"]}}},
          {"id": 22, "video": 1, "urls": {"540Webp": {"urls": ["https://img/t2"]}}},
          {"id": 33, "video": 1, "urls": {"540": {"urls": ["https://img/t3"]}}}],
          "videos": {"22": {"url": "https://vid/22.mp4"}}}}}
        """#
        guard let post = JSLiteral.parse(text)?["data"]?["post"] else { return XCTFail("解析失败") }
        XCTAssertEqual(ZuiyouParser.medias(post), [
            ZuiyouParser.Item(url: "https://img/s1", thumb: "https://img/s1", isVideo: false),
            ZuiyouParser.Item(url: "https://vid/22.mp4", thumb: "https://img/t2", isVideo: true)
        ])
    }
}
