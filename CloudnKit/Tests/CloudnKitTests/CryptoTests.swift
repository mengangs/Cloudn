import XCTest
@testable import CloudnKit

/// 期望值由 Python 标准实现（hashlib / zlib / cryptography / 内置 pow）独立计算
final class CryptoTests: XCTestCase {
    let fox = String(repeating: "The quick brown fox jumps over the lazy dog", count: 3)

    func testDigests() {
        XCTAssertEqual(Crypto.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(Crypto.md5Hex(fox), "4e67db4a7a406b0cfdadd887cde7888e")
        XCTAssertEqual(Crypto.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(Crypto.sha1Hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(Crypto.sha1Hex(fox), "d42f858ad812fd986fd8dc7216af5f88bcaa1463")
        XCTAssertEqual(Crypto.crc32Hex("123456789"), "cbf43926")
        // 不补前导 0（与 Java Long.toHexString 一致）
        XCTAssertEqual(Crypto.crc32Hex("hello world"), "d4a1185")
    }

    func testAESKnownAnswers() {
        let pt = Crypto.bytes(hex: "00112233445566778899aabbccddeeff")!
        XCTAssertEqual(Crypto.hex(AES(key: Array(0..<16))!.encrypt(pt).prefix(16)), "69c4e0d86a7b0430d8cdb78070b4c55a")
        XCTAssertEqual(Crypto.hex(AES(key: Array(0..<24))!.encrypt(pt).prefix(16)), "dda97ca4864cdfe06eaf70a0ec0d7191")
        XCTAssertEqual(Crypto.hex(AES(key: Array(0..<32))!.encrypt(pt).prefix(16)), "8ea2b7ca516745bfeafc49904b496089")
        XCTAssertNil(AES(key: [1, 2, 3]))
    }

    func testAESRoundTrip() {
        let aes = AES(key: Array("PVGDwmcvfs1uV3d1".utf8))!
        let iv = Array(UInt8(100)..<UInt8(116))
        for n in [0, 1, 15, 16, 17, 100] {
            let plain = (0..<n).map { UInt8($0 % 251) }
            XCTAssertEqual(aes.decrypt(aes.encrypt(plain)), plain)
            XCTAssertEqual(aes.decrypt(aes.encrypt(plain, mode: .cbc(iv: iv)), mode: .cbc(iv: iv)), plain)
        }
        XCTAssertNil(aes.decrypt([1, 2, 3]))
    }

    func testBigUIntPower() {
        let n = Pan115Crypto.modulus
        let x = BigUInt(hex: String(repeating: "0123456789abcdef", count: 8))!
        let expected = "706ccd4dc41d3d0a2adb1b385ea3653a24490488269ff4279aaf3eadcefe93ab80ef4fd1145f2b97e687bae09e58698a" +
            "4c4608da1f4b1be26248990a220888bc255eb72ccde7d51f9d182d86b3423782d2c89f4988231787d90d46e0d7519cd1d7d00ee7b907e" +
            "70173d790162d6a64b366c25676c28577b765f0c4c73eeca267"
        XCTAssertEqual(Crypto.hex(x.power(Pan115Crypto.exponent, modulus: n).bytes(length: 128)), expected)
        XCTAssertEqual(BigUInt(7).power(BigUInt(13), modulus: BigUInt(1_000_003)), BigUInt(719_743))
    }

    func testBase64Lenient() {
        XCTAssertEqual(Crypto.base64Decode("aGVsbG8"), Data("hello".utf8))
        XCTAssertEqual(Crypto.base64Decode("-_8"), Data([0xfb, 0xff]))
    }

    func testOrderedJSON() {
        let j = OrderedJSON.object([("b", .int(1)), ("a", .array([.string("x\"y"), .bool(true)])), ("c", .object([]))])
        XCTAssertEqual(j.text, #"{"b":1,"a":["x\"y",true],"c":{}}"#)
    }
}
