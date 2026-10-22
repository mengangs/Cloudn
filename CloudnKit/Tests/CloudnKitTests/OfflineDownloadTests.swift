import XCTest
@testable import CloudnKit

/// 迅雷 / 115 / 123 / 光鸭 / 百度 / 夸克离线下载：请求体构造与任务列表解析（纯逻辑，不联网）
final class OfflineDownloadTests: XCTestCase {
    // MARK: 迅雷

    func testXunleiOfflineRequests() {
        XCTAssertEqual(XunleiResolver.offlineAddBody(url: "magnet:?xt=urn:btih:abc", parent: "VP1").text,
                       #"{"kind":"drive#file","name":"","parent_id":"VP1","upload_type":"UPLOAD_TYPE_URL","# +
                       #""url":{"url":"magnet:?xt=urn:btih:abc"},"space":""}"#)
        XCTAssertEqual(XunleiResolver.offlineListURL("https://api-pan.xunlei.com", pageToken: ""),
                       "https://api-pan.xunlei.com/drive/v1/tasks?type=offline&limit=100&page_token=&space=")
        XCTAssertEqual(XunleiResolver.offlineDeleteURL("https://b", ids: ["t1", "t2"]),
                       "https://b/drive/v1/tasks?task_ids=t1%2Ct2&delete_files=false&space=")
    }

    func testXunleiOfflineTasks() {
        let json = JSON(text: #"""
        {"tasks":[
          {"id":"t1","name":"a.mkv","phase":"PHASE_TYPE_RUNNING","progress":45,"file_size":"1000"},
          {"id":"t2","file_name":"b","phase":"PHASE_TYPE_COMPLETE","progress":100,"file_size":"20"},
          {"id":"t3","name":"c","phase":"PHASE_TYPE_ERROR","message":"资源失效","progress":0},
          {"id":"t4","name":"d","phase":"PHASE_TYPE_PENDING"},
          {"name":"no id"}
        ],"next_page_token":""}
        """#)!
        let tasks = XunleiResolver.parseOfflineTasks(json)
        XCTAssertEqual(tasks.count, 4)
        XCTAssertEqual(tasks[0], OfflineTask(id: "t1", name: "a.mkv", progress: 0.45, size: 1000, state: .running))
        XCTAssertEqual(tasks[1].name, "b")
        XCTAssertEqual(tasks[1].state, .done)
        XCTAssertEqual(tasks[1].progress, 1)
        XCTAssertEqual(tasks[2].state, .failed("资源失效"))
        XCTAssertEqual(tasks[3].state, .waiting)
    }

    // MARK: 115

    func testPan115OfflineRequests() {
        XCTAssertEqual(Pan115Resolver.offlineAddPayload(urls: ["magnet:?xt=1", "http://x/a"], folderId: "0", appVersion: "36.0.1", uid: "123"),
                       #"{"ac":"add_task_urls","app_ver":"36.0.1","uid":"123","url[0]":"magnet:?xt=1","url[1]":"http://x/a","wp_path_id":"0"}"#)
        XCTAssertEqual(Pan115Resolver.appVersion(fromUA: "Mozilla/5.0 115Browser/35.6.0.3"), "35.6.0.3")
        XCTAssertEqual(Pan115Resolver.appVersion(fromUA: "Mozilla/5.0"), "36.0.1")
        XCTAssertEqual(Pan115Resolver.offlineDeleteFields(hash: "h1").map { "\($0.0)=\($0.1)" }, ["hash=h1", "flag=0"])
    }

    func testPan115OfflineAddResult() throws {
        let ok = JSON(text: #"{"state":true,"result":[{"state":true,"info_hash":"abc","name":"movie","url":"magnet:?"}]}"#)!
        XCTAssertEqual(try Pan115Resolver.parseOfflineAddResult(ok), "movie")
        let quota = JSON(text: #"{"state":true,"result":[{"state":false,"errcode":10010,"error_msg":"quota"}]}"#)!
        XCTAssertThrowsError(try Pan115Resolver.parseOfflineAddResult(quota)) { error in
            XCTAssertEqual((error as? CloudnError)?.message, "离线配额已用完，需要会员")
        }
        let exists = JSON(text: #"{"state":false,"errno":10008,"error":"任务已存在"}"#)!
        XCTAssertThrowsError(try Pan115Resolver.parseOfflineAddResult(exists)) { error in
            XCTAssertEqual((error as? CloudnError)?.message, "该任务已存在")
        }
    }

    func testPan115OfflineTasks() {
        let json = JSON(text: #"""
        {"state":true,"page_count":1,"tasks":[
          {"info_hash":"h1","name":"A","size":2048,"status":1,"percentDone":12.5,"wp_path_id":"99"},
          {"info_hash":"h2","name":"","url":"http://x/b","size":1,"status":2,"percentDone":100,"wp_path_id":"0"},
          {"info_hash":"h3","name":"C","status":-1},
          {"info_hash":"h4","name":"D","status":0}
        ]}
        """#)!
        let tasks = Pan115Resolver.parseOfflineTasks(json)
        XCTAssertEqual(tasks.count, 4)
        XCTAssertEqual(tasks[0], OfflineTask(id: "h1", name: "A", progress: 0.125, size: 2048, state: .running, folderId: "99"))
        XCTAssertEqual(tasks[1].name, "http://x/b")
        XCTAssertEqual(tasks[1].state, .done)
        XCTAssertEqual(tasks[2].state, .failed("离线下载失败"))
        XCTAssertEqual(tasks[3].state, .waiting)
    }

    // MARK: 123

    func testPan123OfflineRequests() throws {
        let body = Pan123Resolver.offlineSubmitBody(resourceId: 7, fileIds: [1, 2], uploadDir: 0)
        let json = JSON(data: JSON.serialize(body))!
        XCTAssertEqual(json["resource_list"][0]["resource_id"].int64, 7)
        XCTAssertEqual(json["resource_list"][0]["select_file_id"].array.map(\.int64), [1, 2])
        XCTAssertEqual(json["upload_dir"].int64, 0)
        let list = JSON(data: JSON.serialize(Pan123Resolver.offlineListBody(page: 2)))!
        XCTAssertEqual(list["current_page"].int, 2)
        XCTAssertEqual(list["status_arr"].array.map(\.int), [0, 1, 2, 3])

        let resolved = try Pan123Resolver.parseOfflineResolve(JSON(text: #"{"code":0,"data":{"list":[{"result":0,"id":55,"files":[{"id":3,"name":"x.mp4"},{"id":0}]}]}}"#)!)
        XCTAssertEqual(resolved.id, 55)
        XCTAssertEqual(resolved.fileIds, [3])
        XCTAssertThrowsError(try Pan123Resolver.parseOfflineResolve(JSON(text: #"{"data":{"list":[{"result":1,"err_msg":"不支持的链接"}]}}"#)!)) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "不支持的链接")
        }
        XCTAssertNoThrow(try Pan123Resolver.checkOfflineSubmit(JSON(text: #"{"data":{"task_list":[{"task_id":9,"result":0}]}}"#)!))
        XCTAssertThrowsError(try Pan123Resolver.checkOfflineSubmit(JSON(text: #"{"data":{"task_list":[{"task_id":0,"result":1}]}}"#)!))
    }

    func testPan123OfflineTasks() {
        let json = JSON(text: #"""
        {"code":0,"data":{"total":3,"list":[
          {"task_id":1,"name":"a","status":0,"size":100,"downloaded":25,"progress":0,"upload_idr":12},
          {"task_id":2,"name":"b","status":2,"size":5,"progress":100},
          {"task_id":3,"name":"c","status":1,"size":5,"progress":40}
        ]}}
        """#)!
        let tasks = Pan123Resolver.parseOfflineTasks(json)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0], OfflineTask(id: "1", name: "a", progress: 0.25, size: 100, state: .running, folderId: "12"))
        XCTAssertEqual(tasks[1].state, .done)
        XCTAssertEqual(tasks[1].progress, 1)
        XCTAssertEqual(tasks[2].state, .failed("离线下载失败"))
        XCTAssertEqual(tasks[2].progress, 0.4)
    }

    // MARK: 光鸭

    func testGuangYaOfflineCreateBody() {
        let bt = JSON(text: #"{"resType":2,"url":"magnet:?xt=urn:btih:N","btResInfo":{"fileName":"剧集","subfiles":[{"fileIndex":3},{"fileName":"x"}]}}"#)!
        let req = GuangYaResolver.offlineCreateBody(bt, source: "magnet:?xt=urn:btih:n", parentId: "")
        XCTAssertEqual(req.name, "剧集")
        XCTAssertEqual(req.body.text, #"{"url":"magnet:?xt=urn:btih:N","parentId":"","newName":"剧集","fileIndexes":[3,1]}"#)
        let http = GuangYaResolver.offlineCreateBody(JSON(text: #"{"resType":1}"#)!, source: "https://x.com/dir/a%20b.zip?k=1", parentId: "f9")
        XCTAssertEqual(http.name, "a b.zip")
        XCTAssertEqual(http.body.text, #"{"url":"https://x.com/dir/a%20b.zip?k=1","parentId":"f9","newName":"a b.zip"}"#)
        XCTAssertEqual(GuangYaResolver.defaultOfflineName("magnet:?xt=urn:btih:n"), "offline_download")
    }

    func testGuangYaOfflineTasks() {
        let data = JSON(text: #"""
        {"cursor":"","total":4,"list":[
          {"taskId":"g1","fileName":"a","totalSize":10,"status":1,"progress":30},
          {"taskId":"g2","fileName":"b","totalSize":10,"status":5,"progress":80},
          {"taskId":"g3","fileName":"c","status":4},
          {"taskId":"g4","fileName":"d","status":0}
        ]}
        """#)!
        let tasks = GuangYaResolver.parseOfflineTasks(data)
        XCTAssertEqual(tasks.count, 4)
        XCTAssertEqual(tasks[0], OfflineTask(id: "g1", name: "a", progress: 0.3, size: 10, state: .running))
        XCTAssertEqual(tasks[1].state, .done)
        XCTAssertEqual(tasks[2].state, .failed("任务已取消"))
        XCTAssertEqual(tasks[3].state, .waiting)
    }

    // MARK: 百度

    func testBaiduOfflineParams() {
        func q(_ p: [(String, String)]) -> [String: String] { Dictionary(p, uniquingKeysWith: { _, b in b }) }
        let magnet = q(BaiduResolver.addTaskParams(source: "magnet:?xt=1", savePath: "/下载", magnetFileCount: 3))
        XCTAssertEqual(magnet["method"], "add_task")
        XCTAssertEqual(magnet["type"], "4")
        XCTAssertEqual(magnet["selected_idx"], "1,2,3")
        XCTAssertEqual(magnet["save_path"], "/下载")
        XCTAssertEqual(magnet["app_id"], "250528")
        let http = q(BaiduResolver.addTaskParams(source: "http://x/a", savePath: "/", magnetFileCount: nil))
        XCTAssertEqual(http["task_from"], "0")
        XCTAssertEqual(http["selected_idx"], "1")
        XCTAssertNil(http["type"])
        XCTAssertEqual(q(BaiduResolver.magnetInfoParams(source: "m", savePath: "/"))["method"], "query_magnetinfo")
        XCTAssertEqual(q(BaiduResolver.queryTaskParams(ids: ["1", "2"]))["task_ids"], "1,2")
        let url = BaiduResolver.cloudDlRequestURL([("method", "list_task"), ("save_path", "/a b")], bdstoken: "tk")
        XCTAssertEqual(url, "https://pan.baidu.com/rest/2.0/services/cloud_dl?method=list_task&save_path=%2Fa%20b&channel=chunlei&web=1&clienttype=0&bdstoken=tk")
    }

    func testBaiduOfflineErrors() {
        XCTAssertNoThrow(try BaiduResolver.checkCloudDl(JSON(text: #"{"task_id":1,"request_id":2}"#)!))
        XCTAssertThrowsError(try BaiduResolver.checkCloudDl(JSON(text: #"{"error_code":36016,"error_msg":"task already exist"}"#)!)) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "该任务已存在")
        }
        XCTAssertThrowsError(try BaiduResolver.checkCloudDl(JSON(text: #"{"error_code":36099,"error_msg":"unknown"}"#)!)) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "unknown")
        }
    }

    func testBaiduOfflineTasks() {
        let list = JSON(text: #"""
        {"task_info":[
          {"task_id":"11","task_name":"a.iso","status":"1","save_path":"/下载","source_url":"magnet:?a"},
          {"task_id":"12","task_name":"","status":"0","save_path":"/","source_url":"http://x/b"},
          {"task_id":"13","task_name":"c","status":"6","save_path":"/"}
        ],"total":3}
        """#)!
        var tasks = BaiduResolver.parseOfflineTasks(list)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0].state, .running)
        XCTAssertNil(tasks[0].progress)
        XCTAssertEqual(tasks[0].folderId, "/下载")
        XCTAssertEqual(tasks[1].name, "http://x/b")
        XCTAssertEqual(tasks[1].progress, 1)
        XCTAssertEqual(tasks[2].state, .failed("网盘空间不足"))

        let detail = JSON(text: #"{"task_info":{"11":{"status":"1","file_size":"400","finished_size":"100","task_name":"a.iso","save_path":"/下载"}}}"#)!
        tasks = BaiduResolver.mergeQueryTask(tasks, detail)
        XCTAssertEqual(tasks[0], OfflineTask(id: "11", name: "a.iso", progress: 0.25, size: 400, state: .running, folderId: "/下载"))
        XCTAssertEqual(tasks[1].id, "12")
    }

    // MARK: 夸克

    func testQuarkWGEnvelope() {
        // 公开的测试向量（qrypt / QuarkPlusPlus）
        XCTAssertEqual(QuarkFamilyResolver.wgEncrypt("hello"), "NxTFGiL/qySwJSpexPNDuS1r")
        XCTAssertEqual(QuarkFamilyResolver.wgDecrypt("NxTFGiL/qySwJSpexPNDuS1r"), "hello")
        let body = QuarkFamilyResolver.offlineSubmitBody(token: "tk_m", pdirFid: "0", files: [0, 2]).text
        XCTAssertEqual(QuarkFamilyResolver.wgDecrypt(QuarkFamilyResolver.wgEncrypt(body)), body)
        XCTAssertNil(QuarkFamilyResolver.wgDecrypt("not base64"))
    }

    func testQuarkOfflineBodies() {
        XCTAssertEqual(QuarkFamilyResolver.offlineSubmitBody(token: "tk", pdirFid: "d1", files: [0, 3]).text,
                       #"{"token":"tk","entry":"download","parse_mode":0,"pdir_fid":"d1","auto_select":false,"selected_files":[0,3],"title":""}"#)
        let parse = JSON(text: QuarkFamilyResolver.offlineParseBody(url: "magnet:?xt=1").text)!
        XCTAssertEqual(parse["url"].string, "magnet:?xt=1")
        XCTAssertEqual(parse["entry"].string, "download")
        XCTAssertEqual(parse["conflict_mode"].int, 4)
        XCTAssertFalse(parse["auto_download"].bool)
        XCTAssertEqual(QuarkFamilyResolver.taskStatusBody(ids: ["a"], opType: 0).text, #"{"task_ids":["a"],"op_type":0}"#)
        let files = JSON(text: #"[{"file_no":0},{"file_no":"3,4"},{"file_no":4},{"file_name":"x"}]"#)!.array
        XCTAssertEqual(QuarkFamilyResolver.selectedFileNumbers(files), [0, 3, 4])
    }

    func testQuarkOfflineTasks() throws {
        let data = JSON(text: #"""
        {"list":[
          {"task_id":"q1","task_type":5,"task_title":"电影","status":1,"progress":250},
          {"task_id":"q2","task_type":5,"task_title":"","status":2,"progress":1000,
           "offdl_result":{"list":[{"fid":"f1","file_name":"b.mkv","pdir_fid":"d9","size":30},{"fid":"f2","size":12}]}},
          {"task_id":"q3","task_type":5,"task_title":"c","status":3},
          {"task_id":"q4","task_type":1,"task_title":"转存"}
        ]}
        """#)!
        let tasks = QuarkFamilyResolver.parseOfflineTasks(data)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0], OfflineTask(id: "q1", name: "电影", progress: 0.25, size: 0, state: .running))
        XCTAssertEqual(tasks[1], OfflineTask(id: "q2", name: "b.mkv", progress: 1, size: 42, state: .done, folderId: "d9"))
        XCTAssertEqual(tasks[2].state, .failed("离线下载失败"))

        XCTAssertNoThrow(try QuarkFamilyResolver.checkOffline(JSON(text: #"{"status":200,"code":0,"data":{}}"#)!, status: 200, fallback: "x"))
        XCTAssertNoThrow(try QuarkFamilyResolver.checkOffline(JSON(text: #"{"task_id":"q","status":2,"code":0}"#)!, status: 200, fallback: "x"))
        XCTAssertThrowsError(try QuarkFamilyResolver.checkOffline(JSON(text: #"{"status":400,"code":32007,"message":"dup"}"#)!, status: 400, fallback: "x")) {
            XCTAssertEqual(($0 as? CloudnError)?.message, "该任务已存在")
        }
    }

    func testQuarkOfflineSchemesOnlyForQuark() {
        let quark = QuarkFamilyResolver(config: .quark, credentials: NoCredentials())
        let uc = QuarkFamilyResolver(config: .uc, credentials: NoCredentials())
        XCTAssertTrue(quark.acceptsOffline("magnet:?xt=urn:btih:abc"))
        XCTAssertFalse(uc.acceptsOffline("magnet:?xt=urn:btih:abc"))
    }
}
