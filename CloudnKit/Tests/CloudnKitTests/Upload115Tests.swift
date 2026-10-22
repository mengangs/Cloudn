import XCTest
@testable import CloudnKit

/// 115 上传：ec115 加解密、LZ4 块解码、k_ec、sig / token、Go 表单编码、分片规则、响应解析。
///
/// 期望值用 Python 独立算出（cryptography 包做 AES）：
/// ```python
/// import hashlib, zlib, base64, struct, urllib.parse
/// from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
/// pub = bytes.fromhex("1d02c9950992c11a0058df0d5018cdf49844bf58360c12616fd79b9a9414")
/// key = bytes.fromhex("78a21bbcdbd7000342907f577db5ae4b")
/// iv  = bytes.fromhex("7db5ae4bf60401aeba29711ceb392697")
/// sha1 = lambda s: hashlib.sha1(s.encode()).hexdigest()
/// md5 = lambda s: hashlib.md5(s.encode()).hexdigest()
/// uid, ukey, fid, target = "123456789", "ABCDEF0123456789", "AAF4C61DDCC5E8A2DABEDE0F3B482CD9AEA9434D", "U_1_0"
/// print(sha1(ukey + sha1(uid + fid + target + "0") + "000000").upper())          # SIG
/// salt, t, ver = "Qclm8MGWUv59TnrR0XPg", "1760932800000", "36.0.1"
/// print(md5(salt + fid + "5" + "" + "" + uid + t + md5(uid) + ver))              # TOKEN（首轮）
/// print(md5(salt + fid + "5" + "abc" + "DEF" + uid + t + md5(uid) + ver))        # TOKEN（区间校验轮）
/// def kec(ts, r1, r2):
///     tb = struct.pack(">I", ts & 0xffffffff)
///     tmp = bytes(b ^ r1 for b in pub[:15]) + bytes([r1, 0x73 ^ r1]) + bytes([r1]*3) + bytes(r1 ^ tb[3-i] for i in range(4))
///     tmp += bytes(b ^ r2 for b in pub[15:]) + bytes([r2, 0x01 ^ r2]) + bytes([r2]*3)
///     crc = zlib.crc32(b"^j>WD3Kr?J2gLFjD4W2y@" + tmp)
///     return base64.b64encode(tmp + struct.pack("<I", crc)).decode()
/// print(kec(1760932800123, 0x5A, 0xC3))                                           # K_EC
/// print(urllib.parse.urlencode(sorted([("b", "2 3"), ("a", "x/y+z"), ("c", "中~*'")]), quote_via=urllib.parse.quote_plus))
/// def enc(p):
///     pad = 16 - len(p) % 16; p += bytes([pad]) * pad
///     e = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor(); return e.update(p) + e.finalize()
/// print(enc(b"hello").hex())                                                      # 加密
/// msg = b'{"state":true}'; blk = bytes([len(msg) << 4]) + msg
/// print(enc(struct.pack("<H", len(blk)) + blk).hex())                             # 响应密文
/// ```
final class Upload115Tests: XCTestCase {
    // MARK: LZ4

    func testLZ4LiteralsOnly() {
        let block: [UInt8] = [0x50] + Array("hello".utf8)
        XCTAssertEqual(LZ4Block.decompress(block), Array("hello".utf8))
        // 字面量长度续读：15 + 5 = 20
        let twenty: [UInt8] = (0..<20).map { UInt8(65 + $0) }
        XCTAssertEqual(LZ4Block.decompress([0xF0, 0x05] + twenty), twenty)
        // 恰好 15：续读字节为 0
        let fifteen: [UInt8] = (0..<15).map { UInt8(97 + $0) }
        XCTAssertEqual(LZ4Block.decompress([0xF0, 0x00] + fifteen), fifteen)
        XCTAssertEqual(LZ4Block.decompress([]), [UInt8]())
    }

