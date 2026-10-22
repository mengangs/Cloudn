import XCTest
@testable import CloudnKit

/// Google 云端硬盘、OneDrive、阿里云盘：链接识别与页面 / 接口数据解析（不联网）
final class GlobalDriveTests: XCTestCase {

    // MARK: 链接识别

    func testGoogleDriveLinks() {
        let cases: [(String, GoogleDriveResolver.Target)] = [
            ("https://drive.google.com/drive/folders/15uNXeRBIhVvZJIhL4yTw4IsStMhUaaxl?usp=sharing", .folder("15uNXeRBIhVvZJIhL4yTw4IsStMhUaaxl")),
            ("https://drive.google.com/drive/u/1/folders/15uNXeRBIhVvZJIhL4yTw4IsStMhUaaxl", .folder("15uNXeRBIhVvZJIhL4yTw4IsStMhUaaxl")),
            ("https://drive.google.com/file/d/1l_5RK28JRL19wpT22B-DY9We3TVXnnQQ/view?usp=sharing", .file("1l_5RK28JRL19wpT22B-DY9We3TVXnnQQ")),
            ("https://drive.google.com/uc?id=0B9P1L--7Wd2vU3VUVlFnbTgtS2c", .file("0B9P1L--7Wd2vU3VUVlFnbTgtS2c")),
            ("https://drive.google.com/open?id=0B9P1L--7Wd2vU3VUVlFnbTgtS2c", .file("0B9P1L--7Wd2vU3VUVlFnbTgtS2c")),
            ("https://docs.google.com/presentation/d/1DvsG277pWa4WMssXjD9qYYAdF51y7hVidZ6eklfq480/edit?usp=drive_link",
             .doc(kind: "presentation", id: "1DvsG277pWa4WMssXjD9qYYAdF51y7hVidZ6eklfq480")),
            ("https://docs.google.com/spreadsheets/d/1SheetCdEfGhIjKlMnOpQrStUvWxYz3A/edit#gid=0", .doc(kind: "spreadsheets", id: "1SheetCdEfGhIjKlMnOpQrStUvWxYz3A")),
        ]
        for (url, target) in cases {
            XCTAssertEqual(GoogleDriveResolver.target(of: url), target, url)
            let parsed = ShareLinkParser.parse("看看这个 \(url) 好用")
            XCTAssertEqual(parsed?.platform, .gdrive, url)
            XCTAssertEqual(parsed?.shareId, target.id, url)
        }
        XCTAssertEqual(GoogleDriveResolver.resourceKey(in: "https://drive.google.com/drive/folders/0B1abcdefghij?resourcekey=0-AbC_d-1"), "0-AbC_d-1")
        XCTAssertNil(ShareLinkParser.parse("https://www.google.com/search?q=drive"))
    }

    func testOneDriveLinks() {
        for url in ["https://1drv.ms/f/c/05b6df5b859ecdde/IgBLUOUDkt5bQ4S80HI2Gb_7AZW-uXoxuXuFPXCrwOUrBPo?e=6fBF22",
                    "https://1drv.ms/u/s!AkfaAbCdEf",
                    "https://onedrive.live.com/?authkey=%21ABC&id=05B6DF5B859ECDDE%21123&cid=05B6DF5B859ECDDE",
                    "https://stuhiteducn-my.sharepoint.com/:f:/g/personal/1150700117_stu_hit_edu_cn/EumyrYnHDMtIiNoAHNshbXUBHU5diRWyGVB1rmso860kog?e=KKEKOO",
                    "https://contoso.sharepoint.com/:u:/s/team/EdAbC?e=1"] {
            let parsed = ShareLinkParser.parse(url + "。")
            XCTAssertEqual(parsed?.platform, .onedrive, url)
            XCTAssertEqual(parsed?.shareId, url, url)
        }
        XCTAssertNil(ShareLinkParser.parse("https://contoso.sharepoint.com/sites/team/Shared%20Documents"))
        XCTAssertTrue(OneDriveResolver.isSharePoint("https://contoso-my.sharepoint.com/:f:/g/personal/x/abc"))
        XCTAssertFalse(OneDriveResolver.isSharePoint("https://1drv.ms/f/c/abc/def"))
    }

