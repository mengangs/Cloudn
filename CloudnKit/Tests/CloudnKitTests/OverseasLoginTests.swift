import XCTest
@testable import CloudnKit

/// 海外平台可选登录：账号类型映射、Cookie 判据、请求头与各平台校验响应的判定（离线）
final class OverseasLoginTests: XCTestCase {
    func testAccountKinds() {
        for kind in OverseasAccount.kinds {
            XCTAssertFalse(kind.isDrive)
            XCTAssertNotNil(OverseasAccount.loginURL(kind))
            XCTAssertFalse(OverseasAccount.cookieDomains(kind).isEmpty)
            XCTAssertFalse(OverseasAccount.manualHint(kind).isEmpty)
        }
        XCTAssertEqual(AccountKind.twitter.rawValue, "twitter")
        XCTAssertEqual(AccountKind.facebook.displayName, "Facebook")
        XCTAssertEqual(VideoPlatform.twitter.accountKind, .twitter)
        XCTAssertEqual(VideoPlatform.instagram.accountKind, .instagram)
        XCTAssertEqual(VideoPlatform.tiktok.accountKind, .tiktok)
        XCTAssertEqual(VideoPlatform.reddit.accountKind, .reddit)
        XCTAssertEqual(VideoPlatform.facebook.accountKind, .facebook)
        XCTAssertEqual(VideoPlatform.threads.accountKind, .threads)
        XCTAssertNil(OverseasAccount.loginURL(.quark))
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.quark, cookie: "__pus=1"))
    }

    func testLooksLoggedIn() {
        XCTAssertTrue(OverseasAccount.looksLoggedIn(.twitter, cookie: "guest_id=v1; auth_token=abc; ct0=def"))
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.twitter, cookie: "guest_id=v1; ct0=def"))
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.twitter, cookie: "auth_token=; ct0=def"))

        XCTAssertTrue(OverseasAccount.looksLoggedIn(.instagram, cookie: "csrftoken=c; sessionid=1%3Aabc; ds_user_id=123"))
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.instagram, cookie: "csrftoken=c; mid=m"))

        XCTAssertTrue(OverseasAccount.looksLoggedIn(.tiktok, cookie: "ttwid=t; sessionid=s1"))
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.tiktok, cookie: "ttwid=t; tt_chain_token=x"))

        XCTAssertTrue(OverseasAccount.looksLoggedIn(.reddit, cookie: "loid=l; reddit_session=eyJhbGci.x.y"))
        // token_v2 游客也有
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.reddit, cookie: "loid=l; token_v2=eyJ"))

        XCTAssertTrue(OverseasAccount.looksLoggedIn(.facebook, cookie: "datr=d; c_user=100012345678; xs=12%3Aabc"))
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.facebook, cookie: "datr=d; c_user=100012345678"))
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.facebook, cookie: "c_user=deleted; xs=1"))
    }

    func testThreadsLogin() {
        XCTAssertTrue(OverseasAccount.looksLoggedIn(.threads, cookie: "csrftoken=c; sessionid=1%3Aabc; ds_user_id=123"))
        XCTAssertFalse(OverseasAccount.looksLoggedIn(.threads, cookie: "csrftoken=c; mid=m"))
        XCTAssertEqual(OverseasAccount.fallbackName(.threads, cookie: "sessionid=s; ds_user_id=55501234"), "Threads 用户 · 1234")
        XCTAssertEqual(ThreadsParser.probeResult(status: 302, location: "https://www.threads.com/login?next=/"), .invalid)
        XCTAssertEqual(ThreadsParser.probeResult(status: 200, location: ""), .unknown)
    }

    func testUserIDAndFallbackName() {
        XCTAssertEqual(OverseasAccount.xUserID(cookie: "twid=u%3D1234567890; ct0=a"), "1234567890")
        XCTAssertEqual(OverseasAccount.xUserID(cookie: "twid=\"u=42\""), "42")
        XCTAssertNil(OverseasAccount.xUserID(cookie: "ct0=a"))
        XCTAssertEqual(OverseasAccount.fallbackName(.twitter, cookie: "twid=u%3D1234567890"), "X 用户 · 7890")
        XCTAssertEqual(OverseasAccount.fallbackName(.instagram, cookie: "ds_user_id=55501234"), "Instagram 用户 · 1234")
        XCTAssertEqual(OverseasAccount.fallbackName(.facebook, cookie: "c_user=100099998888; xs=1"), "Facebook 用户 · 8888")
        XCTAssertEqual(OverseasAccount.fallbackName(.reddit, cookie: "reddit_session=x"), "Reddit 用户")
        XCTAssertEqual(OverseasAccount.conclude(.valid("@jack"), kind: .twitter, cookie: ""), "@jack")
        XCTAssertEqual(OverseasAccount.conclude(.valid(""), kind: .tiktok, cookie: ""), "TikTok 用户")
        XCTAssertNil(OverseasAccount.conclude(.invalid, kind: .tiktok, cookie: "sessionid=1"))
        XCTAssertEqual(OverseasAccount.conclude(.unknown, kind: .reddit, cookie: "reddit_session=1"), "Reddit 用户")
    }

    // MARK: X

    func testTwitterCsrfAndHeaders() {
        let cookie = "guest_id=v1%3A1; auth_token=tok; ct0=abc123; twid=u%3D9"
        XCTAssertEqual(TwitterParser.csrfToken(cookie), "abc123")
        XCTAssertEqual(TwitterParser.csrfToken("ct0=\"q1\""), "q1")
        XCTAssertNil(TwitterParser.csrfToken("auth_token=tok"))
        XCTAssertNil(TwitterParser.csrfToken("ct0="))

        let headers = TwitterParser.apiHeaders(cookie: cookie)
        func value(_ name: String, _ list: [(String, String)]) -> String? { list.first(where: { $0.0 == name })?.1 }
        XCTAssertEqual(value("x-csrf-token", headers), "abc123")
        XCTAssertEqual(value("x-twitter-auth-type", headers), "OAuth2Session")
        XCTAssertEqual(value("Cookie", headers), cookie)
        XCTAssertEqual(value("authorization", headers), TwitterParser.bearer)

        let guest = TwitterParser.apiHeaders(cookie: "ct0=only")
        XCTAssertNil(value("x-csrf-token", guest))
        XCTAssertNil(value("Cookie", guest))
    }

    func testTwitterProbe() {
        let ok = JSON(text: #"{"screen_name":"jack","language":"en"}"#)
        XCTAssertEqual(TwitterParser.probeResult(status: 200, json: ok), .valid("@jack"))
        let bad = JSON(text: #"{"errors":[{"code":32,"message":"Could not authenticate you."}]}"#)
        XCTAssertEqual(TwitterParser.probeResult(status: 401, json: bad), .invalid)
        XCTAssertEqual(TwitterParser.probeResult(status: 403, json: nil), .invalid)
        XCTAssertEqual(TwitterParser.probeResult(status: 429, json: nil), .unknown)
        XCTAssertEqual(TwitterParser.probeResult(status: 200, json: JSON(text: "{}")), .unknown)
    }

    func testLoginRequiredMessage() {
        XCTAssertTrue(OverseasHTTP.loginRequired("X").detail.contains("请先到「我的」页登录 X"))
        XCTAssertTrue(OverseasHTTP.loginRequired("Instagram", reason: "受限").detail.hasPrefix("受限。"))
        // Threads 没有账号入口，不引导去登录
        let threads = OverseasHTTP.loginRequired("Threads").detail
        XCTAssertTrue(threads.contains("需要登录"))
        XCTAssertFalse(threads.contains("「我的」"))
    }

    // MARK: Instagram

    func testInstagramProbe() {
        let ok = JSON(text: #"{"user":{"pk":"1","username":"insta_user","full_name":"I"},"status":"ok"}"#)
        XCTAssertEqual(InstagramParser.probeResult(status: 200, json: ok), .valid("insta_user"))
        XCTAssertEqual(InstagramParser.probeResult(status: 302, json: nil), .invalid)
        let required = JSON(text: #"{"message":"login_required","status":"fail"}"#)
        XCTAssertEqual(InstagramParser.probeResult(status: 400, json: required), .invalid)
        let checkpoint = JSON(text: #"{"message":"checkpoint_required","status":"fail"}"#)
        XCTAssertEqual(InstagramParser.probeResult(status: 400, json: checkpoint), .invalid)
        XCTAssertEqual(InstagramParser.probeResult(status: 429, json: nil), .unknown)
    }

    // MARK: TikTok

    func testTikTokProbe() {
        let ok = JSON(text: #"{"data":{"username":"tt_user","screen_name":"昵称","user_id_str":"1"},"message":"success"}"#)
        XCTAssertEqual(TikTokParser.probeResult(status: 200, json: ok), .valid("昵称"))
        let noNick = JSON(text: #"{"data":{"username":"tt_user","screen_name":""},"message":"success"}"#)
        XCTAssertEqual(TikTokParser.probeResult(status: 200, json: noNick), .valid("@tt_user"))
        let expired = JSON(text: #"{"data":{"captcha":"","description":"Session expired, please sign in again.","error_code":4},"message":"error"}"#)
        XCTAssertEqual(TikTokParser.probeResult(status: 200, json: expired), .invalid)
        let other = JSON(text: #"{"data":{"description":"Too many attempts","error_code":7},"message":"error"}"#)
        XCTAssertEqual(TikTokParser.probeResult(status: 200, json: other), .unknown)
        XCTAssertEqual(TikTokParser.probeResult(status: 200, json: nil), .unknown)
    }

    // MARK: Reddit

    func testRedditProbe() {
        let ok = JSON(text: #"{"kind":"t2","data":{"name":"spez","id":"1w72"}}"#)
        XCTAssertEqual(RedditParser.probeResult(status: 200, json: ok), .valid("u/spez"))
        XCTAssertEqual(RedditParser.probeResult(status: 200, json: JSON(text: "{}")), .invalid)
        XCTAssertEqual(RedditParser.probeResult(status: 401, json: nil), .invalid)
        XCTAssertEqual(RedditParser.probeResult(status: 403, json: nil), .unknown)
        XCTAssertTrue(RedditParser.hasLoginCookie("reddit_session=abc"))
        XCTAssertFalse(RedditParser.hasLoginCookie("token_v2=abc"))
    }

    // MARK: Facebook

    func testFacebookProbe() {
        let html = #"<script>require(["CurrentUserInitialData",[],{"ACCOUNT_ID":"100012345678","USER_ID":"100012345678","NAME":"Jane Doe","SHORT_NAME":"Jane"},270]);</script>"#
        XCTAssertEqual(FacebookParser.probeResult(status: 200, html: html, finalURL: "https://www.facebook.com/", cUser: "100012345678"),
                       .valid("Jane Doe"))
        let escaped = #"["CurrentUserInitialData",[],{"USER_ID":"7","NAME":"张三"},270]"#
        XCTAssertEqual(FacebookParser.probeResult(status: 200, html: escaped, finalURL: "https://www.facebook.com/", cUser: "7"), .valid("张三"))
        let guest = #"["CurrentUserInitialData",[],{"ACCOUNT_ID":"0","USER_ID":"0","NAME":""},270]"#
        XCTAssertEqual(FacebookParser.probeResult(status: 200, html: guest, finalURL: "https://www.facebook.com/", cUser: "7"), .invalid)
        XCTAssertEqual(FacebookParser.probeResult(status: 200, html: "", finalURL: "https://www.facebook.com/login/?next=x", cUser: "7"),
                       .invalid)
        XCTAssertEqual(FacebookParser.probeResult(status: 200, html: #"{"USER_ID":"7"}"#, finalURL: "https://www.facebook.com/", cUser: "7"),
                       .valid(""))
        XCTAssertEqual(FacebookParser.probeResult(status: 200, html: "<html></html>", finalURL: "https://www.facebook.com/", cUser: "7"),
                       .unknown)
        XCTAssertEqual(FacebookParser.probeResult(status: 500, html: "", finalURL: "https://www.facebook.com/", cUser: "7"), .unknown)
    }
}
