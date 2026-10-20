import XCTest
@testable import CloudnKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class GitHubTests: XCTestCase {
    func testLinkParsing() {
        XCTAssertEqual(GitHubLink.parse("https://raw.githubusercontent.com/a/b/main/dir/x.txt"),
                       .file(url: "https://raw.githubusercontent.com/a/b/main/dir/x.txt", name: "x.txt"))
        XCTAssertEqual(GitHubLink.parse("下载 https://github.com/mengangs/Cloudn/releases/download/v1.0/Cloudn.ipa。"),
                       .file(url: "https://github.com/mengangs/Cloudn/releases/download/v1.0/Cloudn.ipa", name: "Cloudn.ipa"))
        XCTAssertEqual(GitHubLink.parse("https://github.com/CYQawa/YunX"), .repository(owner: "CYQawa", repo: "YunX", subPath: nil))
        XCTAssertEqual(GitHubLink.parse("https://github.com/CYQawa/YunX.git"), .repository(owner: "CYQawa", repo: "YunX", subPath: nil))
        XCTAssertEqual(GitHubLink.parse("https://github.com/a/b/tree/main/src?x=1"), .repository(owner: "a", repo: "b", subPath: "tree/main/src"))
        XCTAssertEqual(GitHubLink.parse("https://github.com/mengangs"), .account(owner: "mengangs"))
        XCTAssertNil(GitHubLink.parse("https://github.com/features/actions"))
        XCTAssertNil(GitHubLink.parse("https://github.com/trending"))
        XCTAssertNil(GitHubLink.parse("https://example.com/a/b"))
        if case .github = DetectedInput.detect("https://github.com/a/b") {} else { XCTFail() }
    }

    func testMirror() {
        XCTAssertEqual(GitHubMirror.apply("https://github.com/a/b/releases/download/v1/x.zip", prefix: "https://m.example/"),
                       "https://m.example/https://github.com/a/b/releases/download/v1/x.zip")
        XCTAssertEqual(GitHubMirror.apply("https://raw.githubusercontent.com/a/b/main/x", prefix: "https://m.example"),
                       "https://m.example/https://raw.githubusercontent.com/a/b/main/x")
        XCTAssertEqual(GitHubMirror.apply("https://example.com/x", prefix: "https://m.example/"), "https://example.com/x")
        XCTAssertEqual(GitHubMirror.apply("https://github.com/x", prefix: ""), "https://github.com/x")
    }

    func testParsers() {
        let repo = GitHubClient.parseRepo(JSON(["name": "b", "full_name": "a/b", "owner": ["login": "a"], "default_branch": "dev", "stargazers_count": 3]))
        XCTAssertEqual(repo.defaultBranch, "dev")
        XCTAssertEqual(repo.owner, "a")
        let entry = GitHubClient.parseEntry(JSON(["name": "src", "path": "src", "type": "dir", "size": 0]))
        XCTAssertTrue(entry.isDirectory)
        let rel = GitHubClient.parseRelease(JSON(["tag_name": "v1", "prerelease": true,
                                                  "assets": [["name": "a.ipa", "size": 10, "browser_download_url": "https://x/a.ipa"]]]))
        XCTAssertEqual(rel.name, "v1")
        XCTAssertEqual(rel.assets.first?.size, 10)
        XCTAssertTrue(rel.isPrerelease)
    }

    func testPrivateRepoAssets() {
        let repo = GitHubClient.parseRepo(JSON(["name": "b", "full_name": "a/b", "owner": ["login": "a"], "private": true]))
        XCTAssertTrue(repo.isPrivate)
        let rel = GitHubClient.parseRelease(JSON(["tag_name": "v1", "assets": [[
            "name": "app.zip", "size": 10, "browser_download_url": "https://github.com/a/b/releases/download/v1/app.zip",
            "url": "https://api.github.com/repos/a/b/releases/assets/42"
        ]]]))
        let asset = rel.assets[0]
        XCTAssertEqual(asset.apiURL, "https://api.github.com/repos/a/b/releases/assets/42")
        XCTAssertEqual(asset.privateDownloadHeaders(token: "t")["Accept"], "application/octet-stream")
        XCTAssertEqual(asset.privateDownloadHeaders(token: "t")["Authorization"], "Bearer t")
    }

    /// 跳到别的主机（签名的存储地址）时去掉 Authorization，同主机跳转保留
    func testRedirectDropsAuthorizationAcrossHosts() {
        var original = URLRequest(url: URL(string: "https://api.github.com/repos/a/b/releases/assets/42")!)
        original.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        var signed = URLRequest(url: URL(string: "https://objects.githubusercontent.com/x?sig=1")!)
        signed.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        signed.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let out = StreamingSession.strippingAuthorizationAcrossHosts(signed, from: original)
        XCTAssertNil(out.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(out.value(forHTTPHeaderField: "Range"), "bytes=0-9")

        var sameHost = URLRequest(url: URL(string: "https://api.github.com/other")!)
        sameHost.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(StreamingSession.strippingAuthorizationAcrossHosts(sameHost, from: original).value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    /// 旧任务表没有 refresh 字段也能读；新字段能来回编码
    func testRefreshSourceCoding() throws {
        let old = #"{"url":"u","headers":{},"fileName":"a","folder":"","kind":{"file":{}},"expectedSize":-1,"source":"s"}"#
        let decoded = try JSONDecoder().decode(DownloadRequest.self, from: Data(old.utf8))
        XCTAssertNil(decoded.refresh)
        XCTAssertFalse(decoded.canRefresh)

        let file = ShareFile(fid: "f1", name: "a.mp4", size: 9, isDirectory: false, parentId: "p", token: "tk")
        var request = DownloadRequest(url: "u", fileName: "a.mp4", refresh: .drive(platform: .quark, file: DriveFileRef(file)))
        XCTAssertTrue(request.canRefresh)
        let round = try JSONDecoder().decode(DownloadRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(round.refresh, request.refresh)
        request.refresh = .video(pageURL: "https://www.douyin.com/video/1", fileName: "a.mp4", index: 0)
        XCTAssertEqual(try JSONDecoder().decode(DownloadRequest.self, from: JSONEncoder().encode(request)).refresh, request.refresh)
    }
}
