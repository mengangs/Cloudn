// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 登录凭据续期的协调：同一份凭据同一时间只续期一次，并发的请求共用结果。
/// 阿里云盘、迅雷等每次续期都会换一个新的 refresh_token、旧的随即作废：几个请求同时拿旧令牌续期，
/// 除第一个外都会失败而被误判为「登录已失效」。续期前读到旧凭据、续期完成后才来续期的请求，也直接用这次的结果。
actor CredentialRenewal {
    static let shared = CredentialRenewal()
    /// 续期结果保留多久
    static let reuseWindow: TimeInterval = 120

    private var running: [String: Task<String, Error>] = [:]
    private var recent: [String: (value: String, at: Date)] = [:]
    private var validated: [String: String] = [:]

    private static func key(_ kind: AccountKind, _ s: String) -> String { kind.rawValue + "\n" + s }

    /// raw 为续期前保存的凭据串；work 续期并回写，返回新的凭据串。失败不缓存，下次重新续期
    func renew(_ kind: AccountKind, raw: String, _ work: @escaping @Sendable () async throws -> String) async throws -> String {
        let key = Self.key(kind, raw)
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value.at) < Self.reuseWindow }
        if let done = recent[key] { return done.value }
        if let task = running[key] { return try await task.value }
        let task = Task { try await work() }
        running[key] = task
        do {
            let value = try await task.value
            running[key] = nil
            recent[key] = (value, Date())
            return value
        } catch {
            running[key] = nil
            throw error
        }
    }

    /// 登录校验时（凭据还没保存）已用掉旧 refresh_token 续期：记下新凭据，解析器读到旧凭据时换成它
    func recordValidated(_ kind: AccountKind, consumedRefreshToken: String, renewed: String) {
        guard !consumedRefreshToken.isEmpty else { return }
        validated[Self.key(kind, consumedRefreshToken)] = renewed
    }

    func validatedRenewal(_ kind: AccountKind, refreshToken: String) -> String? {
        validated[Self.key(kind, refreshToken)]
    }
}
