import XCTest
@testable import CloudnKit

final class PasswordLoginTests: XCTestCase {
    func testProviders() {
        for kind in [AccountKind.pan123, .guangya, .xunlei, .ilanzou, .lanzou] {
            XCTAssertNotNil(PasswordLogins.provider(for: kind), kind.rawValue)
        }
        XCTAssertNil(PasswordLogins.provider(for: .quark))
        XCTAssertEqual(PasswordLogins.provider(for: .guangya)?.supportsSMS, true)
        XCTAssertEqual(PasswordLogins.provider(for: .xunlei)?.supportsSMS, true)
        XCTAssertEqual(PasswordLogins.provider(for: .pan123)?.supportsSMS, false)
    }

    func testNewPlatformsHaveAccounts() {
        XCTAssertEqual(SharePlatform.guangya.accountKind, .guangya)
        XCTAssertEqual(SharePlatform.ilanzou.accountKind, .ilanzou)
        XCTAssertEqual(SharePlatform.lanzou.accountKind, .lanzou)
        XCTAssertTrue(AccountKind.guangya.isDrive)
        let resolvers = ShareResolvers(credentials: NoCredentials())
        XCTAssertNotNil(resolvers.saver(for: .guangya))
        XCTAssertNotNil(resolvers.saver(for: .ilanzou))
        XCTAssertNil(resolvers.saver(for: .lanzou))
    }

    func testGuangYaCredentialRoundTrip() throws {
        let cred = GuangYaCredential(accessToken: "acc-0123456789abcdef", refreshToken: "ref", deviceId: String(repeating: "a", count: 32),
                                     deviceSign: "wdi10." + String(repeating: "a", count: 32) + String(repeating: "b", count: 32), expiresAt: 1_900_000_000)
        XCTAssertEqual(GuangYaCredential.parse(cred.serialized), cred)
        // 裸 access_token 也能识别，并补出设备
        let bare = try XCTUnwrap(GuangYaCredential.parse("eyJhbGciOiJSUzI1NiJ9.payload"))
        XCTAssertEqual(bare.deviceId.count, 32)
        XCTAssertTrue(bare.deviceSign.hasPrefix("wdi10." + bare.deviceId))
        XCTAssertNil(GuangYaCredential.parse("short"))
        XCTAssertEqual(AccountValidator.normalize(.guangya, " \(cred.serialized) "), cred.serialized)
    }

    func testGuangYaHelpers() {
        XCTAssertEqual(GuangYaLogin.normalize("13800138000"), "+86 13800138000")
        XCTAssertEqual(GuangYaLogin.normalize("+86 138 0013 8000"), "+86 13800138000")
        XCTAssertEqual(GuangYaLogin.normalize("a@b.com"), "a@b.com")
        XCTAssertEqual(GuangYaLogin.meta(for: "+86 13800138000")["phone_number"] as? String, "+86 13800138000")
        XCTAssertEqual(GuangYaLogin.meta(for: "a@b.com")["email"] as? String, "a@b.com")
        let id = String(repeating: "c", count: 32)
        let headers = Dictionary(GuangYaLogin.accountHeaders((id, "wdi10." + String(repeating: "d", count: 32) + "eeee")), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(headers["X-Device-Id"], String(repeating: "d", count: 32))
        XCTAssertEqual(headers["X-Client-Id"], GuangYaLogin.clientId)
        XCTAssertTrue(GuangYaLogin.isSuccess(JSON(["access_token": "x"])))
        XCTAssertFalse(GuangYaLogin.isSuccess(JSON(["error": "invalid_grant"])))
        XCTAssertEqual(GuangYaLogin.signinError(JSON(["error": "invalid_password"])), "光鸭账号或密码不正确，请检查后重试")
    }

    func testXunleiAppCredential() throws {
        let cred = XunleiCredential(accessToken: "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJlLXZhbHVl", refreshToken: "a1.refresh-token-0123456789abcdef", deviceId: "d", source: "app")
        XCTAssertEqual(XunleiCredential.parse(cred.serialized)?.source, "app")
        let device = XunleiLogin.Device(id: String(repeating: "0", count: 32), peer: "p")
        XCTAssertTrue(device.sign.hasPrefix("div101." + device.id))
        XCTAssertEqual(device.sign.count, "div101.".count + 32 + 32)
    }

    func testILanzouCredentialAndTransferBody() {
        let cred = ILanzouCredential(appToken: "token-0123456789abcdef", uuid: "uuid-123456", userId: "42")
        XCTAssertEqual(ILanzouCredential.parse(cred.serialized), cred)
        XCTAssertNil(ILanzouCredential.parse("{}"))
        let files = [ShareFile(fid: "f:11", name: "a.txt", size: 1, isDirectory: false), ShareFile(fid: "f:12", name: "b.txt", size: 1, isDirectory: false),
                     ShareFile(fid: "d:7", name: "dir", size: 0, isDirectory: true)]
        XCTAssertEqual(ILanzouResolver.transferBody(shareId: "S1", files: files, to: "d:99").text,
                       #"{"targetFileId":"11,12","targetFolderId":"7","folderId":"99","shareId":"S1"}"#)
        XCTAssertEqual(ILanzouResolver.transferBody(shareId: "S1", files: [], to: "").text,
                       #"{"targetFileId":"","targetFolderId":"","folderId":"0","shareId":"S1"}"#)
    }

    func testLanzouCookie() {
        XCTAssertTrue(LanzouAccount.isValidCookie("ylogin=1; phpdisk_info=abc"))
        XCTAssertFalse(LanzouAccount.isValidCookie("PHPSESSID=1"))
        var jar = LanzouLogin.CookieJar()
        jar.set("pc.woozooo.com", "ylogin", "1")
        jar.set("pc.woozooo.com", "phpdisk_info", "x")
        XCTAssertEqual(jar.cookieString(host: "pc.woozooo.com"), "phpdisk_info=x; ylogin=1")
        XCTAssertEqual(jar.header(for: "https://accounts.woozooo.com/x").count, 0)
    }
}
