import XCTest
@testable import CloudnKit

actor MemoryCredentials: CredentialStore {
    var cookies: [AccountKind: String] = [:]
    func cookie(for kind: AccountKind) async -> String? { cookies[kind] }
    func updateCookie(_ new: String, replacing old: String, for kind: AccountKind) async {
        if cookies[kind] == old { cookies[kind] = new }
    }
    func set(_ kind: AccountKind, _ c: String?) { cookies[kind] = c }
}

final class QuarkFamilyTests: XCTestCase {
    func makeConfig(_ server: String) -> QuarkFamilyConfig {
        let q = QuarkFamilyConfig.quark
        return QuarkFamilyConfig(platform: .quark, account: .quark, apiBase: server, prQuery: q.prQuery, apiUA: q.apiUA,
                                 guestUA: q.guestUA, guestSecChUa: nil, webOrigin: q.webOrigin, tokenExtra: q.tokenExtra,
                                 listing: .sharepageDetail, pageSize: 100, downloadURL: "\(server)/1/clouddrive/file/download?pr=ucpro",
                                 downloadOrigin: false, transferFallback: false, accountInfoURL: "\(server)/account/info")
    }

    func testGuestAndLoginFlow() async throws {
        guard let server = ProcessInfo.processInfo.environment["CLOUDN_TEST_SERVER"] else { throw XCTSkip("未设置 CLOUDN_TEST_SERVER") }
        let creds = MemoryCredentials()
        let resolver = QuarkFamilyResolver(config: makeConfig(server), credentials: creds)
        let share = ShareLinkParser.parse("https://pan.quark.cn/s/abc 提取码：abcd")!

        do {
            _ = try await resolver.openSession(share, pwd: "zzzz")
            XCTFail("错误提取码应失败")
        } catch let e as CloudnError {
            XCTAssertEqual(e.message, "提取码错误")
        }

        let session = try await resolver.openSession(share, pwd: nil)
        XCTAssertEqual(session.title, "测试分享")
        let files = try await resolver.list(session, dirId: "0")
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[1].token, "tok1")

        let guest = try await resolver.downloadLink(session, file: files[1])
        XCTAssertEqual(guest.url, "https://cdn/guest")
        XCTAssertEqual(guest.headers["Cookie"], "__pugs=guest123")
        XCTAssertEqual(guest.headers["Referer"], "https://pan.quark.cn/")

        await creds.set(.quark, "__pus=p1; __puus=old")
        let login = try await resolver.downloadLink(session, file: files[1])
        XCTAssertEqual(login.url, "https://cdn/login")
        // 服务端续期的 __puus 已回写账号，且直链请求头用的是续期后的 Cookie
        let saved = await creds.cookie(for: .quark)
        XCTAssertEqual(saved, "__pus=p1; __puus=renewed")
        XCTAssertEqual(login.headers["Cookie"], "__pus=p1; __puus=renewed")
    }
}