    func testLZ4MatchCopy() {
        // "abc" + 向前 3 字节复制 9 个（重叠）+ 末尾字面量 "XYZ"
        let block: [UInt8] = [0x35, 0x61, 0x62, 0x63, 0x03, 0x00, 0x30, 0x58, 0x59, 0x5A]
        XCTAssertEqual(String(decoding: LZ4Block.decompress(block) ?? [], as: UTF8.self), "abcabcabcabcXYZ")
        // 匹配长度续读：15 + 10 + 4 = 29，offset 1 → 共 30 个 a，再接 "b"
        let long: [UInt8] = [0x1F, 0x61, 0x01, 0x00, 0x0A, 0x10, 0x62]
        XCTAssertEqual(String(decoding: LZ4Block.decompress(long) ?? [], as: UTF8.self), String(repeating: "a", count: 30) + "b")
        // 非重叠复制：offset 4，长度 4
        let plain: [UInt8] = [0x40, 0x31, 0x32, 0x33, 0x34, 0x04, 0x00, 0x10, 0x35]
        XCTAssertEqual(String(decoding: LZ4Block.decompress(plain) ?? [], as: UTF8.self), "123412345")
    }

    func testLZ4RejectsMalformed() {
        XCTAssertNil(LZ4Block.decompress([0x35, 0x61, 0x62, 0x63, 0x00, 0x00]))        // offset 0
        XCTAssertNil(LZ4Block.decompress([0x35, 0x61, 0x62, 0x63, 0x09, 0x00]))        // offset 越过已输出
        XCTAssertNil(LZ4Block.decompress([0x50, 0x61, 0x62]))                          // 字面量不够
        XCTAssertNil(LZ4Block.decompress([0x35, 0x61, 0x62, 0x63, 0x03]))              // offset 只有 1 字节
        XCTAssertNil(LZ4Block.decompress([0xF0]))                                      // 续读字节缺失
        XCTAssertNil(LZ4Block.decompress([0x1F, 0x61, 0x01, 0x00, 0xFF, 0xFF, 0x10, 0x62], maxOutput: 100)) // 超过上限
    }

    // MARK: ec115

    func testConstants() {
        XCTAssertEqual(EC115.pubKey.count, 30)
        XCTAssertEqual(EC115.pubKey[0], 0x1D)
        XCTAssertTrue(EC115.pubKey[1] == 0x02 || EC115.pubKey[1] == 0x03)
        XCTAssertEqual(EC115.aesKey.count, 16)
        XCTAssertEqual(EC115.aesIV.count, 16)
        // key 与 IV 取自同一个 28 字节共享密钥：S[12..<16] 重叠
        XCTAssertEqual(Array(EC115.aesKey[12..<16]), Array(EC115.aesIV[0..<4]))
    }

    func testEncryptKnownAnswer() {
        XCTAssertEqual(Crypto.hex(EC115.encrypt(Array("hello".utf8))), "c65b9a39ee4e4430d160daffe09be266")
    }

    func testDecryptKnownAnswer() {
        let cipher = Crypto.bytes(hex: "4e93a5d539a6b678f74987742137e5acf87d7718fa8f7ef2174883360baf11ae")!
        XCTAssertEqual(EC115.decrypt(cipher).map { String(decoding: $0, as: UTF8.self) }, "{\"state\":true}")
        // 多出来的尾巴（不足一个分组）会被截掉
        XCTAssertEqual(EC115.decrypt(cipher + [1, 2, 3]).map { String(decoding: $0, as: UTF8.self) }, "{\"state\":true}")
        XCTAssertNil(EC115.decrypt([1, 2, 3]))
    }

