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

/// 平台 → 解析器
public final class ShareResolvers: Sendable {
    public let credentials: CredentialStore
    private let resolvers: [SharePlatform: ShareResolver]

    public init(credentials: CredentialStore, client: HTTPClient = .shared) {
        self.credentials = credentials
        var map: [SharePlatform: ShareResolver] = [:]
        map[.quark] = QuarkFamilyResolver(config: .quark, credentials: credentials, client: client)
        map[.uc] = QuarkFamilyResolver(config: .uc, credentials: credentials, client: client)
        map[.lanzou] = LanzouResolver(client: client)
        resolvers = map
    }

    public func resolver(for platform: SharePlatform) -> ShareResolver? { resolvers[platform] }
}
