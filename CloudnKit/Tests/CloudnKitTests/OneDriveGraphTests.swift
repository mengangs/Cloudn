import XCTest
@testable import CloudnKit

/// OneDrive「我的网盘」：OAuth（PKCE）、分享请求体与已有分享解析（不联网）
final class OneDriveGraphTests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636() {
        XCTAssertEqual(OAuthProvider.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(OAuthProvider.randomString(64).count, 64)
    }

    func testAuthorizeRequestAndCallback() throws {
        let provider = OAuthProvider.microsoft
        let request = provider.makeRequest()
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(value("client_id"), "f6a6cccb-4eb1-476c-89fa-c3ce80650d62")
        XCTAssertEqual(value("redirect_uri"), "cloudn://oauth/microsoft")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), OAuthProvider.challenge(for: request.verifier))
        XCTAssertEqual(value("scope"), "Files.ReadWrite.All offline_access User.Read")
        XCTAssertEqual(provider.callbackScheme, "cloudn")

        let ok = URL(string: "cloudn://oauth/microsoft?code=M.abc&state=\(request.state)")!
        XCTAssertEqual(try provider.code(from: ok, request: request), "M.abc")
        let forged = URL(string: "cloudn://oauth/microsoft?code=M.abc&state=other")!
        XCTAssertThrowsError(try provider.code(from: forged, request: request))
        let denied = URL(string: "cloudn://oauth/microsoft?error=access_denied&state=\(request.state)")!
        XCTAssertThrowsError(try provider.code(from: denied, request: request)) { XCTAssertEqual($0.localizedDescription, "已取消授权") }
    }

    func testCredentialRoundTrip() throws {
        let cred = OAuthCredential(refreshToken: "r", accessToken: "a", expiresAt: 4_000_000_000, name: "张三")
        XCTAssertEqual(OAuthCredential.parse(cred.serialized), cred)
        XCTAssertTrue(cred.isFresh)
        XCTAssertNil(OAuthCredential.parse(#"{"access_token":"a"}"#))
        XCTAssertEqual(AccountValidator.normalize(.onedrive, " \(cred.serialized) "), cred.serialized)
        XCTAssertEqual(SharePlatform.onedrive.accountKind, .onedrive)
        XCTAssertTrue(AccountKind.onedrive.isDrive)
    }

    func testLinkBody() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plain = OneDriveResolver.linkBody(ShareOptions(), now: now)
        XCTAssertEqual(plain["type"] as? String, "view")
        XCTAssertEqual(plain["scope"] as? String, "anonymous")
        XCTAssertNil(plain["password"])
        XCTAssertNil(plain["expirationDateTime"])
        let full = OneDriveResolver.linkBody(ShareOptions(audience: .organization, role: .edit, expiry: ShareExpiry(days: 7), password: "p@ss"), now: now)
        XCTAssertEqual(full["type"] as? String, "edit")
        XCTAssertEqual(full["scope"] as? String, "organization")
        XCTAssertEqual(full["password"] as? String, "p@ss")
        XCTAssertEqual(full["expirationDateTime"] as? String, "2027-01-22T08:00:00Z")
    }

    func testParseShareInfo() throws {
        let json = JSON(text: """
        {"value":[
          {"id":"p1","roles":["read"],"hasPassword":true,"expirationDateTime":"2026-11-01T00:00:00Z",
           "link":{"type":"view","scope":"anonymous","webUrl":"https://1drv.ms/u/c/abc/xyz"}},
          {"id":"p2","roles":["write"],"link":{"type":"edit","scope":"organization","webUrl":"https://contoso-my.sharepoint.com/:u:/g/x"}},
          {"id":"owner","roles":["owner"],"grantedTo":{"user":{"displayName":"我"}}}
        ]}
        """)!
        let shares = json["value"].array.compactMap(OneDriveResolver.parseShareInfo)
        XCTAssertEqual(shares.map(\.id), ["p1", "p2"])
        XCTAssertEqual(shares[0].audience, "知道链接的任何人")
        XCTAssertEqual(shares[0].role, "仅查看")
        XCTAssertTrue(shares[0].hasPassword)
        XCTAssertFalse(shares[0].expires.isEmpty)
        XCTAssertEqual(shares[1].audience, "仅组织内的人")
        XCTAssertEqual(shares[1].role, "可编辑")
        XCTAssertEqual(shares[1].expires, "")
    }

    func testGraphItemAndPaths() {
        XCTAssertEqual(OneDriveResolver.itemPath(""), "/me/drive/root")
        XCTAssertEqual(OneDriveResolver.itemPath("ABC!12"), "/me/drive/items/ABC!12")
        let f = OneDriveResolver.parseGraphItem(JSON(text: #"{"id":"1","name":"a","folder":{"childCount":2},"parentReference":{"driveId":"d"}}"#)!, parent: "")
        XCTAssertTrue(f.isDirectory)
        XCTAssertEqual(f.token, "d")
        XCTAssertEqual(OneDriveResolver.uploadChunk % (320 * 1024), 0)
        let resolvers = ShareResolvers(credentials: NoCredentials())
        XCTAssertNotNil(resolvers.manager(for: .onedrive))
        XCTAssertNotNil(resolvers.uploader(for: .onedrive))
    }
}
