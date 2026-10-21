import XCTest
@testable import CloudnKit

final class QuarkKoulingTests: XCTestCase {
    func testExtract() {
        XCTAssertEqual(QuarkKouling.extract("  绝对有效 咐置松君杂货铺叩苓\n"), "绝对有效 咐置松君杂货铺叩苓")
        // 整段被成对括号包住时去掉外层；引导文案保留（服务端靠它判断夸克 / UC）
        XCTAssertEqual(QuarkKouling.extract("「绝对有效 咐置松君杂货铺叩苓」"), "绝对有效 咐置松君杂货铺叩苓")
        XCTAssertEqual(QuarkKouling.extract("复制整段，打开「夸克APP」即可获取 /~f55235Aq4Q~:/"), "复制整段，打开「夸克APP」即可获取 /~f55235Aq4Q~:/")
        // 内部还有同种括号：不是整体包裹，原样保留
        XCTAssertEqual(QuarkKouling.extract("「资源」打开「夸克APP」"), "「资源」打开「夸克APP」")
        // 只有口令码也算；纯英文数字不算
        XCTAssertEqual(QuarkKouling.extract(" /~f55235Aq4Q~:/ "), "/~f55235Aq4Q~:/")
        XCTAssertNil(QuarkKouling.extract("abc123"))
        XCTAssertNil(QuarkKouling.extract("   "))
        XCTAssertNil(QuarkKouling.extract("「」"))
        XCTAssertNil(QuarkKouling.extract("看这个 https://example.com/a"))
        XCTAssertNil(QuarkKouling.extract("看这个 HTTP://example.com/a"))
        XCTAssertNil(QuarkKouling.extract(String(repeating: "字", count: 121)))
        XCTAssertNotNil(QuarkKouling.extract(String(repeating: "字", count: 120)))
    }

    func testMentionsQuarkOrUC() {
        XCTAssertTrue(QuarkKouling.mentionsQuarkOrUC("打开「夸克APP」即可获取"))
        XCTAssertTrue(QuarkKouling.mentionsQuarkOrUC("打开UC浏览器查看"))
        XCTAssertTrue(QuarkKouling.mentionsQuarkOrUC("复制这段 /~f55235Aq4Q~:/ 打开"))
        XCTAssertFalse(QuarkKouling.mentionsQuarkOrUC("张三丰资源"))
        XCTAssertFalse(QuarkKouling.mentionsQuarkOrUC("绝对有效 咐置松君杂货铺叩苓"))
    }

    func testRequest() throws {
        let req = QuarkKouling.request(for: "绝对有效 \"口令\"")
        XCTAssertEqual(req.url, "https://starsea-api.qwq.pics/api/resolve")
        XCTAssertEqual(req.method, "POST")
        XCTAssertLessThanOrEqual(req.timeout, 15)
        let headers = Dictionary(req.headers, uniquingKeysWith: { $1 })
        XCTAssertEqual(headers["X-API-Key"], QuarkKouling.apiKey)
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["Accept"], "application/json")
        let body = try XCTUnwrap(req.body.flatMap { JSON(data: $0) })
        XCTAssertEqual(body["clipboard"].string, "绝对有效 \"口令\"")
        XCTAssertEqual(body["platform"].string, "auto")
        XCTAssertEqual(body["step"].string, "parse")
        XCTAssertNotNil(URL(string: req.url))
    }

    func testShareURLForPlatform() {
        XCTAssertEqual(QuarkKouling.shareURL(platform: "qk", pwdId: "81c7b58ff633"), "https://pan.quark.cn/s/81c7b58ff633")
        XCTAssertEqual(QuarkKouling.shareURL(platform: "UC", pwdId: "abc"), "https://drive.uc.cn/s/abc")
        XCTAssertEqual(QuarkKouling.shareURL(platform: "", pwdId: "abc"), "https://pan.quark.cn/s/abc")
        // 合成的链接必须能被本地分享识别认出来，否则「口令 → 本地链路」就断了
        let quark = ShareLinkParser.parse(QuarkKouling.shareURL(platform: "qk", pwdId: "81c7b58ff633"))
        XCTAssertEqual(quark?.platform, .quark)
        XCTAssertEqual(quark?.shareId, "81c7b58ff633")
        let uc = ShareLinkParser.parse(QuarkKouling.shareURL(platform: "uc", pwdId: "abcdef123456"))
        XCTAssertEqual(uc?.platform, .uc)
        XCTAssertEqual(uc?.shareId, "abcdef123456")
    }

    private func parse(_ status: Int, _ body: String) throws -> String {
        try QuarkKouling.shareURL(status: status, body: Data(body.utf8))
    }

    private func failure(_ status: Int, _ body: String) -> String? {
        do {
            _ = try parse(status, body)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testParseSuccess() throws {
        XCTAssertEqual(try parse(200, #"{"success":true,"msg":"ok","data":{"platform":"qk","pwdId":"81c7b58ff633"}}"#),
                       "https://pan.quark.cn/s/81c7b58ff633")
        XCTAssertEqual(try parse(200, #"{"success":true,"data":{"platform":"uc","pwdId":"abcdef123456"}}"#),
                       "https://drive.uc.cn/s/abcdef123456")
    }

    func testParseFailures() {
        // 服务端给了原因就用它的，HTTP 码不论
        XCTAssertEqual(failure(200, #"{"success":false,"msg":"口令无效或已过期"}"#), "口令无效或已过期")
        XCTAssertEqual(failure(500, #"{"success":false,"msg":"口令已过期"}"#), "口令已过期")
        // 没有 JSON 时按 HTTP 码给原因
        XCTAssertEqual(failure(429, "Too Many Requests"), "口令解析服务繁忙，请稍后再试")
        XCTAssertEqual(failure(401, ""), "口令解析服务鉴权失败，请更新应用")
        XCTAssertEqual(failure(502, "<html>bad gateway</html>"), "口令解析失败（HTTP 502）")
        XCTAssertEqual(failure(200, #"{"success":false}"#), "无法识别该口令")
        // 成功但缺字段 / 字段异常
        XCTAssertEqual(failure(200, #"{"success":true}"#), "口令解析失败：响应缺少 data")
        XCTAssertEqual(failure(200, #"{"success":true,"data":{"platform":"qk","pwdId":""}}"#), "口令解析失败：未取到分享 ID")
        XCTAssertEqual(failure(200, #"{"success":true,"data":{"platform":"qk","pwdId":"../evil?x=1"}}"#), "口令解析失败：分享 ID 格式异常")
    }

    func testResolveRejectsNonKouling() async {
        do {
            _ = try await QuarkKouling.resolve("  ")
            XCTFail("空文本不该发请求")
        } catch {
            XCTAssertEqual(error.localizedDescription, "不像夸克 / UC 口令")
        }
    }
}
