// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
#if DEBUG
import CloudnKit
import Foundation
import Network
import SwiftUI
import UIKit

/// 截图模式（仅 Debug 构建）：只在带 `-CloudnScreenshot <页面>` 启动参数时生效，供 CI 自动截图（见 .github/workflows/screenshots.yml）。
///
/// 生效时：
/// - 数据目录换成每次启动都清空重建的临时目录，预置一套固定的演示数据（最近记录、收藏、下载任务、解析结果、预览文件）；
///   「首次使用」类页面（resolve-empty 等）什么都不预置；
/// - 偏好设置只写进不落盘的参数域（关掉剪贴板提示、自动检查更新、实时活动、通知等）；
/// - 「下载中」的任务连到本机回环地址上的限速服务，有真实的进度和速度，不访问外网；
/// - 网盘分享、我的网盘、转存、视频解析换成本地演示数据（分享页的各种出错状态也由这里给出）；
/// - 演示账号（仅模拟器）只在账号仓库读取的那一刻写进钥匙串，读完立即删掉，不留在钥匙串里。
///
/// 不带这个参数启动时 `screen` 为 nil，这里的代码都不会运行；Release 构建里没有这个文件的内容
enum ScreenshotMode {
    enum Screen: String, CaseIterable {
        // 解析
        case resolve
        /// 首次打开：没有任何记录
        case resolveEmpty = "resolve-empty"
        /// 剪贴板里有链接
        case clipboard
        /// 输入框识别出网盘分享与提取码
        case detect
        /// 单个作品解析中
        case resolving
        /// 作者主页翻页获取中
        case collecting
        /// 解析失败：给出网页嗅探 / 去登录
        case resolveFailed = "resolve-failed"
        // 作品详情
        case video
        /// 刚加入下载：行尾变成进度、底部提示
        case videoAdded = "video-added"
        /// 多清晰度 + 分轨 + 字幕 + 登录已失效
        case videoBili = "video-bili"
        /// 作者主页 / 合集勾选
        case collection
        case batch
        // 网盘分享
        case share
        case shareSelect = "share-select"
        case sharePassword = "share-password"
        case shareExpired = "share-expired"
        case shareGuest = "share-guest"
        /// 转存：选目标文件夹
        case save
        // 网页嗅探
        case sniffer
        case snifferList = "sniffer-list"
        case snifferRecord = "sniffer-record"
        // 下载
        case downloads
        case downloadsEmpty = "downloads-empty"
        /// 只有一个展开的分享分组：看分组里直链失效（可换链）的失败任务
        case downloadsGroup = "downloads-group"
        case previewImage = "preview-image"
        case previewText = "preview-text"
        // 我的
        case me
        case meEmpty = "me-empty"
        case accountList = "account-list"
        case drive
        case settings
        /// 真实网络：GitHub 仓库（和粘贴链接后的正常流程一样）
        case github

        var tab: AppTab {
            switch self {
            case .downloads, .downloadsEmpty, .downloadsGroup, .previewImage, .previewText: return .downloads
            case .me, .meEmpty, .accountList, .drive, .settings: return .me
            default: return .resolve
            }
        }

        /// 首次使用：不预置任何记录、下载与账号
        var isFresh: Bool { [Screen.resolveEmpty, .clipboard, .downloadsEmpty, .meEmpty].contains(self) }

        var isShare: Bool { [Screen.share, .shareSelect, .sharePassword, .shareExpired, .shareGuest, .save].contains(self) }
    }

    static let argument = "-CloudnScreenshot"

