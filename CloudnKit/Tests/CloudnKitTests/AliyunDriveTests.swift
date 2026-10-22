import XCTest
@testable import CloudnKit

/// 阿里云盘「我的网盘」：secp256k1 设备签名与个人盘请求体（不联网）。签名向量用独立的整数实现算出
final class AliyunDriveTests: XCTestCase {
    static let userId = "0fd192bc802944bf9efcc429dee83c10"

    func testSecp256k1Generator() throws {
        // 私钥 1 的公钥就是生成元 G
        let pub = try XCTUnwrap(Secp256k1.publicKey([UInt8](repeating: 0, count: 31) + [1]))
        XCTAssertEqual(Crypto.hex(pub), "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
                                      + "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")
        // 2G
        let two = try XCTUnwrap(Secp256k1.publicKey([UInt8](repeating: 0, count: 31) + [2]))
        XCTAssertEqual(Crypto.hex(Array(two.prefix(32))), "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5")
        XCTAssertNil(Secp256k1.publicKey([UInt8](repeating: 0, count: 32)))
    }

    func testDeviceKeyAndFixedNonceSignature() throws {
        let deviceId = Crypto.hex(Crypto.sha256(Data(Self.userId.utf8)))
        XCTAssertEqual(deviceId, "af051b4e47e80584c3adae3d0b359ccab9e45b697edaca9a9474390adf171b6f")
        let priv = try XCTUnwrap(Crypto.bytes(hex: deviceId))
        let pub = try XCTUnwrap(Secp256k1.publicKey(priv))
        XCTAssertEqual(Crypto.hex(pub), "710db382a9acad0d002607ed57faf8583d2abf109c5e9c9c1c0797a55ba2aa1d"
                                      + "b6762a1946e26b2fd8ae7ea0ceefbe88f7a8dbeb7c52dc1b1448dba214e31688")
        let hash = Crypto.sha256(Data("5dde4e1bdf9e4966b387ba58f4b3fdc3:\(deviceId):\(Self.userId):0".utf8))
        XCTAssertEqual(Crypto.hex(hash), "f51a264ef0dc2dd4d326edb2b993ab49a3c094b8a7c1bed50a88711bba1889af")
        let sig = try XCTUnwrap(Secp256k1.sign(hash: hash, priv: priv, nonce: { [UInt8](repeating: 0x11, count: 32) }))
        XCTAssertEqual(Crypto.hex(sig), "4f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa"
                                      + "0fe07231be75e7b9e0914860b42c00a340e7a8aa48469f2a7fdb9cfdfa1f7711" + "00")
        XCTAssertTrue(Secp256k1.verify(hash: hash, signature: sig, publicKey: pub))
    }

    func testRandomNonceSignaturesVerify() throws {
        let sig = try XCTUnwrap(AliyunResolver.deviceSignature(userId: Self.userId))
        XCTAssertEqual(sig.deviceId, "af051b4e47e80584c3adae3d0b359ccab9e45b697edaca9a9474390adf171b6f")
        let bytes = try XCTUnwrap(Crypto.bytes(hex: sig.signature))
        XCTAssertEqual(bytes.count, 65)
        XCTAssertLessThanOrEqual(bytes[64], 1)
        // s 取低位
        XCTAssertLessThan(bytes[32], 0x80)
        let hash = Crypto.sha256(Data("5dde4e1bdf9e4966b387ba58f4b3fdc3:\(sig.deviceId):\(Self.userId):0".utf8))
        XCTAssertTrue(Secp256k1.verify(hash: hash, signature: bytes, publicKey: try XCTUnwrap(Crypto.bytes(hex: sig.publicKey))))
        var tampered = bytes
        tampered[10] ^= 1
        XCTAssertFalse(Secp256k1.verify(hash: hash, signature: tampered, publicKey: try XCTUnwrap(Crypto.bytes(hex: sig.publicKey))))
    }

