import XCTest
@testable import CloudnKit

final class Cloud189Tests: XCTestCase {
    // MARK: 链接识别

    func testShareTargets() {
        XCTAssertEqual(Cloud189Resolver.shareTarget("https://cloud.189.cn/t/AbCdEf123")?.id, "AbCdEf123")
        XCTAssertNil(Cloud189Resolver.shareTarget("https://cloud.189.cn/t/AbCdEf123")?.pwd)
        XCTAssertEqual(Cloud189Resolver.shareTarget("https://cloud.189.cn/web/share?code=XyZ123")?.id, "XyZ123")
        XCTAssertEqual(Cloud189Resolver.shareTarget("https://cloud.189.cn/web/share?a=1&code=XyZ124")?.id, "XyZ124")
        XCTAssertEqual(Cloud189Resolver.shareTarget("https://h5.cloud.189.cn/share.html#/t/QwE987")?.id, "QwE987")
        XCTAssertEqual(Cloud189Resolver.shareTarget("https://m.cloud.189.cn/t/mObile1")?.id, "mObile1")
        let inline = Cloud189Resolver.shareTarget("https://cloud.189.cn/t/abc123（访问码：k3j9")
        XCTAssertEqual(inline?.id, "abc123")
        XCTAssertEqual(inline?.pwd, "k3j9")
        let encoded = Cloud189Resolver.shareTarget("https://cloud.189.cn/t/abc124%EF%BC%88%E8%AE%BF%E9%97%AE%E7%A0%81%EF%BC%9Az9y8%EF%BC%89")
        XCTAssertEqual(encoded?.id, "abc124")
        XCTAssertEqual(encoded?.pwd, "z9y8")
        XCTAssertNil(Cloud189Resolver.shareTarget("https://pan.quark.cn/s/abc"))
        XCTAssertNil(Cloud189Resolver.shareTarget("https://notcloud.189.cn.example.com/x"))
    }

    func testLinkParserIntegration() {
        let p = ShareLinkParser.parse("天翼云盘分享：https://cloud.189.cn/t/ABCdef12 （访问码：ab12）")
        XCTAssertEqual(p?.platform, .cloud189)
        XCTAssertEqual(p?.shareId, "ABCdef12")
        XCTAssertEqual(p?.pwd, "ab12")
    }

    // MARK: 凭据

