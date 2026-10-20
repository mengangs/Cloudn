// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 「网盘更新」：发布说明里附的网盘分享链接，自动找到里面的安装包（参考 YunX「网盘更新」）
public enum UpdatePackage {
    /// 发布说明里的所有网盘分享（按行识别，同一行的提取码跟着链接走）
    public static func shares(in notes: String) -> [ParsedShare] {
        var seen = Set<String>()
        var out: [ParsedShare] = []
        for line in notes.split(whereSeparator: \.isNewline) {
            // 一行里可能有多条链接：按 http 切开逐段识别（每段 = 链接 + 它后面的文字）
            let parts = String(line).components(separatedBy: "http")
            for i in parts.indices.dropFirst() {
                guard let share = ShareLinkParser.parse("http" + parts[i]), share.platform.isResolvable,
                      seen.insert(share.url).inserted else { continue }
                // 提取码也可能写在链接前面（「提取码：abcd 迅雷：https://…」）
                let pwd = share.pwd ?? ShareLinkParser.textPassword(in: parts[i - 1])
                out.append(ParsedShare(shareId: share.shareId, pwd: pwd, platform: share.platform, url: share.url))
            }
        }
        return out
    }

    /// 在分享里找安装包：逐层展开文件夹（最多 maxDepth 层、maxFolders 个），取体积最大的 .ipa
    public static func findPackage(resolver: ShareResolver, session: ShareSession, extensions: [String] = ["ipa"],
                                   maxDepth: Int = 6, maxFolders: Int = 60) async throws -> ShareFile? {
        var queue: [(id: String, depth: Int)] = [(session.rootId, 0)]
        var visited = 0
        var best: ShareFile?
        while !queue.isEmpty, visited < maxFolders {
            let (id, depth) = queue.removeFirst()
            visited += 1
            for f in try await resolver.list(session, dirId: id) {
                if f.isDirectory {
                    if depth + 1 <= maxDepth { queue.append((f.fid, depth + 1)) }
                } else if extensions.contains(FileNames.fileExtension(f.name).lowercased()), f.size > (best?.size ?? -1) {
                    best = f
                }
            }
        }
        return best
    }
}