    func testCompositeIds() {
        XCTAssertEqual(AliyunResolver.compose(drive: "859958522", file: "65d459e6"), "859958522:65d459e6")
        XCTAssertEqual(AliyunResolver.split("859958522:root")?.file, "root")
        XCTAssertEqual(AliyunResolver.split("859958522:root")?.drive, "859958522")
        XCTAssertNil(AliyunResolver.split(""))
        XCTAssertNil(AliyunResolver.split("root"))
        let account = AliyunResolver.DriveAccount(userId: "u", backupDrive: "1", resourceDrive: "2", deviceId: "", signature: "", publicKey: "")
        XCTAssertEqual(account.drives.map(\.name), ["资源库", "备份盘"])
        XCTAssertEqual(account.defaultDrive, "2")
        let old = AliyunResolver.DriveAccount(userId: "u", backupDrive: "1", resourceDrive: "", deviceId: "", signature: "", publicKey: "")
        XCTAssertEqual(old.drives.map(\.id), ["1"])
        let resolver = AliyunResolver()
        XCTAssertEqual(resolver.target("", account: account).drive, "2")
        XCTAssertEqual(resolver.target("", account: account).file, "root")
        XCTAssertEqual(resolver.target("1:abc", account: account).drive, "1")

        let f = AliyunResolver.parseDriveFile(JSON(text: #"{"drive_id":"2","file_id":"abc","name":"a.mp4","type":"file","size":5}"#)!,
                                              drive: "9", parent: "2:root")
        XCTAssertEqual(f.fid, "2:abc")
        XCTAssertEqual(f.token, "2")
        XCTAssertFalse(f.isDirectory)
    }

    func testUploadHelpers() throws {
        XCTAssertEqual(AliyunResolver.partNumbers(size: 0, partSize: 10 << 20), [1])
        XCTAssertEqual(AliyunResolver.partNumbers(size: 25 << 20, partSize: 10 << 20), [1, 2, 3])
        XCTAssertEqual(AliyunResolver.uploadPartSize(1 << 30), 10 << 20)
        let huge: Int64 = 200 << 30
        let part = AliyunResolver.uploadPartSize(huge)
        XCTAssertLessThanOrEqual(AliyunResolver.partNumbers(size: huge, partSize: part).count, 10000)

        // md5("token") = 94a08da1fecbb6e8b46990538c7b50b2 → 前 16 位 0x94a08da1fecbb6e8
        XCTAssertEqual(AliyunResolver.proofOffset(accessToken: "token", size: 1000), 56)
        XCTAssertEqual(AliyunResolver.proofOffset(accessToken: "token", size: 0), 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aliyun-proof-\(UUID().uuidString)")
        try Data((0..<1000).map { UInt8($0 % 256) }).write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let offset = 56
        let expected = Data((offset..<min(offset + 8, 1000)).map { UInt8($0 % 256) }).base64EncodedString()
        XCTAssertEqual(try AliyunResolver.proofCode(dir, size: 1000, accessToken: "token"), expected)
        XCTAssertEqual(AliyunResolver.ossError("<Error><Code>SignatureDoesNotMatch</Code></Error>"), "：SignatureDoesNotMatch")
    }

    func testShareExpirationAndBatch() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AliyunResolver.expiration(.forever, now: now), "")
        XCTAssertEqual(AliyunResolver.expiration(ShareExpiry(days: 7), now: now), "2027-01-22T08:00:00.000Z")
        XCTAssertNoThrow(try AliyunResolver.checkBatch(JSON(text: #"{"responses":[{"id":"0","status":200},{"id":"1","status":202}]}"#)!, action: "移动"))
        XCTAssertThrowsError(try AliyunResolver.checkBatch(
            JSON(text: #"{"responses":[{"id":"0","status":200},{"id":"1","status":404,"body":{"code":"NotFound.File","message":"文件不存在"}}]}"#)!,
            action: "移动")) { error in
            XCTAssertTrue(error.localizedDescription.contains("文件不存在"), error.localizedDescription)
        }
    }

    func testCapabilitiesRegistered() {
        let resolvers = ShareResolvers(credentials: NoCredentials())
        XCTAssertNotNil(resolvers.manager(for: .aliyun))
        XCTAssertNotNil(resolvers.saver(for: .aliyun))
        XCTAssertNotNil(resolvers.uploader(for: .aliyun))
    }
}
