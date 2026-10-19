import XCTest
@testable import CloudnKit

/// 各网盘的签名 / 加密参数与响应解析。签名期望值由 Python 独立实现计算
final class DrivePlatformTests: XCTestCase {
    func testAllPlatformsRegistered() {
        let resolvers = ShareResolvers(credentials: NoCredentials())
        for p in SharePlatform.allCases {
            XCTAssertTrue(p.isResolvable)
            XCTAssertEqual(resolvers.resolver(for: p)?.platform, p, "\(p) 未注册解析器")
        }
    }

    // MARK: 蓝奏云优享版

    func testILanzouAES() {
        XCTAssertEqual(ILanzouResolver.aesHex("123|1700000000000"),
                       "790f9f7cf7e017afcea5b8de25cfab8f530f69b25004eff231c49c71538015b9")
        XCTAssertEqual(ILanzouResolver.query([("appToken", "a:b c")]), "appToken=a:b%20c")
    }

    func testILanzouParseItem() {
        let folder = ILanzouResolver.parseItem(JSON(text: #"{"fileType":2,"folderId":42,"folderName":"资料"}"#)!, parent: "")
        XCTAssertEqual(folder?.fid, "d:42")
        XCTAssertEqual(folder?.isDirectory, true)
        let file = ILanzouResolver.parseItem(JSON(text: #"{"fileType":1,"fileId":"7","fileName":"a.zip","fileSize":3}"#)!, parent: "d:42")
        XCTAssertEqual(file?.fid, "f:7")
        XCTAssertEqual(file?.size, 3072)
        XCTAssertNil(ILanzouResolver.parseItem(JSON(text: #"{"fileType":1,"fileId":0}"#)!, parent: ""))
    }

    // MARK: 123

    func testPan123Sign() {
        let s = Pan123Resolver.sign(path: "/b/api/share/download/info", ts: 1_700_000_000, random: 1_234_567)
        XCTAssertEqual(s.key, "f2ac3dd")
        XCTAssertEqual(s.value, "1700000000-1234567-ecfbd1b2")
    }

    func testPan123DecodeURL() {
        let real = "https://cdn.example.com/file?x=1"
        let b64 = Data(real.utf8).base64EncodedString()
        XCTAssertEqual(Pan123Resolver.decodeDownloadURL(b64), real)
        let urlSafe = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(Pan123Resolver.decodeDownloadURL("https://download.123pan.cn/download-v2/?params=\(urlSafe)&is_s3=0"), real)
        XCTAssertNil(Pan123Resolver.decodeDownloadURL("https://a.com/no-params"))
    }

    func testPan123Token() {
        XCTAssertEqual(Pan123Resolver.normalizeToken(" \"Bearer eyJabc.def\" "), "eyJabc.def")
        XCTAssertEqual(Pan123Resolver.normalizeToken("eyJabc.def"), "eyJabc.def")
    }

    // MARK: 139

    func testC139Sign() {
        let body = #"{"getOutLinkInfoReq":{"account":"","linkID":"1A2b","passwd":"x y"}}"#
        XCTAssertEqual(C139Resolver.sign(body, ts: "2026-10-19 12:00:00", rand: "abcdefghijklmnop"), "BC51EF3E8688D759E647FD1FA63988B1")
        let header = C139Resolver.signHeader(body, rand: "abcdefghijklmnop")
        XCTAssertTrue(header.hasSuffix(",abcdefghijklmnop," + C139Resolver.sign(body, ts: String(header.prefix(19)), rand: "abcdefghijklmnop")))
    }

    func testC139Envelope() {
        let iv = Array(UInt8(100)..<UInt8(116))
        let enc = C139Resolver.encrypt(#"{"a":"中文"}"#, iv: iv)
        XCTAssertEqual(enc, "ZGVmZ2hpamtsbW5vcHFyc5eZ9ox4NeH/VU7Pdx68yo0=")
        XCTAssertEqual(C139Resolver.decrypt(enc), #"{"a":"中文"}"#)
        XCTAssertNil(C139Resolver.decrypt(#"{"plain":"json"}"#))
    }

    func testC139ParseListAndCookie() {
        let data = JSON(text: #"{"caLst":[{"caID":"c1","caName":"文件夹"}],"coLst":[{"coID":"o1","coName":"a.mp4","coSize":9,"coType":1},{"coID":"o2","coName":"子","coType":2}]}"#)!
        let files = C139Resolver.parseList(data, parent: "root")
        XCTAssertEqual(files.map(\.fid), ["c1", "o1", "o2"])
        XCTAssertEqual(files.map(\.isDirectory), [true, false, true])

        let auth = "Basic " + Data("pc:13800000000:tok".utf8).base64EncodedString()
        let cookie = "authorization=\(auth); ORCHES-I-ACCOUNT-SIMPLIFY=138****0000"
        XCTAssertTrue(C139Resolver.isValidCookie(cookie))
        XCTAssertEqual(C139Resolver.account(in: cookie), "13800000000")
        XCTAssertEqual(C139Resolver.displayAccount(in: cookie), "138****0000")
        XCTAssertTrue(C139Resolver.isValidCookie("Os_SSo_Sid=a; RMKEY=b"))
        XCTAssertFalse(C139Resolver.isValidCookie("RMKEY=b"))
    }

    // MARK: 百度

    func testBaiduPickURL() {
        let urls = JSON(text: #"[{"url":"https://d2-ant.baidu.com/x","encrypt":1},{"url":"http://appall01.baidupcs.com/y","encrypt":0},{"url":"https://appall02.baidupcs.com/z","encrypt":0}]"#)!.array
        XCTAssertEqual(BaiduResolver.pickURL(urls), "https://appall02.baidupcs.com/z")
        XCTAssertEqual(BaiduResolver.pickURL(Array(urls.prefix(1))), "https://d2-ant.baidu.com/x")
        XCTAssertNil(BaiduResolver.pickURL([]))
        XCTAssertEqual(BaiduResolver.withBDCLND("BDUSS=a", "rk"), "BDUSS=a; BDCLND=rk")
        XCTAssertEqual(BaiduResolver.withBDCLND("", "rk"), "BDCLND=rk")
        XCTAssertEqual(BaiduResolver.withBDCLND("BDUSS=a", ""), "BDUSS=a")
    }

    // MARK: 光鸭

    func testGuangYaParse() {
        let dir = GuangYaResolver.parseFile(JSON(text: #"{"fileId":"1","fileName":"电影","resType":"2"}"#)!)
        XCTAssertTrue(dir.isDirectory)
        let file = GuangYaResolver.parseFile(JSON(text: #"{"id":"2","name":"a.mkv","fileSize":"1024"}"#)!)
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, 1024)
        XCTAssertThrowsError(try GuangYaResolver.check(JSON(text: #"{"code":"209","msg":"x"}"#)!, fallback: "f")) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "光鸭分享提取码错误或缺失")
        }
        XCTAssertNoThrow(try GuangYaResolver.check(JSON(text: #"{"code":"0","data":{}}"#)!, fallback: "f"))
    }

    // MARK: 迅雷

    func testXunleiCaptchaSign() {
        XCTAssertEqual(XunleiResolver.captchaSign(deviceId: "0123456789abcdef0123456789abcdef", timestamp: "1700000000000"),
                       "1.cc950d448d3aeabc80ad961e2062725e")
    }

    func testXunleiCredential() {
        let access = "eyJhbGciOiJSUzI1NiJ9." + Data(#"{"sub":"42","exp":1700000000}"#.utf8).base64EncodedString() + ".sig"
        let raw = #"{"access_token":"\#(access)","refresh_token":"refresh-token-123456","device_id":"dev1"}"#
        let cred = XunleiCredential.parse(raw)
        XCTAssertEqual(cred?.accessToken, access)
        XCTAssertEqual(cred?.refreshToken, "refresh-token-123456")
        XCTAssertEqual(cred?.deviceId, "dev1")
        XCTAssertEqual(XunleiCredential.parse(cred!.serialized), cred)
        XCTAssertEqual(XunleiCredential.jwtClaim(access, "sub").string, "42")
        XCTAssertEqual(XunleiCredential.jwtClaim(access, "exp").int64, 1_700_000_000)
        // 嵌套包装、裸 token、登录中间态
        XCTAssertEqual(XunleiCredential.parse(#"{"data":{"accessToken":"\#(access)"}}"#)?.accessToken, access)
        XCTAssertEqual(XunleiCredential.parse("Bearer \(access)")?.accessToken, access)
        XCTAssertNil(XunleiCredential.parse(#"{"access_token":"null"}"#))
        XCTAssertNil(XunleiCredential.parse(""))
    }

    // MARK: 115

    func testPan115Encode() {
        let expected = "T4+b33vozRftqeWTTeaZBOcAe/GcFsteAuxUSLXswbsC69EiLT+ZRFdORxoq4qntM5jt/EduqBHZLBqG5Sk/GPR5rPll6XZpBBlt8/V9e8PCqhqU9KHxwrYPcA6l0OHcVWhg8r9ZyU11C0+MUcnxVnyu1GEvNjmEfjjyzO8fbWA="
        XCTAssertEqual(Pan115Crypto.encode(#"{"pickcode":"abc"}"#, key: Array(0..<16)), expected)
    }

    func testPan115Helpers() {
        XCTAssertTrue(Pan115Resolver.matches("a.mp4", "a.mp4"))
        XCTAssertTrue(Pan115Resolver.matches("a(1).mp4", "a.mp4"))
        XCTAssertFalse(Pan115Resolver.matches("ab.mp4", "a.mp4"))
        XCTAssertTrue(Pan115Resolver.matches("readme(2)", "readme"))
        let token = Pan115Resolver.decodeToken("ab12|10086")
        XCTAssertEqual(token.code, "ab12")
        XCTAssertEqual(token.uid, "10086")
        XCTAssertEqual(Pan115Resolver.decodeToken("ab12").uid, "")

        let setCookie = "acw_tc=1; Path=/; HttpOnly, 0123abcd=ffee; expires=Thu, 01 Jan 2026 00:00:00 GMT; path=/abc/def/; domain=115cdn.net"
        XCTAssertEqual(Pan115Resolver.cdnCookie(setCookie), "0123abcd=ffee")
        XCTAssertEqual(Pan115Resolver.cdnCookie("only=1; Path=/"), "only=1")
        XCTAssertNil(Pan115Resolver.cdnCookie(nil))

        let files = Pan115Resolver.parseShareFiles(JSON(text: #"[{"cid":"9","n":"目录","fc":0},{"fid":"5","cid":"9","n":"a.txt","s":12,"fc":1}]"#)!.array)
        XCTAssertEqual(files.map(\.fid), ["9", "5"])
        XCTAssertEqual(files.map(\.isDirectory), [true, false])
        XCTAssertThrowsError(try Pan115Resolver.check(JSON(text: #"{"state":false,"errno":4100008}"#)!, fallback: "x")) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "访问码错误，请检查后重试")
        }
    }

    func testAccountNormalize() {
        XCTAssertEqual(AccountValidator.normalize(.pan123, "\"Bearer abcdefghijklmnopq\""), "abcdefghijklmnopq")
        XCTAssertEqual(AccountValidator.normalize(.baidu, "  BDUSS=x \n"), "BDUSS=x")
        let access = "abcdefghijklmnopqrstuvwxyz"
        XCTAssertEqual(XunleiCredential.parse(AccountValidator.normalize(.xunlei, access))?.accessToken, access)
    }
}

/// 转存请求体的构造（字段名 / 顺序与官方一致）
final class SaveToDriveTests: XCTestCase {
    func testSaversRegistered() {
        let resolvers = ShareResolvers(credentials: NoCredentials())
        for p in [SharePlatform.quark, .uc, .baidu, .xunlei, .pan115, .pan123, .c139, .ilanzou, .guangya] {
            XCTAssertNotNil(resolvers.saver(for: p), "\(p) 应支持转存")
        }
        XCTAssertNil(resolvers.saver(for: .lanzou))
        XCTAssertEqual(resolvers.saver(for: .baidu)?.rootFolderId, "/")
        XCTAssertEqual(resolvers.saver(for: .c139)?.rootFolderId, "/")
        XCTAssertEqual(resolvers.saver(for: .xunlei)?.rootFolderId, "")
    }

    func testBaiduFsidList() {
        XCTAssertEqual(BaiduResolver.fsidList(["1", "22"]), #"["1","22"]"#)
    }

    func testPan123SaveEntry() {
        let item = JSON(text: #"{"FileId":123,"FileName":"a.mp4","Size":9,"Type":0,"ParentFileId":5,"S3KeyFlag":"1816216065-0","Etag":"e1","StorageNode":"m3"}"#)!
        let file = Pan123Resolver.parseItem(item)
        XCTAssertEqual(file.token, "1816216065-0|e1|m3")
        XCTAssertEqual(Pan123Resolver.mshareId(fromToken: file.token), "1816216065")
        XCTAssertNil(Pan123Resolver.mshareId(fromToken: "||"))
        let entry = Pan123Resolver.copySaveEntry(file, parent: 7)
        XCTAssertEqual(entry["fileID"] as? Int64, 123)
        XCTAssertEqual(entry["parentFileId"] as? Int64, 7)
        XCTAssertEqual(entry["etag"] as? String, "e1")
        XCTAssertEqual(entry["S3KeyFlag"] as? String, "1816216065-0")
        XCTAssertEqual(entry["StorageNode"] as? String, "m3")
        XCTAssertEqual(entry["type"] as? Int, 0)
    }

    func testC139TransferBody() {
        let files = [ShareFile(fid: "co1", name: "a", size: 1, isDirectory: false), ShareFile(fid: "ca1", name: "d", size: 0, isDirectory: true)]
        let body = C139Resolver.transferTaskBody(account: "13800000000", linkID: "L1", files: files, target: "/").text
        XCTAssertEqual(body, #"{"createOuterLinkBatchOprTaskReq":{"msisdn":"13800000000","ownerAccount":"","taskType":1,"#
            + #""taskInfo":{"contentInfoList":["/co1"],"catalogInfoList":["ca1"],"newCatalogID":"/","linkID":"L1","#
            + #""newCatalogName":"手机图片","needPassword":true},"linkID":"L1","needPassword":true},"#
            + #""commonAccountInfo":{"account":"13800000000","accountType":1}}"#)
        XCTAssertEqual(C139Resolver.folderListBody(parentId: "/", cursor: .null).text,
                       #"{"pageInfo":{"pageSize":100,"pageCursor":null},"orderBy":"updated_at","orderDirection":"DESC","#
                       + #""parentFileId":"/","imageThumbnailStyleList":["Small","Large"],"type":"folder"}"#)
        let headers = Dictionary(C139Resolver.personalHeaders(authorization: "Basic x"), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(headers["Authorization"], "Basic x")
        XCTAssertEqual(headers["mcloud-version"], "7.17.9")
        XCTAssertNotNil(headers["x-yun-client-info"])
    }
}
