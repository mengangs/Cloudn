// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的 youtube 解析（extractor/youtube/_video.py 的字幕、_tab.py 的播放列表）。
import Foundation

// MARK: 字幕

extension YouTubeParser {
    /// 播放器响应里的字幕轨：人工字幕在前，自动生成（kind == "asr"）在后；统一取 WebVTT。
    /// 地址带 `exp=xpe` / `exp=xpv` 实验标记的轨需要 PO Token（与 yt-dlp 的检测一致），拿不到就跳过
    static func subtitles(_ pr: JSON) -> [SubtitleTrack] {
        let tracks = pr["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array
        var manual: [SubtitleTrack] = []
        var automatic: [SubtitleTrack] = []
        var seen = Set<String>()
        for t in tracks {
            let base = t["baseUrl"].string
            guard !base.isEmpty, !captionRequiresPOToken(base) else { continue }
            let isAuto = t["kind"].string == "asr"
            let vss = t["vssId"].string
            var language = t["languageCode"].string
            if language.isEmpty {
                // vssId 形如 ".en"、"a.en"、".zh-Hans.xyz"
                let trimmed = vss.hasPrefix("a.") ? String(vss.dropFirst(2)) : (vss.hasPrefix(".") ? String(vss.dropFirst()) : vss)
                language = trimmed.substringBefore(".")
            }
            guard !language.isEmpty else { continue }
            let key = (isAuto ? "a|" : "m|") + (vss.isEmpty ? language : vss)
            if seen.contains(key) { continue }
            seen.insert(key)
            var name = text(t["name"]).trimmed
            if name.isEmpty { name = language }
            if isAuto && !name.lowercased().contains("auto") && !name.contains("自动") { name += "（自动生成）" }
            let track = SubtitleTrack(name: name, language: language, url: captionURL(base), format: .vtt,
                                      headers: mediaHeaders, automatic: isAuto)
            if isAuto {
                automatic.append(track)
            } else {
                manual.append(track)
            }
        }
        return manual + automatic
    }

    /// 相对地址补全；去掉 xosf（会带上不需要的位置信息）并指定 fmt
    static func captionURL(_ base: String, format: String = "vtt") -> String {
        let absolute = base.hasPrefix("/") ? "https://www.youtube.com" + base : base
        let noFragment = absolute.substringBefore("#")
        guard let q = noFragment.firstIndex(of: "?") else { return noFragment + "?fmt=" + format }
        let path = String(noFragment[..<q])
        let query = String(noFragment[noFragment.index(after: q)...])
        var kept: [String] = []
        for pair in query.split(separator: "&") {
            let name = String(pair).substringBefore("=")
            if name == "fmt" || name == "xosf" || name.isEmpty { continue }
            kept.append(String(pair))
        }
        kept.append("fmt=" + format)
        return path + "?" + kept.joined(separator: "&")
    }

    /// yt-dlp：`exp` 参数里出现 xpe / xpv 实验时字幕需要 PO Token
    static func captionRequiresPOToken(_ base: String) -> Bool {
        let values = Rx(#"[?&]exp=([^&#]*)"#).allMatches(in: base).map { $0[1] }
        return values.contains("xpe") || values.contains("xpv")
    }
}

// MARK: 播放列表

extension YouTubeParser {
    static let browseAPI = "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false"
    /// 与 yt-dlp INNERTUBE_CLIENTS["web"] 一致
    static let webClientVersion = "2.20260708.00.00"
    /// 最多列出的条数
    static let playlistLimit = 500

    static func playlistID(from url: String) -> String? {
        Rx(#"[?&]list=([0-9A-Za-z_\-]+)"#).first(in: url)
    }

    /// 合辑（Mix，RD 开头）按观看记录动态生成，browse 接口拿不到
    static func isMixPlaylist(_ id: String) -> Bool {
        id.hasPrefix("RD") || id.hasPrefix("UL")
    }

    func parsePlaylist(_ link: DetectedVideoLink) async throws -> VideoParseResult {
        let id = link.id.nilIfBlank ?? Self.playlistID(from: link.url) ?? ""
        guard !id.isEmpty else { throw VideoParseError(.unsupported, "无法从链接中识别 YouTube 播放列表 ID") }
        if Self.isMixPlaylist(id) {
            throw VideoParseError(.unsupported, "YouTube 合辑（Mix）是按观看记录动态生成的，无法整体下载，请复制其中单个视频的链接")
        }

        let first = try await browse(["browseId": "VL" + id], visitorData: "")
        var visitor = first["responseContext"]["visitorData"].string
        let firstPage = Self.playlistPage(first)
        var entries: [VideoEntry] = []
        var seen = Set<String>()
        for e in firstPage.entries where !seen.contains(e.url) {
            seen.insert(e.url)
            entries.append(e)
        }
        if entries.isEmpty, let error = Self.alertError(first) { throw error }

        var token = firstPage.continuation
        var usedTokens = Set<String>()
        var incomplete = false
        while !token.isEmpty && entries.count < Self.playlistLimit && !usedTokens.contains(token) {
            usedTokens.insert(token)
            let next: JSON
            do {
                next = try await browse(["continuation": token], visitorData: visitor)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                incomplete = true
                break
            }
            let v = next["responseContext"]["visitorData"].string
            if !v.isEmpty { visitor = v }
            let page = Self.playlistPage(next)
            for e in page.entries where !seen.contains(e.url) {
                seen.insert(e.url)
                entries.append(e)
            }
            token = page.continuation
        }
        let truncated = entries.count >= Self.playlistLimit && (entries.count > Self.playlistLimit || !token.isEmpty)
        if entries.count > Self.playlistLimit { entries = Array(entries.prefix(Self.playlistLimit)) }
        guard !entries.isEmpty else { throw VideoParseError(.unsupported, "这个 YouTube 播放列表里没有可下载的视频") }

        var notice = ""
        if truncated {
            notice = "播放列表较长，只列出了前 \(Self.playlistLimit) 个视频"
        } else if incomplete {
            notice = "播放列表后面的部分加载失败，只列出了 \(entries.count) 个视频"
        }
        let info = Self.playlistInfo(first)
        let title = info.title.isEmpty ? "YouTube 播放列表 \(id)" : info.title
        return VideoParseResult(platform: platform, title: title, author: info.author,
                                cover: info.cover.isEmpty ? entries[0].cover : info.cover, text: info.description,
                                url: "https://www.youtube.com/playlist?list=\(id)", notice: notice, entries: entries)
    }

    private func browse(_ fields: [String: Any], visitorData: String) async throws -> JSON {
        let body = Self.browseRequestBody(fields)
        let headers = Self.browseHeaders(visitorData: visitorData)
        let r = try await OverseasHTTP.send(.postJSON(Self.browseAPI, body, headers: headers.sortedPairs), site: "YouTube")
        if r.isSuccess, let json = r.json { return json }
        switch r.status {
        case 429: throw VideoParseError(.blocked, "YouTube 请求过于频繁（HTTP 429）")
        case 400, 404:
            if let json = r.json, let error = Self.alertError(json) { throw error }
            throw VideoParseError(.notFound, "YouTube 播放列表不存在或不可见（HTTP \(r.status)）")
        case 403: throw VideoParseError(.unknown, "YouTube 拒绝了请求（HTTP 403），所在网络的 IP 可能被风控，可更换代理节点后重试")
        default: throw VideoParseError(.unknown, "YouTube 播放列表接口请求失败（HTTP \(r.status)）")
        }
    }

    static func browseRequestBody(_ fields: [String: Any]) -> [String: Any] {
        let client: [String: Any] = ["clientName": "WEB", "clientVersion": webClientVersion,
                                     "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": 0]
        var body: [String: Any] = ["context": ["client": client]]
        for (k, v) in fields { body[k] = v }
        return body
    }

    static func browseHeaders(visitorData: String) -> [String: String] {
        var h = ["X-YouTube-Client-Name": "1", "X-YouTube-Client-Version": webClientVersion,
                 "Origin": "https://www.youtube.com", "Cookie": consentCookie, "User-Agent": VideoHTTP.uaChrome,
                 "Accept-Language": "en-US,en;q=0.9"]
        if !visitorData.isEmpty { h["X-Goog-Visitor-Id"] = visitorData }
        return h
    }

    // MARK: 纯逻辑：browse 响应

    struct PlaylistPage {
        let entries: [VideoEntry]
        /// 下一页的 continuation token，没有为空串
        let continuation: String
    }

    struct PlaylistInfo {
        let title: String
        let author: String
        let description: String
        let cover: String
    }

    /// 递归收集指定键的值（字典按键名排序遍历，数组保持原顺序）
    static func collect(_ raw: Any?, keys: Set<String>, into out: inout [(String, JSON)]) {
        if let dict = raw as? [String: Any] {
            for k in dict.keys.sorted() {
                let v = dict[k]
                if keys.contains(k) {
                    out.append((k, JSON(v)))
                } else {
                    collect(v, keys: keys, into: &out)
                }
            }
        } else if let arr = raw as? [Any] {
            for v in arr { collect(v, keys: keys, into: &out) }
        }
    }

    /// 首页 / 续页响应 → 视频条目 + 下一页 token。
    /// 视频在 playlistVideoRenderer（新版布局可能是 contentType 为视频的 lockupViewModel）里；
    /// 下一页在 continuationItemRenderer 的 continuationCommand.token
    static func playlistPage(_ json: JSON) -> PlaylistPage {
        var found: [(String, JSON)] = []
        collect(json.raw, keys: ["playlistVideoRenderer", "playlistPanelVideoRenderer", "lockupViewModel"], into: &found)
        var entries: [VideoEntry] = []
        for (key, r) in found {
            let entry = key == "lockupViewModel" ? lockupEntry(r) : playlistVideoEntry(r)
            if let entry { entries.append(entry) }
        }
        return PlaylistPage(entries: entries, continuation: continuationToken(json))
    }

    static func continuationToken(_ json: JSON) -> String {
        var items: [(String, JSON)] = []
        collect(json.raw, keys: ["continuationItemRenderer", "continuationItemViewModel", "nextContinuationData"], into: &items)
        for (key, item) in items {
            if key == "nextContinuationData" {
                let c = item["continuation"].string
                if !c.isEmpty { return c }
                continue
            }
            var commands: [(String, JSON)] = []
            collect(item.raw, keys: ["continuationCommand"], into: &commands)
            for (_, command) in commands {
                let token = command["token"].string
                if !token.isEmpty { return token }
            }
        }
        return ""
    }

    static func playlistVideoEntry(_ r: JSON) -> VideoEntry? {
        let id = r["videoId"].string
        guard isVideoID(id) else { return nil }
        // 已删除 / 私享视频：isPlayable == false
        if r.has("isPlayable") && !r["isPlayable"].bool { return nil }
        var title = text(r["title"]).trimmed
        if title.isEmpty { title = id }
        var duration: Double?
        let seconds = r["lengthSeconds"].int
        if seconds > 0 {
            duration = Double(seconds)
        } else {
            duration = parseClock(text(r["lengthText"]))
        }
        return VideoEntry(title: title, url: "https://www.youtube.com/watch?v=\(id)", duration: duration,
                          cover: largestImage(r["thumbnail"]["thumbnails"].array, fallbackID: id))
    }

    static func lockupEntry(_ vm: JSON) -> VideoEntry? {
        guard vm["contentType"].string == "LOCKUP_CONTENT_TYPE_VIDEO" else { return nil }
        let id = vm["contentId"].string
        guard isVideoID(id) else { return nil }
        var title = vm["metadata"]["lockupMetadataViewModel"]["title"]["content"].string.trimmed
        if title.isEmpty { title = id }
        let thumb = vm["contentImage"]["thumbnailViewModel"]
        var duration: Double?
        for overlay in thumb["overlays"].array {
            let badges = overlay["thumbnailOverlayBadgeViewModel"]["thumbnailBadges"].array
                + overlay["thumbnailBottomOverlayViewModel"]["badges"].array
            for b in badges {
                if let d = parseClock(b["thumbnailBadgeViewModel"]["text"].string) {
                    duration = d
                    break
                }
            }
            if duration != nil { break }
        }
        return VideoEntry(title: title, url: "https://www.youtube.com/watch?v=\(id)", duration: duration,
                          cover: largestImage(thumb["image"]["sources"].array, fallbackID: id))
    }

    static func largestImage(_ list: [JSON], fallbackID: String) -> String {
        var best = ""
        var bestWidth = -1
        for t in list {
            let url = t["url"].string
            if !url.isEmpty && t["width"].int > bestWidth {
                bestWidth = t["width"].int
                best = url
            }
        }
        return best.isEmpty ? "https://i.ytimg.com/vi/\(fallbackID)/hqdefault.jpg" : best
    }

    /// `1:02:03` / `4:05` → 秒；不是时钟格式返回 nil
    static func parseClock(_ s: String) -> Double? {
        let t = s.trimmed
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        var total = 0
        for p in parts {
            guard let v = Int(p), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return Double(total)
    }

    static func playlistInfo(_ json: JSON) -> PlaylistInfo {
        let meta = json["metadata"]["playlistMetadataRenderer"]
        let header = json["header"]["playlistHeaderRenderer"]
        let pageHeader = json["header"]["pageHeaderRenderer"]
        let micro = json["microformat"]["microformatDataRenderer"]

        var title = meta["title"].string.trimmed
        if title.isEmpty { title = text(header["title"]).trimmed }
        if title.isEmpty { title = pageHeader["pageTitle"].string.trimmed }
        if title.isEmpty { title = micro["title"].string.trimmed }

        var author = text(header["ownerText"]).trimmed
        if author.isEmpty {
            for item in json["sidebar"]["playlistSidebarRenderer"]["items"].array {
                let owner = text(item["playlistSidebarSecondaryInfoRenderer"]["videoOwner"]["videoOwnerRenderer"]["title"]).trimmed
                if !owner.isEmpty {
                    author = owner
                    break
                }
            }
        }
        if author.isEmpty {
            let rows = pageHeader["content"]["pageHeaderViewModel"]["metadata"]["contentMetadataViewModel"]["metadataRows"].array
            outer: for row in rows {
                for part in row["metadataParts"].array {
                    let content = part["text"]["content"].string.trimmed
                    if content.hasPrefix("by ") {
                        author = String(content.dropFirst(3)).trimmed
                        break outer
                    }
                }
            }
        }
        // 「by X and 2 others」
        if let main = Rx(#"^(?:by )?(.+?) and \d+ others?$"#).first(in: author) { author = main }
        if author.hasPrefix("by ") { author = String(author.dropFirst(3)) }

        var description = meta["description"].string
        if description.isEmpty { description = micro["description"].string }
        let thumbs = micro["thumbnail"]["thumbnails"].array
        var cover = ""
        var width = -1
        for t in thumbs where !t["url"].string.isEmpty && t["width"].int > width {
            width = t["width"].int
            cover = t["url"].string
        }
        return PlaylistInfo(title: title, author: author, description: description, cover: cover)
    }

    /// alerts 里的 ERROR（播放列表不存在 / 私享）
    static func alertError(_ json: JSON) -> VideoParseError? {
        for alert in json["alerts"].array {
            for key in alert.keys.sorted() {
                let a = alert[key]
                guard a["type"].string.uppercased() == "ERROR" else { continue }
                let message = text(a["text"]).trimmed
                let suffix = message.isEmpty ? "" : "（\(message)）"
                return VideoParseError(.notFound, "YouTube 播放列表不存在、已删除或为私享\(suffix)")
            }
        }
        return nil
    }
}
