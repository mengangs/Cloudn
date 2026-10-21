// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 基于 URLSessionDataDelegate 的流式下载：边收边写盘，不把整个文件放进内存。
final class StreamingSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response {
        let status: Int
        let headers: [String: String]
    }

    /// onResponse 返回 false 时取消该请求
    final class Handler {
        let onResponse: (Response) -> Bool
        let onData: (Data) throws -> Void
        let completion: (Error?) -> Void
        var failure: Error?

        init(onResponse: @escaping (Response) -> Bool, onData: @escaping (Data) throws -> Void, completion: @escaping (Error?) -> Void) {
            self.onResponse = onResponse
            self.onData = onData
            self.completion = completion
        }
    }

    struct Rejected: Error {}

    private var sessions: ProxyAwareSession!
    private let lock = NSLock()
    /// 按任务对象区分：改代理后新旧两个会话的任务编号会重复
    private var handlers: [ObjectIdentifier: Handler] = [:]
    /// 已被取消的请求：取消后仍可能有排队的数据回调，一律丢弃，免得和下一轮重复写同一段
    private var cancelled: Set<ObjectIdentifier> = []
    private let limiter: RateLimiter?

    init(limiter: RateLimiter? = nil) {
        self.limiter = limiter
        super.init()
        sessions = ProxyAwareSession { [unowned self] in
            let config = HTTPClient.makeConfiguration()
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 7 * 24 * 3600
            config.httpMaximumConnectionsPerHost = 64
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            return URLSession(configuration: config, delegate: self, delegateQueue: queue)
        }
    }

    /// 发起请求并在完成（或失败/取消）时返回
    func run(_ request: URLRequest, onResponse: @escaping (Response) -> Bool, onData: @escaping (Data) throws -> Void) async throws {
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = sessions.current.dataTask(with: request)
                let handler = Handler(onResponse: onResponse, onData: onData) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
                lock.lock()
                handlers[ObjectIdentifier(task)] = handler
                lock.unlock()
                box.task = task
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            guard let task = box.task else { return }
            self.lock.lock()
            self.cancelled.insert(ObjectIdentifier(task))
            self.lock.unlock()
            task.cancel()
        }
    }

    /// 仍在进行（没被取消、没出错）的请求对应的回调
    private func handler(for task: URLSessionTask) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled.contains(ObjectIdentifier(task)), let h = handlers[ObjectIdentifier(task)], h.failure == nil else { return nil }
        return h
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let h = handler(for: dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        if h.onResponse(Response(status: http.statusCode, headers: headers)) {
            completionHandler(.allow)
        } else {
            lock.lock()
            h.failure = h.failure ?? Rejected()
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    /// 跳到别的主机时去掉 Authorization：GitHub 私有附件会 302 到已签名的存储地址，再带 Token 会被拒（只允许一种鉴权）
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.strippingAuthorizationAcrossHosts(request, from: task.originalRequest))
    }

    static func strippingAuthorizationAcrossHosts(_ request: URLRequest, from original: URLRequest?) -> URLRequest {
        guard let newHost = request.url?.host?.lowercased(), newHost != original?.url?.host?.lowercased(),
              request.value(forHTTPHeaderField: "Authorization") != nil else { return request }
        var copy = request
        copy.setValue(nil, forHTTPHeaderField: "Authorization")
        return copy
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let h = handler(for: dataTask) else { return }
        limiter?.throttle(data.count)
        // 限速等待期间可能已被取消
        guard handler(for: dataTask) != nil else { return }
        do {
            try h.onData(data)
        } catch {
            lock.lock()
            h.failure = error
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let h = handlers.removeValue(forKey: ObjectIdentifier(task))
        cancelled.remove(ObjectIdentifier(task))
        lock.unlock()
        guard let h else { return }
        if let failure = h.failure { h.completion(failure) } else { h.completion(error) }
    }

}

/// 取消回调里要拿到的 URLSessionTask
/// 续体里写入、取消回调（在别的线程）里读取：读写都要加锁，否则是数据竞争（强引用读写交错可能直接崩）
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLSessionTask?

    var task: URLSessionTask? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

extension HTTPClient {
    private static let prefixStreamer = StreamingSession()

    /// 只取前 limit 字节：带 Range 请求，服务端忽略 Range 时也会在取够之后主动断开，不会把整个文件读进内存。
    /// partial 为 true 表示文件比 limit 长（只拿到了开头）
    public static func fetchPrefix(_ url: String, headers: [(String, String)], limit: Int) async throws -> (status: Int, data: Data, partial: Bool) {
        let r = try await fetchPrefixResponse(url, headers: headers, limit: limit)
        return (r.status, r.data, r.partial)
    }

    /// 同 fetchPrefix，另外带回响应头（探测大小时读 Content-Range / Content-Length）
    public static func fetchPrefixResponse(_ url: String, headers: [(String, String)], limit: Int,
                                           timeout: TimeInterval = 60) async throws -> PrefixResponse {
        guard let u = URL(string: url) else { throw HTTPError.invalidURL(url) }
        var request = URLRequest(url: u, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=0-\(max(0, limit - 1))", forHTTPHeaderField: "Range")
        let buffer = PrefixBuffer()
        do {
            try await prefixStreamer.run(request, onResponse: { response in
                buffer.set(status: response.status, headers: response.headers)
                return true
            }, onData: { data in
                if buffer.append(data) >= limit { throw PrefixBuffer.Enough() }
            })
        } catch is PrefixBuffer.Enough {
            // 取够了
        }
        let (status, responseHeaders, data) = buffer.snapshot()
        return PrefixResponse(status: status, headers: responseHeaders, data: data.prefix(limit),
                              partial: status == 206 || data.count > limit)
    }
}

/// fetchPrefixResponse 的结果：响应头的键已转小写
public struct PrefixResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data
    /// 文件比 limit 长（只拿到了开头）
    public let partial: Bool

    public var isSuccess: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

private final class PrefixBuffer: @unchecked Sendable {
    struct Enough: Error {}
    private let lock = NSLock()
    private var status = 0
    private var headers: [String: String] = [:]
    private var data = Data()

    func set(status: Int, headers: [String: String]) {
        lock.lock()
        self.status = status
        self.headers = headers
        lock.unlock()
    }

    func append(_ chunk: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        return data.count
    }

    func snapshot() -> (Int, [String: String], Data) {
        lock.lock()
        defer { lock.unlock() }
        return (status, headers, data)
    }
}
