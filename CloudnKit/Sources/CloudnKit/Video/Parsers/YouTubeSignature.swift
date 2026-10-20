// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 youtube 签名 / n 参数求解（jsc/_builtin/ejs.py + yt-dlp/ejs 求解脚本）。
import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// YouTube 播放地址的两类 JS 挑战：
/// - sig：`signatureCipher` 里的加密签名 `s`，解出后以 `sp`（默认 signature）参数拼回地址；
/// - n：地址里的 `n` 参数，不变换会被限速甚至直接 403。
///
/// 做法与 yt-dlp 当前的 EJS 求解器一致：下载播放器 base.js，用内嵌的 meriyah 把它解析成语法树，
/// 删掉顶层的副作用调用、找到带 `X.set("alr","yes")` 的那个 URL 处理函数，再把整个播放器
/// 在 JavaScriptCore 里跑一遍，用它把挑战值变换成结果。预处理后的播放器按播放器版本缓存在内存里，
/// 同一版本只需解析一次。没有 JavaScriptCore 的平台（Linux）直接报不支持。
enum YouTubeSignature {
    struct Solution: Sendable, Equatable {
        var sig: [String: String] = [:]
        var n: [String: String] = [:]
    }

    static let cache = YouTubePlayerCache()

    static var isSupported: Bool {
        #if canImport(JavaScriptCore)
        return true
        #else
        return false
        #endif
    }

    static let unsupportedError = VideoParseError(.unsupported, "当前平台无法执行 JavaScript，解不开 YouTube 播放地址的签名")

    /// 求解一批挑战。`playerJS` 为空时要求缓存里已有该版本预处理过的播放器。
    static func solve(playerID: String, playerJS: String?, sig: [String], n: [String]) async throws -> Solution {
        let sigs = Array(Set(sig)).sorted()
        let ns = Array(Set(n)).sorted()
        if sigs.isEmpty && ns.isEmpty { return Solution() }
        guard isSupported else { throw unsupportedError }

        var player = ""
        var preprocessed = false
        if let cached = cache.preprocessed(for: playerID) {
            player = cached
            preprocessed = true
        } else if let js = playerJS, !js.isEmpty {
            player = js
        } else {
            throw VideoParseError(.unknown, "缺少 YouTube 播放器脚本，无法求解签名")
        }

        let (request, types) = requestJSON(sig: sigs, n: ns)
        let output = try await evaluate(player: player, preprocessed: preprocessed, request: request)
        let parsed = try parseOutput(output, types: types)
        if !preprocessed, !parsed.preprocessed.isEmpty {
            cache.storePreprocessed(parsed.preprocessed, for: playerID)
        }
        return parsed.solution
    }

    // MARK: 纯逻辑

    /// 交给求解脚本的请求（不含播放器本体）；返回 JSON 文本和请求类型的顺序
    static func requestJSON(sig: [String], n: [String]) -> (String, [String]) {
        var requests: [[String: Any]] = []
        var types: [String] = []
        if !sig.isEmpty {
            requests.append(["type": "sig", "challenges": sig])
            types.append("sig")
        }
        if !n.isEmpty {
            requests.append(["type": "n", "challenges": n])
            types.append("n")
        }
        let data = JSON.serialize(["requests": requests])
        return (String(decoding: data, as: UTF8.self), types)
    }

    /// 解析求解脚本的输出：`{"type":"result","responses":[{"type":"result","data":{挑战:结果}}|{"type":"error",...}],"preprocessed_player":"..."}`
    static func parseOutput(_ text: String, types: [String]) throws -> (solution: Solution, preprocessed: String) {
        guard let json = JSON(text: text) else { throw VideoParseError(.unknown, "YouTube 签名求解脚本输出无法解析") }
        if json["type"].string == "error" {
            throw VideoParseError(.unknown, "YouTube 签名求解失败：\(String(json["error"].string.prefix(200)))")
        }
        var solution = Solution()
        let responses = json["responses"].array
        for (i, type) in types.enumerated() where i < responses.count {
            let response = responses[i]
            guard response["type"].string == "result" else { continue }
            let data = response["data"]
            var map: [String: String] = [:]
            for key in data.keys {
                let value = data[key].string
                if !value.isEmpty { map[key] = value }
            }
            if type == "sig" { solution.sig = map } else { solution.n = map }
        }
        return (solution, json["preprocessed_player"].string)
    }

