// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// tracker 公告（HTTP / UDP）
enum TrackerClient {
    struct Announce {
        var infoHash: [UInt8]
        var peerId: [UInt8]
        var port: UInt16 = 6881
        var downloaded: Int64 = 0
        var left: Int64 = 0
        var event: Int32 = 2 // UDP：0 无 / 1 完成 / 2 开始 / 3 停止
    }

    static func announce(_ tracker: String, _ a: Announce, network: TorrentNetwork, client: HTTPClient) async throws -> [PeerAddress] {
        let lower = tracker.lowercased()
        if lower.hasPrefix("udp://") {
            guard let address = udpAddress(tracker) else { throw TransferError("tracker 地址无效") }
            return try await announceUDP(address, a, network: network)
        }
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { throw TransferError("不支持的 tracker") }
        var request = HTTPRequest.get(httpURL(tracker, a), headers: [("User-Agent", "Cloudn/1.0")])
        request.timeout = 15
        let r = try await client.send(request)
        guard (200..<300).contains(r.status) else { throw TransferError("tracker HTTP \(r.status)") }
        return try parseHTTPResponse(r.body)
    }

    static func httpURL(_ tracker: String, _ a: Announce) -> String {
        let event = a.event == 2 ? "&event=started" : ""
        return tracker + (tracker.contains("?") ? "&" : "?") +
            "info_hash=\(percent(a.infoHash))&peer_id=\(percent(a.peerId))&port=\(a.port)&uploaded=0" +
            "&downloaded=\(a.downloaded)&left=\(a.left)&compact=1&numwant=200\(event)"
    }

    /// 原始字节逐个百分号编码（只保留不需要编码的字符）
    static func percent(_ bytes: [UInt8]) -> String {
        bytes.map { b -> String in
            let c = Character(UnicodeScalar(b))
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || "-._~".contains(c) { return String(c) }
            return String(format: "%%%02X", b)
        }.joined()
    }

    static func parseHTTPResponse(_ body: Data) throws -> [PeerAddress] {
        let v = try Bencode.decode(body)
        if let reason = v["failure reason"]?.string { throw TransferError("tracker：\(reason)") }
        var peers: [PeerAddress] = []
        if let compact = v["peers"]?.data {
            peers += PeerAddress.compact(compact)
        } else if let list = v["peers"]?.list {
            for p in list {
                if let ip = p["ip"]?.string, let port = p["port"]?.int, port > 0, port < 65536 { peers.append(PeerAddress(host: ip, port: UInt16(port))) }
            }
        }
        if let v6 = v["peers6"]?.data { peers += PeerAddress.compact(v6, ipv6: true) }
        return peers
    }

    static func udpAddress(_ tracker: String) -> PeerAddress? {
        guard let comps = URLComponents(string: tracker), let host = comps.host, let port = comps.port, port > 0, port < 65536 else { return nil }
        return PeerAddress(host: host, port: UInt16(port))
    }

    /// BEP 15：先 connect 拿 connection_id，再 announce
    static func announceUDP(_ address: PeerAddress, _ a: Announce, network: TorrentNetwork) async throws -> [PeerAddress] {
        let tid1 = UInt32.random(in: 0...UInt32.max)
        let connectResp = [UInt8](try await network.udpRequest(address, payload: udpConnect(tid1), timeout: 8))
        let connectionId = try parseUDPConnect(connectResp, transaction: tid1)
        let tid2 = UInt32.random(in: 0...UInt32.max)
        let resp = [UInt8](try await network.udpRequest(address, payload: udpAnnounce(connectionId, tid2, a), timeout: 8))
        return try parseUDPAnnounce(resp, transaction: tid2)
    }

    static func udpConnect(_ tid: UInt32) -> Data {
        Data(PeerWire.be64(0x41727101980) + PeerWire.be32(0) + PeerWire.be32(tid))
    }

    static func parseUDPConnect(_ b: [UInt8], transaction: UInt32) throws -> UInt64 {
        guard b.count >= 16, PeerWire.readBE32(b, 0) == 0, PeerWire.readBE32(b, 4) == transaction else { throw TransferError("UDP tracker 连接失败") }
        return PeerWire.readBE64(b, 8)
    }

    static func udpAnnounce(_ connectionId: UInt64, _ tid: UInt32, _ a: Announce) -> Data {
        var d = PeerWire.be64(connectionId) + PeerWire.be32(1) + PeerWire.be32(tid)
        d += a.infoHash + a.peerId
        d += PeerWire.be64(UInt64(max(0, a.downloaded))) + PeerWire.be64(UInt64(max(0, a.left))) + PeerWire.be64(0)
        d += PeerWire.be32(UInt32(bitPattern: a.event)) + PeerWire.be32(0) + PeerWire.be32(UInt32.random(in: 0...UInt32.max))
        d += PeerWire.be32(UInt32(bitPattern: -1)) + PeerWire.be16(a.port)
        return Data(d)
    }

