import XCTest
@testable import CloudnKit

/// 光鸭 / 蓝奏优享 / 蓝奏云「我的网盘」管理的请求体构造与响应解析（不联网）
final class DriveManagerLanzouGuangYaTests: XCTestCase {
    private func json(_ text: String) -> JSON { JSON(text: text)! }

    func testRegisteredAsManagers() {
        let resolvers = ShareResolvers(credentials: NoCredentials())
        XCTAssertEqual(resolvers.manager(for: .guangya)?.driveCapabilities, DriveCapabilities.all)
        XCTAssertEqual(resolvers.manager(for: .ilanzou)?.driveCapabilities, DriveCapabilities([.createFolder, .rename, .move, .delete]))
        XCTAssertEqual(resolvers.manager(for: .lanzou)?.driveRootId, "-1")
        XCTAssertEqual(resolvers.manager(for: .guangya)?.driveRootId, "")
    }

    func testNotLoggedInThrowsLoginRequired() async {
        for platform in [SharePlatform.guangya, .ilanzou, .lanzou] {
            let manager = ShareResolvers(credentials: NoCredentials()).manager(for: platform)!
            do {
                _ = try await manager.listDrive(manager.driveRootId)
                XCTFail("\(platform) 未登录应抛错")
            } catch {
                XCTAssertEqual(error as? CloudnError, platform.loginRequired)
            }
        }
    }

    // MARK: 光鸭云盘

