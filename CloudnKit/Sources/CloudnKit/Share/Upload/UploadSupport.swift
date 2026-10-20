// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 上传到「我的网盘」：协议参考 OpenList drivers（AGPL-3.0）与 SheltonZhu/115driver
public protocol DriveUploader: Sendable {
    /// 单个文件大小上限（字节）；nil 表示由服务端判断
    var uploadSizeLimit: Int64? { get }
    /// 把本地文件上传到 folderId（与「我的网盘」列表用的目录 id 一致）
    func upload(_ file: URL, name: String, to folderId: String, progress: UploadProgress) async throws
}

public extension DriveUploader {
    var uploadSizeLimit: Int64? { nil }
}

public enum UploadPhase: Sendable, Equatable {
    /// 计算校验值（秒传与分片校验要用）
    case hashing
    case uploading
    /// 通知网盘合并 / 等网盘处理完
    case finishing
}

/// 上传进度回报：阶段 + 0...1
public struct UploadProgress: Sendable {
    private let report: @Sendable (UploadPhase, Double) -> Void
    public init(_ report: @escaping @Sendable (UploadPhase, Double) -> Void) { self.report = report }
    public static let ignore = UploadProgress { _, _ in }

    public func callAsFunction(_ phase: UploadPhase, _ fraction: Double) { report(phase, min(1, max(0, fraction))) }

    /// 读文件算摘要时的进度回调
    public func hashing(total: Int64) -> (Int64) -> Void {
        { done in self(.hashing, total > 0 ? Double(done) / Double(total) : 1) }
    }
}

// MARK: - 请求体与传输

/// 上传的数据：内存里的一段，或文件里的一段
public enum UploadBody: Sendable {
    case data(Data)
    case file(URL, offset: Int64, length: Int64)

    var length: Int64 {
        switch self {
        case .data(let d): return Int64(d.count)
        case .file(_, _, let l): return l
        }
    }
}

extension HTTPClient {
    private static let uploader = UploadSession()

    /// 上传：带发送进度回调（已发送字节数），超时放宽到 10 分钟。文件中间的一段超过 32MB 时先切到临时文件再传
    public func upload(_ request: HTTPRequest, body: UploadBody, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else { throw HTTPError.invalidURL(request.url) }
        var urlRequest = URLRequest(url: url, timeoutInterval: max(request.timeout, 600))
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (k, v) in request.headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
        // 不显式给 Content-Type 时 CFNetwork 会补一个表单类型，签名里算的是空串就对不上
        if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil { urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        switch body {
        case .data(let d):
            return try await Self.uploader.run(urlRequest, source: .data(d), progress: progress)
        case .file(let file, let offset, let length):
            let whole = offset == 0 && length == FileChunks.size(of: file)
            if whole { return try await Self.uploader.run(urlRequest, source: .file(file), progress: progress) }
            if length <= 32 << 20 {
                return try await Self.uploader.run(urlRequest, source: .data(try FileChunks.read(file, offset: offset, length: Int(length))), progress: progress)
            }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-part-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            try FileChunks.copy(file, offset: offset, length: length, to: temp)
            return try await Self.uploader.run(urlRequest, source: .file(temp), progress: progress)
        }
    }
}

extension FileChunks {
    /// 把文件里的一段复制成新文件（1MB 一块）
    static func copy(_ source: URL, offset: Int64, length: Int64, to dest: URL) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: dest)
        defer { try? output.close() }
        try input.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            guard let d = try input.read(upToCount: Int(min(remaining, 1 << 20))), !d.isEmpty else { throw CloudnError("读取文件失败") }
            try output.write(contentsOf: d)
            remaining -= Int64(d.count)
        }
    }
}

