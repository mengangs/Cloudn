import XCTest
@testable import CloudnKit

final class WxChannelsTests: XCTestCase {
    // MARK: 链接

    func testShareID() {
        XCTAssertEqual(WxChannelsParser.shareID(in: "https://weixin.qq.com/sph/AbCd12_x"), "AbCd12_x")
        XCTAssertEqual(WxChannelsParser.shareID(in: "复制链接 https://weixin.qq.com/sph/AEnKyXQ2s 打开"), "AEnKyXQ2s")
        XCTAssertEqual(WxChannelsParser.shareID(in: "https://channels.weixin.qq.com/finder-preview/pages/sph?from=share&id=Xy9_z&x=1"), "Xy9_z")
        XCTAssertEqual(WxChannelsParser.shareID(in: "https://channels.weixin.qq.com/finder-preview/pages/sph?id=Q1w2"), "Q1w2")
        XCTAssertNil(WxChannelsParser.shareID(in: "https://mp.weixin.qq.com/s/abcdef"))
        XCTAssertNil(WxChannelsParser.shareID(in: "https://channels.weixin.qq.com/finder-preview/pages/sph?vid=1"))
        XCTAssertEqual(WxChannelsParser.shareURL("AbC"), "https://weixin.qq.com/sph/AbC")
    }

    func testPlayableParams() {
        let p = WxChannelsParser.playableParams(
            "https://channels.weixin.qq.com/finder-preview/pages/feed?entry_card_type=48&token=tok%2Fen%3D&eid=export%2F1")
        XCTAssertEqual(p?.token, "tok/en=")
        XCTAssertEqual(p?.exportID, "export/1")
        XCTAssertNil(WxChannelsParser.playableParams("https://channels.weixin.qq.com/finder-preview/pages/feed?token=a"))
        XCTAssertNil(WxChannelsParser.playableParams("https://channels.weixin.qq.com/finder-preview/pages/feed"))
    }