    /// 启动参数指定的页面；没带参数为 nil（正常启动）
    static let screen: Screen? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: ScreenshotMode.argument), i + 1 < args.count else { return nil }
        return Screen(rawValue: args[i + 1])
    }()

    static var isActive: Bool { screen != nil }

    /// `-CloudnAccent RRGGBB`：用指定主题色截图（检查各主题色的对比度）；没带为 nil（默认陶土色）
    static let accentHex: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-CloudnAccent"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    struct Directories {
        let support: URL
        let documents: URL
    }

    /// 演示用的解析结果（视频 + 图集 + 实况照片）
    @MainActor private(set) static var demoResult: VideoParseResult?
    /// 哔哩哔哩：多清晰度、分轨、字幕
    @MainActor private(set) static var biliResult: VideoParseResult?
    /// 作者主页（合集勾选）
    @MainActor private(set) static var collectionResult: VideoParseResult?
    /// 预览页打开的本地文件
    @MainActor private(set) static var previewImageURL: URL?
    @MainActor private(set) static var previewTextURL: URL?

    @MainActor private static let server = DemoDownloadServer()
    @MainActor private static var seededKeychainKeys: [String] = []

    // MARK: 启动时准备

    /// AppModel 初始化时最先调用：截图模式下准备临时目录与演示数据并返回目录；正常启动返回 nil、什么都不做
    @MainActor
    static func prepare() -> Directories? {
        guard let screen else { return nil }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CloudnScreenshot", isDirectory: true)
        try? fm.removeItem(at: root)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let documents = root.appendingPathComponent("documents", isDirectory: true)
        let media = root.appendingPathComponent("media", isDirectory: true)
        for dir in [support, documents, media] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        applyDefaults(screen)
        let port: UInt16 = server.start() ? server.port : 0
        let images = writeMedia(media: media, documents: documents)
        if !screen.isFresh {
            writeBookmarks(support: support)
            writeDownloads(support: support, port: port)
            seedAccounts()
        }
        if screen == .clipboard {
            // 应用自己写进去的不算「处理过」：解析页照常提示
            UIPasteboard.general.string = "7.94 复制打开抖音，看看【山野散步的作品】雨后的西湖 https://v.douyin.com/iRNBho6/ 07/12 Gbq:/"
        }
        demoResult = makeResult(images: images, port: port)
        biliResult = makeBiliResult(images: images, port: port)
        collectionResult = makeCollection(images: images)
        return Directories(support: support, documents: documents)
    }

    /// 账号仓库已把演示账号读进内存：从钥匙串删掉（只删本次写入的）
    @MainActor
    static func accountsLoaded() {
        for key in seededKeychainKeys { Keychain.delete(key) }
        seededKeychainKeys = []
    }

    /// 偏好设置写进参数域（优先级最高、不落盘，退出即失效）
    private static func applyDefaults(_ screen: Screen) {
        // 哔哩哔哩的登录已失效（「我的」页红点、作品页的重新登录提示），其余有效
        let health: [String: AccountStore.HealthRecord] = Dictionary(uniqueKeysWithValues: demoAccounts.map {
            ($0.kind.rawValue, AccountStore.HealthRecord(expired: $0.kind == .bilibili, checkedAt: Date()))
        })
        var overrides: [String: Any] = [
            "acceptedNotice": true,
            "clipboardHint": screen == .clipboard,
            "autoCheckUpdates": false,
            "lastUpdateCheck": Date(),
            "liveActivity": false,
            "notifyOnFinish": false,
            "autoSaveToPhotos": false,
            "maxConcurrentTasks": 2,
            "retryCount": 3,
            "speedLimitKB": 0,
            "appearance": Appearance.system.rawValue,
            "accentHex": accentHex ?? "",
            "platformIconStyle": PlatformIconStyle.line.rawValue,
            "hiddenDrives": [String](),
            "proxyEnabled": false,
            "multiAccountDownload": false,
        ]
        if let data = try? JSONEncoder().encode(health) { overrides["accountHealth"] = data }
        if !screen.isFresh {
            // 「我的」页网盘卡片上的容量（上次取到的缓存）
            let tb: Int64 = 1 << 40
            let quotas = [
                "quark": CachedQuota(used: tb * 138 / 100, total: tb * 6, owner: "云端小陈"),
                "baidu": CachedQuota(used: tb * 162 / 100, total: tb * 205 / 100, owner: "陈小舟"),
                "pan123": CachedQuota(used: tb * 31 / 100, total: tb * 2, owner: "chenzhou"),
            ]
            if let data = try? JSONEncoder().encode(quotas) { overrides["accounts.quotaCache"] = data }
        }
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain.merge(overrides) { $1 }
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    // MARK: 演示账号

    private static let demoAccounts: [(kind: AccountKind, names: [String])] = [
        (.quark, ["云端小陈", "小陈的工作号"]),
        (.baidu, ["陈小舟"]),
        (.pan123, ["chenzhou"]),
        (.bilibili, ["小陈不吃香菜"]),
        (.xiaohongshu, ["山野散步"]),
    ]

    /// 只在模拟器上、且该平台本机没有账号时写入；AppModel 建好账号仓库后由 accountsLoaded 立即删掉
    @MainActor
    private static func seedAccounts() {
        #if targetEnvironment(simulator)
        let encoder = JSONEncoder()
        for (kind, names) in demoAccounts {
            guard Keychain.read(kind.rawValue) == nil, Keychain.read(kind.rawValue + ".extra") == nil else { continue }
            let accounts = names.enumerated().map { index, name in
                Account(cookie: "cloudn-screenshot-demo-\(kind.rawValue)-\(index)", nickname: name,
                        updatedAt: Date().addingTimeInterval(-86_400 * Double(index + 2)))
            }
            guard let primary = try? encoder.encode(accounts[0]), Keychain.write(kind.rawValue, primary) else { continue }
            seededKeychainKeys.append(kind.rawValue)
            if accounts.count > 1, let extra = try? encoder.encode(Array(accounts.dropFirst())),
               Keychain.write(kind.rawValue + ".extra", extra) {
                seededKeychainKeys.append(kind.rawValue + ".extra")
            }
        }
        #endif
    }

    // MARK: 演示链接

    static let designShareURL = "https://pan.quark.cn/s/7f3a9c2e1b4d"

    /// 各页面打开的链接
    static var demoLink: String {
        switch screen {
        case .detect: return "链接: https://pan.baidu.com/s/1Xa9kLmN2bQ7rTcV 提取码: 8k2m 复制这段内容后打开百度网盘手机App，操作更方便哦"
        case .resolving, .resolveFailed: return "https://www.bilibili.com/video/BV1xK4y1Z7aB"
        case .github: return "https://github.com/mengangs/Cloudn"
        case .collecting: return "https://www.douyin.com/user/MS4wLjABAAAAv7iSuuXDJGDvJkmH_vz1qkDZYo1apxgzaxdBSeIuPi2tKj"
        case .sharePassword: return "https://pan.baidu.com/s/1AbCdEfGh2jKmN3p"
        case .shareExpired: return "https://pan.quark.cn/s/0d9e8f7a6b5c"
        case .shareGuest: return "https://pan.xunlei.com/s/VNa1b2c3d4e5f6g7h8"
        default: return designShareURL
        }
    }

    // MARK: 收藏与最近记录

    private static func writeBookmarks(support: URL) {
        let now = Date()
        let bookmarks = [
            Bookmark(title: "每周壁纸", text: "https://pan.quark.cn/s/2b8e4f6a9c1d", source: "夸克网盘", createdAt: now.addingTimeInterval(-86_400 * 3)),
            Bookmark(title: "纪录片合集", text: "https://pan.xunlei.com/s/VNa1b2c3d4e5f6g7h8", source: "迅雷网盘", createdAt: now.addingTimeInterval(-86_400 * 5)),
            Bookmark(title: "Cloudn", text: "https://github.com/mengangs/Cloudn", source: "GitHub", createdAt: now.addingTimeInterval(-86_400 * 6)),
            Bookmark(title: "常用工具", text: "https://wwi.lanzoux.com/b0f1a2b3c", source: "蓝奏云", createdAt: now.addingTimeInterval(-86_400 * 9)),
        ]
        let history = [
            Bookmark(title: "设计素材合集", text: designShareURL, source: "夸克网盘", createdAt: now.addingTimeInterval(-12 * 60)),
            Bookmark(title: "雨后的西湖，苏堤一路走到断桥", text: "https://www.xiaohongshu.com/explore/66f1a2b3000000001e03c4d5",
                     source: "小红书", createdAt: now.addingTimeInterval(-35 * 60)),
            Bookmark(title: "期末复习资料", text: "https://pan.baidu.com/s/1Xa9kLmN2bQ7rTcV?pwd=8k2m", source: "百度网盘",
                     createdAt: now.addingTimeInterval(-2 * 3600)),
            Bookmark(title: "城市夜景延时摄影", text: "https://www.bilibili.com/video/BV1xK4y1Z7aB", source: "哔哩哔哩",
                     createdAt: now.addingTimeInterval(-5 * 3600)),
            Bookmark(title: "SwiftUI 实战课程", text: "https://www.123pan.com/s/aBcD-Ef9Gh", source: "123 云盘",
                     createdAt: now.addingTimeInterval(-26 * 3600)),
            Bookmark(title: "mengangs/Cloudn", text: "https://github.com/mengangs/Cloudn", source: "GitHub",
                     createdAt: now.addingTimeInterval(-50 * 3600)),
        ]
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(bookmarks) { try? data.write(to: support.appendingPathComponent("bookmarks.json")) }
        if let data = try? encoder.encode(history) { try? data.write(to: support.appendingPathComponent("history.json")) }
    }

    // MARK: 下载任务

    /// 直接写下载引擎的任务表（downloads.json），引擎启动时照常读取。
    /// 「下载中」的两个任务以排队状态写入、带上已下好的分片与预留好的数据文件，引擎回到前台后从本机限速服务续传
    private static func writeDownloads(support: URL, port: UInt16) {
        let fm = FileManager.default
        let now = Date()
        var list: [[String: Any]] = []

        func add(_ name: String, source: String, total: Int64, status: DownloadStatus, received: Int64 = 0, ago: TimeInterval,
                 finishedAgo: TimeInterval? = nil, error: String? = nil, folder: String = "", group: DownloadGroup? = nil,
                 origin: ShareOrigin? = nil, rate: Int64? = nil) {
            let id = UUID()
            var status = status
            var url = "https://cloudn.invalid/demo/\(id.uuidString.prefix(8))"
            var chunks: [[String: Any]] = received > 0 ? [["start": 0, "end": total - 1, "received": received]] : []
            if let rate {
                if port > 0 {
                    url = "http://127.0.0.1:\(port)/\(id.uuidString.prefix(8)).bin?size=\(total)&rate=\(rate)"
                    // 续传用的数据文件：按总长预留（稀疏文件，不真的占空间）
                    let dir = support.appendingPathComponent("work/\(id.uuidString)", isDirectory: true)
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let file = dir.appendingPathComponent("data")
                    fm.createFile(atPath: file.path, contents: nil)
                    if let handle = try? FileHandle(forWritingTo: file) {
                        try? handle.truncate(atOffset: UInt64(total))
                        try? handle.close()
                    }
                    status = .queued
                } else {
                    status = .paused
                }
                chunks = [["start": 0, "end": total - 1, "received": received]]
            }
            let request = DownloadRequest(url: url, fileName: name, folder: folder, expectedSize: total, source: source,
                                          origin: origin, group: group)
            guard let data = try? JSONEncoder().encode(request), let requestObject = try? JSONSerialization.jsonObject(with: data) else { return }
            var item: [String: Any] = [
                "id": id.uuidString,
                "request": requestObject,
                "status": status.rawValue,
                "totalBytes": total,
                "receivedBytes": status == .completed ? total : received,
                "createdAt": now.addingTimeInterval(-ago).timeIntervalSinceReferenceDate,
                "chunks": chunks,
                "phase": 0,
                "segmentsDone": 0,
                "segmentsTotal": 0,
            ]
            if let finishedAgo { item["finishedAt"] = now.addingTimeInterval(-finishedAgo).timeIntervalSinceReferenceDate }
            if status == .completed { item["outputPath"] = folder.isEmpty ? name : folder + "/" + name }
            if let error { item["errorMessage"] = error }
            list.append(item)
        }

        let mb: Int64 = 1024 * 1024
        let groupOnly = screen == .downloadsGroup
        // 排在最前（最新）的排队任务等前两个下载中的任务（同时下载上限 2）
        if !groupOnly {
            add("期末复习资料.zip", source: "百度网盘", total: 128 * mb, status: .queued, ago: 40)
            add("雨后的西湖_1080P.mp4", source: "小红书", total: 86 * mb + 412_000, status: .running, received: 49 * mb,
                ago: 90, rate: 3_400_000)
            add("河西走廊 第3集.mkv", source: "夸克网盘", total: 1_502 * mb, status: .running, received: 583 * mb,
                ago: 240, rate: 5_900_000)
            add("SwiftUI 实战 第12讲.mp4", source: "123 云盘", total: 642 * mb, status: .paused, received: 251 * mb, ago: 2 * 3600)
        }
        // 没有来源信息、不能重新取链的失败任务：重试仍用原地址（与分组里能换链的那个对照）
        add("演唱会现场 4K.mp4", source: "百度网盘", total: 2_150 * mb, status: .failed, received: 304 * mb, ago: 3 * 3600,
            error: "HTTP 403：直链已失效或被拒绝，请重新解析后下载")

        // 一个网盘分享里的一组文件（和「最近」里的分享对应，解析页会显示 3/5）
        let design = DownloadGroup(title: "设计素材合集")
        func origin(_ fid: String, _ name: String, _ size: Int64) -> ShareOrigin {
            ShareOrigin(platform: .quark, shareURL: designShareURL, pwd: "",
                        file: ShareFile(fid: fid, name: name, size: size, isDirectory: false, parentId: "0"))
        }
        for (index, file) in DemoShareService.designFiles.enumerated() {
            add(file.name, source: "夸克网盘", total: file.size, status: file.status, received: file.received, ago: 4 * 3600 + Double(index),
                finishedAgo: file.status == .completed ? 4 * 3600 - 300 : nil, error: file.error, folder: "设计素材合集",
                group: design, origin: origin(file.fid, file.name, file.size))
        }

        guard !groupOnly else {
            if let data = try? JSONSerialization.data(withJSONObject: list) { try? data.write(to: support.appendingPathComponent("downloads.json")) }
            return
        }
        add("城市夜景延时_4K.mp4", source: "哔哩哔哩", total: 237 * mb, status: .completed, ago: 5 * 3600, finishedAgo: 5 * 3600 - 600)

        let album = DownloadGroup(title: "雨后的西湖")
        let sizes: [Int64] = [2_811_000, 3_402_000, 2_190_000, 4_018_000, 2_655_000, 3_120_000]
        for (index, size) in sizes.enumerated() {
            add("雨后的西湖_\(index + 1).jpg", source: "小红书", total: size, status: .completed, ago: 26 * 3600 + Double(index),
                finishedAgo: 26 * 3600 - 60, folder: "雨后的西湖", group: album)
        }
        add("黄昏的湖.png", source: "夸克网盘", total: 8 * mb + 620_000, status: .completed, ago: 50 * 3600, finishedAgo: 50 * 3600 - 30)
        add("Cloudn-1.4.0.ipa", source: "GitHub", total: 18 * mb + 300_000, status: .completed, ago: 72 * 3600, finishedAgo: 72 * 3600 - 20)

        if let data = try? JSONSerialization.data(withJSONObject: list) {
            try? data.write(to: support.appendingPathComponent("downloads.json"))
        }
    }

    // MARK: 解析结果

    private struct MediaFiles {
        var cover = ""
        var avatar = ""
        var photos: [String] = []
        var biliCover = ""
        var thumbs: [String] = []
    }

    /// 本机限速服务上的地址（真能下载，有进度）；服务没起来时是个不存在的地址
    private static func demoURL(_ port: UInt16, _ name: String, size: Int64, rate: Int64 = 2_600_000) -> String {
        port > 0 ? "http://127.0.0.1:\(port)/\(name)?size=\(size)&rate=\(rate)" : "https://cloudn.invalid/\(name)"
    }

    @MainActor
    private static func makeResult(images: MediaFiles, port: UInt16) -> VideoParseResult {
        let title = "雨后的西湖，苏堤一路走到断桥"
        var medias = [
            VideoMedia(url: demoURL(port, "video_1080.mp4", size: 90_596_966), kind: .video, fileName: "雨后的西湖_1080P.mp4",
                       size: 90_596_966, quality: "1080P", variantGroup: "main"),
            VideoMedia(url: demoURL(port, "video_720.mp4", size: 43_201_331), kind: .video, fileName: "雨后的西湖_720P.mp4",
                       size: 43_201_331, quality: "720P", variantGroup: "main"),
            VideoMedia(url: demoURL(port, "video_540.mp4", size: 23_907_123), kind: .video, fileName: "雨后的西湖_540P.mp4",
                       size: 23_907_123, quality: "540P", variantGroup: "main"),
        ]
        for (index, url) in images.photos.enumerated() {
            medias.append(VideoMedia(url: url, kind: .image, fileName: "雨后的西湖_\(index + 1).jpg", size: 2_400_000 + Int64(index) * 310_000))
        }
        // 第 2 张是实况照片：同名加 _live 的视频挂在图片上
        medias.append(VideoMedia(url: demoURL(port, "live_2.mp4", size: 3_280_000), kind: .video, fileName: "雨后的西湖_2_live.mp4",
                                 size: 3_280_000))
        return VideoParseResult(
            platform: .xiaohongshu, title: title, author: "山野散步", avatar: images.avatar, cover: images.cover,
            text: "下了一整夜的雨，清早的西湖起了薄雾。从苏堤南口一路慢慢走到断桥，柳枝还挂着水珠，湖面安静得像一面镜子。\n\n#西湖 #杭州 #雨天 #city walk",
            timestamp: 1_792_312_920, url: "https://www.xiaohongshu.com/explore/66f1a2b3000000001e03c4d5",
            medias: medias, authorID: "shanye", fileBase: "雨后的西湖")
    }

    /// 哔哩哔哩：四档清晰度（音视频分轨），两条字幕
    @MainActor
    private static func makeBiliResult(images: MediaFiles, port: UInt16) -> VideoParseResult {
        let mb: Int64 = 1024 * 1024
        let audio = demoURL(port, "bili_audio.m4s", size: 21 * mb)
        let levels: [(String, Int64)] = [("4K", 1_146 * mb), ("1080P 60帧", 486 * mb), ("1080P", 312 * mb), ("720P", 156 * mb)]
        let medias = levels.enumerated().map { index, level in
            VideoMedia(url: demoURL(port, "bili_\(index).m4s", size: level.1), kind: .video, fileName: "城市夜景延时摄影_\(level.0).mp4",
                       size: level.1, quality: level.0, audioURL: audio, variantGroup: "main")
        }
        let subtitles = [
            SubtitleTrack(name: "中文（自动生成）", language: "ai-zh", url: "https://cloudn.invalid/sub_zh.json", format: .biliJSON, automatic: true),
            SubtitleTrack(name: "English", language: "en", url: "https://cloudn.invalid/sub_en.json", format: .biliJSON),
        ]
        return VideoParseResult(
            platform: .bilibili, title: "城市夜景延时摄影｜从外滩到陆家嘴的 24 小时", author: "光影旅人", avatar: images.avatar,
            cover: images.biliCover,
            text: "用了三个晚上拍完的延时，素材 4000 多张。器材和后期流程放在简介里，欢迎交流～",
            timestamp: 1_791_964_800, url: "https://www.bilibili.com/video/BV1xK4y1Z7aB", medias: medias, subtitles: subtitles,
            fileBase: "城市夜景延时摄影")
    }

    /// 作者主页：一串作品，默认全选
    @MainActor
    private static func makeCollection(images: MediaFiles) -> VideoParseResult {
        let titles: [(String, Double)] = [
            ("雨后的西湖，苏堤一路走到断桥", 48), ("龙井村的清晨，茶园里的雾", 63), ("灵隐寺旁的小路，秋天来了", 37),
            ("九溪十八涧徒步全程", 512), ("南宋御街夜市，吃了一整条街", 214), ("满觉陇的桂花开了", 29),
            ("西溪湿地划船，水面像镜子", 95), ("北山街的梧桐，下午四点的光", 41), ("径山寺看日出", 128),
            ("城隍阁俯瞰西湖夜景", 57), ("杨公堤骑行一圈", 302), ("宝石山看日落，人比云多", 76),
        ]
        let entries = titles.enumerated().map { index, item in
            VideoEntry(title: item.0, url: "https://www.xiaohongshu.com/explore/66f1a2b3000000001e03c4\(String(format: "%02d", index))",
                       duration: item.1, cover: images.thumbs.isEmpty ? "" : images.thumbs[index % images.thumbs.count])
        }
        return VideoParseResult(platform: .xiaohongshu, title: "山野散步的作品", author: "山野散步", avatar: images.avatar,
                                url: "https://www.xiaohongshu.com/user/profile/5f1a2b3c000000000101d4e5", entries: entries)
    }

    /// 解析入口（ResolveView）先问这里：解析中 / 解析失败几个页面返回演示结果或报错；其余页面返回 nil，照常解析
    @MainActor
    static func parse(_ link: DetectedVideoLink) async throws -> VideoParseResult? {
        switch screen {
        case .resolving:
            try await Task.sleep(for: .seconds(3600))
        case .collecting:
            // 翻页解析：已获取数一页页涨上去，然后停在获取中
            for fetched in stride(from: 18, through: 54, by: 18) {
                CollectionProgress.report(fetched: fetched, total: 128)
                try await Task.sleep(for: .milliseconds(500))
            }
            try await Task.sleep(for: .seconds(3600))
        case .resolveFailed:
            try await Task.sleep(for: .milliseconds(600))
            throw CloudnError("该视频需要登录后才能观看")
        default:
            return nil
        }
        return nil
    }

    /// 截图模式下网盘分享、转存、我的网盘都用本地演示数据；正常启动返回 nil
    @MainActor
    static func shareService(for platform: SharePlatform) -> DemoShareService? {
        guard let screen else { return nil }
        return DemoShareService(platform: platform, screen: screen, port: server.port)
    }

    // MARK: 图片与预览文件（运行时生成，不依赖网络）

    @MainActor
    private static func writeMedia(media: URL, documents: URL) -> MediaFiles {
        var files = MediaFiles()
        func save(_ image: UIImage, _ url: URL) -> String {
            guard let data = image.pngData(), (try? data.write(to: url)) != nil else { return "" }
            return url.absoluteString
        }
        files.cover = save(Artwork.render(CGSize(width: 960, height: 600), palette: .lake), media.appendingPathComponent("cover.png"))
        files.biliCover = save(Artwork.render(CGSize(width: 960, height: 600), palette: .dusk, seed: 3), media.appendingPathComponent("bili.png"))
        files.avatar = save(Artwork.render(CGSize(width: 160, height: 160), palette: .dawn), media.appendingPathComponent("avatar.png"))
        let palettes: [Artwork.Palette] = [.lake, .dawn, .forest, .dusk]
        files.photos = palettes.enumerated().map { index, palette in
            save(Artwork.render(CGSize(width: 600, height: 800), palette: palette, seed: CGFloat(index)),
                 media.appendingPathComponent("photo_\(index + 1).png"))
        }
        files.thumbs = palettes.enumerated().map { index, palette in
            save(Artwork.render(CGSize(width: 192, height: 120), palette: palette, seed: CGFloat(index) + 5),
                 media.appendingPathComponent("thumb_\(index + 1).png"))
        }

        let imageURL = documents.appendingPathComponent("黄昏的湖.png")
        if !save(Artwork.render(CGSize(width: 1200, height: 1600), palette: .dusk, seed: 2), imageURL).isEmpty {
            previewImageURL = imageURL
        }
        let textURL = documents.appendingPathComponent("下载说明.txt")
        if (try? Data(previewText.utf8).write(to: textURL)) != nil { previewTextURL = textURL }
        return files
    }

    private static let previewText = """
        Cloudn 下载说明

        一、支持的链接
        · 网盘分享：夸克、UC、百度、迅雷、115、123、139、光鸭、蓝奏云、蓝奏云优享版
        · 短视频与图集：抖音、小红书、哔哩哔哩、微博、快手、X、Instagram、TikTok 等
        · GitHub 仓库、Release 与用户主页；磁力链接与种子文件

        二、下载
        1. 在「解析」页粘贴链接，打开分享或作品页。
        2. 点文件右侧的下载键，或多选后「下载所选」。
        3. 下载页可以暂停、继续、重新获取直链；切到后台后普通文件由系统继续下载。

        三、文件在哪里
        下载完成的文件在「文件」App →「我的 iPhone」→ Cloudn。
        也可以在设置里选一个文件夹（如 iCloud 云盘），完成后自动移过去。

        四、常见问题
        · 直链过期（HTTP 403 / 404）：长按任务，选「重新获取直链并继续」。
        · 夸克未登录只能下载约 50MB 以内的文件，登录后不限大小。
        · m3u8 与分轨视频会在下载完成后自动合并为 MP4。

        登录凭据只保存在本机钥匙串，只发给对应平台。
        """

    // MARK: 批量与嗅探

    /// 批量任务：前几条已加入下载、一条失败、一条正在解析、其余等待
    @MainActor
    static func makeBatch() -> BatchJob {
        let titles = ["城市夜景延时摄影", "龙井村的清晨", "九溪十八涧徒步全程", "南宋御街夜市", "满觉陇的桂花开了",
                      "西溪湿地划船", "径山寺看日出", "宝石山看日落"]
        let job = BatchJob(title: "批量下载 \(titles.count) 个", entries: titles.enumerated().map { index, title in
            (title: title, url: "https://www.bilibili.com/video/BV1xK4y1Z7a\(index)")
        })
        job.setDemoStates([.added(1), .added(3), .added(1), .failed("作品已删除或仅作者可见"), .parsing], running: true)
        return job
    }

    /// 网页嗅探：本机服务上的一个演示视频页，放好已探测的结果
    @MainActor
    static func makeSniffer() -> SnifferBrowser {
        let port = server.port
        let base = "http://127.0.0.1:\(port)"
        let browser = SnifferBrowser(url: port > 0 ? base + "/watch" : "about:blank")
        let mb: Int64 = 1024 * 1024
        if screen == .snifferRecord {
            browser.loadDemo([], mse: ["sb1": #"video/mp4; codecs="avc1.640028""#, "sb2": #"audio/mp4; codecs="mp4a.40.2""#])
        } else {
            browser.loadDemo([
                (url: base + "/hls/master.m3u8", kind: .hls, info: MediaProbeResult(size: 812 * mb, estimated: true, duration: 1_504, height: 1080)),
                (url: base + "/media/trailer_720.mp4", kind: .video, info: MediaProbeResult(size: 18 * mb + 420_000, duration: 62, height: 720)),
                (url: base + "/ads/preroll_360.mp4", kind: .video, info: MediaProbeResult(size: 1_240_000, duration: 15, height: 360)),
            ])
        }
        return browser
    }
}

// MARK: - 演示网盘

/// 网盘分享 / 转存 / 我的网盘的演示数据。分享页的几种出错状态按截图页面给出
struct DemoShareService: ShareResolver, ShareSaver, DriveManager {
    let platform: SharePlatform
    let screen: ScreenshotMode.Screen
    let port: UInt16

    struct DesignFile {
        let fid: String
        let name: String
        let size: Int64
        /// 下载页里这个文件的状态（分享页行尾据此显示已下载 / 暂停 / 失败）
        let status: DownloadStatus
        var received: Int64 = 0
        var error: String?
    }

    private static let mb: Int64 = 1024 * 1024

    /// 「设计素材合集」根目录里已经下载过的几个文件
    static let designFiles: [DesignFile] = [
        DesignFile(fid: "f1", name: "图标集 v3.zip", size: 48 * mb, status: .completed),
        DesignFile(fid: "f2", name: "品牌手册.pdf", size: 12 * mb + 400_000, status: .completed),
        DesignFile(fid: "f3", name: "海报模板.psd", size: 286 * mb, status: .completed),
        DesignFile(fid: "f4", name: "样机素材.zip", size: 412 * mb, status: .paused, received: 120 * mb),
        DesignFile(fid: "f5", name: "字体包.zip", size: 96 * mb, status: .failed, error: "HTTP 404：文件不存在或直链已过期"),
    ]

    private static func stamp(_ daysAgo: Double) -> String {
        String(Int((Date().timeIntervalSince1970 - daysAgo * 86_400) * 1000))
    }

    var supportsGuestDownload: Bool { platform != .xunlei }

    func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession {
        try await Task.sleep(for: .milliseconds(500))
        switch screen {
        case .sharePassword where (pwd ?? "").isEmpty:
            throw CloudnError("此\(platform.displayName)分享需要提取码，请填写后重新解析")
        case .shareExpired:
            throw CloudnError("\(platform.displayName)分享已过期或已被分享者取消")
        default:
            break
        }
        let title = switch screen {
        case .sharePassword: "期末复习资料"
        case .shareGuest: "纪录片合集"
        default: "设计素材合集"
        }
        return ShareSession(platform: platform, shareId: share.shareId, stoken: "demo", title: title)
    }

    func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile] {
        try await Task.sleep(for: .milliseconds(300))
        let mb = Self.mb
        switch session.title {
        case "纪录片合集":
            return [
                ShareFile(fid: "d1", name: "河西走廊", size: 0, isDirectory: true, modified: Self.stamp(12)),
                ShareFile(fid: "d2", name: "航拍中国 第四季", size: 0, isDirectory: true, modified: Self.stamp(30)),
                ShareFile(fid: "v1", name: "如果国宝会说话 第1集.mp4", size: 412 * mb, isDirectory: false, modified: Self.stamp(40)),
                ShareFile(fid: "v2", name: "如果国宝会说话 第2集.mp4", size: 398 * mb, isDirectory: false, modified: Self.stamp(40)),
                ShareFile(fid: "v3", name: "字幕合集.zip", size: 3 * mb, isDirectory: false, modified: Self.stamp(41)),
            ]
        case "期末复习资料":
            return [
                ShareFile(fid: "p1", name: "高等数学 重点整理.pdf", size: 18 * mb, isDirectory: false, modified: Self.stamp(3)),
                ShareFile(fid: "p2", name: "线性代数 习题答案.pdf", size: 9 * mb, isDirectory: false, modified: Self.stamp(3)),
            ]
        default:
            return [
                ShareFile(fid: "d1", name: "源文件", size: 0, isDirectory: true, modified: Self.stamp(6)),
                ShareFile(fid: "d2", name: "灵感参考", size: 0, isDirectory: true, modified: Self.stamp(8)),
            ] + Self.designFiles.map {
                ShareFile(fid: $0.fid, name: $0.name, size: $0.size, isDirectory: false, parentId: "0", modified: Self.stamp(6))
            } + [
                ShareFile(fid: "f6", name: "封面预览.jpg", size: 2 * mb + 310_000, isDirectory: false, modified: Self.stamp(6)),
                ShareFile(fid: "f7", name: "使用说明.txt", size: 4_200, isDirectory: false, modified: Self.stamp(6)),
                ShareFile(fid: "f8", name: "品牌宣传片.mp4", size: 1_240 * mb, isDirectory: false, modified: Self.stamp(7)),
            ]
        }
    }

    func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        try await Task.sleep(for: .milliseconds(300))
        let url = port > 0 ? "http://127.0.0.1:\(port)/\(file.fid).bin?size=\(max(1, file.size))&rate=4000000" : "https://cloudn.invalid/\(file.fid)"
        return DownloadLink(fileName: file.name, url: url, size: file.size, headers: [:])
    }

    // MARK: 转存

    var rootFolderId: String { "0" }

    func listFolders(_ parentId: String) async throws -> [ShareFile] {
        try await Task.sleep(for: .milliseconds(300))
        guard parentId == rootFolderId else { return [] }
        return ["来自分享", "工作", "学习资料", "照片备份", "电影"].enumerated().map {
            ShareFile(fid: "m\($0.offset)", name: $0.element, size: 0, isDirectory: true, parentId: parentId)
        }
    }

    func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws {
        try await Task.sleep(for: .seconds(1))
    }

    // MARK: 我的网盘

    var driveRootId: String { "0" }

    func listDrive(_ folderId: String) async throws -> [ShareFile] {
        try await Task.sleep(for: .milliseconds(300))
        guard folderId == driveRootId else { return [] }
        let mb = Self.mb
        return [
            ShareFile(fid: "m0", name: "来自分享", size: 0, isDirectory: true, modified: Self.stamp(0.2)),
            ShareFile(fid: "m1", name: "工作", size: 0, isDirectory: true, modified: Self.stamp(2)),
            ShareFile(fid: "m2", name: "学习资料", size: 0, isDirectory: true, modified: Self.stamp(9)),
            ShareFile(fid: "m3", name: "照片备份", size: 0, isDirectory: true, modified: Self.stamp(15)),
            ShareFile(fid: "m4", name: "电影", size: 0, isDirectory: true, modified: Self.stamp(40)),
            ShareFile(fid: "x1", name: "年度总结.key", size: 64 * mb, isDirectory: false, modified: Self.stamp(1)),
            ShareFile(fid: "x2", name: "家庭合影.heic", size: 3 * mb + 200_000, isDirectory: false, modified: Self.stamp(4)),
            ShareFile(fid: "x3", name: "Cloudn-1.4.0.ipa", size: 18 * mb + 300_000, isDirectory: false, modified: Self.stamp(6)),
            ShareFile(fid: "x4", name: "旅行 vlog 初剪.mov", size: 2_840 * mb, isDirectory: false, modified: Self.stamp(20)),
        ]
    }

    func driveDownloadLink(_ file: ShareFile) async throws -> DownloadLink {
        DownloadLink(fileName: file.name, url: "https://cloudn.invalid/\(file.fid)", size: file.size, headers: [:])
    }

    func quota() async -> DriveQuota? {
        let tb: Int64 = 1 << 40
        return DriveQuota(used: tb * 138 / 100, total: tb * 6)
    }
}