/// 基于代理的上传会话：拿发送进度、收响应体；任务被取消时取消请求
final class UploadSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Source { case data(Data), file(URL) }

    private final class Handler {
        var data = Data()
        let progress: (@Sendable (Int64) -> Void)?
        let completion: (Result<HTTPResponse, Error>) -> Void
        init(progress: (@Sendable (Int64) -> Void)?, completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
            self.progress = progress
            self.completion = completion
        }
    }

    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let config = HTTPClient.makeConfiguration()
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func run(_ request: URLRequest, source: Source, progress: (@Sendable (Int64) -> Void)?) async throws -> HTTPResponse {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPResponse, Error>) in
                let task: URLSessionUploadTask
                switch source {
                case .data(let d): task = session.uploadTask(with: request, from: d)
                case .file(let url): task = session.uploadTask(with: request, fromFile: url)
                }
                let handler = Handler(progress: progress) { cont.resume(with: $0) }
                lock.lock(); handlers[task.taskIdentifier] = handler; lock.unlock()
                box.task = task
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private func handler(_ task: URLSessionTask) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        handler(task)?.progress?(totalBytesSent)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); handlers[dataTask.taskIdentifier]?.data.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let h = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let h else { return }
        if let error {
            h.completion(.failure((error as NSError).code == NSURLErrorCancelled ? CancellationError() : HTTPError.network(error.localizedDescription)))
            return
        }
        guard let http = task.response as? HTTPURLResponse, let url = task.originalRequest?.url else {
            h.completion(.failure(HTTPError.network("无响应")))
            return
        }
        h.completion(.success(HTTPClient.makeResponse(http, data: h.data, fallbackURL: url)))
    }
}

// MARK: - multipart/form-data

/// multipart/form-data：普通字段 + 一个文件字段。大文件写成临时文件再上传，不整个放进内存
public struct MultipartForm: Sendable {
    public let boundary = "----CloudnBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    public var fields: [(String, String)] = []

    public init(fields: [(String, String)] = []) { self.fields = fields }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    func head(fileField: String, fileName: String, mime: String) -> Data {
        var s = ""
        for (k, v) in fields {
            s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
        }
        s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName.replacingOccurrences(of: "\"", with: "'"))\"\r\n"
        s += "Content-Type: \(mime)\r\n\r\n"
        return Data(s.utf8)
    }

    var tail: Data { Data("\r\n--\(boundary)--\r\n".utf8) }

    /// 文件内容放在内存里的版本（分片、小文件）
    public func body(fileField: String, fileName: String, mime: String = "application/octet-stream", content: Data) -> Data {
        head(fileField: fileField, fileName: fileName, mime: mime) + content + tail
    }

    /// 写成临时文件（整文件上传）；调用方用完删除
    public func write(fileField: String, fileName: String, mime: String = "application/octet-stream", file: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cloudn-form-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        try handle.write(contentsOf: head(fileField: fileField, fileName: fileName, mime: mime))
        try FileChunks.scan(file, chunkSize: 1 << 20) { _, d in try handle.write(contentsOf: d) }
        try handle.write(contentsOf: tail)
        return out
    }
}

// MARK: - 签名与小工具

public enum UploadUtil {
    /// RFC 1123 GMT 时间（OSS / HTTP Date）
    public static func httpDate(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }

    /// 简单取 XML 标签内容（<UploadId>…</UploadId>）
    public static func xmlValue(_ tag: String, in text: String) -> String? {
        guard let a = text.range(of: "<\(tag)>"), let b = text.range(of: "</\(tag)>", range: a.upperBound..<text.endIndex) else { return nil }
        return String(text[a.upperBound..<b.lowerBound])
    }

    /// 分片数与第 i 片（从 0 开始）的范围
    public static func parts(size: Int64, partSize: Int64) -> [(offset: Int64, length: Int64)] {
        guard size > 0 else { return [] }
        let p = max(1, partSize)
        return stride(from: Int64(0), to: size, by: Int(p)).map { ($0, min(p, size - $0)) }
    }

    /// URL 路径里的对象名：逐段百分号编码、保留 /
    public static func encodePath(_ key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    }

    /// OSS / S3 分片合并的 XML
    public static func completeXML(_ etags: [String], s3Namespace: Bool = false) -> String {
        var s = s3Namespace ? "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" : "<CompleteMultipartUpload>"
        for (i, e) in etags.enumerated() { s += "<Part><PartNumber>\(i + 1)</PartNumber><ETag>\(e)</ETag></Part>" }
        return s + "</CompleteMultipartUpload>"
    }
}

/// 阿里云 OSS V1 签名（AccessKey / STS 临时凭证）
public struct OSSSigner: Sendable {
    public let accessKeyId: String
    public let accessKeySecret: String
    public let securityToken: String

    public init(accessKeyId: String, accessKeySecret: String, securityToken: String = "") {
        self.accessKeyId = accessKeyId
        self.accessKeySecret = accessKeySecret
        self.securityToken = securityToken
    }