    func testRequestShapes() {
        XCTAssertEqual(WxChannelsParser.feedURL(rid: "65f0a1b2-0123abcd"),
                       "https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info?_rid=65f0a1b2-0123abcd"
                       + "&_pageUrl=https%3A%2F%2Fchannels.weixin.qq.com%2Ffinder-preview%2Fpages%2Ffeed")
        let rid = WxChannelsParser.makeRid(now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(rid.hasPrefix("6553f100-"))
        XCTAssertEqual(rid.count, "6553f100-".count + 8)
        let body = WxChannelsParser.yuanbaoBody(shareID: "AbC")
        XCTAssertEqual(body["type"] as? String, "video_channel_url")
        XCTAssertEqual(body["url"] as? String, "https://weixin.qq.com/sph/AbC")
        XCTAssertEqual(body["scene"] as? Int, 1)
        let headers = WxChannelsParser.yuanbaoHeaders(cookie: "hy_user=u; hy_token=t")
        XCTAssertTrue(headers.contains(where: { $0.0 == "Cookie" && $0.1 == "hy_user=u; hy_token=t" }))
        XCTAssertTrue(headers.contains(where: { $0.0 == "Origin" && $0.1 == "https://yuanbao.tencent.com" }))
    }

    // MARK: 元宝响应

    func testYuanbaoData() throws {
        let ok = JSON(text: #"{"code":0,"data":{"wx_export_id":"e1","playable_url":"https://x/?token=t&eid=e","desc":"d"}}"#)
        XCTAssertEqual(try WxChannelsParser.yuanbaoData(status: 200, json: ok)["wx_export_id"].string, "e1")

        XCTAssertThrowsError(try WxChannelsParser.yuanbaoData(status: 401, json: nil)) { e in
            XCTAssertEqual((e as? VideoParseError)?.detail, WxChannelsParser.expired)
        }
        let expired = JSON(text: #"{"error":{"code":20000,"message":"need login"}}"#)
        XCTAssertThrowsError(try WxChannelsParser.yuanbaoData(status: 200, json: expired)) { e in
            XCTAssertEqual((e as? VideoParseError)?.detail, WxChannelsParser.expired)
        }
        let other = JSON(text: #"{"error":{"code":"500","message":"busy"}}"#)
        XCTAssertThrowsError(try WxChannelsParser.yuanbaoData(status: 200, json: other)) { e in
            XCTAssertEqual((e as? VideoParseError)?.detail, "腾讯元宝解析失败：busy")
        }
        let bad = JSON(text: #"{"code":1,"message":"链接无效"}"#)
        XCTAssertThrowsError(try WxChannelsParser.yuanbaoData(status: 200, json: bad)) { e in
            XCTAssertEqual((e as? VideoParseError)?.detail, "微信视频号解析失败：链接无效")
        }
        // 空 error 不算错误
        let emptyError = JSON(text: #"{"error":null,"code":0,"data":{"wx_export_id":"e2"}}"#)
        XCTAssertEqual(try WxChannelsParser.yuanbaoData(status: 200, json: emptyError)["wx_export_id"].string, "e2")
    }

    func testFeedDataErrors() throws {
        let ok = JSON(text: #"{"errCode":0,"data":{"feedInfo":{"description":"x"},"errMsg":{"type":0}}}"#)!
        XCTAssertEqual(try WxChannelsParser.feedData(ok)["feedInfo"]["description"].string, "x")

        let hidden = JSON(text: #"{"errCode":0,"data":{"errMsg":{"type":3,"title":"<b>视频已删除</b>","content":"作者已删除&amp;隐藏"}}}"#)!
        XCTAssertThrowsError(try WxChannelsParser.feedData(hidden)) { e in
            XCTAssertEqual((e as? VideoParseError)?.detail, "微信视频号：视频已删除 作者已删除&隐藏")
        }
        let failed = JSON(text: #"{"errCode":-1,"errMsg":"token expired"}"#)!
        XCTAssertThrowsError(try WxChannelsParser.feedData(failed)) { e in
            XCTAssertEqual((e as? VideoParseError)?.detail, "微信视频号解析失败：token expired")
        }
    }

    // MARK: 媒体

    func testBuildVideoResult() throws {
        let feed = JSON(text: #"""
        {"feedInfo":{"description":"日落 #旅行","coverUrl":"https://finder.video.qq.com/cover.jpg","createtime":1700000000,
          "mediaType":4,"videoUrl":"https://finder.video.qq.com/plain.mp4",
          "h264VideoInfo":{"videoUrl":"https://finder.video.qq.com/h264.mp4"},
          "h265VideoInfo":{"videoUrl":"https://finder.video.qq.com/h265.mp4"}},
         "authorInfo":{"nickname":"作者","headImgUrl":"https://wx.qlogo.cn/a.jpg"}}
        """#)!
        let yb = JSON(text: #"{"desc":"元宝描述","author":"元宝作者","cover_url":"https://c"}"#)!
        let r = try WxChannelsParser.buildResult(feed: feed, yuanbao: yb, shareID: "AbC")
        // H.264 仍是默认档，H.265 作为同组的另一档
        XCTAssertEqual(r.medias.count, 2)
        XCTAssertEqual(r.medias[0].url, "https://finder.video.qq.com/h264.mp4")
        XCTAssertEqual(r.medias[1].url, "https://finder.video.qq.com/h265.mp4")
        XCTAssertEqual(r.medias[1].quality, "H.265")
        XCTAssertEqual(r.medias[0].variantGroup, r.medias[1].variantGroup)
        XCTAssertFalse(r.medias[0].variantGroup.isEmpty)
        XCTAssertNotEqual(r.medias[0].fileName, r.medias[1].fileName)
        XCTAssertEqual(r.defaultDownloads.count, 1)
        XCTAssertEqual(r.medias[0].kind, .video)
        XCTAssertEqual(r.medias[0].quality, "H.264")
        XCTAssertTrue(r.medias[0].fileName.hasSuffix(".mp4"))
        XCTAssertEqual(r.title, "日落 #旅行")
        XCTAssertEqual(r.author, "作者")
        XCTAssertEqual(r.avatar, "https://wx.qlogo.cn/a.jpg")
        XCTAssertEqual(r.cover, "https://finder.video.qq.com/cover.jpg")
        XCTAssertEqual(r.timestamp, 1_700_000_000)
        XCTAssertEqual(r.url, "https://weixin.qq.com/sph/AbC")
        XCTAssertEqual(r.notice, "")
    }

    func testVideoFallbacksAndYuanbaoMeta() throws {
        let onlyH265 = JSON(text: #"{"feedInfo":{"h265VideoInfo":{"videoUrl":"https://v/h265"}}}"#)!
        XCTAssertEqual(WxChannelsParser.videoURL(onlyH265["feedInfo"])?.url, "https://v/h265")
        XCTAssertEqual(WxChannelsParser.videoURL(onlyH265["feedInfo"])?.quality, "H.265")
        let plain = JSON(text: #"{"videoUrl":"https://v/plain","h265VideoInfo":{"videoUrl":"https://v/h265"}}"#)!
        XCTAssertEqual(WxChannelsParser.videoURL(plain)?.url, "https://v/plain")

        let yb = JSON(text: #"{"desc":"元宝描述","author":"元宝作者","cover_url":"https://c","author_icon":"https://i"}"#)!
        let r = try WxChannelsParser.buildResult(feed: onlyH265, yuanbao: yb, shareID: "Z")
        XCTAssertEqual(r.title, "元宝描述")
        XCTAssertEqual(r.author, "元宝作者")
        XCTAssertEqual(r.cover, "https://c")
        XCTAssertEqual(r.avatar, "https://i")
    }

    func testImagePostAndNoMedia() throws {
        let feed = JSON(text: #"{"feedInfo":{"mediaType":2,"description":"图集","picInfo":[{"url":"https://p/1"},{"url":""},{"url":"https://p/2.png"}]}}"#)!
        let r = try WxChannelsParser.buildResult(feed: feed, yuanbao: JSON(nil), shareID: "P")
        XCTAssertEqual(r.medias.map(\.url), ["https://p/1", "https://p/2.png"])
        XCTAssertEqual(r.imageCount, 2)
        XCTAssertTrue(r.medias[0].fileName.hasSuffix("_1.jpg"))
        XCTAssertTrue(r.medias[1].fileName.hasSuffix("_2.png"))

        let empty = JSON(text: #"{"feedInfo":{"description":"x"}}"#)!
        XCTAssertThrowsError(try WxChannelsParser.buildResult(feed: empty, yuanbao: JSON(nil), shareID: "E"))
    }

    func testDecodeKeyNotice() throws {
        let feed = JSON(text: #"{"feedInfo":{"h264VideoInfo":{"videoUrl":"https://v/1","decodeKey":"123"}}}"#)!
        XCTAssertEqual(WxChannelsParser.decodeKey(feed["feedInfo"]), "123")
        let r = try WxChannelsParser.buildResult(feed: feed, yuanbao: JSON(nil), shareID: "K")
        XCTAssertFalse(r.notice.isEmpty)
    }

    // MARK: 登录态

    func testLoginCookies() {
        XCTAssertTrue(WxChannelsParser.looksLoggedIn(cookie: "hy_source=web; hy_user=abcdef123456; hy_token=xyz"))
        XCTAssertFalse(WxChannelsParser.looksLoggedIn(cookie: "hy_source=web; hy_user=abcdef123456"))
        XCTAssertFalse(WxChannelsParser.looksLoggedIn(cookie: "hy_user=; hy_token=xyz"))
        XCTAssertFalse(WxChannelsParser.looksLoggedIn(cookie: ""))
        XCTAssertEqual(WxChannelsParser.displayName(cookie: "hy_user=abcdef123456; hy_token=x"), "腾讯元宝用户 · 3456")
        XCTAssertEqual(WxChannelsParser.displayName(cookie: "hy_token=x"), "腾讯元宝用户")
        XCTAssertTrue(WxChannelsParser.isLoginExpired(status: 401, json: nil))
        XCTAssertTrue(WxChannelsParser.isLoginExpired(status: 200, json: JSON(text: #"{"error":{"code":"20000"}}"#)))
        XCTAssertFalse(WxChannelsParser.isLoginExpired(status: 200, json: JSON(text: #"{"code":1,"message":"url invalid"}"#)))
    }

    // MARK: ISAAC64 解密（期望值由 Python 实现算出，并与 wx_channels_download 的 Go DecryptData 交叉核对一致）

    func testKeystreamZeroSeedMatchesStandardISAAC64() {
        // 种子 0 的首个输出 0x9D39247E33776D41 即标准 ISAAC64（PolyGlot Random64 表首项）
        XCTAssertEqual(Crypto.hex(WxChannelsCrypto.keystream(key: 0, count: 32)),
                       "9d39247e33776d412af7398005aaa5c744db0150246235479c15f73e62a76ae2")
    }

    func testKeystreamVectors() {
        let cases: [(UInt64, String, String)] = [
            (1, "e19ed5d2ca98af2da7a18d07cab39b52a0ab0232d180af1472b36dcf1af5e46f",
             "39d98f5b25cc52f0996f7ef9e1022156cb029901be6a11ebbdd7469c6ffd5839"),
            (1_234_567_890_123_456_789, "981c44954c02d3c62fd66a014dfdf39285b4e3e282339bff6115553361443053",
             "7a760c59b0fddef2c9d212bdca8671b9f293e3a1b0a4e39699a6cb1f5d363572"),
            (UInt64.max, "7c38fd3a2e7cd8ad64081892c82430f3a8eca8122a6f4607f6943b85ac39b6f0",
             "5afbffd76305e81467f97c6370fa07916e9b197611bf5c357a854eb92a6354a1")
        ]
        for (key, head, digest) in cases {
            let ks = WxChannelsCrypto.keystream(key: key, count: WxChannelsCrypto.defaultLimit)
            XCTAssertEqual(Crypto.hex(ks.prefix(32)), head)
            XCTAssertEqual(Crypto.hex(Crypto.sha256(Data(ks))), digest)
        }
        // 跨过第一轮 256 个输出（2048 字节）的重新生成边界
        let ks = WxChannelsCrypto.keystream(key: 1, count: 2056)
        XCTAssertEqual(Crypto.hex(ks[2040..<2056]), "c3bee27657f8eb684f248babbf324897")
    }

    func testDecryptInPlace() {
        var data = Data((0..<20).map { UInt8($0) })
        WxChannelsCrypto.decrypt(&data, key: 42, limit: 16)
        XCTAssertEqual(Crypto.hex(data), "bbd71da6145f5f6d9335c29746c659b510111213")
        // 对称：再来一次还原
        WxChannelsCrypto.decrypt(&data, key: 42, limit: 16)
        XCTAssertEqual(data, Data((0..<20).map { UInt8($0) }))
        // 字符串密钥
        var s = Data((0..<20).map { UInt8($0) })
        XCTAssertTrue(WxChannelsCrypto.decrypt(&s, key: "42", limit: 16))
        XCTAssertEqual(Crypto.hex(s), "bbd71da6145f5f6d9335c29746c659b510111213")
        XCTAssertFalse(WxChannelsCrypto.decrypt(&s, key: "abc", limit: 16))
        XCTAssertEqual(WxChannelsCrypto.parseKey("18446744073709551615"), UInt64.max)
    }

    func testDecryptChunksMatchWhole() {
        let original = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var whole = original
        WxChannelsCrypto.decrypt(&whole, key: 987_654_321)
        // 只动前 128KB
        XCTAssertEqual(whole.suffix(from: WxChannelsCrypto.defaultLimit), original.suffix(from: WxChannelsCrypto.defaultLimit))
        XCTAssertNotEqual(whole.prefix(WxChannelsCrypto.defaultLimit), original.prefix(WxChannelsCrypto.defaultLimit))

        var rebuilt = Data()
        var offset = 0
        while offset < original.count {
            let end = min(offset + 50_000, original.count)
            var chunk = Data(original[offset..<end])
            WxChannelsCrypto.decrypt(&chunk, key: 987_654_321, offset: offset)
            rebuilt.append(chunk)
            offset = end
        }
        XCTAssertEqual(rebuilt, whole)
    }
}