    func testAliyunLinks() {
        let p = ShareLinkParser.parse("「Raptor」https://www.alipan.com/s/DW1H1JZgBoH 提取码: 8x2k\n点击链接保存")
        XCTAssertEqual(p?.platform, .aliyun)
        XCTAssertEqual(p?.shareId, "DW1H1JZgBoH")
        XCTAssertEqual(p?.pwd, "8x2k")
        XCTAssertEqual(ShareLinkParser.parse("https://www.aliyundrive.com/s/SwCbQBN2nZQ/folder/678e69868efed504046e469bb500c33129f809b9")?.shareId, "SwCbQBN2nZQ")
        XCTAssertEqual(AliyunResolver.folderId(in: "https://www.alipan.com/s/SwCbQBN2nZQ/folder/678e69868efed504046e469bb500c33129f809b9"),
                       "678e69868efed504046e469bb500c33129f809b9")
        XCTAssertNil(AliyunResolver.folderId(in: "https://www.alipan.com/s/SwCbQBN2nZQ"))
    }

    // MARK: Google

    /// 取自 embeddedfolderview 的真实页面（截短）
    static let folderHTML = """
    <!DOCTYPE html><html><head><title>gdown &amp; co</title></head><body><div class="flip-entries">\
    <div class="flip-entry" id="entry-1oow464Z4Et95RAwtRZn6dLOFb_YYpLwL" tabindex="0" role="link"><div class="flip-entry-info">\
    <a href="https://drive.google.com/drive/folders/1oow464Z4Et95RAwtRZn6dLOFb_YYpLwL" target="_blank"><div class="flip-entry-visual">\
    <div class="flip-entry-visual-card"><div class="flip-entry-icon"><div aria-label="Folder" class="icon-color-1 drive-sprite-folder-grid-shared-icon">\
    </div></div></div></div><div class="flip-entry-list-icon"><div aria-label="Folder" class="icon-color-1 drive-sprite-folder-list-shared-icon"></div></div>\
    <div class="flip-entry-title">deep_folder</div></a></div><div class="flip-entry-last-modified"><div>6/25/22</div></div></div>\
    <div class="flip-entry" id="entry-1TFYNzuZJTgNGzGmjraZ58ZVOh9_YoKeBnU-opWgXQL4" tabindex="0" role="link"><div class="flip-entry-info">\
    <a href="https://docs.google.com/document/d/1TFYNzuZJTgNGzGmjraZ58ZVOh9_YoKeBnU-opWgXQL4/edit?usp=drive_web" target="_blank">\
    <div class="flip-entry-title">gdown.docx</div></a></div><div class="flip-entry-last-modified"><div>Apr 11</div></div></div>\
    <div class="flip-entry" id="entry-1DvsG277pWa4WMssXjD9qYYAdF51y7hVidZ6eklfq480" tabindex="0" role="link"><div class="flip-entry-info">\
    <a href="https://docs.google.com/presentation/d/1DvsG277pWa4WMssXjD9qYYAdF51y7hVidZ6eklfq480/edit?usp=drive_web" target="_blank">\
    <div class="flip-entry-title">slides</div></a></div><div class="flip-entry-last-modified"><div>Apr 11</div></div></div>\
    <div class="flip-entry" id="entry-1l_5RK28JRL19wpT22B-DY9We3TVXnnQQ" tabindex="0" role="link"><div class="flip-entry-info">\
    <a href="https://drive.google.com/file/d/1l_5RK28JRL19wpT22B-DY9We3TVXnnQQ/view?usp=drive_web" target="_blank">\
    <div class="flip-entry-title">fcn8s &#39;caffe&#39;.npz</div></a></div><div class="flip-entry-last-modified"><div>5/2/18</div></div></div>\
    </div></body></html>
    """

