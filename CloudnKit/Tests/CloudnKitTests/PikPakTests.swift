import XCTest
@testable import CloudnKit

/// PikPak：链接识别、凭据、签名、请求体与响应解析（纯逻辑，不联网）
final class PikPakTests: XCTestCase {
    // MARK: 链接

    func testShareTarget() {
        let t = PikPakResolver.shareTarget("https://mypikpak.com/s/VNe2BZ0DXCudmDX1f7mOZhGOo1")
        XCTAssertEqual(t?.id, "VNe2BZ0DXCudmDX1f7mOZhGOo1")
        XCTAssertNil(t?.pwd)
        let p = PikPakResolver.shareTarget("https://mypikpak.net/s/VO8BcRb-XXXXX/VO8Bfolder01?pwd=ab12")
        XCTAssertEqual(p?.id, "VO8BcRb-XXXXX")
        XCTAssertEqual(p?.pwd, "ab12")
        XCTAssertEqual(PikPakResolver.folderId(in: "https://mypikpak.com/s/VO8BcRb-XXXXX/VO8Bfolder01"), "VO8Bfolder01")
        XCTAssertNil(PikPakResolver.folderId(in: "https://mypikpak.com/s/VO8BcRb-XXXXX"))
        XCTAssertNil(PikPakResolver.shareTarget("https://notmypikpak.com/s/VNe2BZ0DXCud"))
        XCTAssertNil(PikPakResolver.shareTarget("https://pan.xunlei.com/s/VNe2BZ0DXCud"))
    }

    func testLinkParserIntegration() {
        let parsed = ShareLinkParser.parse("PikPak 分享 https://mypikpak.com/s/VNe2BZ0DXCudmDX1 提取码：x9y8")
        XCTAssertEqual(parsed?.platform, .pikpak)
        XCTAssertEqual(parsed?.shareId, "VNe2BZ0DXCudmDX1")
        XCTAssertEqual(parsed?.pwd, "x9y8")
    }

    // MARK: 凭据

