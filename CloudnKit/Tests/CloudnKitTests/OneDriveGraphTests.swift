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

/// Google 云端硬盘「我的网盘」：OAuth 配置、Drive API 数据解析（不联网）
final class GoogleDriveAPITests: XCTestCase {
    func testGoogleAuthorizeRequest() throws {
        let provider = OAuthProvider.google
        XCTAssertEqual(provider.callbackScheme, "com.googleusercontent.apps.150941028615-uchr3htd2p0cg83gcpbhdja5fa3bb942")
        let request = provider.makeRequest()
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(value("access_type"), "offline")
        XCTAssertEqual(value("scope"), "https://www.googleapis.com/auth/drive")
        XCTAssertEqual(value("redirect_uri"), "com.googleusercontent.apps.150941028615-uchr3htd2p0cg83gcpbhdja5fa3bb942:/oauth2redirect")
        let callback = URL(string: "com.googleusercontent.apps.150941028615-uchr3htd2p0cg83gcpbhdja5fa3bb942:/oauth2redirect?state=\(request.state)&code=4/0Ab&scope=x")!
        XCTAssertEqual(try provider.code(from: callback, request: request), "4/0Ab")
    }

    func testParseFiles() {
        let doc = GoogleDriveResolver.parseAPIFile(JSON(text: #"{"id":"d","name":"周报","mimeType":"application/vnd.google-apps.document","modifiedTime":"2026-10-01T02:03:04.000Z"}"#)!, parent: "")
        XCTAssertEqual(doc.name, "周报.docx")
        XCTAssertFalse(doc.isDirectory)
        XCTAssertEqual(GoogleDriveResolver.docKind(mime: doc.token), "document")
        let folder = GoogleDriveResolver.parseAPIFile(JSON(text: #"{"id":"f","name":"资料","mimeType":"application/vnd.google-apps.folder"}"#)!, parent: "x")
        XCTAssertTrue(folder.isDirectory)
        let file = GoogleDriveResolver.parseAPIFile(JSON(text: #"{"id":"v","name":"a.mp4","mimeType":"video/mp4","size":"12345"}"#)!, parent: "")
        XCTAssertEqual(file.size, 12345)
        XCTAssertEqual(GoogleDriveResolver.listQuery(""), "'root' in parents and trashed = false")
        XCTAssertEqual(GoogleDriveResolver.uploadChunk % (256 * 1024), 0)
    }

    func testParsePermissions() {
        let anyone = GoogleDriveResolver.parseShareInfo(JSON(text: #"{"id":"anyoneWithLink","type":"anyone","role":"reader"}"#)!, url: "https://drive.google.com/file/d/x/view")
        XCTAssertEqual(anyone?.audience, "知道链接的任何人")
        XCTAssertEqual(anyone?.role, "仅查看")
        let user = GoogleDriveResolver.parseShareInfo(JSON(text: #"{"id":"1","type":"user","role":"writer","emailAddress":"a@b.com"}"#)!, url: "")
        XCTAssertEqual(user?.audience, "a@b.com")
        XCTAssertEqual(user?.role, "可编辑")
        XCTAssertNil(GoogleDriveResolver.parseShareInfo(JSON(text: #"{"id":"2","type":"user","role":"owner"}"#)!, url: ""))
        let resolvers = ShareResolvers(credentials: NoCredentials())
        XCTAssertNotNil(resolvers.manager(for: .gdrive))
        XCTAssertNotNil(resolvers.saver(for: .gdrive))
        XCTAssertNotNil(resolvers.uploader(for: .gdrive))
        XCTAssertTrue(AccountKind.gdrive.isDrive)
    }
}