    func testGoogleFolderPage() {
        let page = GoogleDriveResolver.parseFolderPage(Self.folderHTML)
        XCTAssertEqual(page.title, "gdown & co")
        XCTAssertEqual(page.entries.map(\.kind), ["folder", "doc:document", "doc:presentation", "file"])
        XCTAssertEqual(page.entries.map(\.id).last, "1l_5RK28JRL19wpT22B-DY9We3TVXnnQQ")
        let files = page.entries.map { $0.file(parent: "root") }
        XCTAssertEqual(files.map(\.name), ["deep_folder", "gdown.docx", "slides.pptx", "fcn8s 'caffe'.npz"])
        XCTAssertEqual(files.map(\.isDirectory), [true, false, false, false])
        XCTAssertEqual(files[0].modified, "6/25/22")
        XCTAssertEqual(GoogleDriveResolver.parseFolderPage("<html><title>empty</title><body></body></html>").entries, [])
    }

    func testGoogleNamesAndURLs() {
        XCTAssertEqual(GoogleDriveResolver.fileName(fromDisposition: #"attachment; filename="fcn8s_from_caffe.npz""#), "fcn8s_from_caffe.npz")
        XCTAssertEqual(GoogleDriveResolver.fileName(fromDisposition: #"attachment; filename="gdown.pptx"; filename*=UTF-8''%E6%B5%8B%E8%AF%95.pptx"#), "测试.pptx")
        XCTAssertNil(GoogleDriveResolver.fileName(fromDisposition: "inline"))
        XCTAssertEqual(GoogleDriveResolver.exportName("报告", kind: "document"), "报告.docx")
        XCTAssertEqual(GoogleDriveResolver.exportName("表.xlsx", kind: "spreadsheets"), "表.xlsx")
        XCTAssertNil(GoogleDriveResolver.exportFormat("forms"))
        XCTAssertEqual(GoogleDriveResolver.downloadURL("abc", key: ""), "https://drive.usercontent.google.com/download?id=abc&export=download&confirm=t")
        XCTAssertEqual(GoogleDriveResolver.downloadURL("abc", key: "0-k"), "https://drive.usercontent.google.com/download?id=abc&export=download&confirm=t&resourcekey=0-k")
        XCTAssertEqual(GoogleDriveResolver.exportURL(kind: "presentation", id: "x", format: "pptx", key: ""), "https://docs.google.com/presentation/d/x/export?format=pptx")
        XCTAssertEqual(GoogleDriveResolver.exportURL(kind: "drawings", id: "x", format: "png", key: "k"), "https://docs.google.com/drawings/d/x/export/png?resourcekey=k")
        XCTAssertEqual(GoogleDriveResolver.decodeEntities("a&#x4e2d;&#25991;&lt;b&gt;"), "a中文<b>")
    }

    // MARK: OneDrive

    func testOneDriveShareToken() {
        // 微软文档里的示例：base64url，去掉末尾的 =，前面加 u!
        XCTAssertEqual(OneDriveResolver.shareToken("https://onedrive.live.com/redir?resid=1231244193912!12&authKey=1201919!12921!1"),
                       "u!aHR0cHM6Ly9vbmVkcml2ZS5saXZlLmNvbS9yZWRpcj9yZXNpZD0xMjMxMjQ0MTkzOTEyITEyJmF1dGhLZXk9MTIwMTkxOSExMjkyMSEx")
        let token = OneDriveResolver.shareToken("https://1drv.ms/f/c/05b6df5b859ecdde/IgBLUOUDkt5bQ4S80HI2Gb_7AZW-uXoxuXuFPXCrwOUrBPo?e=6fBF22")
        XCTAssertFalse(token.contains("=") || token.contains("+") || token.contains("/"))
    }

    func testOneDriveItem() {
        let json = JSON(text: """
        {"id":"01JPYYOBU5DOCQHNE6YFBZREQG2AUBNKQU","name":"CID dataset.z01","size":4697620480,"file":{},
         "lastModifiedDateTime":"2019-04-01T08:00:00Z","parentReference":{"driveId":"b!abc","id":"01ROOT"},
         "@content.downloadUrl":"https://example.sharepoint.com/download.aspx?UniqueId=1"}
        """)!
        let f = OneDriveResolver.parseItem(json, parent: "01ROOT")
        XCTAssertEqual(f.fid, "01JPYYOBU5DOCQHNE6YFBZREQG2AUBNKQU")
        XCTAssertEqual(f.size, 4_697_620_480)
        XCTAssertFalse(f.isDirectory)
        XCTAssertEqual(f.token, "b!abc")
        let folder = OneDriveResolver.parseItem(JSON(text: #"{"id":"F","name":"CID","folder":{"childCount":7},"size":1}"#)!, parent: "")
        XCTAssertTrue(folder.isDirectory)
    }

    // MARK: 阿里云盘

    func testAliyunCredential() throws {
        let web = """
        {"access_token":"eyJhbGc.x.y","refresh_token":"0f1e2d3c4b5a69788796a5b4c3d2e1f0","expires_in":7200,"token_type":"Bearer",
         "user_id":"u1","user_name":"138***500","nick_name":"云端小陈","expire_time":"2026-10-22T10:00:00.123Z","default_drive_id":"1"}
        """
        let cred = try XCTUnwrap(AliyunCredential.parse(web))
        XCTAssertEqual(cred.refreshToken, "0f1e2d3c4b5a69788796a5b4c3d2e1f0")
        XCTAssertEqual(cred.accessToken, "eyJhbGc.x.y")
        XCTAssertEqual(cred.nickname, "云端小陈")
        XCTAssertEqual(cred.expiresAt, Int64(ISO8601DateFormatter.flexible("2026-10-22T10:00:00Z")!.timeIntervalSince1970))
        // 序列化后再解析不丢字段
        XCTAssertEqual(AliyunCredential.parse(cred.serialized), cred)
        XCTAssertEqual(AccountValidator.normalize(.aliyun, web), cred.serialized)
        // 手动粘贴的裸 refresh_token
        XCTAssertEqual(AliyunCredential.parse(" 0f1e2d3c4b5a69788796a5b4c3d2e1f0 ")?.refreshToken, "0f1e2d3c4b5a69788796a5b4c3d2e1f0")
        XCTAssertNil(AliyunCredential.parse("not a token!"))
        XCTAssertNil(AliyunCredential.parse(#"{"access_token":"x"}"#))
    }

    func testAliyunItemsAndErrors() {
        let item = JSON(text: """
        {"drive_id":"859958522","file_id":"65d459e6","name":"Raptor","type":"folder","updated_at":"2026-04-22T13:39:49.934Z"}
        """)!
        let f = AliyunResolver.parseFile(item, parent: "root")
        XCTAssertTrue(f.isDirectory)
        XCTAssertEqual(f.token, "859958522")
        XCTAssertEqual(AliyunResolver.error(JSON(text: #"{"code":"ShareLinkTokenInvalid","message":"x"}"#)!, status: 401, fallback: "").code,
                       AliyunResolver.shareTokenExpired)
        let pwd = AliyunResolver.error(JSON(text: #"{"code":"InvalidResource.SharePwd","message":"x"}"#)!, status: 400, fallback: "")
        XCTAssertTrue(pwd.message.contains("提取码"), "提取码错误时要让界面弹出提取码输入")
        XCTAssertTrue(AliyunResolver.error(JSON(text: #"{"code":"Other","message":"出错了"}"#)!, status: 400, fallback: "失败").message.contains("出错了"))
    }

    func testPlatformsRegistered() {
        let resolvers = ShareResolvers(credentials: NoCredentials())
        for p in [SharePlatform.aliyun, .gdrive, .onedrive] {
            XCTAssertNotNil(resolvers.resolver(for: p), p.rawValue)
        }
        XCTAssertEqual(SharePlatform.aliyun.accountKind, .aliyun)
        XCTAssertNil(SharePlatform.gdrive.accountKind)
        XCTAssertTrue(AccountKind.aliyun.isDrive)
    }
}
