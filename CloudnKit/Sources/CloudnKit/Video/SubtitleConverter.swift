// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 yt-dlp（Unlicense）的字幕处理（bilibili json2srt、srt_subtitles_timecode）。
import Foundation

/// 把各平台的字幕统一转成 SRT：WebVTT、B 站字幕 JSON、YouTube json3；SRT 原样返回
public enum SubtitleConverter {
    /// 一条字幕（毫秒）
    struct Cue: Equatable {
        var start: Int
        var end: Int
        var text: String
    }

    /// 转换失败或没有任何字幕条目时返回 nil
    public static func toSRT(_ data: Data, format: SubtitleTrack.Format) -> Data? {
        let cues: [Cue]
        switch format {
        case .srt:
            return data.isEmpty ? nil : data
        case .vtt:
            guard let text = decodeText(data) else { return nil }
            cues = vttCues(text)
        case .biliJSON:
            guard let json = JSON(data: data) else { return nil }
            cues = biliCues(json)
        case .youtubeJSON3:
            guard let json = JSON(data: data) else { return nil }
            cues = json3Cues(json)
        }
        guard !cues.isEmpty else { return nil }
        return Data(srt(cues).utf8)
    }

    // MARK: SRT 输出

    static func srt(_ cues: [Cue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n\(timecode(cue.start)) --> \(timecode(cue.end))\n\(cue.text)\n\n"
        }
        return out
    }

    /// 毫秒 → `HH:MM:SS,mmm`
    static func timecode(_ ms: Int) -> String {
        let v = max(0, ms)
        let h = v / 3_600_000
        let m = (v / 60_000) % 60
        let s = (v / 1000) % 60
        let f = v % 1000
        return pad(h, 2) + ":" + pad(m, 2) + ":" + pad(s, 2) + "," + pad(f, 3)
    }

    static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// 时间上限（约 100 年）：字幕文件 / 接口里的时间不可信，超大值、负数、inf / nan 都夹到 0...上限，
    /// 后面的加减比较（开始 + 时长、相邻两条之差）才不会溢出崩溃
    static let maxMilliseconds = 100 * 365 * 24 * 3600 * 1000

    static func clampMilliseconds(_ ms: Int) -> Int { min(max(0, ms), maxMilliseconds) }

    static func milliseconds(_ seconds: Double) -> Int {
        clampMilliseconds(Int(saturating: (seconds * 1000).rounded()))
    }

    static func decodeText(_ data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    // MARK: WebVTT

    /// `hh:mm:ss.ttt` 或 `mm:ss.ttt`（容忍逗号小数点）→ 毫秒
    static func vttTime(_ raw: String) -> Int? {
        let s = raw.trimmed.replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0 else { return nil }
            if i < parts.count - 1 && p.contains(".") { return nil }
            total = total * 60 + v
        }
        return milliseconds(total)
    }

    /// 去掉 cue 文本里的标签（`<c>`、`<00:00:01.000>`、`<v 名字>`、`<b>` 等）并还原实体
    static func cleanVTTText(_ line: String) -> String {
        var s = Rx(#"<[^>]*>"#).replacing(in: line, with: "")
        let entities: [(String, String)] = [("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", ""), ("&lt;", "<"), ("&gt;", ">"),
                                            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.trimmed
    }

    /// 时间行 `00:00:01.000 --> 00:00:04.000 align:start position:0%` → (开始, 结束)
    static func vttTiming(_ line: String) -> (Int, Int)? {
        let halves = line.components(separatedBy: "-->")
        guard halves.count == 2 else { return nil }
        let endToken = halves[1].trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map { String($0) } ?? ""
        guard let start = vttTime(halves[0]), let end = vttTime(endToken) else { return nil }
        return (start, end)
    }

    /// 逐行扫描：时间行开启一条 cue，严格的空行结束它（YouTube 自动字幕的 cue 里有只含空格的行，不能当分隔）；
    /// 不在 cue 里的行（文件头、cue 标识、NOTE / STYLE / REGION 块）一律忽略
    static func vttCues(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        var timing: (Int, Int)?
        var body: [String] = []

        func finish() {
            if let t = timing {
                let lines = body.map { SubtitleConverter.cleanVTTText($0) }.filter { !$0.isEmpty }
                if !lines.isEmpty { SubtitleConverter.append(Cue(start: t.0, end: t.1, text: lines.joined(separator: "\n")), to: &cues) }
            }
            timing = nil
            body = []
        }

        for line in normalized.components(separatedBy: "\n") {
            if line.contains("-->"), let t = vttTiming(line) {
                finish()
                timing = t
            } else if line.isEmpty {
                finish()
            } else if timing != nil {
                body.append(line)
            }
        }
        finish()
        return cues
    }

    /// YouTube 自动字幕的 VTT 是「滚动」式的：每条带上一条的末行，中间夹着 10 毫秒的重复条。
    /// 时间相接（间隔 ≤100ms）时：文本与上一条完全相同 → 并入上一条（延长结束时间）；
    /// 首行等于上一条末行且不止一行 → 去掉该行
    static func append(_ cue: Cue, to cues: inout [Cue]) {
        guard var last = cues.last, cue.start - last.end <= 100, cue.start >= last.start else {
            cues.append(cue)
            return
        }
        if cue.text == last.text {
            last.end = max(last.end, cue.end)
            cues[cues.count - 1] = last
            return
        }
        var lines = cue.text.components(separatedBy: "\n")
        let lastLine = last.text.components(separatedBy: "\n").last ?? ""
        if lines.count > 1 && lines[0] == lastLine {
            lines.removeFirst()
            cues.append(Cue(start: cue.start, end: cue.end, text: lines.joined(separator: "\n")))
            return
        }
        cues.append(cue)
    }

    // MARK: B 站字幕 JSON

    /// `{"body":[{"from":1.2,"to":3.4,"content":"…"}]}`（秒）
    static func biliCues(_ json: JSON) -> [Cue] {
        var cues: [Cue] = []
        for line in json["body"].array {
            let text = line["content"].string.trimmed
            guard !text.isEmpty else { continue }
            let start = milliseconds(line["from"].double)
            let end = milliseconds(line["to"].double)
            cues.append(Cue(start: start, end: max(start, end), text: text))
        }
        return cues
    }

    // MARK: YouTube json3

    /// `{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"…"}]}]}`；
    /// 没有 segs 的是窗口定义，只有换行的是自动字幕的追加事件，都跳过
    static func json3Cues(_ json: JSON) -> [Cue] {
        let events = json["events"].array
        var cues: [Cue] = []
        for (i, e) in events.enumerated() {
            let segs = e["segs"].array
            guard !segs.isEmpty else { continue }
            let raw = segs.map { $0["utf8"].string }.joined()
            let lines = raw.components(separatedBy: "\n").map { $0.trimmed }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            let start = clampMilliseconds(e["tStartMs"].int)
            var end = start + clampMilliseconds(e["dDurationMs"].int)
            if !e.has("dDurationMs") {
                let next = i + 1 < events.count ? clampMilliseconds(events[i + 1]["tStartMs"].int) : 0
                end = next > start ? next : start + 2000
            }
            cues.append(Cue(start: start, end: end, text: lines.joined(separator: "\n")))
        }
        return cues
    }
}
