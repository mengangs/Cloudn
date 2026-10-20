// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 bilibili 解析（WBI 签名、CC 字幕、多 P / 合集）。
import Foundation

/// 多 P / 合集（ugc_season）展开结果
struct BiliCollection {
    /// 非 nil 时替换结果标题
    let title: String?
    let notice: String
    let entries: [VideoEntry]

    static let empty = BiliCollection(title: nil, notice: "", entries: [])
}

extension BilibiliParser {
    static let subtitleListURL = "https://api.bilibili.com/x/player/wbi/v2"

    // MARK: 多 P / 合集

    /// 多 P 且链接没指定 ?p= → 列出全部分 P；否则视频属于合集 → 列出合集全部视频
    static func collection(_ data: JSON, explicitPage: Bool) -> BiliCollection {
        let pages = pageEntries(data)
        if pages.count > 1 && !explicitPage {
            let title = data["title"].string
            return BiliCollection(title: title.isEmpty ? nil : title,
                                  notice: "该视频共 \(pages.count) 个分 P，可在列表里选择要下载的分 P；直接下载的是 P1",
                                  entries: pages)
        }
        let season = seasonEntries(data)
        if season.count > 1 {
            let name = data["ugc_season"]["title"].string
            let label = name.isEmpty ? "合集" : "合集「\(name)」"
            return BiliCollection(title: nil, notice: "该视频属于\(label)，共 \(season.count) 个视频，可在列表里选择下载",
                                  entries: season)
        }
        return .empty
    }

    static func pageEntries(_ data: JSON) -> [VideoEntry] {
        let bvid = data["bvid"].string
        guard !bvid.isEmpty else { return [] }
        let pages = data["pages"].array
        var out: [VideoEntry] = []
        for (i, p) in pages.enumerated() {
            let number = p["page"].int > 0 ? p["page"].int : i + 1
            let part = p["part"].string.trimmed
            let title = part.isEmpty ? "P\(number)" : "P\(number) \(part)"
            let seconds = p["duration"].double
            let cover = p["first_frame"].string.nilIfBlank ?? data["pic"].string
            out.append(VideoEntry(title: title, url: "https://www.bilibili.com/video/\(bvid)?p=\(number)",
                                  duration: seconds > 0 ? seconds : nil, cover: secure(cover)))
        }
        return out
    }

    static func seasonEntries(_ data: JSON) -> [VideoEntry] {
        let season = data["ugc_season"]
        guard season.isObject else { return [] }
        var out: [VideoEntry] = []
        var seen = Set<String>()
        for section in season["sections"].array {
            for ep in section["episodes"].array {
                let bvid = ep["bvid"].string.nilIfBlank ?? ep["arc"]["bvid"].string
                guard !bvid.isEmpty, !seen.contains(bvid) else { continue }
                seen.insert(bvid)
                let title = ep["title"].string.nilIfBlank ?? ep["arc"]["title"].string.nilIfBlank ?? bvid
                var seconds = ep["arc"]["duration"].double
                if seconds <= 0 { seconds = ep["page"]["duration"].double }
                out.append(VideoEntry(title: title, url: "https://www.bilibili.com/video/\(bvid)",
                                      duration: seconds > 0 ? seconds : nil, cover: secure(ep["arc"]["pic"].string)))
            }
        }
        return out
    }

    /// 协议相对 / http 地址统一成 https
    static func secure(_ url: String) -> String {
        if url.hasPrefix("//") { return "https:" + url }
        if url.hasPrefix("http://") { return "https://" + String(url.dropFirst(7)) }
        return url
    }

    // MARK: CC 字幕

    /// 字幕列表（x/player/wbi/v2，带 WBI 签名；拿不到密钥时不签名，yt-dlp 也是直接请求）。
    /// 字幕基本都要登录才给地址，没有登录 Cookie（SESSDATA）就不请求了
    func subtitleTracks(bvid: String, cid: Int64, cookie: String) async -> [SubtitleTrack] {
        guard !(CookieUtil.value(of: "SESSDATA", in: cookie) ?? "").isEmpty else { return [] }
        let headers = Self.headers(cookie)
        let params = ["bvid": bvid, "cid": String(cid)]
        var query = params.keys.sorted().map { "\($0)=\(BilibiliWbi.encode(params[$0] ?? ""))" }.joined(separator: "&")
        if let key = await BilibiliWbi.cache.mixinKey(headers: headers) {
            query = BilibiliWbi.sign(params, mixinKey: key, timestamp: Int(Date().timeIntervalSince1970))
        }
        guard let json = try? await VideoHTTP.getJSON("\(Self.subtitleListURL)?\(query)", headers: headers, what: "B站字幕列表"),
              json["code"].int == 0 else { return [] }
        return Self.subtitleTracks(json)
    }

