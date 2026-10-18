// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [(String, String)]
    public var body: Data?
    public var followRedirects: Bool
    public var timeout: TimeInterval

    public init(
        url: String,
        method: String = "GET",
        headers: [(String, String)] = [],
        body: Data? = nil,
        followRedirects: Bool = true,
        timeout: TimeInterval = 30
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
        self.timeout = timeout
    }

    public static func get(_ url: String, headers: [(String, String)] = [], followRedirects: Bool = true) -> HTTPRequest {
        HTTPRequest(url: url, headers: headers, followRedirects: followRedirects)
    }

    /// JSON POST；Content-Type 未显式给出时补 application/json
    public static func postJSON(_ url: String, _ object: Any, headers: [(String, String)] = []) -> HTTPRequest {
        var h = headers
        if !h.contains(where: { $0.0.lowercased() == "content-type" }) { h.append(("Content-Type", "application/json")) }
        return HTTPRequest(url: url, method: "POST", headers: h, body: JSON.serialize(object))
    }

    /// 表单 POST（application/x-www-form-urlencoded），字段顺序保持传入顺序
    public static func postForm(_ url: String, _ fields: [(String, String)], headers: [(String, String)] = [], followRedirects: Bool = true) -> HTTPRequest {
        var h = headers
        h.append(("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8"))
        let body = fields.map { "\($0.0.formEncoded)=\($0.1.formEncoded)" }.joined(separator: "&")
        return HTTPRequest(url: url, method: "POST", headers: h, body: Data(body.utf8), followRedirects: followRedirects)
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    /// 响应头（键已转小写）
    public let headers: [String: String]
    /// Set-Cookie 中的 name=value 对（只保留键值，去掉属性），按出现顺序
    public let cookies: [(name: String, value: String)]
    public let body: Data
    public let url: String

    public var text: String { String(decoding: body, as: UTF8.self) }
    public var json: JSON? { JSON(data: body) }
    public var isSuccess: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public func cookie(_ name: String) -> String? { cookies.last(where: { $0.name == name })?.value }
}

public enum HTTPError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "无效的地址：\(u)"
        case .network(let m): return "网络请求失败：\(m)"
        }
    }
}

/// 统一的 HTTP 客户端。
///
/// ★ 刻意关闭 URLSession 的自动 Cookie 管理：各网盘的 Cookie 由账号体系显式拼进请求头，
///   让系统 Cookie 罐自动合并会把游客态与登录态、不同账号的 Cookie 混在一起（直链签名对不上直接 412/403）。
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    private let following: URLSession
    private let nonFollowing: URLSession

    public init() {
        following = URLSession(configuration: HTTPClient.makeConfiguration())
        nonFollowing = URLSession(configuration: HTTPClient.makeConfiguration(), delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 16
        return config
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else { throw HTTPError.invalidURL(request.url) }
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
        urlRequest.httpBody = request.body
        let session = request.followRedirects ? following : nonFollowing

        return try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    cont.resume(throwing: HTTPError.network(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: HTTPError.network("无响应"))
                    return
                }
                cont.resume(returning: HTTPClient.makeResponse(http, data: data ?? Data(), fallbackURL: url))
            }
            task.resume()
        }
    }

    static func makeResponse(_ http: HTTPURLResponse, data: Data, fallbackURL: URL) -> HTTPResponse {
        var headers: [String: String] = [:]
        var rawFields: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            let key = String(describing: k)
            let value = String(describing: v)
            headers[key.lowercased()] = value
            rawFields[key] = value
        }
        let responseURL = http.url ?? fallbackURL
        let cookies = parseSetCookies(rawFields, url: responseURL)
        return HTTPResponse(status: http.statusCode, headers: headers, cookies: cookies, body: data, url: responseURL.absoluteString)
    }

    /// 解析 Set-Cookie。Apple 平台把多条 Set-Cookie 用逗号拼成一条，Expires 里又含逗号，
    /// 所以交给 HTTPCookie 解析；它因域名不匹配丢掉的条目再用手工切分兜底。
    static func parseSetCookies(_ fields: [String: String], url: URL) -> [(name: String, value: String)] {
        guard let raw = fields.first(where: { $0.key.lowercased() == "set-cookie" })?.value, !raw.isEmpty else { return [] }
        var result: [(String, String)] = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url)
            .map { ($0.name, $0.value) }
        for (name, value) in CookieUtil.splitSetCookieHeader(raw) where !result.contains(where: { $0.0 == name }) {
            result.append((name, value))
        }
        return result
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension String {
    /// application/x-www-form-urlencoded 编码（空格编码为 %20，服务端均可接受）
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