    func testEncryptDecryptRoundTrip() {
        let payload = Array("{\"status\":2,\"statuscode\":0,\"pickcode\":\"abc123\",\"statusmsg\":\"\"}".utf8)
        let block = Self.literalBlock(payload)
        var framed: [UInt8] = [UInt8(block.count & 0xff), UInt8(block.count >> 8)]
        framed.append(contentsOf: block)
        let cipher = EC115.encrypt(framed)
        XCTAssertEqual(cipher.count % 16, 0)
        XCTAssertEqual(EC115.decrypt(cipher), payload)
        // 解出的 JSON 能直接交给 initupload 解析
        let ticket = try? Pan115Resolver.parseInitUpload(JSON(data: Data(payload))!)
        XCTAssertEqual(ticket?.status, 2)
        XCTAssertEqual(ticket?.pickCode, "abc123")
    }

    /// 只含字面量的 LZ4 块（长度 ≥ 15 时续读字节）
    static func literalBlock(_ data: [UInt8]) -> [UInt8] {
        guard data.count >= 15 else { return [UInt8(data.count << 4)] + data }
        var out: [UInt8] = [0xF0]
        var rest = data.count - 15
        while rest >= 255 {
            out.append(255)
            rest -= 255
        }
        out.append(UInt8(rest))
        out.append(contentsOf: data)
        return out
    }

    func testKECLayout() {
        let t: Int64 = 1_760_932_800_123
        let r1: UInt8 = 0x5A
        let r2: UInt8 = 0xC3
        let bytes = EC115.tokenBytes(timestamp: t, r1: r1, r2: r2)
        XCTAssertEqual(bytes.count, 48)
        XCTAssertEqual(bytes[0..<15].map { $0 ^ r1 }, Array(EC115.pubKey[0..<15]))
        XCTAssertEqual(Array(bytes[15..<20]), [r1, 0x73 ^ r1, r1, r1, r1])
        // 时间戳截成 UInt32，按小端异或 r1
        let ts = UInt32(truncatingIfNeeded: t)
        let timeBytes: [UInt8] = bytes[20..<24].map { $0 ^ r1 }
        XCTAssertEqual(timeBytes, [UInt8(ts & 0xff), UInt8((ts >> 8) & 0xff), UInt8((ts >> 16) & 0xff), UInt8(ts >> 24)])
        XCTAssertEqual(bytes[24..<39].map { $0 ^ r2 }, Array(EC115.pubKey[15..<30]))
        XCTAssertEqual(Array(bytes[39..<44]), [r2, 0x01 ^ r2, r2, r2, r2])
        // 末 4 字节为「盐 + 前 44 字节」的 CRC32 小端
        var salted: [UInt8] = Array(EC115.crcSalt.utf8)
        salted.append(contentsOf: bytes[0..<44])
        let crc = Crypto.crc32(salted)
        let tail: [UInt8] = Array(bytes[44..<48])
        XCTAssertEqual(tail, [UInt8(crc & 0xff), UInt8((crc >> 8) & 0xff), UInt8((crc >> 16) & 0xff), UInt8(crc >> 24)])
        XCTAssertEqual(Data(bytes).base64EncodedString(), "R1iTz1PIm0BaAoVXCkKXWilaWlohfJylN1uHfJv1z9GirBRYWVfXw8LDw8O4pZKm")
        // 随机版本：长度固定 64 个 Base64 字符
        XCTAssertEqual(EC115.encodeToken(timestamp: t).count, 64)
    }

    // MARK: sig / token / 表单

    private let account = Pan115Resolver.UploadAccount(userId: "123456789", userKey: "ABCDEF0123456789", sizeLimit: 0)
    private let fileId = "AAF4C61DDCC5E8A2DABEDE0F3B482CD9AEA9434D"

    func testSigAndToken() {
        XCTAssertEqual(Pan115Resolver.uploadSig(userId: "123456789", userKey: "ABCDEF0123456789", fileId: fileId, target: "U_1_0"),
                       "52107390104027E257CC23E221F4888002780A02")
        XCTAssertEqual(Pan115Resolver.uploadToken(userId: "123456789", fileId: fileId, size: 5, signKey: "", signVal: "",
                                                  timestamp: "1760932800000", version: "36.0.1"),
                       "6c5ece06f852de65964ee1ea79c8cbae")
        XCTAssertEqual(Pan115Resolver.uploadToken(userId: "123456789", fileId: fileId, size: 5, signKey: "abc", signVal: "DEF",
                                                  timestamp: "1760932800000", version: "36.0.1"),
                       "502baef0c3b9df7e5989d6af1862b8cf")
    }

