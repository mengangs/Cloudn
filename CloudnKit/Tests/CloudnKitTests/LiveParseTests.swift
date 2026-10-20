import XCTest
@testable import CloudnKit

/// 在线巡检：用真实链接解析各平台，确认接口没变、直链能访问。
/// 只在设置了 CLOUDN_LIVE=1 时运行（每日定时任务 .github/workflows/live.yml），平时跳过。
/// 链接大多取自 yt-dlp 的测试用例（长期有效的公开作品）。国内平台从海外服务器访问会被拦，不在这里巡检。
final class LiveParseTests: XCTestCase {
    private static let service = VideoParseService(credentials: NoCredentials(), webExtractor: nil)

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["CLOUDN_LIVE"] == "1" else {
            throw XCTSkip("在线巡检只在 CLOUDN_LIVE=1 时运行")
        }
    }

    func testYouTube() async { await check("https://www.youtube.com/watch?v=jNQXAC9IVRw") }
    func testBilibili() async { await check("https://www.bilibili.com/video/BV13x41117TL") }
    func testTwitter() async { await check("https://twitter.com/freethenipple/status/643211948184596480") }
    func testTikTok() async { await check("https://www.tiktok.com/@leenabhushan/video/6748451240264420610") }
    func testInstagram() async { await check("https://www.instagram.com/p/BQ0eAlwhDrw/") }
    func testFacebook() async { await check("https://www.facebook.com/radiokicksfm/videos/3676516585958356/") }
    func testReddit() async { await check("https://www.reddit.com/r/videos/comments/6rrwyj/that_small_heart_attack/") }
    func testPinterest() async { await check("https://www.pinterest.com/pin/664281013778109217/") }
    func testTumblr() async { await check("https://tatianamaslanydaily.tumblr.com/post/54196191430/orphan-black-dvd-extra-behind-the-scenes") }
    func testImgur() async { await check("https://imgur.com/A61SaA1") }
    func testBluesky() async { await check("https://bsky.app/profile/blu3blue.bsky.social/post/3l4omssdl632g") }
    func testSnapchat() async { await check("https://www.snapchat.com/spotlight/W7_EDlXWTBiXAEEniNoMPwAAYYWtidGhudGZpAX1TKn0JAX1TKnXJAAAAAA") }
    func testVimeo() async { await check("https://vimeo.com/76979871") }
    func testDailymotion() async { await check("https://www.dailymotion.com/video/x5kesuj") }
    func testTwitchClip() async { await check("https://clips.twitch.tv/FaintLightGullWholeWheat") }
    func testSoundCloud() async { await check("https://soundcloud.com/ethmusic/lostin-powers-she-so-heavy") }

    /// 解析出至少一个媒体，且第一个媒体的直链能探测到（大小或时长）
    private func check(_ url: String, file: StaticString = #filePath, line: UInt = #line) async {
        guard let link = VideoLinkParser.parse(url) else {
            report(url, ok: false, detail: "链接识别失败")
            return XCTFail("链接识别失败：\(url)", file: file, line: line)
        }
        let name = link.platform.displayName
        do {
            let result = try await Self.service.parse(link)
            guard let media = result.medias.first else {
                report(name, ok: false, detail: "没有解析出媒体")
                return XCTFail("\(name)：没有解析出媒体", file: file, line: line)
            }
            let probe = await MediaProbe.probe(media.url, headers: media.headers, isHLS: media.isHLS)
            let reachable = probe.map { $0.size != nil || $0.duration != nil } ?? false
            let detail = "\(result.medias.count) 个媒体" + (media.quality.isEmpty ? "" : "，首个 \(media.quality)")
                + (reachable ? "" : "，但直链探测失败")
            report(name, ok: reachable, detail: detail)
            XCTAssertTrue(reachable, "\(name)：直链探测失败 \(media.url)", file: file, line: line)
        } catch {
            report(name, ok: false, detail: error.localizedDescription + ((error as? VideoParseError).map { "（\($0.detail)）" } ?? ""))
            XCTFail("\(name)：\(error.localizedDescription)", file: file, line: line)
        }
    }

    /// 每个平台一行写进报告文件（CLOUDN_LIVE_REPORT），定时任务把它贴到运行摘要里
    private func report(_ name: String, ok: Bool, detail: String) {
        guard let path = ProcessInfo.processInfo.environment["CLOUDN_LIVE_REPORT"] else { return }
        let line = "| \(name) | \(ok ? "✅" : "❌") | \(detail.replacingOccurrences(of: "|", with: "/")) |\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
