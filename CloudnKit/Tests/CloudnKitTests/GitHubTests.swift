import XCTest
@testable import CloudnKit

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
}