    static func parseUDPAnnounce(_ b: [UInt8], transaction: UInt32) throws -> [PeerAddress] {
        guard b.count >= 8, PeerWire.readBE32(b, 4) == transaction else { throw TransferError("UDP tracker 响应无效") }
        let action = PeerWire.readBE32(b, 0)
        if action == 3 { throw TransferError("tracker：\(String(decoding: b[8...], as: UTF8.self))") }
        guard action == 1, b.count >= 20 else { throw TransferError("UDP tracker 响应无效") }
        return PeerAddress.compact(Data(b[20...]))
    }
}

/// DHT（BEP 5）：只做 get_peers 迭代查找，不对外提供节点服务
actor DHTLookup {
    struct Node: Hashable {
        let id: [UInt8]
        let address: PeerAddress
    }

    static let bootstrap = [PeerAddress(host: "router.bittorrent.com", port: 6881), PeerAddress(host: "dht.transmissionbt.com", port: 6881),
                            PeerAddress(host: "router.utorrent.com", port: 6881), PeerAddress(host: "dht.libtorrent.org", port: 25401),
                            PeerAddress(host: "router.bitcomet.com", port: 6881), PeerAddress(host: "dht.aelitis.com", port: 6881)]

    private let network: TorrentNetwork
    private let target: [UInt8]
    private let nodeId: [UInt8]
    /// 上一轮查到的近邻，下一次查找从这里继续（不必每次都从引导节点开始）
    private var known: [Node] = []

    init(network: TorrentNetwork, infoHash: [UInt8]) {
        self.network = network
        target = infoHash
        nodeId = (0..<20).map { _ in UInt8.random(in: 0...255) }
    }

    /// 一次迭代查找：每轮并发问 8 个离目标最近、还没问过的节点；查到的 peer 边找边回调
    /// 返回本次有回应的节点数（诊断用）
    @discardableResult
    func findPeers(rounds: Int = 12, onPeers: @escaping @Sendable ([PeerAddress]) async -> Void) async -> Int {
        var responded = 0
        var candidates = known
        var asked = Set<PeerAddress>()
        var bootstrapUsed = false
        for _ in 0..<rounds {
            if Task.isCancelled { return responded }
            candidates.sort { Self.closer($0.id, than: $1.id, to: target) }
            var batch = candidates.filter { !asked.contains($0.address) }.prefix(8).map(\.address)
            if batch.isEmpty {
                guard !bootstrapUsed else { break }
                bootstrapUsed = true
                batch = Self.bootstrap
            }
            batch.forEach { asked.insert($0) }
            let query = Self.getPeersQuery(nodeId: nodeId, infoHash: target, transaction: [UInt8.random(in: 0...255), UInt8.random(in: 0...255)])
            let results = await withTaskGroup(of: (PeerAddress, DHTResponse?).self) { group -> [(PeerAddress, DHTResponse?)] in
                for address in batch {
                    group.addTask { [network] in
                        let data = try? await network.udpRequest(address, payload: query, timeout: 3)
                        return (address, data.flatMap { try? Self.parseResponse($0) })
                    }
                }
                var all: [(PeerAddress, DHTResponse?)] = []
                for await r in group { all.append(r) }
                return all
            }
            var peers: [PeerAddress] = []
            var progressed = false
            for (_, response) in results {
                guard let response else { continue }
                responded += 1
                peers += response.peers
                for n in response.nodes where !candidates.contains(n) {
                    candidates.append(n)
                    progressed = true
                }
            }
            if !peers.isEmpty { await onPeers(peers) }
            if !progressed && bootstrapUsed && candidates.allSatisfy({ asked.contains($0.address) }) { break }
        }
        candidates.sort { Self.closer($0.id, than: $1.id, to: target) }
        known = Array(candidates.prefix(32))
        return responded
    }

    struct DHTResponse {
        var nodes: [Node] = []
        var peers: [PeerAddress] = []
    }

    static func getPeersQuery(nodeId: [UInt8], infoHash: [UInt8], transaction: [UInt8]) -> Data {
        Bencode.encode(.dict([("t", .bytes(Data(transaction))), ("y", BValue("q")), ("q", BValue("get_peers")),
                              ("a", .dict([("id", .bytes(Data(nodeId))), ("info_hash", .bytes(Data(infoHash)))]))]))
    }

    static func parseResponse(_ data: Data) throws -> DHTResponse {
        let v = try Bencode.decode(data)
        guard v["y"]?.string == "r", let r = v["r"] else { throw TransferError("DHT 响应无效") }
        var out = DHTResponse()
        for value in r["values"]?.list ?? [] {
            if let d = value.data { out.peers += PeerAddress.compact(d) }
        }
        if let nodes = r["nodes"]?.data {
            let b = [UInt8](nodes)
            var i = 0
            while i + 26 <= b.count {
                let id = Array(b[i..<i + 20])
                if let addr = PeerAddress.compact(Data(b[i + 20..<i + 26])).first { out.nodes.append(Node(id: id, address: addr)) }
                i += 26
            }
        }
        return out
    }

    /// XOR 距离比较：a 是否比 b 更接近 target
    static func closer(_ a: [UInt8], than b: [UInt8], to target: [UInt8]) -> Bool {
        for i in 0..<min(20, min(a.count, b.count)) {
            let da = a[i] ^ target[i], db = b[i] ^ target[i]
            if da != db { return da < db }
        }
        return false
    }
}