// MARK: - 根视图

/// 截图模式的根视图：与 RootView 相同的三个标签页，直接停在指定页面；不弹首次须知、更新提示
struct ScreenshotRootView: View {
    let screen: ScreenshotMode.Screen
    @Environment(AppModel.self) private var model
    @State private var previewing: Bool
    @State private var shareModel: ShareBrowserModel?
    @State private var saving: SaveItems?
    @State private var batch: BatchJob?
    @State private var sniffer: SnifferBrowser?
    @State private var listKind: AccountKind?

    init(screen: ScreenshotMode.Screen) {
        self.screen = screen
        _previewing = State(initialValue: screen == .previewImage || screen == .previewText)
    }

    var body: some View {
        AppTabView { resolveTab } me: { meTab }
        .background(Color.paper)
        .background(WindowSceneReader { ToastWindowPresenter.shared.install(in: $0, model: model) })
        .background(WindowTint(color: model.settings.accentUIColor))
        .onAppear(perform: setUp)
        .fullScreenCover(isPresented: $previewing) {
            if let url = previewURL { FilePreviewView(url: url) }
        }
        .fullScreenCover(isPresented: Binding(get: { sniffer != nil }, set: { if !$0 { sniffer = nil } })) {
            if let sniffer { SnifferView(browser: sniffer) }
        }
        .sheet(item: $batch) { BatchView(job: $0) }
        .sheet(item: $saving) { items in
            if let shareModel { SaveToDriveView(model: shareModel, files: items.files) }
        }
        .sheet(item: $listKind) { AccountListView(kind: $0) { _ in } }
    }

