import XCTest
@testable import CloudnKit

/// Dropbox：分享链接识别、凭据格式、请求参数与响应解析（不联网）
final class DropboxTests: XCTestCase {
    private struct Creds: CredentialStore {
        let value: String?
        func cookie(for kind: AccountKind) async -> String? { kind == .dropbox ? value : nil }
        func updateCookie(_ new: String, replacing old: String, for kind: AccountKind) async {}
    }

    func testShareLinkRecognition() throws {
        let file = try XCTUnwrap(DropboxResolver.parseLink("https://www.dropbox.com/scl/fi/abc123xyz/%E6%8A%A5%E5%91%8A.pdf?rlkey=k1k2k3&st=s9&dl=0"))
        XCTAssertEqual(file.url, "https://www.dropbox.com/scl/fi/abc123xyz/%E6%8A%A5%E5%91%8A.pdf?rlkey=k1k2k3&st=s9")
        XCTAssertFalse(file.isFolder)
        XCTAssertEqual(file.name, "报告.pdf")

        let folder = try XCTUnwrap(DropboxResolver.parseLink("https://www.dropbox.com/scl/fo/f0lder1d/AAbbCC?rlkey=xyz&dl=0"))
        XCTAssertTrue(folder.isFolder)
        XCTAssertNil(folder.name)
        XCTAssertEqual(folder.url, "https://www.dropbox.com/scl/fo/f0lder1d/AAbbCC?rlkey=xyz")

        let old = try XCTUnwrap(DropboxResolver.parseLink("https://www.dropbox.com/s/q1w2e3r4/movie.mp4?dl=0"))
        XCTAssertEqual(old.url, "https://www.dropbox.com/s/q1w2e3r4/movie.mp4")
        XCTAssertEqual(old.name, "movie.mp4")
        XCTAssertTrue(try XCTUnwrap(DropboxResolver.parseLink("https://www.dropbox.com/sh/abcd1234/AADxyz?dl=0")).isFolder)

        let content = try XCTUnwrap(DropboxResolver.parseLink("https://dl.dropboxusercontent.com/s/q1w2e3r4/movie.mp4"))
        XCTAssertEqual(content.url, "https://www.dropbox.com/s/q1w2e3r4/movie.mp4")
        XCTAssertNotNil(DropboxResolver.parseLink("https://dropbox.com/scl/fi/a1/b.txt?rlkey=r"))

        XCTAssertNil(DropboxResolver.parseLink("https://www.dropbox.com/home/Documents"))
        XCTAssertNil(DropboxResolver.parseLink("https://example.com/s/abc/file"))

        XCTAssertEqual(DropboxResolver.directURL("https://www.dropbox.com/s/q1/m.mp4"), "https://www.dropbox.com/s/q1/m.mp4?dl=1")
        XCTAssertEqual(DropboxResolver.directURL("https://www.dropbox.com/scl/fo/a/b?rlkey=x"), "https://www.dropbox.com/scl/fo/a/b?rlkey=x&dl=1")
    }

    func testShareLinkParserRoutesToDropbox() throws {
        let parsed = try XCTUnwrap(ShareLinkParser.parse("看看这个 https://www.dropbox.com/scl/fi/abc/x.zip?rlkey=r1&dl=0 。"))
        XCTAssertEqual(parsed.platform, .dropbox)
        XCTAssertEqual(parsed.shareId, "https://www.dropbox.com/scl/fi/abc/x.zip?rlkey=r1")
        XCTAssertNil(parsed.pwd)
    }

