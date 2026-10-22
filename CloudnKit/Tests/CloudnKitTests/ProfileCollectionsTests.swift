// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import CloudnKit

/// 抖音 / 快手主页批量的纯逻辑（离线，内联小样本）
final class ProfileCollectionsTests: XCTestCase {
    private func json(_ text: String) -> JSON {
        guard let j = JSON(text: text) else {
            XCTFail("fixture 不是合法 JSON")
            return JSON(nil)
        }
        return j
    }

    // MARK: 链接识别（与报告里给出的 Rule 正则一致）

    private let douyinVid = Rx(#"douyin\.com/user/[^\s?#]+\?(?:[^\s#]*?&)?vid=(\d{10,})"#, ignoreCase: true)
    private let douyinUser = Rx(#"(?:www\.)?douyin\.com/user/([A-Za-z0-9_\-]{20,})"#, ignoreCase: true)
    private let douyinShareUser = Rx(#"(?:iesdouyin|m\.douyin)\.com/share/user/([A-Za-z0-9_\-]{20,})"#, ignoreCase: true)
    private let kuaishouProfile = Rx(#"(?:www\.)?kuaishou\.com/profile/([A-Za-z\d_\-]+)"#, ignoreCase: true)
    private let kuaishouFwUser = Rx(#"(?:(?:v\.m\.)?chenzhongtech|(?:[a-z\d]+\.)?kuaishou|(?:[a-z\d]+\.)?gifshow)\.com/fw/user/([A-Za-z\d_\-]+)"#,
                                    ignoreCase: true)

    private let secUID = "MS4wLjABAAAAv7iSuuXDJGDvJkmH_vz1qkDZYo1apxgzaxdBSeIuPiM"

    func testDouyinUserRules() {
        XCTAssertEqual(douyinUser.first(in: "https://www.douyin.com/user/\(secUID)?from_tab_name=main"), secUID)
        XCTAssertNil(douyinUser.first(in: "https://www.douyin.com/user/self?showTab=like"))
        XCTAssertEqual(douyinShareUser.first(in: "https://www.iesdouyin.com/share/user/\(secUID)?did=1&sec_uid=\(secUID)"), secUID)
        XCTAssertEqual(douyinShareUser.first(in: "https://m.douyin.com/share/user/\(secUID)"), secUID)
        XCTAssertEqual(douyinVid.first(in: "https://www.douyin.com/user/\(secUID)?from_tab_name=main&vid=7301234567890123456"),
                       "7301234567890123456")
        XCTAssertNil(douyinVid.first(in: "https://www.douyin.com/user/\(secUID)?from_tab_name=main"))
        // 已有作品规则不受影响
        XCTAssertEqual(VideoLinkParser.parse("https://www.douyin.com/user/\(secUID)?modal_id=7301234567890123456")?.kind, "video")
    }

    func testKuaishouProfileRules() {
        XCTAssertEqual(kuaishouProfile.first(in: "https://www.kuaishou.com/profile/3xq8bzjqs8v3wze"), "3xq8bzjqs8v3wze")
        XCTAssertEqual(kuaishouFwUser.first(in: "https://v.m.chenzhongtech.com/fw/user/3xq8bzjqs8v3wze?fid=1&cc=share_copylink"),
                       "3xq8bzjqs8v3wze")
        XCTAssertNil(kuaishouProfile.first(in: "https://www.kuaishou.com/short-video/3x8abcdefg"))
        XCTAssertEqual(KuaishouParser.profileID(in: "https://www.kuaishou.com/profile/3xq8bzjqs8v3wze?x=1"), "3xq8bzjqs8v3wze")
        XCTAssertEqual(KuaishouParser.profileID(in: "https://v.m.chenzhongtech.com/fw/user/3xabc?fid=1"), "3xabc")
        XCTAssertNil(KuaishouParser.profileID(in: "https://v.m.chenzhongtech.com/fw/photo/3xabc?userId=3xdef"))
        XCTAssertNil(KuaishouParser.profileID(in: "https://www.kuaishou.com/short-video/3xabc"))
    }

    // MARK: 抖音 aweme/post

    private let douyinPage1 = """
    {"status_code":0,"has_more":1,"max_cursor":1700000000000,"aweme_list":[
      {"aweme_id":"7301234567890123456","desc":"  第一条视频 #话题 ","aweme_type":0,"duration":15333,
       "author":{"nickname":"测试用户","sec_uid":"MS4w"},
       "video":{"duration":15333,"cover":{"url_list":["https://p3.douyinpic.com/cover1.jpeg"]},"play_addr":{"uri":"v0200"}}},
      {"aweme_id":"7301234567890123457","desc":"图文作品","aweme_type":68,
       "author":{"nickname":"测试用户"},
       "video":{"duration":0,"cover":{"url_list":[]}},
       "images":[{"url_list":["https://p3.douyinpic.com/img1.webp"]},{"url_list":["https://p3.douyinpic.com/img2.webp"]}]},
      {"aweme_id":"","desc":"坏数据"}
    ]}
    """

    private let douyinPage2 = """
    {"status_code":0,"has_more":0,"aweme_list":[
      {"aweme_id":"7301234567890123456","desc":"重复（置顶）","aweme_type":0,"duration":15333},
      {"aweme_id":"7301234567890123458","desc":"","aweme_type":0,
       "video":{"duration":61000,"origin_cover":{"url_list":["https://p3.douyinpic.com/origin3.jpeg"]}}},
      {"aweme_id":"7301234567890123459","desc":"老图集","aweme_type":2}
    ]}
    """

    func testDouyinUserPosts() {
        let posts = DouyinParser.userPosts([json(douyinPage1), json(douyinPage2)])
        XCTAssertEqual(posts.nickname, "测试用户")
        XCTAssertFalse(posts.hasMore)
        XCTAssertEqual(posts.entries.map(\.url), [
            "https://www.douyin.com/video/7301234567890123456",
            "https://www.douyin.com/note/7301234567890123457",
            "https://www.douyin.com/video/7301234567890123458",
            "https://www.douyin.com/note/7301234567890123459"
        ])
        XCTAssertEqual(posts.entries[0].title, "第一条视频 #话题")
        XCTAssertEqual(posts.entries[0].duration ?? 0, 15.333, accuracy: 0.0001)
        XCTAssertEqual(posts.entries[0].cover, "https://p3.douyinpic.com/cover1.jpeg")
        XCTAssertNil(posts.entries[1].duration)
        XCTAssertEqual(posts.entries[1].cover, "https://p3.douyinpic.com/img1.webp")
        XCTAssertEqual(posts.entries[2].title, "视频 7301234567890123458")
        XCTAssertEqual(posts.entries[2].duration ?? 0, 61, accuracy: 0.0001)
        XCTAssertEqual(posts.entries[2].cover, "https://p3.douyinpic.com/origin3.jpeg")
        XCTAssertEqual(posts.entries[3].title, "老图集")
        for e in posts.entries {
            let link = VideoLinkParser.parse(e.url)
            XCTAssertEqual(link?.platform, .douyin)
            XCTAssertEqual(link?.kind, "video")
        }
    }

    func testDouyinUserPostsHasMoreAndHookShape() {
        // 只拿到第一页：仍有更多
        XCTAssertTrue(DouyinParser.userPosts([json(douyinPage1)]).hasMore)
        // 钩子脚本汇总后的形状（作者名在顶层 nickname）
        let hooked = json("""
        {"aweme_list":[{"aweme_id":"7301234567890123460","desc":"x","aweme_type":0,"duration":1000,
          "video":{"cover":{"url_list":["c"]}},"images":[],"author":{"nickname":""}}],
         "has_more":0,"pages":1,"nickname":"顶层昵称","pageTitle":"顶层昵称的抖音 - 抖音"}
        """)
        let posts = DouyinParser.userPosts([hooked])
        XCTAssertEqual(posts.nickname, "顶层昵称")
        XCTAssertEqual(posts.entries.count, 1)
        XCTAssertEqual(posts.entries[0].url, "https://www.douyin.com/video/7301234567890123460")
        XCTAssertTrue(DouyinParser.userPosts([json(#"{"aweme_list":[]}"#)]).entries.isEmpty)
    }

    func testDouyinHelpers() {
        XCTAssertEqual(DouyinParser.userPageURL(secUID), "https://www.douyin.com/user/\(secUID)")
        XCTAssertEqual(DouyinParser.workURL(id: "1", note: true), "https://www.douyin.com/note/1")
        XCTAssertEqual(DouyinParser.workURL(id: "1", note: false), "https://www.douyin.com/video/1")
        XCTAssertEqual(DouyinParser.nickname(fromPageTitle: "测试用户的抖音 - 抖音"), "测试用户")
        XCTAssertEqual(DouyinParser.nickname(fromPageTitle: "抖音"), "")
        XCTAssertTrue(DouyinParser.isNote(json(#"{"image_post_info":{"images":[{}]}}"#)))
        XCTAssertTrue(DouyinParser.isNote(json(#"{"aweme_type":150}"#)))
        XCTAssertFalse(DouyinParser.isNote(json(#"{"aweme_type":0,"images":null}"#)))
    }

    // MARK: 快手 visionProfilePhotoList

    private let kuaishouPage1 = """
    {"data":{"visionProfilePhotoList":{"result":1,"llsid":"1","pcursor":"1.69E12","hostName":"x","feeds":[
      {"type":1,"author":{"id":"3xq8bzjqs8v3wze","name":"快手作者\\u3164"},
       "photo":{"id":"3x8abcdefg","caption":" 第一条 ","duration":12500,"coverUrl":"https://p2.a.yximgs.com/c1.jpg"}},
      {"type":1,"author":{"id":"3xq8bzjqs8v3wze","name":"快手作者"},
       "photo":{"id":"3x8hijklmn","caption":"","duration":0,"coverUrl":"https://p2.a.yximgs.com/c2.jpg"}},
      {"type":1,"photo":{"caption":"没有 id"}}
    ]}}}
    """

    private let kuaishouPage2 = """
    {"data":{"visionProfilePhotoList":{"result":1,"pcursor":"no_more","feeds":[
      {"author":{"name":"快手作者"},"photo":{"id":"3x8abcdefg","caption":"重复","duration":12500}},
      {"author":{"name":"快手作者"},"photo":{"id":"3x8opqrstu","caption":"第三条","duration":30000,"coverUrl":"c3"}}
    ]}}}
    """

    func testKuaishouProfilePosts() {
        let posts = KuaishouParser.profilePosts([json(kuaishouPage1), json(kuaishouPage2)])
        XCTAssertEqual(posts.author, "快手作者")
        XCTAssertFalse(posts.hasMore)
        XCTAssertEqual(posts.entries.map(\.url), [
            "https://www.kuaishou.com/short-video/3x8abcdefg",
            "https://www.kuaishou.com/short-video/3x8hijklmn",
            "https://www.kuaishou.com/short-video/3x8opqrstu"
        ])
        XCTAssertEqual(posts.entries[0].title, "第一条")
        XCTAssertEqual(posts.entries[0].duration ?? 0, 12.5, accuracy: 0.0001)
        XCTAssertEqual(posts.entries[0].cover, "https://p2.a.yximgs.com/c1.jpg")
        XCTAssertEqual(posts.entries[1].title, "作品 3x8hijklmn")
        XCTAssertNil(posts.entries[1].duration)
        XCTAssertEqual(posts.entries[2].duration ?? 0, 30, accuracy: 0.0001)
        for e in posts.entries {
            let link = VideoLinkParser.parse(e.url)
            XCTAssertEqual(link?.platform, .kuaishou)
            XCTAssertEqual(link?.kind, "photo")
        }
        XCTAssertTrue(KuaishouParser.profilePosts([json(kuaishouPage1)]).hasMore)
    }

    func testKuaishouProfilePage() {
        let p1 = KuaishouParser.profilePage(json(kuaishouPage1))
        XCTAssertTrue(p1.ok)
        XCTAssertTrue(p1.hasMore)
        XCTAssertEqual(p1.pcursor, "1.69E12")
        XCTAssertEqual(p1.feedCount, 3)
        let p2 = KuaishouParser.profilePage(json(kuaishouPage2))
        XCTAssertTrue(p2.ok)
        XCTAssertFalse(p2.hasMore)
        let captcha = KuaishouParser.profilePage(json(#"{"errors":[{"message":"Need captcha"}],"data":{"visionProfilePhotoList":null}}"#))
        XCTAssertFalse(captcha.ok)
        XCTAssertTrue(captcha.needsVerify)
        let failed = KuaishouParser.profilePage(json(#"{"data":{"visionProfilePhotoList":{"result":2,"feeds":[],"pcursor":""}}}"#))
        XCTAssertFalse(failed.ok)
    }

    func testKuaishouHelpers() {
        XCTAssertEqual(KuaishouParser.profileURL("3xabc"), "https://www.kuaishou.com/profile/3xabc")
        XCTAssertEqual(KuaishouParser.photoURL("3xdef"), "https://www.kuaishou.com/short-video/3xdef")
        let body = KuaishouParser.profileQueryBody(userId: "3xabc", pcursor: "")
        XCTAssertEqual(body["operationName"] as? String, "visionProfilePhotoList")
        let vars = body["variables"] as? [String: Any]
        XCTAssertEqual(vars?["userId"] as? String, "3xabc")
        XCTAssertEqual(vars?["pcursor"] as? String, "")
        XCTAssertEqual(vars?["page"] as? String, "profile")
        XCTAssertTrue((body["query"] as? String ?? "").contains("visionProfilePhotoList(pcursor: $pcursor"))
        // 钩子脚本汇总后的形状
        let hooked = json("""
        {"data":{"visionProfilePhotoList":{"result":1,"pcursor":"more","feeds":[
          {"photo":{"id":"3xzz","caption":"c","duration":1000,"coverUrl":"u"},"author":{"name":"A"}}]}},"pages":1}
        """)
        let posts = KuaishouParser.profilePosts([hooked])
        XCTAssertEqual(posts.entries.count, 1)
        XCTAssertTrue(posts.hasMore)
        XCTAssertEqual(posts.author, "A")
    }

    // MARK: 共用脚本

    func testProfileScripts() {
        XCTAssertEqual(ProfileCollectionJS.jsString("a'b\\c\nd"), "'a\\'b\\\\c\\nd'")
        let hook = ProfileCollectionJS.hookScript(urlMarker: "aweme/v1/web/aweme/post", handler: DouyinParser.userPostHandlerJS,
                                                  cardSelector: DouyinParser.userCardSelector)
        XCTAssertTrue(hook.contains("'aweme/v1/web/aweme/post'"))
        XCTAssertTrue(hook.contains("root.aweme_list"))
        XCTAssertTrue(hook.contains("[data-e2e=\"user-post-list\"] li"))
        XCTAssertTrue(ProfileCollectionJS.readyScript.contains("\(ProfileCollectionJS.maxItems)"))
        XCTAssertLessThan(Double(ProfileCollectionJS.budgetMs) / 1000, ProfileCollectionJS.extractorTimeout)
    }

    func testProfileWithoutExtractorThrows() async {
        let link = DetectedVideoLink(platform: .douyin, kind: "user", id: secUID, url: "https://www.douyin.com/user/\(secUID)")
        do {
            _ = try await DouyinParser(extractor: nil).parse(link, cookie: "")
            XCTFail("应当抛错")
        } catch let error as VideoParseError {
            XCTAssertEqual(error.detail, "当前环境无法加载抖音主页（需要 App 内置的网页内核）")
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
    }
}