    private var previewURL: URL? {
        switch screen {
        case .previewImage: return ScreenshotMode.previewImageURL
        case .previewText: return ScreenshotMode.previewTextURL
        default: return nil
        }
    }

    @ViewBuilder
    private var resolveTab: some View {
        switch screen {
        case .video, .videoAdded:
            if let result = ScreenshotMode.demoResult { PushedStack(rootTitle: "解析") { VideoResultView(result: result) } }
        case .videoBili:
            if let result = ScreenshotMode.biliResult { PushedStack(rootTitle: "解析") { VideoResultView(result: result) } }
        case .collection:
            if let result = ScreenshotMode.collectionResult { PushedStack(rootTitle: "解析") { VideoResultView(result: result) } }
        case .detect:
            ResolveView(demoInput: ScreenshotMode.demoLink)
        default:
            if screen.isShare, let shareModel {
                PushedStack(rootTitle: "解析") { ShareBrowserView(model: shareModel) }
            } else {
                ResolveView()
            }
        }
    }

    @ViewBuilder
    private var meTab: some View {
        switch screen {
        case .settings:
            PushedStack(rootTitle: "我的") { SettingsView() }
        case .drive:
            let service = ScreenshotMode.shareService(for: .quark)
            PushedStack(rootTitle: "我的") {
                if let service {
                    DriveFolderView(platform: .quark, manager: service, folderId: service.driveRootId, title: SharePlatform.quark.displayName,
                                    quota: DriveQuota(used: (1 << 40) * 138 / 100, total: (1 << 40) * 6))
                }
            }
        default:
            AccountsView()
        }
    }

