import XCTest
@testable import CloudnKit

/// 123 云盘 / 139 网盘「我的网盘」管理：请求体构造与响应解析（纯逻辑，不联网）
final class DriveManager123C139Tests: XCTestCase {
    /// [String: Any] 先序列化再解析，和实际发出去的 JSON 一致
    private func roundTrip(_ body: [String: Any]) -> JSON {
        JSON(data: JSON.serialize(body))!
    }

    // MARK: 123 云盘

    func testPan123DownloadBody() {
        let file = ShareFile(fid: "123456", name: "a.zip", size: 99, isDirectory: false, token: "flag-0|etag1|node")
        let body = roundTrip(Pan123Resolver.driveDownloadBody(file))
        XCTAssertEqual(body["fileId"].int64, 123456)
        XCTAssertEqual(body["s3keyFlag"].string, "flag-0")
        XCTAssertEqual(body["etag"].string, "etag1")
        XCTAssertEqual(body["size"].int64, 99)
        XCTAssertEqual(body["type"].int, 0)
        XCTAssertEqual(body["driveId"].int, 0)
        XCTAssertEqual(body["fileName"].string, "a.zip")
    }

    func testPan123CreateRenameMoveBodies() {
        let folder = roundTrip(Pan123Resolver.createFolderBody(name: "新建", parentId: "88"))
        XCTAssertEqual(folder["parentFileId"].int64, 88)
        XCTAssertEqual(folder["type"].int, 1)
        XCTAssertTrue(folder["NotReuse"].bool)
        XCTAssertTrue(folder.has("RequestSource"))
        XCTAssertTrue(folder["RequestSource"].isNull)

        let rename = roundTrip(Pan123Resolver.renameBody(fileId: "5", name: "b.txt"))
        XCTAssertEqual(rename["fileId"].int64, 5)
        XCTAssertEqual(rename["fileName"].string, "b.txt")
        XCTAssertEqual(rename["event"].string, "fileRename")

        let move = roundTrip(Pan123Resolver.moveBody(fileIds: ["1", "2"], to: "0"))
        XCTAssertEqual(move["fileIdList"].array.map { $0["FileId"].int64 }, [1, 2])
        XCTAssertEqual(move["parentFileId"].int64, 0)
        XCTAssertEqual(move["event"].string, "fileMove")
    }

