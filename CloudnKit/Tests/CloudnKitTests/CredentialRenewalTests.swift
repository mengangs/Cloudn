import XCTest
@testable import CloudnKit

/// 凭据续期合并、OAuth 令牌复用、Google / OneDrive 错误与续传偏移等（不联网）
final class CredentialRenewalTests: XCTestCase {
    private actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    private actor MemoryStore: CredentialStore {
        var stored: [AccountKind: String]
        init(_ stored: [AccountKind: String]) { self.stored = stored }
        func cookie(for kind: AccountKind) async -> String? { stored[kind] }
        func updateCookie(_ new: String, replacing old: String, for kind: AccountKind) async {
            if stored[kind] == old { stored[kind] = new }
        }
    }

    func testConcurrentRenewalsRunOnce() async throws {
        let renewal = CredentialRenewal()
        let counter = Counter()
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await renewal.renew(.aliyun, raw: "old") {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        return "new-\(await counter.next())"
                    }
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(results), ["new-1"])
        // 续期完成后才拿着旧凭据来的请求：直接用刚才的结果，不再用作废的旧令牌
        let late = try await renewal.renew(.aliyun, raw: "old") { "new-\(await counter.next())" }
        XCTAssertEqual(late, "new-1")
        // 不同平台 / 不同凭据各自续期
        let other = try await renewal.renew(.xunlei, raw: "old") { "new-\(await counter.next())" }
        XCTAssertEqual(other, "new-2")
    }

    func testFailedRenewalIsNotCached() async throws {
        let renewal = CredentialRenewal()
        do {
            _ = try await renewal.renew(.gdrive, raw: "r") { throw CloudnError("boom") }
            XCTFail("应当抛出")
        } catch {}
        let value = try await renewal.renew(.gdrive, raw: "r") { "ok" }
        XCTAssertEqual(value, "ok")
    }

    func testValidatedRenewalHandoff() async {
        let renewal = CredentialRenewal()
        await renewal.recordValidated(.aliyun, consumedRefreshToken: "r0", renewed: "{\"refresh_token\":\"r1\"}")
        let hit = await renewal.validatedRenewal(.aliyun, refreshToken: "r0")
        let missOther = await renewal.validatedRenewal(.guangya, refreshToken: "r0")
        XCTAssertEqual(hit, "{\"refresh_token\":\"r1\"}")
        XCTAssertNil(missOther)
    }

    func testOAuthAccessTokenReusesStoredTokenWithoutNetwork() async throws {
        let expires = Int64(Date().timeIntervalSince1970) + 3600
        let cred = OAuthCredential(refreshToken: "rt", accessToken: "at-2", expiresAt: expires, name: "")
        let store = MemoryStore([.gdrive: cred.serialized])
        // 没过期：直接用
        let fresh = try await OAuthCredential.accessToken(.gdrive, provider: .google, credentials: store, client: .shared)
        XCTAssertEqual(fresh, "at-2")
        // 被拒的是旧令牌、保存的已是别的请求续期后的新令牌：直接用新的，不再续期
        let reused = try await OAuthCredential.accessToken(.gdrive, provider: .google, credentials: store, client: .shared, rejecting: "at-1")
        XCTAssertEqual(reused, "at-2")
        // 没登录
        let none = try await OAuthCredential.accessToken(.onedrive, provider: .microsoft, credentials: store, client: .shared)
        XCTAssertNil(none)
    }

    func testOAuthErrorBrief() {
        let ms = "AADSTS70008: The provided authorization code or refresh token has expired.\r\nTrace ID: abc\r\nCorrelation ID: def"
        XCTAssertEqual(OAuthProvider.brief(ms), "AADSTS70008: The provided authorization code or refresh token has expired.")
        XCTAssertEqual(OAuthProvider.brief("bad request Trace ID: 123"), "bad request")
        XCTAssertEqual(OAuthProvider.brief(String(repeating: "x", count: 200)).count, 121)
        XCTAssertEqual(OAuthProvider.brief(""), "")
    }

    func testGoogleResumeOffset() {
        XCTAssertEqual(GoogleDriveResolver.resumeOffset("bytes=0-10485759"), 10_485_760)
        XCTAssertEqual(GoogleDriveResolver.resumeOffset("bytes=0-4095"), 4096)
        XCTAssertEqual(GoogleDriveResolver.resumeOffset(nil), 0)
        XCTAssertEqual(GoogleDriveResolver.resumeOffset("garbage"), 0)
    }

    func testGoogleListURLEncodesQuery() throws {
        let url = GoogleDriveResolver.listURL(query: GoogleDriveResolver.listQuery("abc"), orderBy: "folder,name", pageToken: "a+b/c=")
        let items = URLComponents(string: url)?.queryItems ?? []
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(value("q"), "'abc' in parents and trashed = false")
        XCTAssertEqual(value("pageToken"), "a+b/c=")
        XCTAssertTrue(url.contains("pageToken=a%2Bb"), url)
        XCTAssertFalse(GoogleDriveResolver.listURL(query: "x", orderBy: "name", pageToken: "").contains("pageToken"))
    }

    private func response(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], cookies: [], body: Data(body.utf8), url: "https://example.com")
    }

    func testGoogleAPIErrorMapping() {
        func message(_ status: Int, reason: String, _ text: String = "English text") -> String {
            GoogleDriveResolver.apiError(response(status, #"{"error":{"message":"\#(text)","errors":[{"reason":"\#(reason)"}]}}"#)).message
        }
        XCTAssertEqual(message(401, reason: "authError"), "Google 云端硬盘登录已失效，请到「我的」页重新登录")
        XCTAssertEqual(message(403, reason: "insufficientFilePermissions"), "没有权限进行这个操作")
        XCTAssertEqual(message(403, reason: "cannotDeletePermission", "Cannot delete an inherited permission."),
                       GoogleDriveResolver.inheritedShareError.message)
        XCTAssertEqual(message(429, reason: ""), "Google 请求太频繁，请稍后再试")
        XCTAssertEqual(message(503, reason: "backendError"), "Google 云端硬盘暂时不可用（HTTP 503），请稍后重试")
        XCTAssertEqual(message(400, reason: "badRequest", "Invalid value"), "Google 云端硬盘：Invalid value")
    }

    func testGraphErrorMapping() {
        func error(_ status: Int, code: String) -> CloudnError {
            OneDriveResolver.graphError(response(status, #"{"error":{"code":"\#(code)","message":"English"}}"#))
        }
        XCTAssertEqual(error(403, code: "accessDenied").code, 403)
        XCTAssertEqual(error(429, code: "activityLimitReached").message, "OneDrive 请求太频繁，请稍后再试")
        XCTAssertEqual(error(507, code: "insufficientStorage").message, "OneDrive 空间不足")
        XCTAssertEqual(error(502, code: "").message, "OneDrive 暂时不可用（HTTP 502），请稍后重试")
        XCTAssertEqual(error(409, code: "nameAlreadyExists").message, "已有同名的文件或文件夹")
    }

    func testNetworkErrorText() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(HTTPError.from(timeout).errorDescription, "网络请求失败：请求超时")
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(HTTPError.from(offline).errorDescription, "网络请求失败：网络未连接")
    }

    func testSingleStreamEndedEarly() {
        XCTAssertTrue(RangeTransfer.endedEarly(received: 10, total: 100))
        XCTAssertFalse(RangeTransfer.endedEarly(received: 100, total: 100))
        // 总长未知（-1）或压缩传输收到的比探测长度多：不算提前断开
        XCTAssertFalse(RangeTransfer.endedEarly(received: 10, total: -1))
        XCTAssertFalse(RangeTransfer.endedEarly(received: 150, total: 100))
    }
}
