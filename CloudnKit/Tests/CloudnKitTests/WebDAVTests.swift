import XCTest
@testable import CloudnKit

final class WebDAVTests: XCTestCase {
    private let jianguo = WebDAVCredential(url: "https://dav.jianguoyun.com/dav/", username: "me@example.com", password: "app-pass")

    // MARK: 凭据

    func testMakeCredentialAndNormalize() throws {
        let raw = WebDAVResolver.makeCredential(url: " dav.jianguoyun.com/dav ", username: " me@example.com ", password: "p w")
        let cred = try XCTUnwrap(WebDAVCredential.parse(raw))
        XCTAssertEqual(cred.url, "https://dav.jianguoyun.com/dav/")
        XCTAssertEqual(cred.username, "me@example.com")
        XCTAssertEqual(cred.password, "p w")
        XCTAssertEqual(WebDAVResolver.normalizeCredential(raw), raw)
        XCTAssertEqual(WebDAVResolver.displayHost(raw), "dav.jianguoyun.com")
        XCTAssertEqual(cred.authorization, "Basic " + Data("me@example.com:p w".utf8).base64EncodedString())

        XCTAssertEqual(WebDAVCredential.normalizeURL("http://192.168.1.2:5005"), "http://192.168.1.2:5005/")
        XCTAssertEqual(WebDAVCredential.normalizeURL("https://nas.local:5006/dav?x=1"), "https://nas.local:5006/dav/")
        XCTAssertEqual(WebDAVResolver.displayHost(WebDAVResolver.makeCredential(url: "http://192.168.1.2:5005", username: "", password: "")),
                       "192.168.1.2:5005")
        XCTAssertNil(WebDAVCredential(url: "https://h/", username: "", password: "").authorization)
        // 兼容别名，规范化后统一成 url / username / password
        XCTAssertEqual(WebDAVResolver.normalizeCredential(#"{"address":"https://alist.example.com/dav","user":"u","pass":"p"}"#),
                       #"{"url":"https://alist.example.com/dav/","username":"u","password":"p"}"#)
        XCTAssertNil(WebDAVCredential.parse("cookie=1"))
        XCTAssertNil(WebDAVCredential.parse(#"{"url":"ftp://x/"}"#))
        XCTAssertEqual(WebDAVCredential.normalizeURL("davs://nas/dav"), "https://nas/dav/")
        XCTAssertNil(WebDAVResolver.shareTarget("https://dav.jianguoyun.com/dav/a"))
    }

    // MARK: 路径

    func testResourceURLEncoding() {
        XCTAssertEqual(WebDAVResolver.resourceURL(jianguo, path: "/"), "https://dav.jianguoyun.com/dav/")
        XCTAssertEqual(WebDAVResolver.resourceURL(jianguo, path: "/我的 文件/a#b?.txt"),
                       "https://dav.jianguoyun.com/dav/%E6%88%91%E7%9A%84%20%E6%96%87%E4%BB%B6/a%23b%3F.txt")
        XCTAssertEqual(WebDAVResolver.resourceURL(jianguo, path: "/a/b", directory: true), "https://dav.jianguoyun.com/dav/a/b/")
        XCTAssertEqual(WebDAVResolver.resourceURL(jianguo, path: "/50%.txt"), "https://dav.jianguoyun.com/dav/50%25.txt")
        let root = WebDAVCredential(url: "http://nas:5005", username: "", password: "")
        XCTAssertEqual(WebDAVResolver.resourceURL(root, path: "/x y"), "http://nas:5005/x%20y")
    }

    func testRelativePath() {
        XCTAssertEqual(WebDAVResolver.relativePath(href: "/dav/", cred: jianguo), "/")
        XCTAssertEqual(WebDAVResolver.relativePath(href: "/dav", cred: jianguo), "/")
        XCTAssertEqual(WebDAVResolver.relativePath(href: "/dav/%E6%88%91%E7%9A%84/", cred: jianguo), "/我的")
        XCTAssertEqual(WebDAVResolver.relativePath(href: "https://dav.jianguoyun.com/dav/a%20b/c.txt", cred: jianguo), "/a b/c.txt")
        XCTAssertEqual(WebDAVResolver.relativePath(href: "/dav/未编码 名字.txt", cred: jianguo), "/未编码 名字.txt")
        XCTAssertEqual(WebDAVResolver.relativePath(href: "/DAV/x", cred: jianguo), "/x")
        XCTAssertEqual(WebDAVResolver.parentPath("/a/b/c.txt"), "/a/b")
        XCTAssertEqual(WebDAVResolver.parentPath("/c.txt"), "/")
        XCTAssertEqual(WebDAVResolver.join("/", "a"), "/a")
        XCTAssertEqual(WebDAVResolver.join("/a", "b"), "/a/b")
    }

    // MARK: PROPFIND 解析

    static let jianguoXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:s="http://ns.jianguoyun.com">
      <d:response><d:href>/dav/%E6%88%91%E7%9A%84%E5%9D%9A%E6%9E%9C%E4%BA%91/</d:href>
        <d:propstat><d:prop><d:getlastmodified>Mon, 02 Jan 2006 15:04:05 GMT</d:getlastmodified>
          <d:resourcetype><d:collection/></d:resourcetype><d:displayname>我的坚果云</d:displayname></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/dav/%E6%88%91%E7%9A%84%E5%9D%9A%E6%9E%9C%E4%BA%91/movie%201.mkv</d:href>
        <d:propstat><d:prop><d:getcontentlength>123456789012</d:getcontentlength>
          <d:getlastmodified>Tue, 03 Jan 2006 01:02:03 GMT</d:getlastmodified><d:resourcetype/>
          <d:displayname>movie 1.mkv</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/dav/%E6%88%91%E7%9A%84%E5%9D%9A%E6%9E%9C%E4%BA%91/%E5%AD%90%E7%9B%AE%E5%BD%95/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    </d:multistatus>
    """

    func testParseJianguoListing() throws {
        let entries = try XCTUnwrap(WebDAVMultistatus.parse(Data(Self.jianguoXML.utf8)))
        XCTAssertEqual(entries.count, 3)
        let files = WebDAVResolver.files(entries, in: "/我的坚果云", cred: jianguo)
        XCTAssertEqual(files.map(\.name), ["movie 1.mkv", "子目录"])
        XCTAssertEqual(files[0].fid, "/我的坚果云/movie 1.mkv")
        XCTAssertEqual(files[0].size, 123456789012)
        XCTAssertFalse(files[0].isDirectory)
        XCTAssertEqual(files[0].parentId, "/我的坚果云")
        XCTAssertTrue(files[1].isDirectory)
        XCTAssertEqual(files[1].fid, "/我的坚果云/子目录")
        XCTAssertEqual(files[1].size, 0)
        XCTAssertEqual(WebDAVResolver.listText("Mon, 02 Jan 2006 15:04:05 GMT").count, 16)
        XCTAssertEqual(WebDAVResolver.listText("garbage"), "garbage")
    }

    /// Nextcloud / Apache 风格：D: 前缀、absolute href、不支持的属性在 404 propstat 里
    func testParseNextcloudStyle() throws {
        let xml = """
        <?xml version="1.0"?>
        <D:multistatus xmlns:D="DAV:" xmlns:lp1="DAV:">
          <D:response><D:href>https://cloud.example.com/remote.php/dav/files/u/</D:href>
            <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype>
              <D:quota-used-bytes>1000</D:quota-used-bytes><D:quota-available-bytes>9000</D:quota-available-bytes></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            <D:propstat><D:prop><D:getcontentlength/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
          <D:response><D:href>https://cloud.example.com/remote.php/dav/files/u/a%26b.txt</D:href>
            <D:propstat><D:prop><lp1:getcontentlength>42</lp1:getcontentlength><lp1:resourcetype/></D:prop>
              <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
            <D:propstat><D:prop><D:displayname>wrong</D:displayname></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let cred = WebDAVCredential(url: "https://cloud.example.com/remote.php/dav/files/u/", username: "u", password: "p")
        let entries = try XCTUnwrap(WebDAVMultistatus.parse(Data(xml.utf8)))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].displayName, "")
        let files = WebDAVResolver.files(entries, in: "/", cred: cred)
        XCTAssertEqual(files, [ShareFile(fid: "/a&b.txt", name: "a&b.txt", size: 42, isDirectory: false, parentId: "/")])
        XCTAssertEqual(WebDAVResolver.quota(entries), DriveQuota(used: 1000, total: 10000))
        XCTAssertNil(WebDAVResolver.quota([WebDAVEntry(href: "/")]))
    }

    func testRejectsNonDAV() {
        XCTAssertNil(WebDAVMultistatus.parse(Data("<html><body>login</body></html>".utf8)))
        XCTAssertNil(WebDAVMultistatus.parse(Data("not xml".utf8)))
    }

    func testStatusErrors() {
        XCTAssertEqual(WebDAVResolver.statusError(401, action: "读取目录").message, "WebDAV 账号或密码错误，请重新登录")
        XCTAssertEqual(WebDAVResolver.statusError(412, action: "移动").message, "目标位置已有同名文件")
        XCTAssertEqual(WebDAVResolver.statusError(500, action: "删除").message, "删除失败（HTTP 500）")
    }

    func testWiring() async {
        let resolvers = ShareResolvers(credentials: NoCredentials())
        XCTAssertNotNil(resolvers.manager(for: .webdav))
        XCTAssertNotNil(resolvers.uploader(for: .webdav))
        XCTAssertNil(resolvers.saver(for: .webdav))
        XCTAssertNil(resolvers.offline(for: .webdav))
        XCTAssertEqual(resolvers.manager(for: .webdav)?.driveRootId, "/")
        XCTAssertFalse(resolvers.manager(for: .webdav)?.driveCapabilities.contains(.share) ?? true)
        let invalid = await WebDAVResolver.validate(cookie: "garbage")
        XCTAssertNil(invalid)
        do {
            _ = try await WebDAVResolver().openSession(ParsedShare(shareId: "x", pwd: nil, platform: .webdav, url: "x"), pwd: nil)
            XCTFail("WebDAV 不该能打开分享")
        } catch {}
    }
}