    static let signedSubResources: Set<String> = ["acl", "uploads", "location", "cors", "logging", "website", "referer", "lifecycle",
                                                  "delete", "append", "tagging", "objectMeta", "uploadId", "partNumber", "security-token",
                                                  "position", "img", "style", "styleName", "replication", "replicationProgress",
                                                  "replicationLocation", "cname", "bucketInfo", "comp", "qos", "live", "status", "vod",
                                                  "startTime", "endTime", "symlink", "x-oss-process", "response-content-type",
                                                  "response-content-language", "response-expires", "response-cache-control",
                                                  "response-content-disposition", "response-content-encoding", "udf", "udfName",
                                                  "udfImage", "udfId", "udfImageDesc", "udfApplication", "udfApplicationLog",
                                                  "restore", "callback", "callback-var", "policy", "stat", "sequential",
                                                  "x-oss-enable-sha1"]

    /// 签好的请求头（含 x-oss-date、安全令牌、Authorization）。query 为 [(键, 值)]，值为空写成「键」
    public func headers(method: String, bucket: String, key: String, query: [(String, String)], contentType: String,
                        contentMD5: String = "", extra: [(String, String)] = [], date: Date = Date()) -> [(String, String)] {
        let d = UploadUtil.httpDate(date)
        var all = extra + [("x-oss-date", d)]
        if !securityToken.isEmpty { all.append(("x-oss-security-token", securityToken)) }
        let canonicalHeaders = all.filter { $0.0.lowercased().hasPrefix("x-oss-") }
            .map { ($0.0.lowercased(), $0.1.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }.joined()
        let sub = query.filter { Self.signedSubResources.contains($0.0) }.sorted { $0.0 < $1.0 }
            .map { $0.1.isEmpty ? $0.0 : "\($0.0)=\($0.1)" }.joined(separator: "&")
        let resource = "/\(bucket)/\(key)" + (sub.isEmpty ? "" : "?" + sub)
        let toSign = "\(method)\n\(contentMD5)\n\(contentType)\n\(d)\n\(canonicalHeaders)\(resource)"
        let signature = Data(Crypto.hmac(SHA1Hasher.self, key: Array(accessKeySecret.utf8), message: Data(toSign.utf8))).base64EncodedString()
        var out = all
        out.append(("Content-Type", contentType))
        if !contentMD5.isEmpty { out.append(("Content-MD5", contentMD5)) }
        out.append(("Authorization", "OSS \(accessKeyId):\(signature)"))
        return out
    }
}

/// AWS S3 SigV4（迅雷的对象存储走 S3 协议时用）
public struct S3SigV4: Sendable {
    public let accessKeyId: String
    public let secret: String
    public let sessionToken: String
    public let region: String

    public init(accessKeyId: String, secret: String, sessionToken: String = "", region: String) {
        self.accessKeyId = accessKeyId
        self.secret = secret
        self.sessionToken = sessionToken
        self.region = region
    }

    static func rfc3986(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 返回要加的请求头（host 由 URLSession 自己带，这里只参与签名）
    public func headers(method: String, host: String, path: String, query: [(String, String)], payload: Data?,
                        date: Date = Date()) -> [(String, String)] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = f.string(from: date)
        let day = String(amzDate.prefix(8))
        let payloadHash = payload.map { Crypto.hex(SHA256Hasher.digest($0)) } ?? "UNSIGNED-PAYLOAD"
        var signed: [(String, String)] = [("host", host), ("x-amz-content-sha256", payloadHash), ("x-amz-date", amzDate)]
        if !sessionToken.isEmpty { signed.append(("x-amz-security-token", sessionToken)) }
        signed.sort { $0.0 < $1.0 }
        let canonicalQuery = query.map { (Self.rfc3986($0.0), Self.rfc3986($0.1)) }.sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let canonical = [method, path, canonicalQuery, signed.map { "\($0.0):\($0.1)\n" }.joined(),
                         signed.map(\.0).joined(separator: ";"), payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n" + Crypto.hex(SHA256Hasher.digest(Data(canonical.utf8)))
        var k = Crypto.hmacSHA256(key: Array(("AWS4" + secret).utf8), message: day)
        k = Crypto.hmacSHA256(key: k, message: region)
        k = Crypto.hmacSHA256(key: k, message: "s3")
        k = Crypto.hmacSHA256(key: k, message: "aws4_request")
        let signature = Crypto.hex(Crypto.hmacSHA256(key: k, message: toSign))
        var out = signed.filter { $0.0 != "host" }
        out.append(("Authorization", "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signed.map(\.0).joined(separator: ";")), Signature=\(signature)"))
        return out
    }
}