    func testGuangYaShareBody() {
        let files = [ShareFile(fid: "a1", name: "x.mp4", size: 1, isDirectory: false)]
        XCTAssertEqual(GuangYaResolver.shareBody(files, code: "").text,
                       #"{"fileIds":["a1"],"title":"x.mp4","validateDuration":0,"shareType":0,"code":"","autoFillCode":false,"trafficLimit":"0","maxRestoreCount":0,"downloadType":1}"#)
        let two = files + [ShareFile(fid: "b2", name: "dir", size: 0, isDirectory: true)]
        let body = GuangYaResolver.shareBody(two, code: "ab12", days: 7).text
        XCTAssertTrue(body.contains(#""fileIds":["a1","b2"],"title":"分享 2 个文件","validateDuration":7,"shareType":1,"code":"ab12""#))
    }

    func testGuangYaParseShareAndQuota() {
        XCTAssertEqual(GuangYaResolver.parseShare(json(#"{"shareUrl":"https://www.guangyapan.com/s/abc","code":"x9"}"#), code: ""),
                       DriveShareLink(url: "https://www.guangyapan.com/s/abc", pwd: "x9"))
        XCTAssertEqual(GuangYaResolver.parseShare(json(#"{"shareId":"zz"}"#), code: "c1"),
                       DriveShareLink(url: "https://www.guangyapan.com/s/zz", pwd: "c1"))
        XCTAssertNil(GuangYaResolver.parseShare(json("{}"), code: ""))

        XCTAssertEqual(GuangYaResolver.parseQuota(json(#"{"totalSpaceSize":"1099511627776","usedSpaceSize":"1024"}"#)),
                       DriveQuota(used: 1024, total: 1_099_511_627_776))
        XCTAssertNil(GuangYaResolver.parseQuota(json(#"{"usedSpaceSize":"1"}"#)))
    }

    func testGuangYaPersonalLink() throws {
        let file = ShareFile(fid: "f", name: "a.zip", size: 9, isDirectory: false)
        let link = try GuangYaResolver.personalLink(json(#"{"signedURL":"https://cdn/x","size":"100"}"#), file: file)
        XCTAssertEqual(link.url, "https://cdn/x")
        XCTAssertEqual(link.size, 100)
        XCTAssertEqual(link.headers["Referer"], "https://www.guangyapan.com/")
        XCTAssertThrowsError(try GuangYaResolver.personalLink(json("{}"), file: file))
    }

    // MARK: 蓝奏云优享版

    func testILanzouIds() {
        XCTAssertEqual(ILanzouResolver.rawId("d:12"), "12")
        XCTAssertEqual(ILanzouResolver.rawId("f:34"), "34")
        let ids = ILanzouResolver.splitIds([
            ShareFile(fid: "d:1", name: "a", size: 0, isDirectory: true), ShareFile(fid: "f:2", name: "b", size: 0, isDirectory: false),
            ShareFile(fid: "f:3", name: "c", size: 0, isDirectory: false)
        ])
        XCTAssertEqual(ids.folders, "1")
        XCTAssertEqual(ids.files, "2,3")
        XCTAssertEqual(ILanzouResolver.folderBody(id: "", name: "新建", root: true).text, #"{"folderDesc":"","folderId":"0","folderName":"新建"}"#)
        XCTAssertEqual(ILanzouResolver.folderBody(id: "d:9", name: "n", root: false).text, #"{"folderDesc":"","folderId":"9","folderName":"n"}"#)
    }

    func testILanzouRedirectParams() {
        let params = ILanzouResolver.personalRedirectParams(fileId: "123", userId: "7", uuid: "u1", appToken: "tok", ts: "1700000000000")
        XCTAssertEqual(params.map { $0.0 }, ["uuid", "devType", "devCode", "devModel", "devVersion", "appVersion", "timestamp", "appToken",
                                         "enable", "downloadId", "auth", "timestamp"])
        XCTAssertEqual(params.first(where: { $0.0 == "auth" })?.1, "790f9f7cf7e017afcea5b8de25cfab8f530f69b25004eff231c49c71538015b9")
        XCTAssertEqual(params.first(where: { $0.0 == "downloadId" })?.1, ILanzouResolver.aesHex("123|7"))
        XCTAssertEqual(params[6].1, params[11].1)
        XCTAssertFalse(params.contains(where: { $0.0 == "extra" }))
    }

    func testILanzouQuota() {
        XCTAssertEqual(ILanzouResolver.parseQuota(json(#"{"usedSize":10,"totalSize":100,"vipSize":20,"rewardSize":"4"}"#)),
                       DriveQuota(used: 10 * 1024, total: 124 * 1024))
        XCTAssertNil(ILanzouResolver.parseQuota(json(#"{}"#)))
    }

    // MARK: 蓝奏云

    func testLanzouListParsing() {
        let folders = LanzouResolver.parseFolders(json(#"{"zt":1,"text":[{"fol_id":"55","name":"资料","time":"昨天"},{"name":"bad"}]}"#), parent: "-1")
        XCTAssertEqual(folders, [ShareFile(fid: "d:55", name: "资料", size: 0, isDirectory: true, parentId: "-1", modified: "昨天")])
        let files = LanzouResolver.parseFiles(json(#"{"zt":1,"text":[{"id":"9","name":"a…","name_all":"abc.apk","size":"1.5 M","time":"1 天前"}]}"#), parent: "d:55")
        XCTAssertEqual(files.first?.fid, "f:9")
        XCTAssertEqual(files.first?.name, "abc.apk")
        XCTAssertEqual(files.first?.size, 1_572_864)
        XCTAssertEqual(files.first?.parentId, "d:55")
        XCTAssertEqual(LanzouResolver.folderArg(""), "-1")
        XCTAssertEqual(LanzouResolver.folderArg("d:55"), "55")
        XCTAssertEqual(LanzouResolver.rawId("f:9"), "9")
    }

    func testLanzouDouploadCheck() {
        XCTAssertNoThrow(try LanzouResolver.checkDoupload(json(#"{"zt":1}"#), allowEnd: false))
        XCTAssertNoThrow(try LanzouResolver.checkDoupload(json(#"{"zt":2}"#), allowEnd: true))
        XCTAssertThrowsError(try LanzouResolver.checkDoupload(json(#"{"zt":2}"#), allowEnd: false))
        XCTAssertThrowsError(try LanzouResolver.checkDoupload(json(#"{"zt":9}"#), allowEnd: true)) { error in
            XCTAssertEqual((error as? CloudnError)?.code, 9)
        }
        XCTAssertThrowsError(try LanzouResolver.checkDoupload(json(#"{"zt":0,"info":"名称已存在"}"#), allowEnd: false)) { error in
            XCTAssertEqual((error as? CloudnError)?.message, "蓝奏：名称已存在")
        }
    }

    func testLanzouShareInfo() {
        let file = LanzouResolver.parseShareInfo(json(#"{"zt":1,"info":{"pwd":"ab12","onof":"0","f_id":"iAbC123","is_newd":"https://wwt.lanzouu.com"}}"#), folder: false)
        XCTAssertEqual(file?.url, "https://wwt.lanzouu.com/iAbC123")
        XCTAssertEqual(file?.pwd, "ab12")
        XCTAssertEqual(file?.enabled, false)
        let folder = LanzouResolver.parseShareInfo(json(#"{"zt":1,"info":{"pwd":"x1","onof":"1","new_url":"https://wwt.lanzouu.com/b0abc","is_newd":"wwt.lanzouu.com"}}"#), folder: true)
        XCTAssertEqual(folder?.url, "https://wwt.lanzouu.com/b0abc")
        XCTAssertEqual(folder?.enabled, true)
        XCTAssertNil(LanzouResolver.parseShareInfo(json(#"{"zt":1,"info":"x"}"#), folder: false))
        XCTAssertEqual(LanzouResolver.shareURL("/iX", domain: ""), "https://pan.lanzoui.com/iX")
        XCTAssertEqual(LanzouResolver.shareURL("iX", domain: "lanzoux.com"), "https://lanzoux.com/iX")
    }
}
