import XCTest
@testable import CloudnKit

/// 上传的公共部分：分段摘要、HMAC、OSS / S3 签名、multipart 表单、各平台请求体
final class UploadSupportTests: XCTestCase {
    private let when = ISO8601DateFormatter().date(from: "2026-10-20T04:00:00Z")!

    func testStreamingHashesMatchKnownVectors() {
        XCTAssertEqual(MD5Hasher.hex(Data()), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(SHA1Hasher.hex(Data("abc".utf8)), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA256Hasher.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // 分段喂入与一次算完一致（跨 64 字节分组边界）
        let data = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        var md5 = MD5Hasher(), sha1 = SHA1Hasher(), sha256 = SHA256Hasher()
        for start in stride(from: 0, to: data.count, by: 37) {
            let piece = data.subdata(in: start..<min(data.count, start + 37))
            md5.update(piece); sha1.update(piece); sha256.update(piece)
        }
        XCTAssertEqual(md5.finalize(), Crypto.md5([UInt8](data)))
        XCTAssertEqual(sha1.finalize(), Crypto.sha1([UInt8](data)))
        XCTAssertEqual(sha256.finalize(), SHA256Hasher.digest(data))
    }

    func testHMAC() {
        let msg = "The quick brown fox jumps over the lazy dog"
        XCTAssertEqual(Crypto.hex(Crypto.hmacSHA1(key: "key", message: msg)), "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9")
        XCTAssertEqual(Crypto.hex(Crypto.hmacSHA256(key: Array("key".utf8), message: msg)),
                       "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    }

    func testOSSSignature() {
        let signer = OSSSigner(accessKeyId: "AK", accessKeySecret: "SECRET", securityToken: "TOK")
        let headers = signer.headers(method: "PUT", bucket: "bkt", key: "dir/a b.bin", query: [("uploadId", "UP"), ("partNumber", "2")],
                                     contentType: "application/octet-stream", date: when)
        let dict = Dictionary(headers, uniquingKeysWith: { $1 })
        XCTAssertEqual(dict["x-oss-date"], "Tue, 20 Oct 2026 04:00:00 GMT")
        XCTAssertEqual(dict["x-oss-security-token"], "TOK")
        XCTAssertEqual(dict["Authorization"], "OSS AK:" + Self.ossExpected)
        // 不参与签名的查询参数不进资源串
        let other = signer.headers(method: "PUT", bucket: "bkt", key: "dir/a b.bin", query: [("uploadId", "UP"), ("partNumber", "2"), ("foo", "1")],
                                   contentType: "application/octet-stream", date: when)
        XCTAssertEqual(Dictionary(other, uniquingKeysWith: { $1 })["Authorization"], dict["Authorization"])
    }

    /// 用 Python hmac 按同样的串独立算出来的值（日期为 2026-10-20 04:00:00 GMT，星期二）
    static let ossExpected = "V+eqg+ceNZo3M2AXAcK4GCdQvKA="

    func testS3SigV4() {
        let s = S3SigV4(accessKeyId: "AK", secret: "SECRET", sessionToken: "TOK", region: "xunlei")
        let h = Dictionary(s.headers(method: "PUT", host: "bkt.s3.example.com", path: "/dir/a%20b.bin",
                                     query: [("uploadId", "UP"), ("partNumber", "2")], payload: Data("hello".utf8), date: when),
                           uniquingKeysWith: { $1 })
        XCTAssertEqual(h["x-amz-date"], "20261020T040000Z")
        XCTAssertEqual(h["x-amz-security-token"], "TOK")
        XCTAssertNil(h["host"])
        XCTAssertEqual(h["Authorization"], "AWS4-HMAC-SHA256 Credential=AK/20261020/xunlei/s3/aws4_request, " +
                       "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token, " +
                       "Signature=bf29137e8be9d28682374f8e047b9f1957594e77e195f27bcde006e8202cefb9")
    }

    func testMultipartFormAndUtilities() throws {
        let form = MultipartForm(fields: [("a", "1")])
        let body = String(decoding: form.body(fileField: "file", fileName: "x\"y.txt", content: Data("HI".utf8)), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("--\(form.boundary)\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"x'y.txt\"\r\nContent-Type: application/octet-stream\r\n\r\nHI\r\n--\(form.boundary)--\r\n"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.bin")
        try Data("HI".utf8).write(to: file)
        let written = try form.write(fileField: "file", fileName: "x\"y.txt", file: file)
        defer { try? FileManager.default.removeItem(at: written) }
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), body)

        XCTAssertEqual(UploadUtil.parts(size: 10, partSize: 4).map(\.length), [4, 4, 2])
        XCTAssertEqual(UploadUtil.parts(size: 0, partSize: 4).count, 0)
        XCTAssertEqual(UploadUtil.xmlValue("UploadId", in: "<a><UploadId>XYZ</UploadId></a>"), "XYZ")
        XCTAssertEqual(UploadUtil.encodePath("dir/a b+c.bin"), "dir/a%20b%2Bc.bin")
        XCTAssertEqual(UploadUtil.completeXML(["\"e1\"", "\"e2\""]),
                       "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"e1\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"e2\"</ETag></Part></CompleteMultipartUpload>")
    }

    func testPlatformBodies() {
        let b123 = Pan123Resolver.uploadRequestBody(name: "a.zip", size: 9, etag: "md5", parentId: "42")
        XCTAssertEqual(b123["parentFileId"] as? Int64, 42)
        XCTAssertEqual(b123["duplicate"] as? Int, 1)
        XCTAssertEqual(Pan123Resolver.parsePresigned(JSON(text: #"{"1":"https://u/1","2":"https://u/2","x":"y"}"#)!), [1: "https://u/1", 2: "https://u/2"])

        let parts = C139Resolver.partInfos(UploadUtil.parts(size: 150, partSize: 100))
        XCTAssertEqual(OrderedJSON.array(parts).text,
                       #"[{"partNumber":1,"partSize":100,"parallelHashCtx":{"partOffset":0}},{"partNumber":2,"partSize":50,"parallelHashCtx":{"partOffset":100}}]"#)
        XCTAssertTrue(C139Resolver.uploadCreateBody(name: "a", size: 150, hash: "h", parentId: "", parts: parts).text
            .contains(#""parentFileId":"/","name":"a","type":"file","fileRenameMode":"auto_rename""#))
        XCTAssertEqual(C139Resolver.parseUploadURLs(JSON(text: #"[{"partNumber":2,"uploadUrl":"https://p2"}]"#)!), [2: "https://p2"])
        XCTAssertEqual(C139Resolver.uploadPartSize(for: 1 << 30), 100 << 20)

        XCTAssertEqual(QuarkFamilyResolver.host(of: "http://pds.quark.cn/"), "pds.quark.cn")
        XCTAssertTrue(QuarkFamilyResolver.completeXML(["\"a\""]).contains("<Part>\n<PartNumber>1</PartNumber>\n<ETag>\"a\"</ETag>\n</Part>"))

        XCTAssertEqual(ILanzouResolver.base64URL("disk/2026/a?b"), "ZGlzay8yMDI2L2E_Yg==")
        XCTAssertTrue(ILanzouResolver.objectKey(account: "u1", date: when).hasPrefix("disk/2026/10/20/u1/"))
    }
}
