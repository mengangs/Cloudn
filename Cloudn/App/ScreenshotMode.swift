// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Foundation
import Network
import SwiftUI
import UIKit

/// 截图模式：只在带 `-CloudnScreenshot <页面>` 启动参数时生效，供 CI 自动截图（见 .github/workflows/screenshots.yml）。
///
/// 生效时：
/// - 数据目录换成每次启动都清空重建的临时目录，预置一套固定的演示数据（最近记录、收藏、下载任务、解析结果、预览文件）；
/// - 偏好设置只写进不落盘的参数域（关掉剪贴板提示、自动检查更新、实时活动、通知等）；
/// - 「下载中」的任务连到本机回环地址上的限速服务，有真实的进度和速度，不访问外网；
/// - 演示账号（仅模拟器）只在账号仓库读取的那一刻写进钥匙串，读完立即删掉，不留在钥匙串里。
///
/// 不带这个参数启动时 `screen` 为 nil，这里的代码都不会运行
enum ScreenshotMode {
    enum Screen: String, CaseIterable {
        case resolve, video, downloads, me, settings
        case previewImage = "preview-image"
        case previewText = "preview-text"

        var tab: AppTab {
            switch self {
            case .resolve, .video: return .resolve
            case .downloads, .previewImage, .previewText: return .downloads
            case .me, .settings: return .me
            }
        }
    }

    static let argument = "-CloudnScreenshot"

