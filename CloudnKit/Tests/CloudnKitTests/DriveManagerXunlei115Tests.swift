import XCTest
@testable import CloudnKit

/// 迅雷 / 115「我的网盘」请求体构造与响应解析（纯逻辑，不联网）
final class DriveManagerXunlei115Tests: XCTestCase {
    // MARK: 迅雷

    func testXunleiFilesURL() {
        let url = XunleiResolver.driveFilesURL("https://api-pan.xunlei.com", parent: "", pageToken: "")
        XCTAssertTrue(url.hasPrefix("https://api-pan.xunlei.com/drive/v1/files?parent_id=&page_token=&limit=100&with_audit=true&filters="))
        XCTAssertFalse(url.contains("{"))
        XCTAssertEqual(XunleiResolver.driveParent("0"), "")
        XCTAssertEqual(XunleiResolver.driveParent("VAbc"), "VAbc")
    }

    func testXunleiBodies() {
        XCTAssertEqual(XunleiResolver.createFolderBody(name: "新建", parent: "p1").text,
                       #"{"kind":"drive#folder","name":"新建","parent_id":"p1","space":""}"#)
        XCTAssertEqual(XunleiResolver.moveBody(ids: ["a", "b"], to: "t").text,
                       #"{"ids":["a","b"],"to":{"parent_id":"t","space":""},"space":""}"#)
        XCTAssertEqual(XunleiResolver.trashBody(ids: ["a"]).text, #"{"ids":["a"],"space":""}"#)
        XCTAssertEqual(XunleiResolver.shareBody(ids: ["a"], title: "").text,
                       #"{"file_ids":["a"],"share_to":"copy","params":{"subscribe_push":"false","WithPassCodeInLink":"true","# +
                       #""with_pass_code_in_link":"true"},"title":"分享文件","restore_limit":"-1","expiration_days":"-1"}"#)
    }

    func testXunleiParsers() {
        let share = XunleiResolver.parseShareLink(JSON(text: #"{"share_url":"https://pan.xunlei.com/s/VAx","pass_code":"ab12"}"#)!)
        XCTAssertEqual(share, DriveShareLink(url: "https://pan.xunlei.com/s/VAx", pwd: "ab12"))
        XCTAssertNil(XunleiResolver.parseShareLink(JSON(text: #"{"share_id":"x"}"#)!))
        let quota = XunleiResolver.parseQuota(JSON(text: #"{"kind":"drive#about","quota":{"limit":"2199023255552","usage":"1024"}}"#)!)
        XCTAssertEqual(quota, DriveQuota(used: 1024, total: 2_199_023_255_552))
        XCTAssertNil(XunleiResolver.parseQuota(JSON(text: #"{"kind":"drive#about"}"#)!))
        let file = XunleiResolver.parseFile(JSON(text: #"{"id":"f1","name":"a.mp4","size":"10","kind":"drive#file","parent_id":"p"}"#)!)
        XCTAssertEqual(file.fid, "f1")
        XCTAssertEqual(file.size, 10)
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.parentId, "p")
    }

    // MARK: 115

    static func flat(_ fields: [(String, String)]) -> [String] { fields.map { "\($0.0)=\($0.1)" } }

    func test115PersonalFiles() {
        let json = JSON(text: #"{"data":[{"cid":"100","pid":"0","n":"文件夹","t":"1700000000"},"# +
                              #"{"fid":"200","cid":"100","n":"a.zip","s":2048,"pc":"abc","t":"1700000001"},{"n":"坏条目"}]}"#)!
        let files = Pan115Resolver.parsePersonalFiles(json["data"].array)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].fid, "100")
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[0].parentId, "0")
        XCTAssertEqual(files[1].fid, "200")
        XCTAssertEqual(files[1].token, "abc")
        XCTAssertEqual(files[1].size, 2048)
        XCTAssertEqual(files[1].parentId, "100")
    }

    func test115Fields() {
        XCTAssertEqual(Self.flat(Pan115Resolver.renameFields(id: "9", name: "n")), ["fid=9", "file_name=n", "files_new_name[9]=n"])
        XCTAssertEqual(Self.flat(Pan115Resolver.moveFields(ids: ["1", "2"], to: "")), ["pid=0", "fid[0]=1", "fid[1]=2"])
        XCTAssertEqual(Self.flat(Pan115Resolver.deleteFields(ids: ["1"], pid: "5")), ["pid=5", "fid[0]=1", "ignore_warn=1"])
        XCTAssertEqual(Pan115Resolver.userId(fromCookie: "UID=12345_A1_1700000000; CID=x; SEID=y"), "12345")
        XCTAssertNil(Pan115Resolver.userId(fromCookie: "CID=x"))
        XCTAssertEqual(Pan115Resolver.errorNo(JSON(text: #"{"state":false,"errNo":800007}"#)!), 800007)
    }

    func test115Parsers() {
        let inner = Pan115Resolver.parseShareLink(JSON(text: #"{"state":true,"data":{"share_code":"sw1","receive_code":"ab12","# +
                                                             #""share_url":"https://115cdn.com/s/sw1?password=ab12"}}"#)!)
        XCTAssertEqual(inner?.code, "sw1")
        XCTAssertEqual(inner?.link, DriveShareLink(url: "https://115cdn.com/s/sw1?password=ab12", pwd: "ab12"))
        let top = Pan115Resolver.parseShareLink(JSON(text: #"{"state":true,"share_code":"sw2","sys_receive_code":"zz99"}"#)!)
        XCTAssertEqual(top?.link, DriveShareLink(url: "https://115cdn.com/s/sw2", pwd: "zz99"))
        XCTAssertNil(Pan115Resolver.parseShareLink(JSON(text: #"{"state":true,"data":{}}"#)!))
        let quota = Pan115Resolver.parseQuota(JSON(text: #"{"state":true,"data":{"space_info":{"all_total":{"size":1000},"# +
                                                         #""all_use":{"size":"250"}}}}"#)!)
        XCTAssertEqual(quota, DriveQuota(used: 250, total: 1000))
        XCTAssertNil(Pan115Resolver.parseQuota(JSON(text: #"{"state":true,"data":{}}"#)!))
    }
}
