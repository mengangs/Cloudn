// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 视频解析共用的 HTTP 小工具：状态码 → VideoParseError、短链展开、内嵌 JSON 抠取。
public enum VideoHTTP {
    public static let uaChrome =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    public static let uaIPhone =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 取消照原样抛出（批量任务「停止」时正在解析的那条要回到等待，而不是记成网络失败）；其余错误的原文留在 detail 里
    static func send(_ request: HTTPRequest, client: HTTPClient = .shared) async throws -> HTTPResponse {
        do {
            return try await client.send(request)
        } catch let error as CancellationError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw VideoParseError(.network, "请求失败：\(request.url)（\(error.localizedDescription)）")
        }
    }

    static func requireSuccess(_ r: HTTPResponse, _ what: String) throws {
        if r.isSuccess { return }
        switch r.status {
        case 403, 418, 429: throw VideoParseError(.blocked, "\(what) 被风控拦截（HTTP \(r.status)）")
        case 404, 410: throw VideoParseError(.notFound, "\(what) 不存在（HTTP \(r.status)）")
        default: throw VideoParseError(.unknown, "\(what) 请求失败（HTTP \(r.status)）")
        }
    }

    static func getText(_ url: String, headers: [String: String], what: String) async throws -> String {
        let r = try await send(.get(url, headers: headers.sortedPairs))
        try requireSuccess(r, what)
        return r.text
    }

    static func getJSON(_ url: String, headers: [String: String], what: String) async throws -> JSON {
        let text = try await getText(url, headers: headers, what: what)
        guard let json = JSON(text: text) else { throw VideoParseError(.unknown, "\(what) 返回的不是合法 JSON") }
        return json
    }

    /// 展开一次重定向；3xx 返回 Location，拿不到返回 nil
    static func expandRedirect(_ url: String, headers: [String: String]) async throws -> String? {
        let r = try await send(.get(url, headers: headers.sortedPairs, followRedirects: false))
        if (300..<400).contains(r.status), let loc = r.header("Location") {
            return absolutize(base: url, loc)
        }
        return r.url != url ? r.url : nil
    }

    /// 抠出 `window.XXX = {...}</script>` 这类内嵌 JSON 文本
    static func extractInlineJSON(_ html: String, key: String, stopAt: String = "</script>") -> String? {
        let rx = Rx(Rx.escape(key) + #"\s*=\s*(.*?)"# + Rx.escape(stopAt), dotAll: true)
        guard var text = rx.first(in: html)?.trimmed else { return nil }
        if text.hasSuffix(";") { text.removeLast() }
        return text
    }

    /// 直链统一 https（小红书/微博会给明文或协议相对地址，iOS ATS 会直接拒绝 http）
    public static func secureURL(_ url: String) -> String {
        if url.hasPrefix("//") { return "https:" + url }
        if url.hasPrefix("http://") { return "https://" + url.dropFirst("http://".count) }
        return url
    }

    static func absolutize(base: String, _ target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        if target.hasPrefix("//") { return "https:" + target }
        guard let b = URL(string: base), let u = URL(string: target, relativeTo: b) else { return target }
        return u.absoluteString
    }
}

extension Dictionary where Key == String, Value == String {
    var sortedPairs: [(String, String)] { sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
}