    /// data.subtitle.subtitles[]：lan / lan_doc / subtitle_url；lan 以 ai- 开头的是 AI 生成。人工字幕排前面
    static func subtitleTracks(_ json: JSON) -> [SubtitleTrack] {
        let headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": "https://www.bilibili.com/"]
        var manual: [SubtitleTrack] = []
        var automatic: [SubtitleTrack] = []
        var seen = Set<String>()
        for s in json["data"]["subtitle"]["subtitles"].array {
            let lan = s["lan"].string
            let url = secure(s["subtitle_url"].string)
            guard !lan.isEmpty, !url.isEmpty, !seen.contains(lan) else { continue }
            seen.insert(lan)
            let isAI = lan.hasPrefix("ai-")
            var name = s["lan_doc"].string.trimmed
            if name.isEmpty { name = lan }
            if isAI && !name.contains("自动") && !name.contains("AI") { name += "（AI 生成）" }
            let track = SubtitleTrack(name: name, language: lan, url: url, format: .biliJSON, headers: headers, automatic: isAI)
            if isAI {
                automatic.append(track)
            } else {
                manual.append(track)
            }
        }
        return manual + automatic
    }
}

// MARK: WBI 签名

/// B 站 Web 接口的 WBI 签名：nav 接口 wbi_img 的 img_key + sub_key 按固定表重排取前 32 位作为 mixin key，
/// 参数（含 wts 时间戳）按键名排序、去掉 `!'()*` 后编码拼接，再接上 mixin key 求 MD5 作为 w_rid
enum BilibiliWbi {
    static let mixinTable: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52
    ]

    /// `https://i0.hdslb.com/bfs/wbi/7cd0….png` → `7cd0…`
    static func key(fromURL url: String) -> String {
        url.substringAfterLast("/").substringBefore(".")
    }

    static func mixinKey(imgKey: String, subKey: String) -> String {
        let lookup = Array(imgKey + subKey)
        var out = ""
        for i in mixinTable where i < lookup.count {
            out.append(lookup[i])
        }
        return String(out.prefix(32))
    }

    /// 与 Python urllib.parse.urlencode 一致：字母数字与 `-._~` 原样，空格为 +，其余 UTF-8 百分号编码
    static func encode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || c == "-" || c == "." || c == "_" || c == "~" {
                out.append(c)
            } else if b == 0x20 {
                out.append("+")
            } else {
                let hex = String(b, radix: 16, uppercase: true)
                out += "%" + (hex.count == 1 ? "0" + hex : hex)
            }
        }
        return out
    }

    /// 返回签好名的完整查询串（末尾带 w_rid）
    static func sign(_ params: [String: String], mixinKey: String, timestamp: Int) -> String {
        var all = params
        all["wts"] = String(timestamp)
        let forbidden: Set<Character> = ["!", "'", "(", ")", "*"]
        let query = all.keys.sorted().map { k -> String in
            let value = String((all[k] ?? "").filter { !forbidden.contains($0) })
            return encode(k) + "=" + encode(value)
        }.joined(separator: "&")
        let rid = Crypto.md5Hex(query + mixinKey)
        return query + "&w_rid=" + rid
    }

    /// nav 接口的 wbi_img（未登录也会返回）；密钥每天轮换，缓存 10 分钟
    final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key = ""
        private var fetchedAt = Date.distantPast

        func mixinKey(headers: [String: String]) async -> String? {
            if let cached = current() { return cached }
            guard let json = try? await VideoHTTP.getJSON(BilibiliParser.navURL, headers: headers, what: "B站 WBI 密钥") else { return nil }
            let img = BilibiliWbi.key(fromURL: json["data"]["wbi_img"]["img_url"].string)
            let sub = BilibiliWbi.key(fromURL: json["data"]["wbi_img"]["sub_url"].string)
            guard !img.isEmpty, !sub.isEmpty else { return nil }
            let mixed = BilibiliWbi.mixinKey(imgKey: img, subKey: sub)
            store(mixed)
            return mixed
        }

        private func current() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return !key.isEmpty && Date().timeIntervalSince(fetchedAt) < 600 ? key : nil
        }

        private func store(_ k: String) {
            lock.lock()
            key = k
            fetchedAt = Date()
            lock.unlock()
        }
    }

    static let cache = KeyCache()
}
