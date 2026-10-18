// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

protocol VideoParser: Sendable {
    var platform: VideoPlatform { get }
    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult
}

/// 识别 → 展开短链 → 取该平台 Cookie → 交给对应解析器
public final class VideoParseService: Sendable {
    private let credentials: CredentialStore
    private let parsers: [VideoPlatform: VideoParser]

    public init(credentials: CredentialStore, webExtractor: WebPageExtractor?) {
        self.credentials = credentials
        let list: [VideoParser] = [
            DouyinParser(extractor: webExtractor),
            KuaishouParser(),
            WeiboParser(),
            AcFunParser(),
            BilibiliParser()
        ]
        parsers = Dictionary(uniqueKeysWithValues: list.map { ($0.platform, $0) })
    }

    public func parse(_ link: DetectedVideoLink) async throws -> VideoParseResult {
        let resolved = link.isShortLink ? try await expand(link) : link
        guard let parser = parsers[resolved.platform] else {
            throw VideoParseError(.unsupported, "暂不支持解析\(resolved.platform.displayName)")
        }
        if resolved.isShortLink && resolved.platform != .kuaishou {
            throw VideoParseError(.unsupported, "短链展开失败，请复制完整链接后重试")
        }
        var cookie = ""
        if let kind = resolved.platform.accountKind { cookie = await credentials.cookie(for: kind) ?? "" }
        let result = try await parser.parse(resolved, cookie: cookie)
        return VideoParseResult(platform: result.platform, title: result.title, author: result.author, avatar: result.avatar,
                                cover: VideoHTTP.secureURL(result.cover), text: result.text, timestamp: result.timestamp,
                                url: result.url, medias: result.medias.map { $0.withSecureURLs() })
    }

    /// 展开短链（最多 5 跳），终址能重新识别就用新的识别结果
    private func expand(_ link: DetectedVideoLink) async throws -> DetectedVideoLink {
        var current = link
        let ua = (link.platform == .douyin || link.platform == .kuaishou) ? VideoHTTP.uaIPhone : VideoHTTP.uaChrome
        for _ in 0..<5 {
            guard let next = try await VideoHTTP.expandRedirect(current.url, headers: ["User-Agent": ua]) else { return current }
            guard let again = VideoLinkParser.parse(next) else {
                return DetectedVideoLink(platform: current.platform, kind: current.kind, id: current.id, url: next)
            }
            if !again.isShortLink { return again }
            current = again
        }
        return current
    }
}

/// 账号 Cookie 校验（保存登录态前调用），返回昵称；无效返回 nil
public enum AccountValidator {
    public static func validate(_ kind: AccountKind, cookie: String) async -> String? {
        switch kind {
        case .quark:
            return await QuarkFamilyResolver(config: .quark, credentials: NoCredentials()).fetchNickname(cookie: cookie)
        case .uc:
            return await QuarkFamilyResolver(config: .uc, credentials: NoCredentials()).fetchNickname(cookie: cookie)
        case .bilibili:
            return await BilibiliParser.nickname(cookie: cookie)
        }
    }
}

/// 不提供任何账号的凭证源（校验、测试用）
public struct NoCredentials: CredentialStore {
    public init() {}
    public func cookie(for kind: AccountKind) async -> String? { nil }
    public func updateCookie(_ new: String, replacing old: String, for kind: AccountKind) async {}
}