    func testPan123TrashBody() {
        let files = [ShareFile(fid: "7", name: "d", size: 0, isDirectory: true, token: "||"),
                     ShareFile(fid: "8", name: "f", size: 10, isDirectory: false, token: "s3|e|n")]
        let body = roundTrip(Pan123Resolver.trashBody(files))
        let list = body["fileTrashInfoList"].array
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["Type"].int, 1)
        XCTAssertEqual(list[1]["S3KeyFlag"].string, "s3")
        XCTAssertEqual(list[1]["Etag"].string, "e")
        XCTAssertEqual(body["event"].string, "intoRecycle")
        XCTAssertTrue(body["operation"].bool)
    }

    func testPan123ShareBody() {
        let single = roundTrip(Pan123Resolver.shareCreateBody(fileIds: ["42"], name: "x", pwd: "ab12"))
        XCTAssertEqual(single["fileIdList"].int64, 42)
        XCTAssertEqual(single["sharePwd"].string, "ab12")
        XCTAssertEqual(single["expiration"].string, "2099-12-12T08:00:00+08:00")
        XCTAssertEqual(single["fileNum"].int, 1)
        let multi = roundTrip(Pan123Resolver.shareCreateBody(fileIds: ["1", "2"], name: "y", pwd: ""))
        XCTAssertEqual(multi["fileIdList"].array.map(\.int64), [1, 2])
        XCTAssertFalse(multi.has("sharePwd"))
    }

    func testPan123ShareURL() {
        XCTAssertEqual(Pan123Resolver.shareURL(from: JSON(text: #"{"ShareKey":"k1","shareLinkList":{"list":["https://a/s/k1"]}}"#)!),
                       "https://a/s/k1")
        XCTAssertEqual(Pan123Resolver.shareURL(from: JSON(text: #"{"ShareKey":"k1","shareLinkList":{"standBy":"https://b/s/k1"}}"#)!),
                       "https://b/s/k1")
        XCTAssertEqual(Pan123Resolver.shareURL(from: JSON(text: #"{"ShareKey":"k1"}"#)!), "https://www.123pan.com/s/k1")
        XCTAssertNil(Pan123Resolver.shareURL(from: JSON(text: #"{"ShareKey":""}"#)!))
    }

    func testPan123Quota() {
        let q = Pan123Resolver.parseQuota(JSON(text: #"{"SpaceUsed":100,"SpacePermanent":2000,"SpaceTemp":500}"#)!)
        XCTAssertEqual(q, DriveQuota(used: 100, total: 2500))
        XCTAssertNil(Pan123Resolver.parseQuota(JSON(nil)))
    }

    // MARK: 139 网盘

    func testC139DriveListBodyKeepsNullCursor() {
        XCTAssertEqual(C139Resolver.driveListBody(parentId: "/", cursor: .null).text,
                       #"{"pageInfo":{"pageSize":100,"pageCursor":null},"orderBy":"updated_at","orderDirection":"DESC","parentFileId":"/","imageThumbnailStyleList":["Small","Large"]}"#)
        XCTAssertTrue(C139Resolver.driveListBody(parentId: "x", cursor: .string("c2")).text.contains(#""pageCursor":"c2""#))
    }

    func testC139ParseDriveList() {
        let data = JSON(text: #"{"items":[{"fileId":"F1","name":"dir","type":"folder","updatedAt":"t1"},{"fileId":"F2","name":"a.mp4","type":"file","size":1234}],"nextPageCursor":null}"#)!
        let files = C139Resolver.parseDriveList(data, parent: "/")
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[0].modified, "t1")
        XCTAssertFalse(files[1].isDirectory)
        XCTAssertEqual(files[1].size, 1234)
        XCTAssertEqual(files[1].token, "F2")
        XCTAssertEqual(files[1].parentId, "/")
        XCTAssertEqual(data["nextPageCursor"].string, "")
    }

    func testC139CreateFolderBody() {
        XCTAssertEqual(C139Resolver.createFolderBody(name: "新建", parentId: "/").text,
                       #"{"parentFileId":"/","name":"新建","description":"","type":"folder","fileRenameMode":"force_rename"}"#)
    }

    func testC139OutLinkBody() {
        let files = [ShareFile(fid: "co1", name: "a", size: 1, isDirectory: false),
                     ShareFile(fid: "ca1", name: "d", size: 0, isDirectory: true)]
        XCTAssertEqual(C139Resolver.outLinkBody(account: "13800000000", files: files, name: "分享").text,
                       #"{"getOutLinkReq":{"subLinkType":0,"encrypt":1,"coIDLst":["co1"],"caIDLst":["ca1"],"pubType":1,"dedicatedName":"分享","periodUnit":1,"viewerLst":[],"extInfo":{"isWatermark":0,"shareChannel":"3001"},"commonAccountInfo":{"account":"13800000000","accountType":1}}}"#)
    }

    func testC139ParseOutLink() {
        let data = JSON(text: #"{"getOutLinkRes":{"getOutLinkResSet":[{"linkUrl":"https://caiyun.139.com/m/i?abc","passwd":"x1y2","linkID":"abc"}]}}"#)!
        XCTAssertEqual(C139Resolver.parseOutLink(data), DriveShareLink(url: "https://caiyun.139.com/m/i?abc", pwd: "x1y2"))
        XCTAssertNil(C139Resolver.parseOutLink(JSON(text: #"{"getOutLinkRes":{}}"#)!))
    }

    func testC139CheckPersonal() {
        XCTAssertNoThrow(try C139Resolver.checkPersonal(JSON(text: #"{"success":true,"code":"0000"}"#)!, fallback: "x"))
        XCTAssertNoThrow(try C139Resolver.checkPersonal(JSON(text: #"{"code":"0"}"#)!, fallback: "x"))
        XCTAssertThrowsError(try C139Resolver.checkPersonal(JSON(text: #"{"success":false,"code":"04000005","message":"认证失败"}"#)!, fallback: "x")) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "认证失败")
        }
    }

    func testC139TaskFinished() throws {
        XCTAssertTrue(try C139Resolver.taskFinished(JSON(text: #"{"taskInfo":{"status":"Succeed","progress":50}}"#)!))
        XCTAssertTrue(try C139Resolver.taskFinished(JSON(text: #"{"taskInfo":{"status":"Running","progress":100}}"#)!))
        XCTAssertFalse(try C139Resolver.taskFinished(JSON(text: #"{"taskInfo":{"status":"Running","progress":10},"batchFileResults":[{"fileId":"a","errCode":"0000"}]}"#)!))
        XCTAssertThrowsError(try C139Resolver.taskFinished(JSON(text: #"{"taskInfo":{"progress":10},"batchFileResults":[{"fileId":"a","errCode":"13000001"}]}"#)!))
    }

    func testC139Quota() {
        let mb: Int64 = 1024 * 1024
        let withList = C139Resolver.parseQuota(JSON(text: #"{"diskSize":2048,"freeDiskSize":1000,"quotaList":[{"usedSize":300}]}"#)!)
        XCTAssertEqual(withList, DriveQuota(used: 300 * mb, total: 2048 * mb))
        let noList = C139Resolver.parseQuota(JSON(text: #"{"diskSize":2048,"freeDiskSize":1000}"#)!)
        XCTAssertEqual(noList, DriveQuota(used: 1048 * mb, total: 2048 * mb))
    }
}