    /// 在 JS 里执行的胶水：与 yt-dlp 拼给 deno/node 的 stdin 等价，只是输入走全局变量而不是源码拼接
    static let glueScript = #"""
    var __cloudnInput = JSON.parse(__cloudnRequest);
    if (__cloudnPreprocessed === "1") {
        __cloudnInput.type = "preprocessed";
        __cloudnInput.preprocessed_player = __cloudnPlayer;
    } else {
        __cloudnInput.type = "player";
        __cloudnInput.player = __cloudnPlayer;
        __cloudnInput.output_preprocessed = true;
    }
    JSON.stringify(jsc(__cloudnInput));
    """#

    private static let queue = DispatchQueue(label: "cloudn.youtube.jsc", qos: .userInitiated)

    /// JS 执行是同步且耗 CPU 的（首次解析 base.js 约 1～3 秒），放到专用串行队列上，不占协作线程池
    static func evaluate(player: String, preprocessed: Bool, request: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                do {
                    let text = try YouTubeSignature.evaluateSync(player: player, preprocessed: preprocessed, request: request)
                    cont.resume(returning: text)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    #if canImport(JavaScriptCore)
    static func evaluateSync(player: String, preprocessed: Bool, request: String) throws -> String {
        guard let context = JSContext() else { throw VideoParseError(.unknown, "无法创建 JavaScript 运行环境") }
        let setup = YouTubeSolverScripts.lib + "\nObject.assign(globalThis, lib);\n" + YouTubeSolverScripts.core
        _ = context.evaluateScript(setup)
        if let e = context.exception {
            throw VideoParseError(.unknown, "YouTube 签名求解脚本加载失败：\(e.toString() ?? "")")
        }
        context.setObject(player, forKeyedSubscript: "__cloudnPlayer" as NSString)
        context.setObject(preprocessed ? "1" : "0", forKeyedSubscript: "__cloudnPreprocessed" as NSString)
        context.setObject(request, forKeyedSubscript: "__cloudnRequest" as NSString)
        let value = context.evaluateScript(glueScript)
        if let e = context.exception {
            let message = String((e.toString() ?? "").prefix(200))
            throw VideoParseError(.unknown, "YouTube 签名求解失败（播放器结构可能已变化）：\(message)")
        }
        guard let value, value.isString, let text = value.toString() else {
            throw VideoParseError(.unknown, "YouTube 签名求解脚本没有输出")
        }
        return text
    }
    #else
    static func evaluateSync(player: String, preprocessed: Bool, request: String) throws -> String {
        throw unsupportedError
    }
    #endif
}

/// 播放器脚本缓存：只留最近一个版本（base.js 与预处理结果各约 2～3 MB）
final class YouTubePlayerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var playerID = ""
    private var js: String?
    private var preprocessed: String?
    private var timestamp = 0

    func playerJS(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return id == playerID ? js : nil
    }

    func preprocessed(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return id == playerID ? preprocessed : nil
    }

    func signatureTimestamp(for id: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return id == playerID && timestamp > 0 ? timestamp : nil
    }

    func storePlayer(_ code: String, timestamp sts: Int, for id: String) {
        lock.lock(); defer { lock.unlock() }
        if id != playerID {
            playerID = id
            preprocessed = nil
        }
        js = code
        timestamp = sts
    }

    /// 预处理结果到手后原始 base.js 就用不上了（签名时间戳另存），释放掉
    func storePreprocessed(_ code: String, for id: String) {
        lock.lock(); defer { lock.unlock() }
        if id != playerID {
            playerID = id
            timestamp = 0
        }
        preprocessed = code
        js = nil
    }
}