    func testGoFormEncode() {
        XCTAssertEqual(Pan115Resolver.goFormEncode([("b", "2 3"), ("a", "x/y+z"), ("c", "中~*'")]),
                       "a=x%2Fy%2Bz&b=2+3&c=%E4%B8%AD~%2A%27")
        // 同键保持传入顺序
        XCTAssertEqual(Pan115Resolver.goFormEncode([("k", "2"), ("a", "0"), ("k", "1")]), "a=0&k=2&k=1")
        XCTAssertEqual(Pan115Resolver.goQueryEscape("a+b/c="), "a%2Bb%2Fc%3D")
        XCTAssertEqual(Pan115Resolver.goQueryEscape("AZaz09-_.~"), "AZaz09-_.~")
    }

    func testInitUploadForm() {
        let first = Pan115Resolver.initUploadForm(account: account, name: "a b.txt", size: 5, fileId: fileId, target: "U_1_0",
                                                  version: "36.0.1", timestamp: "1760932800000", signKey: "", signVal: "")
        let dict = Dictionary(first, uniquingKeysWith: { $1 })
        XCTAssertEqual(dict["sig"], "52107390104027E257CC23E221F4888002780A02")
        XCTAssertEqual(dict["token"], "6c5ece06f852de65964ee1ea79c8cbae")
        XCTAssertEqual(dict["topupload"], "true")
        XCTAssertNil(dict["sign_key"])
        let encoded = Pan115Resolver.goFormEncode(first)
        XCTAssertTrue(encoded.hasPrefix("appid=0&appversion=36.0.1&fileid=\(fileId)&filename=a+b.txt&filesize=5&sig="))
        XCTAssertTrue(encoded.hasSuffix("&userid=123456789"))

        let second = Pan115Resolver.initUploadForm(account: account, name: "a b.txt", size: 5, fileId: fileId, target: "U_1_0",
                                                   version: "36.0.1", timestamp: "1760932800000", signKey: "abc", signVal: "DEF")
        let dict2 = Dictionary(second, uniquingKeysWith: { $1 })
        XCTAssertEqual(dict2["sign_key"], "abc")
        XCTAssertEqual(dict2["sign_val"], "DEF")
        XCTAssertEqual(dict2["token"], "502baef0c3b9df7e5989d6af1862b8cf")
    }

    // MARK: 分片

    func testPartSplit() {
        let kb: Int64 = 1 << 10
        let mb: Int64 = 1 << 20
        let gb: Int64 = 1 << 30
        // 50MB：均分 1000 片不足 100KB → 固定 100KB，正好 512 片
        let small = Pan115Resolver.uploadParts(size: 50 * mb)
        XCTAssertEqual(small.count, 512)
        XCTAssertTrue(small.allSatisfy { $0.length == 100 * kb })
        // 150KB：100KB + 50KB
        let tiny = Pan115Resolver.uploadParts(size: 150 * kb)
        XCTAssertEqual(tiny.map { $0.length }, [100 * kb, 50 * kb])
        // 500MB + 1：1000 片，最后一片吸收余数
        let mid = Pan115Resolver.uploadParts(size: 500 * mb + 1)
        XCTAssertEqual(mid.count, 1000)
        XCTAssertEqual(mid[0].length, 524_288)
        XCTAssertEqual(mid[999].length, 524_289)
        XCTAssertEqual(mid[999].offset, 999 * 524_288)
        // 1GB 整：已不小于 1GB → 2000 片；2.5GB → 3000 片；9GB 及以上 → 10000 片
        XCTAssertEqual(Pan115Resolver.uploadParts(size: gb).count, 2000)
        XCTAssertEqual(Pan115Resolver.uploadParts(size: 5 * gb / 2).count, 3000)
        XCTAssertEqual(Pan115Resolver.uploadParts(size: 9 * gb).count, 10_000)
        XCTAssertEqual(Pan115Resolver.uploadParts(size: 20 * gb).count, 10_000)
        XCTAssertTrue(Pan115Resolver.uploadParts(size: 0).isEmpty)
        // 连续、无重叠、总和等于文件大小
        var sizes: [Int64] = [150 * kb, 500 * mb + 1, 20 * gb + 11]
        sizes.append(50 * mb + 7)
        sizes.append(5 * gb / 2 + 3)
        for size in sizes {
            let parts = Pan115Resolver.uploadParts(size: size)
            var next: Int64 = 0
            for p in parts {
                XCTAssertEqual(p.offset, next)
                next += p.length
            }
            XCTAssertEqual(next, size)
        }
    }

