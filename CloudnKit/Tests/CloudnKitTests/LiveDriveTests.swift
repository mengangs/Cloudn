import XCTest
@testable import CloudnKit

/// 在线巡检（网盘）：用公开分享验证 Google 云端硬盘、OneDrive、阿里云盘的接口没变。
/// 只在 CLOUDN_LIVE=1 时运行（.github/workflows/live.yml）。Google 链接取自 gdown 的测试用例。
final class LiveDriveTests: XCTestCase {
    private let resolvers = ShareResolvers(credentials: NoCredentials())

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CLOUDN_LIVE"] == "1" else {
            throw XCTSkip("在线巡检只在 CLOUDN_LIVE=1 时运行")
        }
    }

    func testGoogleFolder() async throws {
        let (session, files) = try await open("https://drive.google.com/drive/folders/15uNXeRBIhVvZJIhL4yTw4IsStMhUaaxl")
        XCTAssertEqual(session.title, "gdown")
        XCTAssertTrue(files.contains { $0.isDirectory && $0.name == "files_100" })
        // 子目录：100 个文件全部列出（页面一次给全）
        let sub = try XCTUnwrap(files.first { $0.name == "files_100" })
        let children = try await resolver(.gdrive).list(session, dirId: sub.fid)
        report("Google 子目录", "\(children.count) 项，" + children.prefix(3).map { "\($0.name)(\($0.size))" }.joined(separator: " "))
        XCTAssertEqual(children.count, 100)
        // 这个目录里都是空文件：取链不能因为探测不到大小而失败
        let empty = try XCTUnwrap(children.first)
        let emptyLink = try await resolver(.gdrive).downloadLink(session, file: empty)
        XCTAssertEqual(emptyLink.size, 0)
        let doc = try XCTUnwrap(files.first { $0.token.hasPrefix("doc:") })
        let link = try await resolver(.gdrive).downloadLink(session, file: doc)
        XCTAssertTrue(link.url.contains("/export"), link.url)
    }

    func testGoogleFile() async throws {
        let (session, files) = try await open("https://drive.google.com/file/d/1l_5RK28JRL19wpT22B-DY9We3TVXnnQQ/view?usp=sharing")
        XCTAssertEqual(session.title, "fcn8s_from_caffe.npz")
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.size, 498_881_336)
        let link = try await resolver(.gdrive).downloadLink(session, file: file)
        try await assertRange(link)
    }

    func testGoogleSlides() async throws {
        let (_, files) = try await open("https://docs.google.com/presentation/d/1DvsG277pWa4WMssXjD9qYYAdF51y7hVidZ6eklfq480/edit?usp=drive_link")
        XCTAssertEqual(files.first?.name.hasSuffix(".pptx"), true, files.first?.name ?? "")
    }

    func testOneDriveSharePointFolder() async throws {
        let (session, files) = try await open("https://stuhiteducn-my.sharepoint.com/:f:/g/personal/1150700117_stu_hit_edu_cn/EumyrYnHDMtIiNoAHNshbXUBHU5diRWyGVB1rmso860kog?e=KKEKOO")
        XCTAssertEqual(session.title, "CID")
        XCTAssertGreaterThanOrEqual(files.count, 7)
        let file = try XCTUnwrap(files.first { !$0.isDirectory })
        XCTAssertGreaterThan(file.size, 0)
        let link = try await resolver(.onedrive).downloadLink(session, file: file)
        try await assertRange(link)
    }

    func testOneDriveSharePointFile() async throws {
        let (session, files) = try await open("https://stuhiteducn-my.sharepoint.com/:u:/g/personal/1150700117_stu_hit_edu_cn/Edor2A427PtElKU6Y0ewvysBv0t3k0UM43mE2xxDFGenlQ?e=VqEyhG")
        let file = try XCTUnwrap(files.first)
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(session.title, file.name)
        let link = try await resolver(.onedrive).downloadLink(session, file: file)
        try await assertRange(link)
    }

    /// 个人版设了密码的分享：不给密码时要提示填写密码
    func testOneDrivePersonalPassword() async throws {
        let share = try XCTUnwrap(ShareLinkParser.parse("https://1drv.ms/f/c/05b6df5b859ecdde/IgBLUOUDkt5bQ4S80HI2Gb_7AZW-uXoxuXuFPXCrwOUrBPo?e=6fBF22"))
        do {
            _ = try await resolver(.onedrive).openSession(share, pwd: nil)
            XCTFail("应要求密码")
        } catch {
            report("OneDrive 个人版密码", error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("密码"), error.localizedDescription)
        }
        // 错误密码：要能走到密码页并报密码错误（而不是解析失败）
        do {
            _ = try await resolver(.onedrive).openSession(share, pwd: "wrong-password")
            XCTFail("错误密码不应成功")
        } catch {
            report("OneDrive 个人版错误密码", error.localizedDescription)
        }
    }

    func testAliyunFolder() async throws {
        let (session, files) = try await open("https://www.alipan.com/s/SwCbQBN2nZQ")
        XCTAssertEqual(session.title, "MediaGo")
        let folder = try XCTUnwrap(files.first { $0.isDirectory })
        let children = try await resolver(.aliyun).list(session, dirId: folder.fid)
        report("阿里云盘子目录", children.map(\.name).joined(separator: "、"))
        XCTAssertFalse(children.isEmpty)
        // 未登录取链要提示登录
        if let file = try await firstFile(session, in: children) {
            do {
                _ = try await resolver(.aliyun).downloadLink(session, file: file)
                XCTFail("未登录不应拿到直链")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("登录"), error.localizedDescription)
            }
        }
    }

    // MARK: 工具

    private func resolver(_ p: SharePlatform) -> ShareResolver { resolvers.resolver(for: p)! }

    private func open(_ url: String) async throws -> (ShareSession, [ShareFile]) {
        let share = try XCTUnwrap(ShareLinkParser.parse(url), url)
        let r = resolver(share.platform)
        let session = try await r.openSession(share, pwd: nil)
        let files = try await r.list(session, dirId: session.rootId)
        report(share.platform.displayName, "\(session.title)：\(files.count) 项 " + files.prefix(4).map { "\($0.name)(\($0.size))" }.joined(separator: " "))
        return (session, files)
    }

    private func firstFile(_ session: ShareSession, in files: [ShareFile], depth: Int = 0) async throws -> ShareFile? {
        if let f = files.first(where: { !$0.isDirectory }) { return f }
        guard depth < 3, let dir = files.first(where: \.isDirectory) else { return nil }
        return try await firstFile(session, in: resolver(session.platform).list(session, dirId: dir.fid), depth: depth + 1)
    }

    /// 直链支持断点：取第 1 个字节返回 206
    private func assertRange(_ link: DownloadLink, file: StaticString = #filePath, line: UInt = #line) async throws {
        var headers = link.headers.map { ($0.key, $0.value) }
        headers.append(("Range", "bytes=0-0"))
        let r = try await HTTPClient.shared.send(HTTPRequest(url: link.url, headers: headers))
        report(link.fileName, "直链 HTTP \(r.status) \(r.header("Content-Range") ?? "")")
        XCTAssertEqual(r.status, 206, "\(link.fileName) 直链不支持断点：HTTP \(r.status)", file: file, line: line)
    }

    private func report(_ name: String, _ detail: String) {
        print("[live] \(name)：\(detail)")
        guard let path = ProcessInfo.processInfo.environment["CLOUDN_LIVE_REPORT"] else { return }
        let line = "| \(name) | ℹ️ | \(detail.replacingOccurrences(of: "|", with: "/")) |\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
