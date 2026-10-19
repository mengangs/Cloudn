import XCTest
@testable import CloudnKit

/// 夸克 / UC / 百度「我的网盘」请求构造与响应解析（纯逻辑，无网络）
final class DriveManagerQuarkBaiduTests: XCTestCase {
    // MARK: 夸克 / UC

    func testQuarkListQuery() {
        let q = QuarkFamilyResolver.driveListQuery(.quark, parent: "0", page: 2)
        XCTAssertTrue(q.hasPrefix("&uc_param_str=&pdir_fid=0&_page=2&_size=100"))
        XCTAssertTrue(q.contains("&_sort=file_type:asc,updated_at:desc"))
        XCTAssertTrue(q.contains("&fetch_all_file=1&fetch_risk_file_name=1"))
    }

    func testUCListQuery() {
        let q = QuarkFamilyResolver.driveListQuery(.uc, parent: "abc", page: 1)
        XCTAssertFalse(q.contains("uc_param_str"))
        XCTAssertTrue(q.hasPrefix("&pdir_fid=abc&_page=1&_size=100"))
        XCTAssertTrue(q.hasSuffix("&_sort=file_type%3Aasc%2Cupdated_at%3Adesc"))
    }

    func testQuarkParseDriveItems() {
        let data = JSON(text: """
        {"list":[{"fid":"d1","file_name":"文件夹","dir":true,"size":0,"pdir_fid":"0","updated_at":1700000000000},
                 {"fid":"f1","fname":"a.mp4","dir":false,"size":1234,"updated_at":1700000001000}]}
        """)!
        let files = QuarkFamilyResolver.parseDriveItems(data, parent: "p")
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].fid, "d1")
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[0].parentId, "0")
        XCTAssertEqual(files[1].name, "a.mp4")
        XCTAssertFalse(files[1].isDirectory)
        XCTAssertEqual(files[1].size, 1234)
        XCTAssertEqual(files[1].parentId, "p")
        XCTAssertEqual(files[1].modified, "1700000001000")
    }

    func testShareCreateBody() {
        let quark = QuarkFamilyResolver.shareCreateBody(.quark, fids: ["a", "b"], title: "", expiredType: 1)
        XCTAssertEqual(quark["fid_list"] as? [String], ["a", "b"])
        XCTAssertEqual(quark["title"] as? String, "分享文件")
        XCTAssertEqual(quark["url_type"] as? Int, 1)
        XCTAssertEqual(quark["expired_type"] as? Int, 1)
        XCTAssertEqual(quark["support_error_code"] as? [String], ["41060"])
        XCTAssertNil(quark["public_search"])

        let uc = QuarkFamilyResolver.shareCreateBody(.uc, fids: ["x"], title: "视频.mp4", expiredType: 2)
        XCTAssertEqual(uc["title"] as? String, "视频.mp4")
        XCTAssertEqual(uc["expired_type"] as? Int, 2)
        XCTAssertEqual(uc["public_search"] as? Int, 1)
        XCTAssertNil(uc["support_error_code"])
    }

    func testShareTitle() {
        let a = ShareFile(fid: "1", name: "a.txt", size: 1, isDirectory: false)
        let b = ShareFile(fid: "2", name: "b.txt", size: 1, isDirectory: false)
        XCTAssertEqual(QuarkFamilyResolver.shareTitle([a]), "a.txt")
        XCTAssertEqual(QuarkFamilyResolver.shareTitle([a, b]), "分享 2 个文件")
    }

    func testQuarkParseQuota() {
        let json = JSON(text: #"{"status":200,"data":{"use_capacity":100,"total_capacity":1000}}"#)!
        XCTAssertEqual(QuarkFamilyResolver.parseQuota(json), DriveQuota(used: 100, total: 1000))
        XCTAssertNil(QuarkFamilyResolver.parseQuota(JSON(text: #"{"status":401,"data":{}}"#)!))
    }

    func testManageExtra() {
        XCTAssertEqual(QuarkFamilyConfig.quark.manageExtra, "&uc_param_str=")
        XCTAssertEqual(QuarkFamilyConfig.uc.manageExtra, "")
        XCTAssertTrue(QuarkFamilyConfig.uc.driveUA.contains("uc-cloud-drive/1.6.1"))
        XCTAssertEqual(QuarkFamilyConfig.quark.driveUA, QuarkFamilyConfig.quark.apiUA)
    }

    // MARK: 百度

    func testBaiduParseDriveList() {
        let json = JSON(text: """
        {"errno":0,"list":[{"fs_id":111,"path":"/资料","server_filename":"资料","isdir":1,"size":0,"server_mtime":1700000000},
                           {"fs_id":222,"path":"/资料/a.zip","server_filename":"a.zip","isdir":0,"size":4096,"server_mtime":1700000001}]}
        """)!
        let files = BaiduResolver.parseDriveList(json, dir: "/")
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].fid, "/资料")
        XCTAssertEqual(files[0].token, "111")
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[1].fid, "/资料/a.zip")
        XCTAssertEqual(files[1].token, "222")
        XCTAssertEqual(files[1].size, 4096)
        XCTAssertEqual(files[1].parentId, "/")
        XCTAssertEqual(files[1].modified, "1700000001")
    }

    func testBaiduChildPath() {
        XCTAssertEqual(BaiduResolver.childPath("/", "新建"), "/新建")
        XCTAssertEqual(BaiduResolver.childPath("", "新建"), "/新建")
        XCTAssertEqual(BaiduResolver.childPath("/a/b/", "c"), "/a/b/c")
        XCTAssertEqual(BaiduResolver.childPath("/a", "c"), "/a/c")
    }

    func testBaiduFilelists() {
        XCTAssertEqual(BaiduResolver.renameFilelist(path: "/a/x.txt", name: "y \"1\".txt"),
                       #"[{"path":"/a/x.txt","newname":"y \"1\".txt"}]"#)
        XCTAssertEqual(BaiduResolver.moveFilelist(paths: ["/a/x.txt", "/a/d"], dest: "/b"),
                       #"[{"path":"/a/x.txt","dest":"/b","newname":"x.txt"},{"path":"/a/d","dest":"/b","newname":"d"}]"#)
        XCTAssertEqual(BaiduResolver.pathList(["/a", "/b"]), #"["/a","/b"]"#)
        XCTAssertEqual(BaiduResolver.shareFidList(["1", "2"]), "[1,2]")
    }

    func testBaiduSharePwd() {
        let allowed = Set("abcdefghijkmnpqrstuvwxyz23456789")
        for _ in 0..<20 {
            let pwd = BaiduResolver.randomSharePwd()
            XCTAssertEqual(pwd.count, 4)
            XCTAssertTrue(pwd.allSatisfy { allowed.contains($0) })
        }
    }

    func testBaiduParseShareLinkAndQuota() {
        XCTAssertEqual(BaiduResolver.parseShareLink(JSON(text: #"{"errno":0,"shorturl":"https://pan.baidu.com/s/1abc","link":"x"}"#)!),
                       "https://pan.baidu.com/s/1abc")
        XCTAssertEqual(BaiduResolver.parseShareLink(JSON(text: #"{"errno":0,"link":"https://pan.baidu.com/s/1def"}"#)!),
                       "https://pan.baidu.com/s/1def")
        XCTAssertNil(BaiduResolver.parseShareLink(JSON(text: #"{"errno":0}"#)!))

        XCTAssertEqual(BaiduResolver.parseQuota(JSON(text: #"{"errno":0,"total":2199023255552,"used":1024}"#)!),
                       DriveQuota(used: 1024, total: 2_199_023_255_552))
        XCTAssertNil(BaiduResolver.parseQuota(JSON(text: #"{"errno":-6}"#)!))
    }
}