    func testCredentialRoundTrip() {
        let c = PikPakCredential(refreshToken: "os.AbCdEfGhIjKlMnOpQr", accessToken: "eyJhbGciOi.x.y", expiresAt: 1_700_000_000,
                                 deviceId: "0123456789abcdef0123456789abcdef", captchaToken: "ck0.abc", userId: "u1", username: "a@b.com",
                                 client: "android")
        XCTAssertEqual(PikPakCredential.parse(c.serialized), c)
        XCTAssertTrue(c.serialized.hasPrefix(#"{"refresh_token":"os.AbCdEfGhIjKlMnOpQr","access_token":"#))
    }

    func testCredentialParseVariants() {
        let bare = PikPakCredential.parse("  os.AbCdEfGhIjKlMnOpQrStUv  ")
        XCTAssertEqual(bare?.refreshToken, "os.AbCdEfGhIjKlMnOpQrStUv")
        XCTAssertEqual(bare?.accessToken, "")
        XCTAssertEqual(bare?.client, "")
        let camel = PikPakCredential.parse(#"{"refreshToken":"os.AbCdEfGhIjKlMnOpQr","accessToken":"t","sub":"u9","expiry":5,"client":"zz"}"#)
        XCTAssertEqual(camel?.userId, "u9")
        XCTAssertEqual(camel?.expiresAt, 5)
        XCTAssertEqual(camel?.client, "")
        XCTAssertNil(PikPakCredential.parse(""))
        XCTAssertNil(PikPakCredential.parse("short"))
        XCTAssertNil(PikPakCredential.parse(#"{"access_token":"only"}"#))
        XCTAssertNil(PikPakCredential.parse("has spaces in the token value"))
    }

    func testClientFromJWT() {
        let payload = Data(#"{"aud":"YUMx5nI8ZU8Ap8pm","exp":1900000000,"sub":"u"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"
        let cred = PikPakCredential.parse(#"{"access_token":"\#(jwt)","refresh_token":"os.AbCdEfGhIjKlMnOpQr","expires_at":"2024-01-01T00:00:00Z"}"#)
        XCTAssertEqual(cred?.client, "web")
        XCTAssertEqual(cred?.expiresAt, 0)
        XCTAssertEqual(cred?.accessExpiry, 1_900_000_000)
        XCTAssertEqual(cred?.clientInfo, .web)
    }

    func testNormalizeFillsDevice() {
        let normalized = PikPakResolver.normalizeCredential("os.AbCdEfGhIjKlMnOpQrStUv")
        let cred = PikPakCredential.parse(normalized)
        XCTAssertEqual(cred?.refreshToken, "os.AbCdEfGhIjKlMnOpQrStUv")
        XCTAssertEqual(cred?.deviceId.count, 32)
        XCTAssertEqual(PikPakResolver.normalizeCredential(" garbage "), "garbage")
    }

    func testNeedsRefresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var c = PikPakCredential(refreshToken: "os.AbCdEfGhIjKlMnOpQr", accessToken: "tok", expiresAt: 1_000_000 + 3600)
        XCTAssertFalse(c.needsRefresh(now: now))
        XCTAssertTrue(c.needsRefresh(rejecting: "tok", now: now))
        c.expiresAt = 1_000_000 + 100
        XCTAssertTrue(c.needsRefresh(now: now))
        c.accessToken = ""
        XCTAssertTrue(c.needsRefresh(now: now))
    }

    func testApplyToken() {
        let json = JSON(text: #"{"token_type":"Bearer","access_token":"acc","refresh_token":"os.new","expires_in":7200,"sub":"uid"}"#)!
        let base = PikPakCredential(refreshToken: "os.old", username: "me")
        let out = PikPakAuth.applyToken(json, to: base, client: .web, deviceId: "dev", now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(out?.accessToken, "acc")
        XCTAssertEqual(out?.refreshToken, "os.new")
        XCTAssertEqual(out?.expiresAt, 7300)
        XCTAssertEqual(out?.userId, "uid")
        XCTAssertEqual(out?.client, "web")
        XCTAssertEqual(out?.deviceId, "dev")
        XCTAssertEqual(out?.username, "me")
        XCTAssertNil(PikPakAuth.applyToken(JSON(text: #"{"error":"invalid_grant","error_code":4126}"#)!, to: base, client: .android, deviceId: "d"))
    }

    // MARK: 签名 / UA

    func testCaptchaSign() {
        let info = PikPakClientInfo.android
        var s = info.id + info.version + info.packageName + "dev" + "123"
        for salt in info.algorithms { s = Crypto.md5Hex(s + salt) }
        XCTAssertEqual(info.captchaSign(deviceId: "dev", timestamp: "123"), "1." + s)
        XCTAssertTrue(info.captchaSign(deviceId: "dev", timestamp: "123").hasPrefix("1."))
        XCTAssertEqual(info.captchaSign(deviceId: "dev", timestamp: "123").count, 34)
    }

    func testDeviceSignAndUA() {
        let sign = PikPakClientInfo.deviceSign(deviceId: "abc", packageName: "com.pikcloud.pikpak")
        XCTAssertEqual(sign, "div101.abc" + Crypto.md5Hex(Crypto.sha1Hex("abccom.pikcloud.pikpak1appkey")))
        let ua = PikPakClientInfo.android.userAgent(deviceId: "abc", userId: "u1", now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(ua.hasPrefix("ANDROID-com.pikcloud.pikpak/1.53.2 protocolVersion/200 accesstype/ clientid/YNxT9w7GMdWvEOKa "))
        XCTAssertTrue(ua.contains(" devicesign/\(sign) "))
        XCTAssertTrue(ua.contains(" datetime/1000 usrno/u1 appname/android-com.pikcloud.pikpak "))
        XCTAssertEqual(PikPakClientInfo.web.userAgent(deviceId: "abc", userId: ""), PikPakClientInfo.webUA)
    }

    func testAction() {
        XCTAssertEqual(PikPakAuth.action("GET", "https://api-drive.mypikpak.com/drive/v1/files?parent_id=&limit=100"), "GET:/drive/v1/files")
        XCTAssertEqual(PikPakAuth.action("POST", "https://user.mypikpak.com/v1/auth/signin"), "POST:/v1/auth/signin")
        XCTAssertEqual(PikPakAuth.action("POST", "https://api-drive.mypikpak.com/drive/v1/files:batchMove"), "POST:/drive/v1/files:batchMove")
    }

    func testLoginMetaAndBodies() {
        XCTAssertEqual(OrderedJSON.object(PikPakAuth.loginMeta("a.b@c.com")).text, #"{"email":"a.b@c.com"}"#)
        XCTAssertEqual(OrderedJSON.object(PikPakAuth.loginMeta("+8613800138000")).text, #"{"phone_number":"+8613800138000"}"#)
        XCTAssertEqual(OrderedJSON.object(PikPakAuth.loginMeta("someone")).text, #"{"username":"someone"}"#)
        let body = PikPakAuth.captchaBody(action: "POST:/v1/auth/signin", captcha: "", client: .android, deviceId: "dev",
                                          meta: [("email", .string("a@b.c"))], timestamp: "1").text
        XCTAssertTrue(body.hasPrefix(#"{"action":"POST:/v1/auth/signin","captcha_token":"","client_id":"YNxT9w7GMdWvEOKa","device_id":"dev","meta":{"email":"a@b.c","client_version":"1.53.2","package_name":"com.pikcloud.pikpak","timestamp":"1","captcha_sign":"1."#))
        XCTAssertTrue(body.hasSuffix(#""redirect_uri":"xlaccsdk01://xbase.cloud/callback?state=harbor"}"#))
        XCTAssertEqual(PikPakLogin.signinBody(username: "u", password: "p", captcha: "c", client: .android).text,
                       #"{"captcha_token":"c","client_id":"YNxT9w7GMdWvEOKa","client_secret":"dbw2OtmVEeuUvIptb1Coyg","username":"u","password":"p"}"#)
    }

    // MARK: 错误

    func testErrors() {
        XCTAssertTrue(PikPakAuth.isAuthError(JSON(text: #"{"error":"unauthenticated","error_code":16}"#)!))
        XCTAssertTrue(PikPakAuth.isAuthError(JSON(text: #"{"error_code":4122}"#)!))
        XCTAssertTrue(PikPakAuth.isCaptchaError(JSON(text: #"{"error":"captcha_invalid","error_code":9}"#)!))
        XCTAssertFalse(PikPakAuth.isError(JSON(text: #"{"kind":"drive#fileList","error_code":0}"#)!))
        XCTAssertEqual(PikPakAuth.error(JSON(text: #"{"error":"invalid_account_or_password","error_code":4022}"#)!, status: 400).message,
                       "PikPak 账号或密码错误")
        XCTAssertEqual(PikPakAuth.error(JSON(text: #"{"error":"invalid_grant","error_code":4126}"#)!, status: 400).code, PikPakAuth.expiredCode)
        XCTAssertEqual(PikPakAuth.error(JSON(text: #"{"error":"task_daily_create_limit_vip","error_code":4}"#)!, status: 400).message,
                       "PikPak 今日离线次数已用完（免费账号有限额）")
        XCTAssertEqual(PikPakAuth.error(JSON(text: #"{"error":"x","error_description":"出错了"}"#)!, status: 400).message, "PikPak：出错了")
    }

    // MARK: 分享

    func testShareStatus() {
        XCTAssertNoThrow(try PikPakResolver.checkShareStatus(JSON(text: #"{"share_status":"OK"}"#)!))
        XCTAssertThrowsError(try PikPakResolver.checkShareStatus(JSON(text: #"{"share_status":"PASS_CODE_EMPTY"}"#)!))
        XCTAssertThrowsError(try PikPakResolver.checkShareStatus(JSON(text: #"{"share_status":"PASS_CODE_ERROR"}"#)!)) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "PikPak 提取码错误，请检查后重新解析")
        }
        XCTAssertThrowsError(try PikPakResolver.checkShareStatus(JSON(text: #"{"share_status":"WEIRD","share_status_text":"不可用"}"#)!)) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "PikPak 分享无法访问：不可用")
        }
    }

    func testShareParsing() {
        let data = JSON(text: #"{"share_status":"OK","pass_code_token":"pct","files":[{"id":"f1","kind":"drive#file","name":"a.mp4","size":"1024","modified_time":"2024-01-02T03:04:05.000+08:00"}]}"#)!
        XCTAssertEqual(PikPakResolver.shareTitle(data), "a.mp4")
        XCTAssertEqual(PikPakResolver.shareTitle(JSON(text: #"{"title":"合集","files":[]}"#)!), "合集")
        XCTAssertEqual(PikPakResolver.shareTitle(JSON(text: #"{"files":[]}"#)!), "PikPak 分享")
        let f = PikPakResolver.parseFile(data["files"][0], parent: "p")
        XCTAssertEqual(f.fid, "f1")
        XCTAssertEqual(f.size, 1024)
        XCTAssertFalse(f.isDirectory)
        XCTAssertEqual(f.parentId, "p")
        XCTAssertFalse(f.modified.contains("T"))
        let folder = PikPakResolver.parseFile(JSON(text: #"{"id":"d","kind":"drive#folder","name":"dir","parent_id":"x"}"#)!, parent: "p")
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.parentId, "x")
    }

    func testFileLink() {
        XCTAssertEqual(PikPakResolver.fileLink(JSON(text: #"{"web_content_link":"https://dl/a","medias":[{"link":{"url":"https://m/1"}}]}"#)!), "https://dl/a")
        XCTAssertEqual(PikPakResolver.fileLink(JSON(text: #"{"web_content_link":"","medias":[{"link":{"url":""}},{"link":{"url":"https://m/2"}}]}"#)!), "https://m/2")
        XCTAssertNil(PikPakResolver.fileLink(JSON(text: #"{"web_content_link":""}"#)!))
    }

    func testShareDetailURL() {
        let url = PikPakResolver.shareDetailURL("https://api", shareId: "S1", parent: "", passToken: "a+b", pageToken: "")
        XCTAssertTrue(url.hasPrefix("https://api/drive/v1/share/detail?share_id=S1&parent_id=&pass_code_token=a%2Bb&limit=100&page_token="))
        XCTAssertFalse(url.contains("{"))
    }

    // MARK: 我的网盘

    func testDriveBodies() {
        XCTAssertEqual(PikPakResolver.createFolderBody(name: "新建", parent: "p1").text, #"{"kind":"drive#folder","parent_id":"p1","name":"新建"}"#)
        XCTAssertEqual(PikPakResolver.moveBody(ids: ["a", "b"], to: "t").text, #"{"ids":["a","b"],"to":{"parent_id":"t"}}"#)
        XCTAssertEqual(PikPakResolver.idsBody(["a"]).text, #"{"ids":["a"]}"#)
        XCTAssertEqual(PikPakResolver.shareBody(ids: ["a"], days: -1).text,
                       #"{"file_ids":["a"],"share_to":"publiclink","expiration_days":-1,"pass_code_option":"NOT_REQUIRED"}"#)
        XCTAssertEqual(PikPakResolver.restoreBody(shareId: "S", passToken: "t", ids: ["x"], to: "").text,
                       #"{"share_id":"S","pass_code_token":"t","file_ids":["x"],"parent_id":"","ancestor_ids":[],"specify_parent_id":true}"#)
        XCTAssertEqual(PikPakResolver.driveParent("0"), "")
        let url = PikPakResolver.driveFilesURL("https://api", parent: "", pageToken: "", foldersOnly: true)
        XCTAssertTrue(url.hasPrefix("https://api/drive/v1/files?parent_id=&thumbnail_size=SIZE_LARGE&with_audit=true&limit=100&page_token=&filters="))
        XCTAssertTrue(url.contains("drive%23folder"))
    }

    func testDriveParsers() {
        XCTAssertEqual(PikPakResolver.parseQuota(JSON(text: #"{"quota":{"limit":"6442450944","usage":"1024","is_unlimited":false}}"#)!),
                       DriveQuota(used: 1024, total: 6_442_450_944))
        XCTAssertNil(PikPakResolver.parseQuota(JSON(text: #"{"kind":"drive#about"}"#)!))
        XCTAssertEqual(PikPakResolver.parseShareLink(JSON(text: #"{"share_id":"S","share_url":"https://mypikpak.com/s/S","pass_code":""}"#)!),
                       DriveShareLink(url: "https://mypikpak.com/s/S"))
        XCTAssertNil(PikPakResolver.parseShareLink(JSON(text: #"{"share_id":"S"}"#)!))
    }

    // MARK: 离线下载

    func testOffline() {
        let r = PikPakResolver()
        XCTAssertTrue(r.acceptsOffline("magnet:?xt=urn:btih:abc"))
        XCTAssertTrue(r.acceptsOffline("ED2K://|file|a|1|h|/"))
        XCTAssertTrue(r.acceptsOffline("https://example.com/a.zip"))
        XCTAssertFalse(r.acceptsOffline("thunder://abc"))
        XCTAssertEqual(PikPakResolver.offlineBody(url: "magnet:?xt=1", parent: "").text,
                       #"{"kind":"drive#file","name":"","upload_type":"UPLOAD_TYPE_URL","url":{"url":"magnet:?xt=1"},"parent_id":"","folder_type":"DOWNLOAD"}"#)
        XCTAssertTrue(PikPakResolver.offlineBody(url: "u", parent: "p").text.hasSuffix(#""parent_id":"p","folder_type":""}"#))
        let url = PikPakResolver.offlineTasksURL("https://api")
        XCTAssertTrue(url.hasPrefix("https://api/drive/v1/tasks?type=offline&"))
        XCTAssertTrue(url.contains("PHASE_TYPE_PENDING"))
    }

    func testParseOfflineTask() {
        let running = PikPakResolver.parseOfflineTask(JSON(text: #"{"id":"t1","name":"movie","file_size":"2048","phase":"PHASE_TYPE_RUNNING","progress":45,"reference_resource":{"parent_id":"dir"}}"#)!)
        XCTAssertEqual(running, OfflineTask(id: "t1", name: "movie", progress: 0.45, size: 2048, state: .running, folderId: "dir"))
        let failed = PikPakResolver.parseOfflineTask(JSON(text: #"{"id":"t2","file_name":"x","phase":"PHASE_TYPE_ERROR","message":"资源失效","progress":0}"#)!)
        XCTAssertEqual(failed?.state, .failed("资源失效"))
        XCTAssertEqual(failed?.name, "x")
        XCTAssertNil(failed?.folderId)
        let done = PikPakResolver.parseOfflineTask(JSON(text: #"{"id":"t3","name":"y","phase":"PHASE_TYPE_COMPLETE","progress":0}"#)!)
        XCTAssertEqual(done?.state, .done)
        XCTAssertEqual(done?.progress, 1)
        XCTAssertEqual(PikPakResolver.parseOfflineTask(JSON(text: #"{"id":"t4","phase":"PHASE_TYPE_PENDING"}"#)!)?.state, .waiting)
        XCTAssertNil(PikPakResolver.parseOfflineTask(JSON(text: #"{"name":"no id"}"#)!))
    }

    // MARK: 上传

    func testUploadBodyAndTicket() {
        XCTAssertEqual(PikPakResolver.uploadBody(name: "a.bin", parent: "p", size: 10, gcid: "ABC").text,
                       #"{"kind":"drive#file","name":"a.bin","size":10,"hash":"ABC","upload_type":"UPLOAD_TYPE_RESUMABLE","objProvider":{"provider":"UPLOAD_TYPE_UNKNOWN"},"parent_id":"p","folder_type":"NORMAL"}"#)
        let json = JSON(text: #"{"upload_type":"UPLOAD_TYPE_RESUMABLE","resumable":{"kind":"drive#resumable","provider":"PROVIDER_ALIYUN","params":{"access_key_id":"AK","access_key_secret":"SK","bucket":"vip-lixian-07","endpoint":"vip-lixian-07.mypikpak.net","key":"dir/obj name","security_token":"ST"}}}"#)!
        let ticket = PikPakResolver.parseUploadTicket(json)
        XCTAssertEqual(ticket?.endpoint, "mypikpak.net")
        XCTAssertEqual(ticket?.objectURL, "https://vip-lixian-07.mypikpak.net/dir/obj%20name")
        XCTAssertEqual(ticket?.securityToken, "ST")
        XCTAssertNil(PikPakResolver.parseUploadTicket(JSON(text: #"{"file":{"id":"x"}}"#)!))
    }

    // MARK: 未登录

    func testRequiresLogin() async {
        let r = PikPakResolver(credentials: NoCredentials())
        do {
            _ = try await r.openSession(ParsedShare(shareId: "S", pwd: nil, platform: .pikpak, url: "https://mypikpak.com/s/S"), pwd: nil)
            XCTFail("应要求登录")
        } catch {
            XCTAssertEqual(error as? CloudnError, SharePlatform.pikpak.loginRequired)
        }
        let quota = await r.quota()
        XCTAssertNil(quota)
        let validated = await PikPakResolver.validate(cookie: "not a credential")
        XCTAssertNil(validated)
    }
}
