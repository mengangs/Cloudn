// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
#if canImport(Network)
import Network
#endif

/// 与一个 peer 的 TCP 字节流
public protocol PeerStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// 读满 n 字节；超时或连接断开抛错
    func receive(exactly n: Int, timeout: TimeInterval) async throws -> Data
    func close()
}

/// BT 用到的网络能力：连 peer（TCP）、一问一答的 UDP（UDP tracker、DHT）。测试里换成内存实现
public protocol TorrentNetwork: Sendable {
    func connect(_ address: PeerAddress, timeout: TimeInterval) async throws -> PeerStream
    func udpRequest(_ address: PeerAddress, payload: Data, timeout: TimeInterval) async throws -> Data
}

enum TorrentTimeout {
    struct Expired: Error, LocalizedError {
        var errorDescription: String? { "连接超时" }
    }

    static func run<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                throw Expired()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Expired() }
            return first
        }
    }
}

#if canImport(Network)
/// Network.framework 实现（会按需唤醒蜂窝网络，与系统 VPN / 代理设置一致）
public struct SystemTorrentNetwork: TorrentNetwork {
    public init() {}

    private static let queue = DispatchQueue(label: "cloudn.torrent.net", attributes: .concurrent)

    public func connect(_ address: PeerAddress, timeout: TimeInterval) async throws -> PeerStream {
        guard let port = NWEndpoint.Port(rawValue: address.port) else { throw TransferError("peer 端口无效") }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(max(1, timeout))
        tcp.noDelay = true
        let conn = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        let stream = NWPeerStream(conn)
        do {
            try await TorrentTimeout.run(timeout) { try await stream.start(queue: Self.queue) }
        } catch {
            stream.close()
            throw error
        }
        return stream
    }

    public func udpRequest(_ address: PeerAddress, payload: Data, timeout: TimeInterval) async throws -> Data {
        guard let port = NWEndpoint.Port(rawValue: address.port) else { throw TransferError("端口无效") }
        let conn = NWConnection(host: NWEndpoint.Host(address.host), port: port, using: .udp)
        defer { conn.cancel() }
        return try await TorrentTimeout.run(timeout) {
            // 超时 / 取消时要让续体结束：取消连接会触发 .cancelled
            try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let once = OnceFlag()
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: payload, completion: .contentProcessed { error in
                            if let error, once.claim() { cont.resume(throwing: error) }
                        })
                        conn.receiveMessage { data, _, _, error in
                            guard once.claim() else { return }
                            if let data, !data.isEmpty { cont.resume(returning: data) } else { cont.resume(throwing: error ?? TransferError("UDP 无响应")) }
                        }
                    case .failed(let error):
                        if once.claim() { cont.resume(throwing: error) }
                    case .cancelled:
                        if once.claim() { cont.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                conn.start(queue: Self.queue)
            } } onCancel: { conn.cancel() }
        }
    }
}

final class NWPeerStream: PeerStream, @unchecked Sendable {
    private let conn: NWConnection
    private let lock = NSLock()
    private var buffer = Data()

    init(_ conn: NWConnection) { self.conn = conn }

    func start(queue: DispatchQueue) async throws {
        try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { cont.resume() }
                case .failed(let e): if once.claim() { cont.resume(throwing: e) }
                case .waiting(let e): if once.claim() { cont.resume(throwing: e) }
                case .cancelled: if once.claim() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            conn.start(queue: queue)
        } } onCancel: { [conn] in conn.cancel() }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    func receive(exactly n: Int, timeout: TimeInterval) async throws -> Data {
        while true {
            lock.lock()
            if buffer.count >= n {
                let out = Data(buffer.prefix(n))
                buffer.removeFirst(n)
                lock.unlock()
                return out
            }
            lock.unlock()
            let chunk = try await TorrentTimeout.run(timeout) { try await self.readSome() }
            lock.lock(); buffer.append(chunk); lock.unlock()
        }
    }

    private func readSome() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                    if let data, !data.isEmpty { cont.resume(returning: data) } else if let error { cont.resume(throwing: error) } else if complete {
                        cont.resume(throwing: TransferError("peer 断开了连接"))
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
        } onCancel: { [conn] in
            conn.cancel()
        }
    }

    func close() { conn.cancel() }
}

/// 回调只放行第一次
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
#endif

/// 没有 Network.framework 的平台（Linux 测试）：BT 下载不可用
public struct UnavailableTorrentNetwork: TorrentNetwork {
    public init() {}
    public func connect(_ address: PeerAddress, timeout: TimeInterval) async throws -> PeerStream {
        throw TransferError("当前平台不支持 BT 下载")
    }
    public func udpRequest(_ address: PeerAddress, payload: Data, timeout: TimeInterval) async throws -> Data {
        throw TransferError("当前平台不支持 BT 下载")
    }
}

public enum TorrentNetworks {
    public static var system: TorrentNetwork {
        #if canImport(Network)
        return SystemTorrentNetwork()
        #else
        return UnavailableTorrentNetwork()
        #endif
    }
}