    func testCredentialFormats() throws {
        let oauth = OAuthCredential(refreshToken: "r", accessToken: "a", expiresAt: 4_000_000_000, name: "")
        XCTAssertEqual(DropboxResolver.parseCredential(oauth.serialized), oauth)

        let bare = "sl.BxYz-abc_DEF123456789.ghiJKL"
        let normalized = DropboxResolver.normalizeCredential("  Bearer \(bare) ")
        let cred = try XCTUnwrap(DropboxResolver.parseCredential(normalized))
        XCTAssertEqual(cred.accessToken, bare)
        XCTAssertEqual(cred.refreshToken, "")
        XCTAssertEqual(AccountValidator.normalize(.dropbox, bare), normalized)

        // 令牌接口的原始响应（expires_in）
        let raw = try XCTUnwrap(DropboxResolver.parseCredential(#"{"access_token":"sl.tok","expires_in":14400,"token_type":"bearer"}"#))
        XCTAssertEqual(raw.accessToken, "sl.tok")
        XCTAssertGreaterThan(raw.expiresAt, Int64(Date().timeIntervalSince1970))

        XCTAssertNil(DropboxResolver.parseCredential("not a token"))
        XCTAssertNil(DropboxResolver.parseCredential(#"{"foo":1}"#))
    }

    func testAccessTokenWithoutRefresh() async throws {
        let resolver = DropboxResolver(credentials: Creds(value: DropboxResolver.normalizeCredential("sl.abcdefghijklmnopqrstuvwxyz")))
        let token = try await resolver.accessToken()
        XCTAssertEqual(token, "sl.abcdefghijklmnopqrstuvwxyz")
        do {
            _ = try await resolver.accessToken(rejecting: "sl.abcdefghijklmnopqrstuvwxyz")
            XCTFail("被拒的令牌没法续期，应提示重新登录")
        } catch let error as CloudnError {
            XCTAssertEqual(error.code, 401)
        }
        let none = try await DropboxResolver(credentials: Creds(value: nil)).accessToken()
        XCTAssertNil(none)
    }

    func testApiArgEscapesNonASCII() throws {
        let arg = DropboxResolver.apiArg(["path": "/文档/a b.txt"])
        XCTAssertTrue(arg.unicodeScalars.allSatisfy { $0.isASCII })
        XCTAssertTrue(arg.contains("\\u6587\\u6863"))
        let decoded = try XCTUnwrap(JSON(text: arg))
        XCTAssertEqual(decoded["path"].string, "/文档/a b.txt")
        // 补充平面字符用代理对
        let emoji = DropboxResolver.apiArg(["path": "/😀"])
        XCTAssertEqual(JSON(text: emoji)?["path"].string, "/😀")
    }

    func testErrorMapping() {
        func err(_ status: Int, _ summary: String) -> String {
            DropboxResolver.apiError(status, JSON(["error_summary": summary, "error": [".tag": "x"]])).message
        }
        XCTAssertEqual(DropboxResolver.apiError(401, nil).code, 401)
        XCTAssertEqual(err(409, "shared_link_not_found/.."), "Dropbox 分享不存在或已失效")
        XCTAssertEqual(err(409, "shared_link_access_denied/..."), "无法访问这个 Dropbox 分享：可能需要密码，或仅限指定的人访问")
        XCTAssertEqual(err(409, "path/not_found/.."), "文件不存在或已被删除")
        XCTAssertEqual(err(409, "path/conflict/folder/..."), "目标位置已有同名文件或文件夹")
        XCTAssertEqual(err(409, "path/insufficient_space/.."), "Dropbox 空间不足")
        XCTAssertEqual(err(409, "settings_error/not_authorized/.."), "设置分享密码或有效期需要 Dropbox 付费账号")
        XCTAssertEqual(err(429, ""), "Dropbox 请求太频繁，请稍后再试")
        XCTAssertTrue(DropboxResolver.apiError(400, nil, text: "Error in call to API function").message.contains("Error in call"))
    }

    func testEntryParsingAndPaths() throws {
        let file = try XCTUnwrap(DropboxResolver.parseEntry(JSON([".tag": "file", "name": "a.mp4", "path_display": "/Videos/a.mp4", "id": "id:AAA",
                                                                  "size": 1234, "server_modified": "2024-01-02T03:04:05Z"]), parent: "/Videos"))
        XCTAssertEqual(file.fid, "/Videos/a.mp4")
        XCTAssertEqual(file.token, "id:AAA")
        XCTAssertEqual(file.size, 1234)
        XCTAssertFalse(file.isDirectory)
        XCTAssertFalse(file.modified.isEmpty)

        // 分享链接里的条目没有 path_display：用相对分享根目录的路径
        let folder = try XCTUnwrap(DropboxResolver.parseEntry(JSON([".tag": "folder", "name": "子目录", "id": "id:B"]), parent: ""))
        XCTAssertEqual(folder.fid, "/子目录")
        XCTAssertTrue(folder.isDirectory)
        XCTAssertNil(DropboxResolver.parseEntry(JSON([".tag": "deleted", "name": "x"]), parent: ""))

        XCTAssertEqual(DropboxResolver.join("", "a"), "/a")
        XCTAssertEqual(DropboxResolver.join("/x/", "a"), "/x/a")
        XCTAssertEqual(DropboxResolver.parentPath("/a/b/c.txt"), "/a/b")
        XCTAssertEqual(DropboxResolver.parentPath("/c.txt"), "")
        XCTAssertEqual(DropboxResolver.moveBody(from: "/a.txt", to: "/b/a.txt")["to_path"] as? String, "/b/a.txt")
    }

    func testQuotaAndShares() throws {
        let quota = DropboxResolver.parseQuota(JSON(["used": 100, "allocation": [".tag": "individual", "allocated": 2_147_483_648]]))
        XCTAssertEqual(quota, DriveQuota(used: 100, total: 2_147_483_648))
        XCTAssertNil(DropboxResolver.parseQuota(JSON(["used": 1])))

        let exists = JSON(["error_summary": "shared_link_already_exists/metadata/..",
                           "error": [".tag": "shared_link_already_exists",
                                     "shared_link_already_exists": [".tag": "metadata", "metadata": [".tag": "file", "url": "https://www.dropbox.com/scl/fi/x"]]]])
        XCTAssertEqual(DropboxResolver.existingLink(exists), "https://www.dropbox.com/scl/fi/x")
        XCTAssertEqual(DropboxResolver.existingLink(JSON(["error_summary": "shared_link_already_exists/..", "error": [".tag": "shared_link_already_exists"]])), "")
        XCTAssertNil(DropboxResolver.existingLink(JSON(["error_summary": "path/not_found/.."])))

        let plain = DropboxResolver.shareSettings(ShareOptions())
        XCTAssertEqual(plain["requested_visibility"] as? String, "public")
        XCTAssertNil(plain["expires"])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let custom = DropboxResolver.shareSettings(ShareOptions(expiry: ShareExpiry(days: 7), password: "1234"), now: now)
        XCTAssertEqual(custom["requested_visibility"] as? String, "password")
        XCTAssertEqual(custom["link_password"] as? String, "1234")
        XCTAssertEqual(custom["expires"] as? String, "2023-11-21T22:13:20Z")

        let info = try XCTUnwrap(DropboxResolver.parseShareInfo(JSON(["url": "https://www.dropbox.com/scl/fi/x", "expires": "2030-01-01T00:00:00Z",
                                                                      "link_permissions": ["resolved_visibility": [".tag": "password"]]])))
        XCTAssertTrue(info.hasPassword)
        XCTAssertEqual(info.id, "https://www.dropbox.com/scl/fi/x")
        XCTAssertFalse(info.expires.isEmpty)
    }

    func testOfflineHelpers() {
        XCTAssertEqual(DropboxResolver.offlineName("https://example.com/files/%E8%A7%86%E9%A2%91.mp4?x=1"), "视频.mp4")
        XCTAssertTrue(DropboxResolver.offlineName("https://example.com/").hasPrefix("download-"))
        XCTAssertEqual(DropboxResolver.jobState(JSON([".tag": "in_progress"])).0, .running)
        let done = DropboxResolver.jobState(JSON([".tag": "complete", "size": 42, "name": "a"]))
        XCTAssertEqual(done.0, .done)
        XCTAssertEqual(done.1, 42)
        XCTAssertEqual(DropboxResolver.jobState(JSON([".tag": "failed", "failed": [".tag": "download_failed"]])).0, .failed("下载失败（源站无法访问）"))
        XCTAssertEqual(DropboxResolver.correctOffset(JSON(["error": [".tag": "incorrect_offset", "correct_offset": 8388608]])), 8388608)
        XCTAssertEqual(DropboxResolver.correctOffset(JSON(["error": [".tag": "lookup_failed", "lookup_failed": [".tag": "incorrect_offset", "correct_offset": 5]]])), 5)
        XCTAssertNil(DropboxResolver.correctOffset(JSON(["error": [".tag": "not_found"]])))

        let resolver = DropboxResolver()
        XCTAssertTrue(resolver.acceptsOffline("https://example.com/a.zip"))
        XCTAssertFalse(resolver.acceptsOffline("magnet:?xt=urn:btih:abc"))
        XCTAssertTrue(resolver.supportsGuestDownload)
        XCTAssertEqual(resolver.driveRootId, "")
    }

    func testSharedLinkDownloadRequest() async throws {
        let resolver = DropboxResolver(credentials: Creds(value: DropboxResolver.normalizeCredential("sl.abcdefghijklmnopqrstuvwxyz")))
        let session = ShareSession(platform: .dropbox, shareId: "https://www.dropbox.com/scl/fo/a/b?rlkey=x", stoken: "pw", title: "t", rootId: "")
        let file = ShareFile(fid: "/子/c.txt", name: "c.txt", size: 9, isDirectory: false, parentId: "/子")
        let link = try await resolver.downloadLink(session, file: file)
        XCTAssertEqual(link.url, "https://content.dropboxapi.com/2/sharing/get_shared_link_file")
        XCTAssertEqual(link.headers["Authorization"], "Bearer sl.abcdefghijklmnopqrstuvwxyz")
        let arg = try XCTUnwrap(JSON(text: link.headers["Dropbox-API-Arg"] ?? ""))
        XCTAssertEqual(arg["url"].string, session.shareId)
        XCTAssertEqual(arg["path"].string, "/子/c.txt")
        XCTAssertEqual(arg["link_password"].string, "pw")

        // 免登录条目：token 即 dl=1 直链
        let direct = ShareFile(fid: DropboxResolver.rootFileId, name: "m.mp4", size: 5, isDirectory: false, token: "https://www.dropbox.com/s/q/m.mp4?dl=1")
        let anon = try await DropboxResolver().downloadLink(session, file: direct)
        XCTAssertEqual(anon.url, "https://www.dropbox.com/s/q/m.mp4?dl=1")

        XCTAssertEqual(DropboxResolver.sharedLinkArg(session)["password"] as? String, "pw")
        XCTAssertNil(DropboxResolver.sharedFileArg(session, path: nil)["path"])
    }

    func testAnonymousErrors() {
        func response(_ status: Int, type: String, url: String = "https://www.dropbox.com/s/x", body: String = "") -> HTTPResponse {
            HTTPResponse(status: status, headers: ["content-type": type], cookies: [], body: Data(body.utf8), url: url)
        }
        XCTAssertNil(DropboxResolver.anonymousError(response(206, type: "video/mp4")))
        XCTAssertEqual(DropboxResolver.anonymousError(response(404, type: "text/html"))?.message, "Dropbox 分享不存在或已失效")
        XCTAssertNotNil(DropboxResolver.anonymousError(response(200, type: "text/html; charset=utf-8")))
        XCTAssertTrue(DropboxResolver.anonymousError(response(200, type: "text/html", url: "https://www.dropbox.com/sm/password?cont=x"))?.message.contains("密码") ?? false)
    }

    func testOAuthProviderDisabledWithoutAppKey() {
        XCTAssertEqual(OAuthProvider.dropboxAppKey, "")
        XCTAssertNil(OAuthProvider.dropbox)
    }
}
