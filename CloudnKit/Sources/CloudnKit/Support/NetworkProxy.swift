// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

/// 应用内网络代理（设置页「网络代理」）。不设置时跟随系统（含 VPN / 系统代理）。
///
/// 改了之后各会话在下一次发请求时换成新配置；正在进行的请求照旧走原来的连接直到结束。
public struct NetworkProxy: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case http, socks5
        public var id: String { rawValue }
        public var title: String { self == .http ? "HTTP" : "SOCKS5" }
    }

    public var kind: Kind
    public var host: String
    public var port: Int

    public init(kind: Kind, host: String, port: Int) {
        self.kind = kind
        self.host = host
        self.port = port
    }

    public var isValid: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(port) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: NetworkProxy?
    nonisolated(unsafe) private static var _generation = 0

    /// 当前生效的代理；nil 表示跟随系统
    public static var current: NetworkProxy? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set {
            let value = newValue?.isValid == true ? newValue : nil
            lock.lock(); defer { lock.unlock() }
            guard value != _current else { return }
            _current = value
            _generation += 1
        }
    }

    /// 每改一次代理加一，长期持有 URLSession 的地方据此重建会话
    static var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return _generation
    }

    /// 把当前代理写进会话配置
    public static func apply(to config: URLSessionConfiguration) {
        current?.apply(to: config)
    }

    public func apply(to config: URLSessionConfiguration) {
        #if canImport(Network)
        if let proxy = proxyConfiguration { config.proxyConfigurations = [proxy] }
        #endif
    }

    #if canImport(Network)
    /// 同一份代理配置也给 WKWebView 的数据仓库用（登录页、嗅探、隐藏网页）
    public var proxyConfiguration: ProxyConfiguration? {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host.trimmingCharacters(in: .whitespaces)), port: p)
        switch kind {
        case .http: return ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .socks5: return ProxyConfiguration(socksv5Proxy: endpoint)
        }
    }
    #endif
}

/// 随代理设置重建的 URLSession：代理一变，下一次取会话时换新的，旧会话等手上的请求结束后释放
final class ProxyAwareSession: @unchecked Sendable {
    private let lock = NSLock()
    private let make: () -> URLSession
    private var session: URLSession?
    private var generation = -1

    init(_ make: @escaping () -> URLSession) {
        self.make = make
    }

    var current: URLSession {
        lock.lock(); defer { lock.unlock() }
        let gen = NetworkProxy.generation
        if let session, gen == generation { return session }
        session?.finishTasksAndInvalidate()
        let fresh = make()
        session = fresh
        generation = gen
        return fresh
    }
}
