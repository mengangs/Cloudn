// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 账号凭证存取（iOS 端由钥匙串实现）。解析器只读 Cookie，并在服务端续期 Cookie 时回写。
public protocol CredentialStore: Sendable {
    func cookie(for kind: AccountKind) async -> String?
    /// 服务端通过 Set-Cookie 续期了会话：仅当当前保存的仍是 `old` 时才替换为 `new`
    func updateCookie(_ new: String, replacing old: String, for kind: AccountKind) async
}

/// 单个网盘平台的分享解析流程：会话 → 列目录 → 取直链。
public protocol ShareResolver: Sendable {
    var platform: SharePlatform { get }
    /// 未登录时能否直接下载（夸克小文件 / UC / 蓝奏云）
    var supportsGuestDownload: Bool { get }

    func openSession(_ share: ParsedShare, pwd: String?) async throws -> ShareSession
    func list(_ session: ShareSession, dirId: String) async throws -> [ShareFile]
    func downloadLink(_ session: ShareSession, file: ShareFile) async throws -> DownloadLink
    /// 下载完成后的清理（夸克临时转存目录）；默认无操作
    func cleanup(token: String) async
}

public extension ShareResolver {
    func cleanup(token: String) async {}
}

/// 把分享里的文件 / 文件夹转存到自己网盘（需要登录对应平台）
public protocol ShareSaver: Sendable {
    /// 「我的网盘」根目录 id
    var rootFolderId: String { get }
    /// 个人网盘某目录下的子文件夹（只返回文件夹）
    func listFolders(_ parentId: String) async throws -> [ShareFile]
    /// 转存到目标文件夹；files 来自同一个分享会话
    func save(_ session: ShareSession, files: [ShareFile], to folderId: String) async throws
}

extension SharePlatform {
    /// 未登录时给转存 / 取链的统一提示
    var loginRequired: CloudnError { CloudnError("请先到「账号」页登录\(displayName)") }
}

/// 运行时可调的解析选项（设置页修改后即时生效）
public final class ResolverOptions: @unchecked Sendable {
    private let lock = NSLock()
    private var _directFirst = true

    public init() {}

    /// 免转存下载：先用分享凭证直接取链，失败再临时转存；关闭后夸克 / UC 一律先转存再取链（个别分享更稳）
    public var directFirst: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _directFirst }
        set { lock.lock(); _directFirst = newValue; lock.unlock() }
    }
}

/// 平台 → 解析器
public final class ShareResolvers: Sendable {
    public let credentials: CredentialStore
    public let options: ResolverOptions
    private let resolvers: [SharePlatform: ShareResolver]

    public init(credentials: CredentialStore, client: HTTPClient = .shared, options: ResolverOptions = ResolverOptions()) {
        self.credentials = credentials
        self.options = options
        var map: [SharePlatform: ShareResolver] = [:]
        map[.quark] = QuarkFamilyResolver(config: .quark, credentials: credentials, client: client, options: options)
        map[.uc] = QuarkFamilyResolver(config: .uc, credentials: credentials, client: client, options: options)
        map[.lanzou] = LanzouResolver(client: client)
        map[.ilanzou] = ILanzouResolver(client: client)
        map[.pan123] = Pan123Resolver(credentials: credentials, client: client)
        map[.c139] = C139Resolver(credentials: credentials, client: client)
        map[.baidu] = BaiduResolver(credentials: credentials, client: client)
        map[.guangya] = GuangYaResolver(client: client)
        map[.xunlei] = XunleiResolver(credentials: credentials, client: client)
        map[.pan115] = Pan115Resolver(credentials: credentials, client: client)
        resolvers = map
    }

    public func resolver(for platform: SharePlatform) -> ShareResolver? { resolvers[platform] }

    /// 支持转存到自己网盘的平台才返回
    public func saver(for platform: SharePlatform) -> ShareSaver? { resolvers[platform] as? ShareSaver }
}