    // MARK: 响应解析

    func testParseResponses() throws {
        let info = JSON(text: "{\"state\":true,\"user_id\":123456789,\"userkey\":\"ABCDEF0123456789\",\"size_limit\":123480309760,\"upload_allowed\":true}")!
        XCTAssertEqual(try Pan115Resolver.parseUploadInfo(info),
                       Pan115Resolver.UploadAccount(userId: "123456789", userKey: "ABCDEF0123456789", sizeLimit: 123_480_309_760))
        let denied = JSON(text: "{\"state\":true,\"user_id\":1,\"userkey\":\"K\",\"upload_allowed\":false,\"upload_allowed_msg\":\"禁止上传\"}")!
        XCTAssertThrowsError(try Pan115Resolver.parseUploadInfo(denied))

        let need = JSON(text: "{\"status\":1,\"statuscode\":0,\"bucket\":\"fhnfile\",\"object\":\"abc/def\"," +
                        "\"callback\":{\"callback\":\"{\\\"callbackUrl\\\":\\\"u\\\"}\",\"callback_var\":\"{\\\"x:a\\\":\\\"1\\\"}\"}}")!
        let ticket = try Pan115Resolver.parseInitUpload(need)
        XCTAssertEqual(ticket.status, 1)
        XCTAssertEqual(ticket.bucket, "fhnfile")
        XCTAssertEqual(ticket.object, "abc/def")
        XCTAssertEqual(ticket.callback, "{\"callbackUrl\":\"u\"}")
        let cb = Dictionary(Pan115Resolver.ossCallbackHeaders(ticket), uniquingKeysWith: { $1 })
        XCTAssertEqual(cb["x-oss-callback"], Data("{\"callbackUrl\":\"u\"}".utf8).base64EncodedString())
        XCTAssertEqual(cb["x-oss-callback-var"], Data("{\"x:a\":\"1\"}".utf8).base64EncodedString())

        let proof = try Pan115Resolver.parseInitUpload(JSON(text: "{\"status\":7,\"statuscode\":701,\"sign_key\":\"SK\",\"sign_check\":\"0-131071\"}")!)
        XCTAssertEqual(proof.status, 7)
        XCTAssertEqual(proof.signKey, "SK")
        XCTAssertEqual(Pan115Resolver.parseSignCheck(proof.signCheck)?.start, 0)
        XCTAssertEqual(Pan115Resolver.parseSignCheck(proof.signCheck)?.end, 131_071)
        XCTAssertNil(Pan115Resolver.parseSignCheck("10-5"))
        XCTAssertNil(Pan115Resolver.parseSignCheck("abc"))

        XCTAssertThrowsError(try Pan115Resolver.parseInitUpload(JSON(text: "{\"status\":0,\"statuscode\":402,\"statusmsg\":\"sig invalid\"}")!)) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "sig invalid")
        }

        let token = try Pan115Resolver.parseOSSToken(JSON(text: "{\"AccessKeyID\":\"AK\",\"AccessKeySecret\":\"SEC\",\"SecurityToken\":\"TOK\",\"StatusCode\":\"200\"}")!)
        XCTAssertEqual(token.accessKeyId, "AK")
        XCTAssertEqual(token.securityToken, "TOK")
        XCTAssertThrowsError(try Pan115Resolver.parseOSSToken(JSON(text: "{\"StatusCode\":\"403\"}")!))
        // 现行返回用 AccessKeyId（小写 d）
        let current = try Pan115Resolver.parseOSSToken(JSON(text: "{\"StatusCode\":\"200\",\"AccessKeySecret\":\"S\",\"SecurityToken\":\"T\",\"Expiration\":\"2026-10-23T00:25:11Z\",\"AccessKeyId\":\"STS.ID\"}")!)
        XCTAssertEqual(current.accessKeyId, "STS.ID")

        XCTAssertNoThrow(try Pan115Resolver.checkOSSCallback(status: 200, body: Data("{\"state\":true,\"code\":0,\"data\":{}}".utf8), fallback: "x"))
        XCTAssertThrowsError(try Pan115Resolver.checkOSSCallback(status: 200, body: Data("{\"state\":false,\"message\":\"坏了\"}".utf8), fallback: "x"))
        XCTAssertThrowsError(try Pan115Resolver.checkOSSCallback(status: 203, body: Data("<Error><Message>Callback failed</Message></Error>".utf8),
                                                                 fallback: "x")) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "x：Callback failed")
        }
    }

    func testOSSRequestSignsCallbackHeaders() {
        let when = ISO8601DateFormatter().date(from: "2026-10-20T04:00:00Z")!
        let signer = OSSSigner(accessKeyId: "AK", accessKeySecret: "SECRET", securityToken: "TOK")
        let extra: [(String, String)] = [("x-oss-callback", "Y2I="), ("x-oss-callback-var", "dmFy")]
        let req = Pan115Resolver.ossRequest(signer, method: "POST", bucket: "fhnfile", object: "a/b c",
                                            query: [("uploadId", "UP+1")], contentType: "application/xml", extra: extra, date: when)
        XCTAssertEqual(req.url, "https://fhnfile.oss-cn-shenzhen.aliyuncs.com/a/b%20c?uploadId=UP%2B1")
        let h = Dictionary(req.headers, uniquingKeysWith: { $1 })
        XCTAssertEqual(h["x-oss-callback"], "Y2I=")
        XCTAssertEqual(h["User-Agent"], "aliyun-sdk-android/2.9.1")
        // 与直接调用签名器一致：回调头参与了签名
        let direct = Dictionary(signer.headers(method: "POST", bucket: "fhnfile", key: "a/b c", query: [("uploadId", "UP+1")],
                                               contentType: "application/xml", extra: extra, date: when), uniquingKeysWith: { $1 })
        XCTAssertEqual(h["Authorization"], direct["Authorization"])
        let unsigned = Dictionary(signer.headers(method: "POST", bucket: "fhnfile", key: "a/b c", query: [("uploadId", "UP+1")],
                                                 contentType: "application/xml", date: when), uniquingKeysWith: { $1 })
        XCTAssertNotEqual(h["Authorization"], unsigned["Authorization"])

        let initiate = Pan115Resolver.ossRequest(signer, method: "POST", bucket: "fhnfile", object: "o",
                                                 query: [("sequential", ""), ("uploads", ""), ("x-oss-enable-sha1", "")],
                                                 contentType: "application/octet-stream", date: when)
        XCTAssertEqual(initiate.url, "https://fhnfile.oss-cn-shenzhen.aliyuncs.com/o?sequential&uploads&x-oss-enable-sha1")
    }

    func testRangeSHA1() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-115-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("0123456789".utf8).write(to: url)
        // sha1("234") 大写
        XCTAssertEqual(try Pan115Resolver.rangeSHA1(url, start: 2, end: 4), Crypto.sha1Hex("234").uppercased())
    }
}