    /// 停到指定页面后要做的事：打开链接、弹出面板、进入多选等
    private func setUp() {
        model.selectedTab = screen.tab
        if screen.isShare, shareModel == nil, let share = ShareLinkParser.parse(ScreenshotMode.demoLink) {
            shareModel = ShareBrowserModel(app: model, share: share, pwd: share.pwd, sourceText: ScreenshotMode.demoLink)
        }
        switch screen {
        case .resolving, .collecting, .resolveFailed, .github:
            model.pendingInput = ScreenshotMode.demoLink
        case .batch:
            let job = ScreenshotMode.makeBatch()
            model.batchJobs.append(job)
            batch = job
        case .accountList:
            listKind = .quark
        case .shareSelect, .save:
            guard let shareModel else { return }
            Task {
                await shareModel.open()
                // 页面自己的 .task 也会打开分享：等列表出来再进入多选 / 弹出转存
                for _ in 0..<50 where shareModel.files.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                if screen == .shareSelect {
                    shareModel.selecting = true
                    shareModel.selection = ["d1", "f6", "f7", "f8"]
                } else {
                    try? await Task.sleep(for: .milliseconds(600))
                    saving = SaveItems(files: shareModel.files.filter { ["d1", "f8"].contains($0.fid) })
                }
            }
        case .sniffer, .snifferList, .snifferRecord:
            let browser = ScreenshotMode.makeSniffer()
            sniffer = browser
            guard screen != .sniffer else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if screen == .snifferList { browser.showingList = true } else { browser.showingRecorder = true }
            }
        case .videoAdded:
            // 和点了行尾下载键一样：加入下载，行尾变成进度环，底部出提示
            guard let result = ScreenshotMode.demoResult, let media = result.medias.first else { return }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                model.downloads.enqueue(media: media, result: result)
                model.show("已加入下载")
            }
        default:
            break
        }
    }
}

