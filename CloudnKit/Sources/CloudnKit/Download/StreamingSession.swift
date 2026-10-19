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

    private var session: URLSession!
    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]

    override init() {
        super.init()
        let config = HTTPClient.makeConfiguration()
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.httpMaximumConnectionsPerHost = 64
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// 发起请求并在完成（或失败/取消）时返回
    func run(_ request: URLRequest, onResponse: @escaping (Response) -> Bool, onData: @escaping (Data) throws -> Void) async throws {
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.dataTask(with: request)
                let handler = Handler(onResponse: onResponse, onData: onData) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
                lock.lock()
                handlers[task.taskIdentifier] = handler
                lock.unlock()
                box.task = task
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private func handler(for task: URLSessionTask) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[task.taskIdentifier]
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
            h.failure = h.failure ?? Rejected()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let h = handler(for: dataTask), h.failure == nil else { return }
        do {
            try h.onData(data)
        } catch {
            h.failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let h = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let h else { return }
        if let failure = h.failure { h.completion(failure) } else { h.completion(error) }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionTask?
    }
}