    func testCredentialForms() throws {
        let cred = Cloud189Credential(accessToken: "acc", refreshToken: "ref", sessionKey: "sk", sessionSecret: "ss", loginName: "u@189.cn")
        XCTAssertEqual(Cloud189Credential.parse(cred.serialized), cred)
        XCTAssertFalse(cred.isCookie)

        let cookie = "JSESSIONID=abc; COOKIE_LOGIN_USER=DEADBEEF; apm_ct=1"
        let web = try XCTUnwrap(Cloud189Credential.parse(cookie))
        XCTAssertTrue(web.isCookie)
        XCTAssertEqual(web.serialized, cookie)
        XCTAssertEqual(Cloud189Resolver.normalizeCredential("  \(cookie)\n"), cookie)
        XCTAssertTrue(Cloud189Resolver.looksLoggedIn(cookie: cookie))

        XCTAssertNil(Cloud189Credential.parse("JSESSIONID=abc"))
        XCTAssertNil(Cloud189Credential.parse("{}"))
        XCTAssertEqual(Cloud189Credential.parse(#"{"access_token":"a","refresh_token":"r"}"#)?.refreshToken, "r")
        XCTAssertEqual(Cloud189Resolver.normalizeCredential(#"{"accessToken":"a"}"#),
                       #"{"accessToken":"a","refreshToken":"","sessionKey":"","sessionSecret":"","loginName":""}"#)
        XCTAssertEqual(Cloud189Resolver.loginURL, "https://cloud.189.cn/web/login.html")
        XCTAssertEqual(Cloud189Resolver.cookieDomains, ["189.cn"])
    }

    func testMergeSession() {
        let old = Cloud189Credential(accessToken: "a1", refreshToken: "r1", sessionKey: "s1", sessionSecret: "x1", loginName: "n")
        let fresh = Cloud189Credential(accessToken: "", refreshToken: "", sessionKey: "s2", sessionSecret: "x2", loginName: "")
        let merged = Cloud189Resolver.merge(old, fresh)
        XCTAssertEqual(merged, Cloud189Credential(accessToken: "a1", refreshToken: "r1", sessionKey: "s2", sessionSecret: "x2", loginName: "n"))
    }

    // MARK: 分享

    func testShareMetaAndBigIds() throws {
        let info = try XCTUnwrap(JSON(text: #"{"res_code":0,"shareId":123456789,"shareMode":1,"isFolder":true,"fileId":72311113563862345,"fileName":"电影","fileSize":0}"#))
        let meta = Cloud189Resolver.shareMeta(info, shareId: Cloud189Resolver.idString(info["shareId"]), accessCode: "ab12")
        XCTAssertEqual(meta.shareId, "123456789")
        XCTAssertEqual(meta.fileId, "72311113563862345")
        XCTAssertTrue(meta.isFolder)
        XCTAssertEqual(Cloud189Resolver.ShareMeta.decode(meta.encoded), meta)
        XCTAssertEqual(Cloud189Resolver.idString(JSON(0)), "")

        let params = Cloud189Resolver.listShareParams(meta, dir: "999", page: 2, pageSize: 100)
        XCTAssertTrue(params.contains { $0 == ("shareId", "123456789") })
        XCTAssertTrue(params.contains { $0 == ("shareDirFileId", "999") })
        XCTAssertTrue(params.contains { $0 == ("accessCode", "ab12") })
        XCTAssertTrue(params.contains { $0 == ("pageNum", "2") })
    }

    func testSingleFileShareList() async throws {
        let meta = Cloud189Resolver.ShareMeta(shareId: "1", shareMode: "1", accessCode: "", isFolder: false, fileId: "55",
                                              fileName: "a.mp4", fileSize: 1024)
        let session = ShareSession(platform: .cloud189, shareId: "code", stoken: meta.encoded, title: "a.mp4", rootId: "55")
        let files = try await Cloud189Resolver().list(session, dirId: "55")
        XCTAssertEqual(files, [ShareFile(fid: "55", name: "a.mp4", size: 1024, isDirectory: false, parentId: "")])
    }

    func testParseFileList() throws {
        let json = try XCTUnwrap(JSON(text: """
        {"res_code":0,"fileListAO":{"count":3,"folderList":[{"id":72311113563862346,"name":"子目录","parentId":10,"lastOpTime":"2024-01-02 03:04:05"}],
        "fileList":[{"id":"8001","name":"It\\\\'s.mkv","size":123456789012,"md5":"ABC","lastOpTime":"2024-01-02 03:04:05"},
        {"id":8002,"name":"b.txt","size":5}]}}
        """))
        let (files, count) = Cloud189Resolver.parseFileList(json, parent: "10")
        XCTAssertEqual(count, 3)
        XCTAssertEqual(files.map(\.fid), ["72311113563862346", "8001", "8002"])
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[0].name, "子目录")
        XCTAssertEqual(files[1].name, "It's.mkv")
        XCTAssertEqual(files[1].size, 123456789012)
        XCTAssertEqual(files[1].parentId, "10")
        XCTAssertEqual(files[2].size, 5)
    }

    func testShareErrors() throws {
        XCTAssertEqual(Cloud189Resolver.shareError(JSON(text: #"{"res_code":"ShareNotFound","res_message":"x"}"#)!)?.message, "天翼云盘分享不存在或已被取消")
        XCTAssertEqual(Cloud189Resolver.shareError(JSON(text: #"{"res_code":"ShareAuditWaiting"}"#)!)?.message, "天翼云盘分享正在审核中，请稍后再试")
        XCTAssertNil(Cloud189Resolver.shareError(JSON(text: #"{"res_code":0}"#)!))
        XCTAssertNil(Cloud189Resolver.apiError(JSON(text: #"{"res_code":0,"res_message":"成功"}"#)!, status: 200))
        XCTAssertEqual(Cloud189Resolver.apiError(JSON(text: #"{"errorCode":"InvalidSessionKey","errorMsg":"x"}"#)!, status: 400), Cloud189Resolver.expired)
        XCTAssertEqual(Cloud189Resolver.apiError(JSON(text: #"{"res_code":"FileAlreadyExists"}"#)!, status: 200)?.message, "目标位置已有同名文件")
        XCTAssertEqual(Cloud189Resolver.apiError(JSON(text: #"{"errorVO":{"errorCode":"ShareCreateOverload"}}"#)!, status: 200)?.message,
                       "今日分享次数已达上限，请明天再试")
        XCTAssertEqual(Cloud189Resolver.apiError(JSON(text: #"{"res_code":"Other","res_message":"出错了"}"#)!, status: 200)?.message, "天翼云盘：出错了")
        XCTAssertEqual(Cloud189Resolver.apiError(JSON(text: "{}")!, status: 500)?.code, 500)
        XCTAssertTrue(Cloud189Resolver.isSessionError(#"{"res_code":"InvalidSessionKey"}"#))
        XCTAssertTrue(Cloud189Resolver.isSessionError("userSessionBO is null"))
        XCTAssertFalse(Cloud189Resolver.isSessionError(#"{"res_code":0}"#))
    }

    func testCleanDownloadURL() {
        XCTAssertEqual(Cloud189Resolver.cleanDownloadURL("http://download.cloud.189.cn/file?a=1&amp;b=2"), "https://download.cloud.189.cn/file?a=1&b=2")
        XCTAssertEqual(Cloud189Resolver.cleanDownloadURL("//x.cn/y"), "https://x.cn/y")
    }

    // MARK: 请求签名

    func testSignatureSorting() {
        let sig = Cloud189Resolver.sign([("shareId", "456"), ("fileId", "123"), ("dt", "1"), ("Timestamp", "1700000000000"), ("AppKey", "600100422")])
        XCTAssertEqual(sig, "9048599b487b6972a831cd0d1bf7886b")
    }

    func testWebRequestGET() throws {
        let req = Cloud189Resolver.webRequest("/api/open/file/getFileDownloadUrl.action", params: [("fileId", "123"), ("dt", "1"), ("shareId", "456")],
                                              sessionKey: "sk 1", cookie: "", timestamp: "1700000000000")
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.url, "https://cloud.189.cn/api/open/file/getFileDownloadUrl.action?fileId=123&dt=1&shareId=456&sessionKey=sk%201")
        let h = Dictionary(req.headers, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(h["Signature"], "9048599b487b6972a831cd0d1bf7886b")
        XCTAssertEqual(h["Sign-Type"], "1")
        XCTAssertEqual(h["AppKey"], "600100422")
        XCTAssertEqual(h["Timestamp"], "1700000000000")
        XCTAssertNil(h["Cookie"])
    }

    func testWebRequestPOSTAndPortal() throws {
        let req = Cloud189Resolver.webRequest("/api/open/file/createFolder.action", method: "POST",
                                              params: [("parentFolderId", "-11"), ("folderName", "新建")], sessionKey: "sk",
                                              cookie: "COOKIE_LOGIN_USER=x", timestamp: "1700000000000")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url, "https://cloud.189.cn/api/open/file/createFolder.action?sessionKey=sk")
        XCTAssertEqual(String(decoding: try XCTUnwrap(req.body), as: UTF8.self), "parentFolderId=-11&folderName=%E6%96%B0%E5%BB%BA")
        let h = Dictionary(req.headers, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(h["Signature"], "e875db81d824ae50eb83133bba64b390")
        XCTAssertEqual(h["Cookie"], "COOKIE_LOGIN_USER=x")

        let portal = Cloud189Resolver.webRequest("/api/portal/getUserSizeInfo.action", params: [], sessionKey: "sk", cookie: "")
        XCTAssertEqual(portal.url, "https://cloud.189.cn/api/portal/getUserSizeInfo.action?sessionKey=sk")
        XCTAssertFalse(portal.headers.contains { $0.0 == "Signature" })
    }

    func testEncoding() {
        XCTAssertEqual(Cloud189Resolver.encodeURIComponent("a b(1)!.txt"), "a%20b(1)!.txt")
        XCTAssertEqual(Cloud189Resolver.encodeURIComponent("视频.mp4"), "%E8%A7%86%E9%A2%91.mp4")
        XCTAssertEqual(Cloud189Resolver.query([("a", "1&2"), ("b", "x y")]), "a=1%262&b=x%20y")
    }

    // MARK: 我的网盘

    func testDriveParsing() throws {
        XCTAssertEqual(Cloud189Resolver.taskInfos([ShareFile(fid: "1", name: "a\"b", size: 0, isDirectory: true),
                                                   ShareFile(fid: "2", name: "c", size: 1, isDirectory: false)]),
                       #"[{"fileId":"1","fileName":"a\"b","isFolder":1},{"fileId":"2","fileName":"c","isFolder":0}]"#)
        XCTAssertTrue(try Cloud189Resolver.batchFinished(JSON(text: #"{"taskStatus":4,"successedCount":1}"#)!))
        XCTAssertFalse(try Cloud189Resolver.batchFinished(JSON(text: #"{"taskStatus":3}"#)!))
        XCTAssertThrowsError(try Cloud189Resolver.batchFinished(JSON(text: #"{"taskStatus":2}"#)!))

        let link = Cloud189Resolver.parseShareLink(JSON(text: #"{"res_code":0,"shareLinkList":[{"url":"https://cloud.189.cn/t/Abc","accessCode":"x1y2"}]}"#)!)
        XCTAssertEqual(link, DriveShareLink(url: "https://cloud.189.cn/t/Abc", pwd: "x1y2"))
        XCTAssertEqual(Cloud189Resolver.parseShareLink(JSON(text: #"{"shortShareUrl":"//cloud.189.cn/t/Q"}"#)!)?.url, "https://cloud.189.cn/t/Q")
        XCTAssertNil(Cloud189Resolver.parseShareLink(JSON(text: "{}")!))

        let q = Cloud189Resolver.parseQuota(JSON(text: #"{"res_code":0,"cloudCapacityInfo":{"totalSize":2199023255552,"usedSize":1024}}"#)!)
        XCTAssertEqual(q, DriveQuota(used: 1024, total: 2199023255552))
        XCTAssertNil(Cloud189Resolver.parseQuota(JSON(text: "{}")!))

        let params = Cloud189Resolver.listParams("-11", page: 1, pageSize: 200)
        XCTAssertTrue(params.contains { $0 == ("folderId", "-11") })
    }

    func testWiring() {
        let resolvers = ShareResolvers(credentials: NoCredentials())
        XCTAssertNotNil(resolvers.manager(for: .cloud189))
        XCTAssertNotNil(resolvers.saver(for: .cloud189))
        XCTAssertNotNil(resolvers.uploader(for: .cloud189))
        XCTAssertNil(resolvers.offline(for: .cloud189))
        XCTAssertEqual(resolvers.manager(for: .cloud189)?.driveRootId, "-11")
        XCTAssertNotNil(PasswordLogins.provider(for: .cloud189))
    }

    // MARK: 上传

    func testPartSize() {
        let mb: Int64 = 1 << 20
        XCTAssertEqual(Cloud189Resolver.partSize(5 * mb), 10 * mb)
        XCTAssertEqual(Cloud189Resolver.partSize(10 * mb * 999), 10 * mb)
        XCTAssertEqual(Cloud189Resolver.partSize(10 * mb * 999 + 1), 20 * mb)
        XCTAssertEqual(Cloud189Resolver.partSize(20 * mb * 999 + 1), 50 * mb)
        XCTAssertEqual(Cloud189Resolver.partSize(100 * 1024 * mb), 60 * mb)
    }

    func testHashesAcrossChunkBoundaries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c189-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<25_000).map { UInt8($0 % 251) })
        try data.write(to: url)
        let (fileMd5, slices) = try Cloud189Resolver.hashes(url, partSize: 10_000, progress: nil)
        XCTAssertEqual(fileMd5, MD5Hasher.hex(data).uppercased())
        XCTAssertEqual(slices.count, 3)
        XCTAssertEqual(slices[0], MD5Hasher.digest(data.subdata(in: 0..<10_000)))
        XCTAssertEqual(slices[2], MD5Hasher.digest(data.subdata(in: 20_000..<25_000)))
        let joined = slices.map { Crypto.hex($0).uppercased() }.joined(separator: "\n")
        XCTAssertEqual(Cloud189Resolver.sliceMd5(fileMd5: fileMd5, slices: slices), Crypto.md5Hex(joined).uppercased())
        XCTAssertEqual(Cloud189Resolver.sliceMd5(fileMd5: "F", slices: [slices[0]]), "F")

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("c189-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: empty) }
        try Data().write(to: empty)
        let e = try Cloud189Resolver.hashes(empty, partSize: 10_000, progress: nil)
        XCTAssertEqual(e.file, "D41D8CD98F00B204E9800998ECF8427E")
        XCTAssertEqual(e.slices.count, 1)
    }

    func testParseUploadHeaders() {
        let h = Cloud189Resolver.parseHeaders("Authorization=AWS a:b=&x-amz-date=20240101T000000Z&Content-Type=")
        XCTAssertEqual(h.map(\.0), ["Authorization", "x-amz-date", "Content-Type"])
        XCTAssertEqual(h[0].1, "AWS a:b=")
        XCTAssertEqual(h[2].1, "")
    }

    func testUploadRequest() throws {
        let key = Cloud189UploadKey(pubKey: Self.testPublicKey, pkId: "pk1")
        let req = try XCTUnwrap(Cloud189Resolver.uploadRequest(
            "/person/initMultiUpload",
            params: [("parentFolderId", "-11"), ("fileName", "a%20b.txt"), ("fileSize", "5"), ("sliceSize", "10485760"),
                     ("fileMd5", "X"), ("sliceMd5", "X")],
            sessionKey: "sk-1", key: key, uuid: "0123456789abcdef0123", requestId: "rid", timestamp: "1700000000000"))
        let enc = "f7d24fd17610395e39f995e8035c1e7ad791b2dee122f781ed54d528e5470bb98e876424f0c684e607dd1de70b4805ebbe42f8f4fabc13e1927161aa1e6414dd7935f84368218ef3fd5afe69840218cfd6a00529981c9694392c3e9849273910"
        XCTAssertEqual(req.url, "https://upload.cloud.189.cn/person/initMultiUpload?params=" + enc)
        let h = Dictionary(req.headers, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(h["Signature"], "13424fc91efac3cc941db51c6c20b0d62c7eba68")
        XCTAssertEqual(h["SessionKey"], "sk-1")
        XCTAssertEqual(h["PkId"], "pk1")
        XCTAssertEqual(h["X-Request-Date"], "1700000000000")
        // EncryptionText 用私钥解开就是 uuid
        let cipher = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(h["EncryptionText"])))
        XCTAssertEqual(Self.decrypt(Array(cipher)), Array("0123456789abcdef0123".utf8))
        let k = Cloud189Resolver.randomUUIDKey()
        XCTAssertTrue((16...31).contains(k.count))
    }

    // MARK: RSA

    /// 测试用 512 位密钥（openssl genrsa 512）
    static let testPublicKey = "MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBALhhXKM0EVBf9E461bt5jSoGuWOb//3iFUk7WXYBLPb/bFa/FD/nVsKeoYep7E0jrk4uW3sXK8z1b/k1nHXPNWECAwEAAQ=="
    static let testModulus = "b8615ca33411505ff44e3ad5bb798d2a06b9639bfffde215493b5976012cf6ff6c56bf143fe756c29ea187a9ec4d23ae4e2e5b7b172bccf56ff9359c75cf3561"
    static let testPrivate = "72da73525684d2847332a803ab9cb40a91d5b9eedb2fd33d5f38d12968e211994af02a8435eaeb86890307f1aa4f80619d03992805914119d64d54f69dd5b681"

    /// 私钥解密并去掉 PKCS#1 v1.5 填充
    static func decrypt(_ cipher: [UInt8]) -> [UInt8]? {
        guard let n = BigUInt(hex: testModulus), let d = BigUInt(hex: testPrivate) else { return nil }
        let em = BigUInt(bytes: cipher).power(d, modulus: n).bytes(length: 64)
        guard em[0] == 0, em[1] == 2, let sep = em[2...].firstIndex(of: 0), sep >= 10 else { return nil }
        return Array(em[(sep + 1)...])
    }

    func testRSA() throws {
        let key = try XCTUnwrap(Cloud189RSA.parse(Self.testPublicKey))
        XCTAssertEqual(key.size, 64)
        XCTAssertEqual(key.modulus, BigUInt(hex: Self.testModulus))
        XCTAssertEqual(key.exponent, BigUInt(65537))
        let pem = "-----BEGIN PUBLIC KEY-----\n\(Self.testPublicKey.prefix(40))\n\(Self.testPublicKey.dropFirst(40))\n-----END PUBLIC KEY-----"
        XCTAssertEqual(Cloud189RSA.parse(pem), key)

        let hex = try XCTUnwrap(Cloud189RSA.encryptHex("13800138000", publicKey: Self.testPublicKey))
        XCTAssertEqual(hex.count, 128)
        XCTAssertEqual(hex, hex.uppercased())
        XCTAssertEqual(Self.decrypt(try XCTUnwrap(Crypto.bytes(hex: hex))), Array("13800138000".utf8))
        // 超过 k - 11 字节不能加密
        XCTAssertNil(Cloud189RSA.encrypt([UInt8](repeating: 1, count: 54), key: key))
        XCTAssertNil(Cloud189RSA.parse("bm90IGEga2V5"))
    }

    // MARK: 登录

    func testLoginParams() throws {
        let redirect = "https://open.e.189.cn/api/logbox/separate/web/index.html?appId=9317140619&lt=LT123&reqId=REQ456"
        let p = try XCTUnwrap(Cloud189Login.parseLoginParams(finalURL: redirect, page: "<html></html>"))
        XCTAssertEqual(p.lt, "LT123")
        XCTAssertEqual(p.reqId, "REQ456")
        XCTAssertEqual(p.paramId, "")
        XCTAssertEqual(p.referer, redirect)

        let page = """
        <script>var lt = "LTold"; var reqId = "R1"; var paramId = "P9"; var encryptUrl = "https://x/y";</script>
        <input type='hidden' name='captchaToken' value='CT7'>
        """
        let old = try XCTUnwrap(Cloud189Login.parseLoginParams(finalURL: "https://open.e.189.cn/api/logbox/oauth2/unifyAccountLogin.do", page: page))
        XCTAssertEqual(old.lt, "LTold")
        XCTAssertEqual(old.paramId, "P9")
        XCTAssertEqual(old.captchaToken, "CT7")
        XCTAssertTrue(old.referer.contains("lt=LTold"))
        XCTAssertTrue(old.referer.contains("encryptUrl=https%3A%2F%2Fx%2Fy"))
        XCTAssertNil(Cloud189Login.parseLoginParams(finalURL: "https://cloud.189.cn/", page: "nothing"))
    }

    func testLoginErrors() {
        XCTAssertNil(Cloud189Login.loginError(JSON(text: #"{"result":0,"toUrl":"https://x"}"#)!))
        XCTAssertEqual(Cloud189Login.loginError(JSON(text: #"{"result":-133,"mobile":"x"}"#)!)?.message, "天翼云盘要求短信验证新设备，请改用网页登录")
        XCTAssertEqual(Cloud189Login.loginError(JSON(text: #"{"result":-2,"msg":"密码错误"}"#)!)?.message, "天翼云盘登录失败：密码错误")
        XCTAssertEqual(Cloud189Login.loginError(JSON(text: #"{"result":-1,"msg":"请输入验证码"}"#)!)?.message, "天翼云盘要求输入验证码，请改用网页登录")
    }

    func testCookieJar() {
        let jar = Cloud189Login.Jar()
        jar.merge([("a", "1"), ("b", "2")])
        jar.merge([("a", "3")])
        XCTAssertEqual(jar.header, "a=3; b=2")
    }

    // MARK: 新设备短信校验

    func testJarDeviceId() {
        let jar = Cloud189Login.Jar(header: "JSESSIONID=abc; LT=x=y", deviceId: "DEV1")
        XCTAssertEqual(jar.header, "JSESSIONID=abc; LT=x=y")
        XCTAssertEqual(jar.header(for: "https://open.e.189.cn/api/logbox/oauth2/loginSubmit.do"), "JSESSIONID=abc; LT=x=y; DEVICEID=DEV1")
        // cloud.189.cn 不带 DEVICEID
        XCTAssertEqual(jar.header(for: "https://cloud.189.cn/api/portal/unifyLoginForPC.action"), "JSESSIONID=abc; LT=x=y")
        jar.merge([("DEVICEID", "DEV2"), ("c", "1")])
        XCTAssertEqual(jar.deviceId, "DEV2")
        XCTAssertEqual(jar.header, "JSESSIONID=abc; LT=x=y; c=1")
        jar.merge([("DEVICEID", "")])
        XCTAssertEqual(jar.deviceId, "DEV2")
        XCTAssertEqual(Cloud189Login.Jar().header(for: "https://open.e.189.cn/x"), "")
    }

    static let sampleAuth = Cloud189Login.SecondAuth(
        account: "13800138000", lt: "LT1", reqId: "REQ1", paramId: "P1",
        referer: "https://open.e.189.cn/api/logbox/separate/web/index.html?appId=9317140619&lt=LT1&reqId=REQ1",
        userName: "{NRP}AABB", pubKey: testPublicKey, pre: "{NRP}", mobile: "ENCMOBILE==", cookie: "JSESSIONID=s1",
        deviceId: "", finger: "1234567890")

    func testSecondAuthState() {
        let auth = Self.sampleAuth
        XCTAssertEqual(Cloud189Login.SecondAuth(state: auth.state), auth)
        XCTAssertEqual(Set(auth.state.keys), Set(Cloud189Login.SecondAuth.keys))
        var missing = auth.state
        missing["mobile"] = ""
        XCTAssertNil(Cloud189Login.SecondAuth(state: missing))
        XCTAssertNil(Cloud189Login.SecondAuth(state: [:]))
        XCTAssertEqual(auth.params.lt, "LT1")
        XCTAssertEqual(auth.params.referer, auth.referer)
    }

    private func form(_ req: HTTPRequest) -> [String: String] {
        let body = String(decoding: req.body ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }

    private func header(_ req: HTTPRequest, _ name: String) -> String? {
        req.headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    func testSendSMSRequest() {
        let req = Cloud189Login.sendSMSRequest(Self.sampleAuth, cookie: "JSESSIONID=s1; DEVICEID=D")
        XCTAssertEqual(req.url, "https://open.e.189.cn/api/logbox/oauth2/sendSmsCodeForSecondAuth.do")
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(form(req), ["mobile": "ENCMOBILE==", "appKey": "9317140619"])
        XCTAssertEqual(header(req, "lt"), "LT1")
        XCTAssertEqual(header(req, "REQID"), "REQ1")
        XCTAssertEqual(header(req, "user-finger"), "1234567890")
        XCTAssertEqual(header(req, "Referer"), Self.sampleAuth.referer)
        XCTAssertEqual(header(req, "Cookie"), "JSESSIONID=s1; DEVICEID=D")
    }

    func testSubmitSMSRequest() {
        let req = Cloud189Login.submitSMSRequest(Self.sampleAuth, epd: "{NRP}CODEHEX", cookie: "")
        XCTAssertEqual(req.url, "https://open.e.189.cn/api/logbox/oauth2/submitForSecondAuth.do")
        let f = form(req)
        XCTAssertEqual(f["mobile"], "ENCMOBILE==")
        XCTAssertEqual(f["appKey"], "9317140619")
        XCTAssertEqual(f["userName"], "{NRP}AABB")
        XCTAssertEqual(f["epd"], "{NRP}CODEHEX")
        XCTAssertEqual(f["accountType"], "02")
        XCTAssertEqual(f["returnUrl"], "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html")
        XCTAssertEqual(f["isOauth2"], "false")
        XCTAssertEqual(f["paramId"], "P1")
        XCTAssertEqual(f["state"], "")
        XCTAssertNil(header(req, "Cookie"))
        XCTAssertEqual(header(req, "lt"), "LT1")
    }

    func testSMSErrors() {
        XCTAssertNil(Cloud189Login.smsError(JSON(text: #"{"result":0,"msg":"发送成功"}"#)!, action: "发送验证码"))
        XCTAssertNil(Cloud189Login.smsError(JSON(text: #"{"result":"0"}"#)!, action: "验证"))
        XCTAssertEqual(Cloud189Login.smsError(JSON(text: #"{"result":-1,"msg":"短信验证码错误"}"#)!, action: "验证")?.message,
                       "天翼云盘验证失败：短信验证码错误")
        XCTAssertEqual(Cloud189Login.smsError(JSON(text: #"{"result":-9}"#)!, action: "发送验证码")?.message, "天翼云盘发送验证码失败（-9）")
        XCTAssertEqual(Cloud189Login.smsError(JSON(text: #"{"result":-2,"msg":"请输入图形验证码"}"#)!, action: "发送验证码")?.message,
                       "天翼云盘要求输入图形验证码，请改用网页登录")
        XCTAssertEqual(Cloud189Login.smsError(JSON(text: #"{"result":-3,"msg":"登录信息已失效"}"#)!, action: "验证")?.message,
                       "天翼云盘登录已超时，请重新用账号密码登录后再获取验证码")
    }

    func testSentMessage() {
        XCTAssertEqual(Cloud189Login.sentMessage(mobile: "138****8000"), "验证码已发送到 138****8000，用于验证新设备")
        XCTAssertEqual(Cloud189Login.sentMessage(mobile: "A1B2C3D4E5F6A7B8C9D0"), "验证码已发送到账号绑定的手机，用于验证新设备")
    }

    func testPendingTTL() {
        let pending = Cloud189Login.Pending()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        pending.set(Self.sampleAuth, now: t0)
        XCTAssertEqual(pending.get(now: t0.addingTimeInterval(60)), Self.sampleAuth)
        XCTAssertNil(pending.get(now: t0.addingTimeInterval(Cloud189Login.secondAuthTTL + 1)))
        XCTAssertNil(pending.get(now: t0))
    }

    func testFingerAndSMSSupport() {
        let finger = Cloud189Login.finger
        XCTAssertEqual(finger.count, 10)
        XCTAssertTrue(finger.allSatisfy(\.isNumber))
        XCTAssertNotEqual(finger.first, "0")
        XCTAssertEqual(Cloud189Login.finger, finger)
        XCTAssertTrue(Cloud189Login(client: .shared).supportsSMS)
    }

    func testSMSWithoutPendingPasswordLogin() async {
        Cloud189Login.pending.set(nil)
        do {
            _ = try await Cloud189Login(client: .shared).sendSMS(phone: "13800138000")
            XCTFail("应提示先用账号密码登录")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("账号密码"))
        }
        do {
            _ = try await Cloud189Login(client: .shared).loginSMS(SMSChallenge(phone: "1", state: [:]), code: "123456")
            XCTFail("缺少现场应报错")
        } catch {
            XCTAssertEqual(error.localizedDescription, "验证码已失效，请重新获取")
        }
    }
}
