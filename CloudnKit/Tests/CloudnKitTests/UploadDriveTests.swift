import XCTest
@testable import CloudnKit

/// 迅雷 / 光鸭 / 百度上传的纯函数：GCID、请求体、凭证解析、域名规整、百度分片摘要。
/// 期望值用 Python 按同样算法独立算出：
///
///     import hashlib
///     def pattern(n): return bytes(((i * 2654435761) >> 13) & 0xff for i in range(n))
///     def gcid(data):
///         bs = 0x40000
///         while len(data) / bs > 0x200 and bs < 0x200000: bs <<= 1
///         outer = hashlib.sha1()
///         for off in range(0, len(data), bs):
///             outer.update(hashlib.sha1(data[off:off + bs]).digest())
///         return outer.hexdigest().upper()
///     gcid(b""), gcid(b"abc"), gcid(pattern(262144)), gcid(pattern(600000))
///     d = pattern(2700000); s = 786432
///     hashlib.md5(d).hexdigest()                                              # content-md5
///     hashlib.md5(d[:262144]).hexdigest()                                     # slice-md5
///     [hashlib.md5(d[o:o + s]).hexdigest() for o in range(0, len(d), s)]      # block_list
final class UploadDriveTests: XCTestCase {
    /// 与 Python 的 pattern(n) 相同的确定性数据（不随 256 字节周期重复）
    private func pattern(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let v: Int = (i &* 2654435761) >> 13
            bytes[i] = UInt8(truncatingIfNeeded: v)
        }
        return Data(bytes)
    }

    // MARK: 迅雷

    func testGCIDBlockSize() {
        XCTAssertEqual(XunleiResolver.gcidBlockSize(0), 0x40000)
        XCTAssertEqual(XunleiResolver.gcidBlockSize(0x200 * 0x40000), 0x40000)
        XCTAssertEqual(XunleiResolver.gcidBlockSize(0x200 * 0x40000 + 1), 0x80000)
        XCTAssertEqual(XunleiResolver.gcidBlockSize(1 << 40), 0x200000)
    }

    func testGCIDVectors() {
        XCTAssertEqual(XunleiResolver.gcid(Data()), "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709")
        XCTAssertEqual(XunleiResolver.gcid(Data("abc".utf8)), "0D3CED9BEC10A777AEC23CCC353A8C08A633045E")
        XCTAssertEqual(XunleiResolver.gcid(pattern(262144)), "F8B0138DBE36A9248FDBB506B6701B4B7BFA46D8")
        let data = pattern(600000)
        XCTAssertEqual(XunleiResolver.gcid(data), "3D573552235077848C202A1891CB27A69DC5D538")
        // 分段喂入（跨块边界）与一次算完一致
        var h = XunleiResolver.GCIDHasher(size: Int64(data.count))
        for start in stride(from: 0, to: data.count, by: 99_991) {
            h.update(data.subdata(in: start..<min(data.count, start + 99_991)))
        }
        XCTAssertEqual(Crypto.hex(h.finalize()).uppercased(), "3D573552235077848C202A1891CB27A69DC5D538")
    }

    func testXunleiCreateFileBody() {
        let body = XunleiResolver.uploadFileBody(name: "a b.txt", parent: XunleiResolver.driveParent("0"), size: 12, gcid: "ABC")
        XCTAssertEqual(body.text, #"{"kind":"drive#file","parent_id":"","name":"a b.txt","size":12,"hash":"ABC","upload_type":"UPLOAD_TYPE_RESUMABLE","space":""}"#)
    }

    func testXunleiRapidAndTicket() {
        XCTAssertTrue(XunleiResolver.isRapidUpload(JSON(text: #"{"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"phase":"PHASE_TYPE_COMPLETE"}}"#)!))
        XCTAssertTrue(XunleiResolver.isRapidUpload(JSON(text: #"{"upload_type":"UPLOAD_TYPE_FORM"}"#)!))
        XCTAssertFalse(XunleiResolver.isRapidUpload(JSON(text: #"{"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"phase":"PHASE_TYPE_PENDING"}}"#)!))
        XCTAssertFalse(XunleiResolver.isRapidUpload(JSON(text: "{}")!))

        let aliyun = JSON(text: #"""
        {"upload_type":"UPLOAD_TYPE_RESUMABLE","file":{"id":"F1","phase":"PHASE_TYPE_PENDING"},
         "resumable":{"kind":"drive#resumable","provider":"PROVIDER_ALIYUN","params":{"access_key_id":"AK","access_key_secret":"SK",
         "bucket":"xl-bkt","endpoint":"xl-bkt.oss-cn-shanghai.aliyuncs.com","key":"dir/obj 1","security_token":"TOK",
         "expiration":"2026-10-20T05:00:00Z"}}}
        """#)!
        let t = XunleiResolver.parseUploadTicket(aliyun)
        XCTAssertEqual(t?.endpoint, "oss-cn-shanghai.aliyuncs.com")
        XCTAssertEqual(t?.host, "xl-bkt.oss-cn-shanghai.aliyuncs.com")
        XCTAssertEqual(t?.path, "/dir/obj%201")
        XCTAssertEqual(t?.objectURL, "https://xl-bkt.oss-cn-shanghai.aliyuncs.com/dir/obj%201")
        XCTAssertEqual(t?.securityToken, "TOK")
        XCTAssertEqual(t?.isAliyun, true)

        let s3 = JSON(text: #"{"resumable":{"provider":"PROVIDER_S3","params":{"access_key_id":"AK","access_key_secret":"SK","bucket":"b","endpoint":"https://vip-lixian.mypikpak.net/","key":"k"}}}"#)!
        XCTAssertEqual(XunleiResolver.parseUploadTicket(s3)?.isAliyun, false)
        XCTAssertEqual(XunleiResolver.parseUploadTicket(s3)?.endpoint, "vip-lixian.mypikpak.net")
        // 缺凭证
        XCTAssertNil(XunleiResolver.parseUploadTicket(JSON(text: #"{"resumable":{"params":{"bucket":"b","endpoint":"e.com","key":"k"}}}"#)!))
    }

    func testXunleiEndpointAndQuery() {
        // 只去掉完整的「bucket.」前缀（OpenList 的 TrimLeft 按字符集裁剪，会把 tos 的 t 也裁掉）
        XCTAssertEqual(XunleiResolver.objectEndpoint("tos.example.com", bucket: "xl-bkt"), "tos.example.com")
        XCTAssertEqual(XunleiResolver.objectEndpoint("http://b.s3.example.com/path", bucket: "b"), "s3.example.com")
        XCTAssertEqual(XunleiResolver.objectQuery([("uploads", "")], oss: true), "uploads")
        XCTAssertEqual(XunleiResolver.objectQuery([("uploads", "")], oss: false), "uploads=")
        XCTAssertEqual(XunleiResolver.objectQuery([("partNumber", "3"), ("uploadId", "a/b")], oss: false), "partNumber=3&uploadId=a%2Fb")
        XCTAssertEqual(XunleiResolver.uploadPartSize(for: 1 << 30), 5 << 20)
        let huge: Int64 = 10000 * (5 << 20) + 1
        XCTAssertEqual(XunleiResolver.uploadPartSize(for: huge), huge / 9999)
        XCTAssertLessThanOrEqual(UploadUtil.parts(size: huge, partSize: XunleiResolver.uploadPartSize(for: huge)).count, 10000)
    }

    // MARK: 光鸭

    func testGuangYaTokenBody() {
        XCTAssertEqual(GuangYaResolver.uploadTokenBody(name: "a.txt", parentId: "P", size: 5, md5: "m").text,
                       #"{"capacity":2,"name":"a.txt","parentId":"P","res":{"fileSize":5,"md5":"m"}}"#)
    }

    func testGuangYaRapidDetection() throws {
        let rapid = try GuangYaResolver.parseUploadToken(JSON(text: #"{"code":156,"msg":"秒传成功","data":{"taskId":"T1"}}"#)!)
        XCTAssertTrue(rapid.rapid)
        XCTAssertEqual(rapid.taskId, "T1")
        XCTAssertTrue(try GuangYaResolver.parseUploadToken(JSON(text: #"{"code":0,"msg":"上传已完成","data":{"taskId":"T"}}"#)!).rapid)
        XCTAssertTrue(GuangYaResolver.isUploadAlreadyDone(" Already Uploaded "))
        XCTAssertFalse(GuangYaResolver.isUploadAlreadyDone("success"))

        let normal = try GuangYaResolver.parseUploadToken(JSON(text: #"""
        {"code":0,"msg":"success","data":{"taskId":"T2","objectPath":"u/1/obj","bucketName":"gy-bkt",
         "endPoint":"oss-cn-hangzhou.aliyuncs.com","fullEndPoint":"https://gy-bkt.oss-cn-hangzhou.aliyuncs.com",
         "creds":{"accessKeyID":"AK","secretAccessKey":"SK","sessionToken":"TOK"}}}
        """#)!)
        XCTAssertFalse(normal.rapid)
        XCTAssertEqual(normal.host, "oss-cn-hangzhou.aliyuncs.com")
        XCTAssertEqual(normal.accessKeyId, "AK")
        XCTAssertEqual(normal.accessKeySecret, "SK")
        XCTAssertEqual(normal.sessionToken, "TOK")
        XCTAssertEqual(normal.objectURL, "https://gy-bkt.oss-cn-hangzhou.aliyuncs.com/u/1/obj")

        XCTAssertThrowsError(try GuangYaResolver.parseUploadToken(JSON(text: #"{"code":10,"msg":"空间不足","data":{}}"#)!)) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "空间不足")
        }
        // 非秒传却没给凭证
        XCTAssertThrowsError(try GuangYaResolver.parseUploadToken(JSON(text: #"{"code":0,"msg":"","data":{"taskId":"T"}}"#)!))
        // taskId 为空
        XCTAssertThrowsError(try GuangYaResolver.parseUploadToken(JSON(text: #"{"code":156,"data":{}}"#)!))
    }

    func testGuangYaHostPartsAndTask() {
        XCTAssertEqual(GuangYaResolver.ossHost(endPoint: "https://gy-bkt.oss.example.com/", fullEndPoint: "", bucket: "gy-bkt"), "oss.example.com")
        XCTAssertEqual(GuangYaResolver.ossHost(endPoint: "oss.example.com", fullEndPoint: "", bucket: "b"), "oss.example.com")
        XCTAssertEqual(GuangYaResolver.ossHost(endPoint: "", fullEndPoint: "http://b.oss.x.com", bucket: "b"), "oss.x.com")
        XCTAssertEqual(GuangYaResolver.ossQuery([("sequential", ""), ("uploads", "")]), "sequential&uploads")
        XCTAssertEqual(GuangYaResolver.ossQuery([("partNumber", "1"), ("uploadId", "U")]), "partNumber=1&uploadId=U")

        let mb: Int64 = 1 << 20
        XCTAssertEqual(GuangYaResolver.uploadPartSize(for: 100 * mb), mb)
        XCTAssertEqual(GuangYaResolver.uploadPartSize(for: 101 * mb), 2 * mb)
        XCTAssertEqual(GuangYaResolver.uploadPartSize(for: 20 << 30), 4 * mb)
        // 50GB 按档位是 4MB，会超过 10000 片，放大到 6MB
        XCTAssertEqual(GuangYaResolver.uploadPartSize(for: 50 << 30), 6 * mb)

        XCTAssertEqual(GuangYaResolver.uploadTaskState(JSON(text: #"{"code":145,"data":{"fileId":"F"}}"#)!), .done)
        XCTAssertEqual(GuangYaResolver.uploadTaskState(JSON(text: #"{"code":145,"msg":"处理中","data":{}}"#)!), .pending)
        XCTAssertEqual(GuangYaResolver.uploadTaskState(JSON(text: #"{"code":0,"data":{}}"#)!), .pending)
        XCTAssertEqual(GuangYaResolver.uploadTaskState(JSON(text: #"{"code":500,"msg":"失败","data":{}}"#)!),
                       .failed("光鸭上传处理失败：失败（code=500）"))
    }

    // MARK: 百度

    func testBaiduHashes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.bin")
        try pattern(2_700_000).write(to: file)
        // 片大小 768KB：片边界与 1MB 的读块边界错开
        let h = try BaiduResolver.uploadHashes(file, sliceSize: 786_432)
        XCTAssertEqual(h.contentMD5, "2ffebe7519b3d3840fc2f789a3298f8a")
        XCTAssertEqual(h.sliceMD5, "b16123b9de0a8004c512dd430e8aecff")
        XCTAssertEqual(h.blocks, ["e421c9c6f707fbe66cbb09886cfcee71", "93246fdca8e556790edf2fc94d3a69d9",
                                  "d5ded4984c61004a38d9353508b60e2a", "0ebb31e9bf218d084b481e233038f12f"])
        XCTAssertEqual(BaiduResolver.blockListJSON(["a", "b"]), #"["a","b"]"#)

        // 短于 256KB 时 slice-md5 = 整个文件的 md5
        let small = dir.appendingPathComponent("s.bin")
        try Data("hello".utf8).write(to: small)
        let s = try BaiduResolver.uploadHashes(small, sliceSize: BaiduResolver.defaultSliceSize)
        XCTAssertEqual(s.contentMD5, "5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(s.sliceMD5, s.contentMD5)
        XCTAssertEqual(s.blocks, [s.contentMD5])

        let mb: Int64 = 1 << 20
        XCTAssertEqual(BaiduResolver.uploadSliceSize(for: 1 << 30), 4 * mb)
        XCTAssertEqual(BaiduResolver.uploadSliceSize(for: 2048 * 4 * mb + 1), 16 * mb)
        XCTAssertEqual(BaiduResolver.uploadSliceSize(for: 100 << 30), 32 * mb)
    }

    func testBaiduForms() {
        XCTAssertEqual(BaiduResolver.targetPath("/a"), "/a/")
        XCTAssertEqual(BaiduResolver.targetPath(""), "/")
        XCTAssertEqual(BaiduResolver.targetPath("/"), "/")

        let pre = BaiduResolver.precreateForm(path: "/a/x.bin", size: 9, blockList: #"["m"]"#, contentMD5: "c", sliceMD5: "s",
                                              targetPath: "/a/", mtime: 100, ctime: 50)
        XCTAssertEqual(pre.map { $0.0 }, ["path", "size", "isdir", "autoinit", "rtype", "block_list", "content-md5", "slice-md5",
                                      "target_path", "local_mtime", "local_ctime"])
        XCTAssertEqual(pre.map { $0.1 }, ["/a/x.bin", "9", "0", "1", "1", #"["m"]"#, "c", "s", "/a/", "100", "50"])
        // uploadid 过期后重来：不带 content-md5 / slice-md5
        let again = BaiduResolver.precreateForm(path: "/a/x.bin", size: 9, blockList: #"["m"]"#, contentMD5: "", sliceMD5: "",
                                                targetPath: "/a/", mtime: 100, ctime: 50)
        XCTAssertFalse(again.contains(where: { $0.0 == "content-md5" || $0.0 == "slice-md5" }))

        let create = BaiduResolver.createForm(path: "/a/x.bin", size: 9, uploadId: "U", blockList: #"["m"]"#, targetPath: "/a/",
                                              mtime: 100, ctime: 50)
        XCTAssertEqual(create.map { $0.0 }, ["path", "size", "isdir", "rtype", "uploadid", "block_list", "target_path", "local_mtime", "local_ctime"])
        XCTAssertEqual(create.map { $0.1 }, ["/a/x.bin", "9", "0", "1", "U", #"["m"]"#, "/a/", "100", "50"])

        XCTAssertEqual(BaiduResolver.missingBlocks(JSON(text: #"{"return_type":1,"block_list":[1,3,9]}"#)!, count: 4), [1, 3])
        XCTAssertEqual(BaiduResolver.missingBlocks(JSON(text: #"{"return_type":1,"block_list":[]}"#)!, count: 4), [0, 1, 2, 3])
    }

    func testBaiduUploadHostAndSuperfile() throws {
        XCTAssertEqual(BaiduResolver.parseUploadHost(JSON(text: #"{"servers":[{"server":"http://c.pcs.baidu.com/"}]}"#)), "https://c.pcs.baidu.com")
        XCTAssertEqual(BaiduResolver.parseUploadHost(JSON(text: #"{"servers":[],"bak_servers":[{"server":"https://b.pcs.baidu.com"}]}"#)),
                       "https://b.pcs.baidu.com")
        XCTAssertEqual(BaiduResolver.parseUploadHost(nil), "https://d.pcs.baidu.com")
        XCTAssertEqual(BaiduResolver.normalizeUploadHost("x.pcs.baidu.com"), "https://x.pcs.baidu.com")

        XCTAssertEqual(BaiduResolver.superfileURL(host: "https://c.pcs.baidu.com", path: "/a/b.txt", uploadId: "U", partseq: 2),
                       "https://c.pcs.baidu.com/rest/2.0/pcs/superfile2?method=upload&app_id=250528&channel=chunlei&clienttype=0&web=1" +
                       "&type=tmpfile&path=%2Fa%2Fb.txt&uploadid=U&uploadsign=0&partseq=2")

        XCTAssertNoThrow(try BaiduResolver.checkSuperfile(#"{"md5":"ABC","partseq":"0","uploadid":"U"}"#, status: 200, expectedMD5: "abc"))
        XCTAssertNoThrow(try BaiduResolver.checkSuperfile(#"{"md5":"def","partseq":"0","uploadid":"U"}"#, status: 200, expectedMD5: "abc"))
        XCTAssertThrowsError(try BaiduResolver.checkSuperfile(#"{"error_code":31066,"error_msg":"file does not exist"}"#, status: 200,
                                                              expectedMD5: "abc")) {
            XCTAssertEqual(($0 as? CloudnError)?.code, 31066)
        }
        XCTAssertThrowsError(try BaiduResolver.checkSuperfile(#"{"error_code":31363,"error_msg":"uploadid not found"}"#, status: 404,
                                                              expectedMD5: "abc")) {
            XCTAssertEqual(($0 as? CloudnError)?.code, BaiduResolver.uploadIdExpiredCode)
        }
        XCTAssertThrowsError(try BaiduResolver.checkSuperfile("<html>", status: 502, expectedMD5: "abc"))
    }
}