    /// 启动参数指定的页面；没带参数为 nil（正常启动）
    static let screen: Screen? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: ScreenshotMode.argument), i + 1 < args.count else { return nil }
        return Screen(rawValue: args[i + 1])
    }()

    static var isActive: Bool { screen != nil }

    struct Directories {
        let support: URL
        let documents: URL
    }

    /// 演示用的解析结果（视频 + 图集 + 实况照片）
    @MainActor private(set) static var demoResult: VideoParseResult?
    /// 预览页打开的本地文件
    @MainActor private(set) static var previewImageURL: URL?
    @MainActor private(set) static var previewTextURL: URL?

    @MainActor private static let server = DemoDownloadServer()
    @MainActor private static var seededKeychainKeys: [String] = []

    // MARK: 启动时准备

    /// AppModel 初始化时最先调用：截图模式下准备临时目录与演示数据并返回目录；正常启动返回 nil、什么都不做
    @MainActor
    static func prepare() -> Directories? {
        guard isActive else { return nil }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CloudnScreenshot", isDirectory: true)
        try? fm.removeItem(at: root)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let documents = root.appendingPathComponent("documents", isDirectory: true)
        let media = root.appendingPathComponent("media", isDirectory: true)
        for dir in [support, documents, media] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }

        applyDefaults()
        let port: UInt16 = server.start() ? server.port : 0
        let images = writeMedia(media: media, documents: documents)
        writeBookmarks(support: support)
        writeDownloads(support: support, port: port)
        seedAccounts()
        demoResult = makeResult(images: images, port: port)
        return Directories(support: support, documents: documents)
    }

    /// 账号仓库已把演示账号读进内存：从钥匙串删掉（只删本次写入的）
    @MainActor
    static func accountsLoaded() {
        for key in seededKeychainKeys { Keychain.delete(key) }
        seededKeychainKeys = []
    }

    /// 偏好设置写进参数域（优先级最高、不落盘，退出即失效）
    private static func applyDefaults() {
        let health: [String: AccountStore.HealthRecord] = Dictionary(uniqueKeysWithValues: demoAccounts.map {
            ($0.kind.rawValue, AccountStore.HealthRecord(expired: false, checkedAt: Date()))
        })
        var overrides: [String: Any] = [
            "acceptedNotice": true,
            "clipboardHint": false,
            "autoCheckUpdates": false,
            "lastUpdateCheck": Date(),
            "liveActivity": false,
            "notifyOnFinish": false,
            "autoSaveToPhotos": false,
            "maxConcurrentTasks": 2,
            "retryCount": 3,
            "speedLimitKB": 0,
            "appearance": Appearance.system.rawValue,
            "accentHex": "",
            "platformIconStyle": PlatformIconStyle.line.rawValue,
            "hiddenDrives": [String](),
            "proxyEnabled": false,
            "multiAccountDownload": false,
        ]
        if let data = try? JSONEncoder().encode(health) { overrides["accountHealth"] = data }
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

    // MARK: 收藏与最近记录

    static let designShareURL = "https://pan.quark.cn/s/7f3a9c2e1b4d"

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
        // 排在最前（最新）的排队任务等前两个下载中的任务（同时下载上限 2）
        add("期末复习资料.zip", source: "百度网盘", total: 128 * mb, status: .queued, ago: 40)
        add("雨后的西湖_1080P.mp4", source: "小红书", total: 86 * mb + 412_000, status: .running, received: 49 * mb,
            ago: 90, rate: 3_400_000)
        add("河西走廊 第3集.mkv", source: "夸克网盘", total: 1_502 * mb, status: .running, received: 583 * mb,
            ago: 240, rate: 5_900_000)
        add("SwiftUI 实战 第12讲.mp4", source: "123 云盘", total: 642 * mb, status: .paused, received: 251 * mb, ago: 2 * 3600)
        add("演唱会现场 4K.mp4", source: "百度网盘", total: 2_150 * mb, status: .failed, received: 304 * mb, ago: 3 * 3600,
            error: "HTTP 403：直链已失效或被拒绝，请重新解析后下载")

        // 一个网盘分享里的一组文件（和「最近」里的分享对应，解析页会显示 3/5）
        let design = DownloadGroup(title: "设计素材合集")
        func origin(_ fid: String, _ name: String, _ size: Int64) -> ShareOrigin {
            ShareOrigin(platform: .quark, shareURL: designShareURL, pwd: "",
                        file: ShareFile(fid: fid, name: name, size: size, isDirectory: false, parentId: "0"))
        }
        let designFiles: [(String, Int64, DownloadStatus, Int64, String?)] = [
            ("图标集 v3.zip", 48 * mb, .completed, 0, nil),
            ("品牌手册.pdf", 12 * mb + 400_000, .completed, 0, nil),
            ("海报模板.psd", 286 * mb, .completed, 0, nil),
            ("样机素材.zip", 412 * mb, .paused, 120 * mb, nil),
            ("字体包.zip", 96 * mb, .failed, 0, "HTTP 404：文件不存在或直链已过期"),
        ]
        for (index, file) in designFiles.enumerated() {
            add(file.0, source: "夸克网盘", total: file.1, status: file.2, received: file.3, ago: 4 * 3600 + Double(index),
                finishedAgo: file.2 == .completed ? 4 * 3600 - 300 : nil, error: file.4, folder: "设计素材合集",
                group: design, origin: origin("f\(index + 1)", file.0, file.1))
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
    }

    @MainActor
    private static func makeResult(images: MediaFiles, port: UInt16) -> VideoParseResult {
        let base = port > 0 ? "http://127.0.0.1:\(port)" : "https://cloudn.invalid"
        let title = "雨后的西湖，苏堤一路走到断桥"
        var medias = [
            VideoMedia(url: "\(base)/video_1080.mp4", kind: .video, fileName: "雨后的西湖_1080P.mp4", size: 90_596_966,
                       quality: "1080P", variantGroup: "main"),
            VideoMedia(url: "\(base)/video_720.mp4", kind: .video, fileName: "雨后的西湖_720P.mp4", size: 43_201_331,
                       quality: "720P", variantGroup: "main"),
            VideoMedia(url: "\(base)/video_540.mp4", kind: .video, fileName: "雨后的西湖_540P.mp4", size: 23_907_123,
                       quality: "540P", variantGroup: "main"),
        ]
        for (index, url) in images.photos.enumerated() {
            medias.append(VideoMedia(url: url, kind: .image, fileName: "雨后的西湖_\(index + 1).jpg", size: 2_400_000 + Int64(index) * 310_000))
        }
        // 第 2 张是实况照片：同名加 _live 的视频挂在图片上
        medias.append(VideoMedia(url: "\(base)/live_2.mp4", kind: .video, fileName: "雨后的西湖_2_live.mp4", size: 3_280_000))
        return VideoParseResult(
            platform: .xiaohongshu, title: title, author: "山野散步", avatar: images.avatar, cover: images.cover,
            text: "下了一整夜的雨，清早的西湖起了薄雾。从苏堤南口一路慢慢走到断桥，柳枝还挂着水珠，湖面安静得像一面镜子。\n\n#西湖 #杭州 #雨天 #city walk",
            timestamp: 1_792_312_920, url: "https://www.xiaohongshu.com/explore/66f1a2b3000000001e03c4d5",
            medias: medias, authorID: "shanye", fileBase: "雨后的西湖")
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
        files.avatar = save(Artwork.render(CGSize(width: 160, height: 160), palette: .dawn), media.appendingPathComponent("avatar.png"))
        let palettes: [Artwork.Palette] = [.lake, .dawn, .forest, .dusk]
        files.photos = palettes.enumerated().map { index, palette in
            save(Artwork.render(CGSize(width: 600, height: 800), palette: palette, seed: CGFloat(index)),
                 media.appendingPathComponent("photo_\(index + 1).png"))
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
}

// MARK: - 根视图

/// 截图模式的根视图：与 RootView 相同的三个标签页，直接停在指定页面；不弹首次须知、更新提示
struct ScreenshotRootView: View {
    let screen: ScreenshotMode.Screen
    @Environment(AppModel.self) private var model
    @State private var previewing: Bool

    init(screen: ScreenshotMode.Screen) {
        self.screen = screen
        _previewing = State(initialValue: screen == .previewImage || screen == .previewText)
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            resolveTab
                .tabItem { Label { Text("解析") } icon: { Image(icon: .link) } }
                .tag(AppTab.resolve)
            DownloadsView()
                .tabItem { Label { Text("下载") } icon: { Image(icon: .download) } }
                .badge(model.downloads.activeCount)
                .tag(AppTab.downloads)
            meTab
                .tabItem { Label { Text("我的") } icon: { Image(icon: .user) } }
                .tag(AppTab.me)
        }
        .background(Color.paper)
        .onAppear { model.selectedTab = screen.tab }
        .fullScreenCover(isPresented: $previewing) {
            if let url = previewURL { FilePreviewView(url: url) }
        }
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
        if screen == .video, let result = ScreenshotMode.demoResult {
            PushedStack(rootTitle: "解析") { VideoResultView(result: result) }
        } else {
            ResolveView()
        }
    }

    @ViewBuilder
    private var meTab: some View {
        if screen == .settings {
            PushedStack(rootTitle: "我的") { SettingsView() }
        } else {
            AccountsView()
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