/// 已经推入一层的导航栈：页面带返回键，和从上一页点进来时一样
private struct PushedStack<Destination: View>: View {
    let rootTitle: String
    @ViewBuilder let destination: () -> Destination
    @State private var path = [0]

    var body: some View {
        NavigationStack(path: $path) {
            Color.paper
                .ignoresSafeArea()
                .navigationTitle(rootTitle)
                .navigationDestination(for: Int.self) { _ in destination() }
        }
    }
}

// MARK: - 生成的配图

/// 截图用的配图：渐变天空、太阳、几层山和水面，按调色板生成，不依赖网络和资源文件
private enum Artwork {
    struct Palette {
        let skyTop: UInt32
        let skyBottom: UInt32
        let sun: UInt32
        let hills: [UInt32]
        let water: UInt32
        let sunX: CGFloat

        static let lake = Palette(skyTop: 0x9DB8C9, skyBottom: 0xE4ECEE, sun: 0xF7F4EA, hills: [0xA9BAC0, 0x6F8A8A, 0x45605A],
                                  water: 0x86A3AE, sunX: 0.7)
        static let dawn = Palette(skyTop: 0xF2C6A6, skyBottom: 0xFAEDE0, sun: 0xFFF7EC, hills: [0xCDB5A3, 0x9E887C, 0x6C5F5A],
                                  water: 0xC4B3AA, sunX: 0.32)
        static let forest = Palette(skyTop: 0xC5DCC4, skyBottom: 0xF1F1E3, sun: 0xFFFFF6, hills: [0x9CB898, 0x678C6B, 0x3E5C46],
                                    water: 0x95B3A3, sunX: 0.62)
        static let dusk = Palette(skyTop: 0x34345A, skyBottom: 0xE8977A, sun: 0xFFD8A6, hills: [0x6A4F72, 0x443756, 0x272139],
                                  water: 0x4D4468, sunX: 0.42)
    }

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func render(_ size: CGSize, palette p: Palette, seed: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let w = size.width, h = size.height
            let space = CGColorSpaceCreateDeviceRGB()
            let horizon = h * 0.74

            // 天空
            if let sky = CGGradient(colorsSpace: space, colors: [color(p.skyTop).cgColor, color(p.skyBottom).cgColor] as CFArray,
                                    locations: [0, 1]) {
                cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation])
            }
            // 太阳与一圈柔光
            let r = min(w, h) * 0.085
            let center = CGPoint(x: w * p.sunX, y: h * 0.3)
            if let glow = CGGradient(colorsSpace: space, colors: [color(p.sun, alpha: 0.55).cgColor, color(p.sun, alpha: 0).cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.drawRadialGradient(glow, startCenter: center, startRadius: r, endCenter: center, endRadius: r * 3.2, options: [])
            }
            cg.setFillColor(color(p.sun).cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))

            // 远近几层山
            for (i, hex) in p.hills.enumerated() {
                let layer = CGFloat(i)
                let base = h * (0.5 + 0.075 * layer)
                let amp = h * (0.11 - 0.025 * layer)
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: horizon))
                var x: CGFloat = 0
                let step = max(2, w / 160)
                while x <= w + step {
                    let t: CGFloat = x / w * CGFloat.pi
                    let a: CGFloat = sin(t * (1.6 + layer * 0.9) + seed * 1.3 + layer * 2.1)
                    let b: CGFloat = sin(t * (4.2 + layer) + seed + layer)
                    let c: CGFloat = sin(t * 11 + layer * 3)
                    let wave: CGFloat = 0.55 * a + 0.3 * b + 0.15 * c
                    path.addLine(to: CGPoint(x: min(x, w), y: base - amp * wave))
                    x += step
                }
                path.addLine(to: CGPoint(x: w, y: horizon))
                path.close()
                color(hex).setFill()
                path.fill()
            }

            // 水面：倒影色渐深，几道浅色波纹
            if let water = CGGradient(colorsSpace: space, colors: [color(p.water).cgColor, color(p.hills.last ?? p.water).cgColor] as CFArray,
                                      locations: [0, 1]) {
                cg.saveGState()
                cg.clip(to: CGRect(x: 0, y: horizon, width: w, height: h - horizon))
                cg.drawLinearGradient(water, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: h * 1.25), options: [])
                cg.restoreGState()
            }
            cg.setFillColor(color(p.sun, alpha: 0.35).cgColor)
            for i in 0..<7 {
                let y = horizon + (h - horizon) * (0.12 + CGFloat(i) * 0.12)
                let width: CGFloat = w * (0.22 - CGFloat(i) * 0.02)
                let drift: CGFloat = sin(CGFloat(i) * 1.7 + seed) * w * 0.04
                let x: CGFloat = center.x - width / 2 + drift
                cg.fill(CGRect(x: x, y: y, width: width, height: max(1.5, h * 0.004)))
            }
        }
    }
}

