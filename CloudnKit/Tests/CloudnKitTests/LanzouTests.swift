import XCTest
@testable import CloudnKit

final class LanzouTests: XCTestCase {
    func testHosts() {
        XCTAssertTrue(LanzouResolver.isLanzouHost("wwi.lanzoui.com"))
        XCTAssertTrue(LanzouResolver.isLanzouHost("pan.lanzouw.com"))
        XCTAssertTrue(LanzouResolver.isLanzouHost("lanzoux.com"))
        XCTAssertFalse(LanzouResolver.isLanzouHost("example.com"))
    }

    func testJsVars() {
        let html = """
        <script>var wp_sign = 'ABC_123';var ajaxdata = 'xyz'; var kdns = 1;
        $.ajax({ url : '/ajaxm.php?file=998877', data : { 'action':'downprocess','t':ib4tq,'k':_h9e }});
        var ib4tq = '1700000000'; var _h9e = 'kkkk';
        </script>
        """
        XCTAssertEqual(LanzouResolver.jsVar(html, "wp_sign"), "ABC_123")
        XCTAssertEqual(LanzouResolver.jsVarRaw(html, "kdns"), "1")
        XCTAssertEqual(LanzouResolver.indirectVar(html, "t"), "1700000000")
        XCTAssertEqual(LanzouResolver.indirectVar(html, "k"), "kkkk")
        XCTAssertEqual(LanzouResolver.ajaxURL(html, origin: "https://a.lanzoui.com", fileId: "998877", withPwd: false),
                       "https://a.lanzoui.com/ajaxm.php?file=998877")
    }

    func testTitle() {
        XCTAssertEqual(LanzouResolver.extractTitle("<title>demo.apk - 蓝奏云</title>"), "demo.apk")
        XCTAssertEqual(LanzouResolver.extractTitle("<div class=\"n\">book.pdf</div>"), "book.pdf")
    }

    func testChallengeShape() {
        let page = "var arg1='0123456789ABCDEF0123456789ABCDEF01234567';"
        let c = LanzouResolver.challengeCookie(page)
        XCTAssertEqual(c?.count, 40)
        XCTAssertEqual(c, LanzouResolver.acwScV2("0123456789ABCDEF0123456789ABCDEF01234567"))
    }

    func testValidateAjax() {
        XCTAssertNoThrow(try LanzouResolver.validateAjax(JSON(text: #"{"zt":1}"#)!))
        XCTAssertThrowsError(try LanzouResolver.validateAjax(JSON(text: #"{"zt":0,"inf":"密码不正确"}"#)!)) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "蓝奏提取码错误，请检查后重新解析")
        }
    }
}