// MARK: - 本机限速下载服务

/// 只监听 127.0.0.1 的极简 HTTP 服务：`/<任意>?size=总字节&rate=每秒字节`，支持 Range，按速率慢慢回零字节。
/// 让下载页的「下载中」任务真的在跑（进度、速度、速度曲线都是真的），又不访问外网
final class DemoDownloadServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Cloudn.ScreenshotMode.server")
    private var listener: NWListener?
    /// 监听成功后的端口；0 表示没起来
    private(set) var port: UInt16 = 0

    /// 同步等到监听就绪（最多 3 秒），返回是否成功
    func start() -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return false }
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        return port != 0
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let query = URLComponents(string: "http://127.0.0.1" + target)?.queryItems ?? []
        func number(_ name: String) -> Int64? { query.first { $0.name == name }?.value.flatMap { Int64($0) } }
        if target.hasPrefix("/watch") {
            // 网页嗅探的演示页面
            let body = Data(Self.watchPage.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        guard let size = number("size"), size > 0 else {
            let header = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let rate = max(64 * 1024, number("rate") ?? 1024 * 1024)
        var start: Int64 = 0
        var end = size - 1
        var partial = false
        if let line = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = line.firstIndex(of: "=") {
            let bounds = line[line.index(after: eq)...].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if let first = bounds.first, let a = Int64(first.trimmingCharacters(in: .whitespaces)), a < size {
                start = a
                if bounds.count > 1, let b = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) { end = min(b, size - 1) }
                partial = end >= start
                if !partial { start = 0; end = size - 1 }
            }
        }
        let length = end - start + 1
        var header = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\nConnection: close\r\n"
        if partial { header += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        header += "\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.pump(connection, remaining: length, rate: rate, tick: 0)
        })
    }

    /// 网页嗅探截图用的视频页：只有画面与文字，不含真的媒体（嗅探结果由截图模式直接放进去）
    private static let watchPage = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>山间晨雾 · 4K 延时 - 影集</title>
        <style>
        body{margin:0;font-family:-apple-system,"PingFang SC",sans-serif;background:#111;color:#eee}
        header{display:flex;align-items:center;gap:10px;padding:12px 16px;background:#1b1b1f}
        header b{font-size:18px;color:#ff6a3d}header span{margin-left:auto;font-size:13px;color:#999}
        .player{position:relative;aspect-ratio:16/9;background:linear-gradient(180deg,#34345a,#e8977a 70%,#443756)}
        .player:after{content:"";position:absolute;left:50%;top:50%;width:64px;height:64px;margin:-32px;border-radius:50%;
        background:rgba(0,0,0,.45) url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'><path d='M9 7l8 5-8 5z' fill='white'/></svg>") center/34px no-repeat}
        .bar{position:absolute;left:0;right:0;bottom:0;height:4px;background:rgba(255,255,255,.25)}
        .bar i{display:block;width:38%;height:100%;background:#ff6a3d}
        main{padding:14px 16px}h1{font-size:19px;margin:0 0 6px}p{margin:0;color:#999;font-size:13px}
        .tags{margin:12px 0;display:flex;gap:8px}.tags em{font-style:normal;font-size:12px;padding:4px 10px;border-radius:12px;background:#26262b;color:#bbb}
        .rel{display:flex;gap:10px;margin-top:14px}.rel div{width:120px;aspect-ratio:16/9;border-radius:6px;background:linear-gradient(135deg,#45605a,#a9bac0)}
        .rel p{flex:1;color:#ddd;font-size:14px}
        </style></head><body>
        <header><b>影集</b><span>登录</span></header>
        <div class="player"><div class="bar"><i></i></div></div>
        <main><h1>山间晨雾 · 4K 延时</h1><p>12.8 万次播放 · 3 天前</p>
        <div class="tags"><em>延时摄影</em><em>风光</em><em>4K</em></div>
        <div class="rel"><div></div><p>云海日出：黄山光明顶</p></div>
        <div class="rel"><div></div><p>城市夜景延时摄影</p></div>
        </main></body></html>
        """

    /// 每 0.1 秒发一小块；速度带一点起伏，速度曲线不是一条直线
    private func pump(_ connection: NWConnection, remaining: Int64, rate: Int64, tick: Int) {
        guard remaining > 0 else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let t = Double(tick)
        let wave = 0.85 + 0.2 * sin(t / 7) + 0.08 * sin(t / 1.9)
        let piece = min(remaining, max(4096, Int64(Double(rate) / 10 * wave)))
        connection.send(content: Data(count: Int(piece)), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.1) {
                self.pump(connection, remaining: remaining - piece, rate: rate, tick: tick + 1)
            }
        })
    }
}
#endif
