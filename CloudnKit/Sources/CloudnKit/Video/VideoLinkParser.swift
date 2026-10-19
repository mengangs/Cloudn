// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 识别规则参考 YunX（AGPL-3.0）的 VideoLinkParser。
import Foundation

public enum VideoLinkParser {
    private struct Rule {
        let platform: VideoPlatform
        let kind: String
        let rx: Rx
    }

    /// 顺序即优先级：短链优先
    private static let rules: [Rule] = [
        Rule(platform: .douyin, kind: "short", rx: Rx(#"v\.douyin\.com/[A-Za-z0-9_\-]+"#, ignoreCase: true)),
        Rule(platform: .douyin, kind: "short", rx: Rx(#"jx\.douyin\.com/[A-Za-z0-9_\-]+"#, ignoreCase: true)),
        Rule(platform: .douyin, kind: "video", rx: Rx(#"(?:www\.)?douyin\.com/(?:video|note)/(\d{10,})"#, ignoreCase: true)),
        Rule(platform: .douyin, kind: "video", rx: Rx(#"iesdouyin\.com/share/(?:slides|video|note)/(\d{10,})"#, ignoreCase: true)),
        Rule(platform: .douyin, kind: "video", rx: Rx(#"m\.douyin\.com/share/(?:slides|video|note)/(\d{10,})"#, ignoreCase: true)),
        Rule(platform: .douyin, kind: "video", rx: Rx(#"jingxuan\.douyin\.com/m/(?:slides|video|note)/(\d{10,})"#, ignoreCase: true)),
        Rule(platform: .douyin, kind: "video", rx: Rx(#"douyin\.com/.*[?&]modal_id=(\d{10,})"#, ignoreCase: true)),

        Rule(platform: .xiaohongshu, kind: "short", rx: Rx(#"xhslink\.(?:com|cn)/[A-Za-z0-9._?%&+=/#@\-]+"#, ignoreCase: true)),
        Rule(platform: .xiaohongshu, kind: "note", rx: Rx(#"xiaohongshu\.com/(?:explore|discovery/item)/([0-9a-zA-Z]{10,})"#, ignoreCase: true)),

        Rule(platform: .kuaishou, kind: "short", rx: Rx(#"v\.kuaishou\.com/[A-Za-z\d._?%&+\-=/#]+"#, ignoreCase: true)),
        Rule(platform: .kuaishou, kind: "photo", rx: Rx(#"(?:www\.)?kuaishou\.com/(?:short-video|fw/photo|fw/long-video)/([A-Za-z\d]+)"#, ignoreCase: true)),
        Rule(platform: .kuaishou, kind: "photo", rx: Rx(#"(?:www\.)?kuaishou\.com/f/([A-Za-z\d]+)"#, ignoreCase: true)),
        Rule(platform: .kuaishou, kind: "photo", rx: Rx(#"(?:v\.m\.)?chenzhongtech\.com/fw/(?:photo|long-video)/([A-Za-z\d]+)"#, ignoreCase: true)),

        Rule(platform: .weibo, kind: "tv", rx: Rx(#"weibo\.com/tv/show/\d{4}:\d+\?mid=(\d+)"#, ignoreCase: true)),
        Rule(platform: .weibo, kind: "fid", rx: Rx(#"video\.weibo\.com/show\?fid=(\d+:\d+)"#, ignoreCase: true)),
        Rule(platform: .weibo, kind: "fid", rx: Rx(#"weibo\.com/tv/show/(\d{4}:\d+)"#, ignoreCase: true)),
        Rule(platform: .weibo, kind: "status", rx: Rx(#"weibo\.cn/(?:status|statuses|detail)/([0-9a-zA-Z]+)"#, ignoreCase: true)),
        Rule(platform: .weibo, kind: "status", rx: Rx(#"weibo\.com/\d+/([0-9a-zA-Z]{6,})"#, ignoreCase: true)),

        Rule(platform: .acfun, kind: "ac", rx: Rx(#"acfun\.cn/.*(?:ac=|/ac)(\d+)"#, ignoreCase: true)),

        Rule(platform: .bilibili, kind: "short", rx: Rx(#"b23\.tv/[A-Za-z\d]+"#, ignoreCase: true)),
        Rule(platform: .bilibili, kind: "short", rx: Rx(#"bili2233\.cn/[A-Za-z\d]+"#, ignoreCase: true)),
        Rule(platform: .bilibili, kind: "video", rx: Rx(#"bilibili\.com/video/(BV[0-9a-zA-Z]{10}|av\d+)"#, ignoreCase: true))
    ]

    /// 只在链接上匹配（不看文案：抖音/快手文案里常带一堆数字，整段匹配必然误判）
    public static func parse(_ text: String) -> DetectedVideoLink? {
        guard let url = ShareLinkParser.firstURL(in: text) else { return nil }
        for rule in rules {
            guard let m = rule.rx.firstMatch(in: url) else { continue }
            let short = rule.kind == "short"
            let id = m.dropFirst().last(where: { !$0.isEmpty }) ?? ""
            // 短链直接用规则匹配到的部分：分享文案里链接后常紧跟中文（「…/AbCd，复制本条信息」），整段当 URL 会展开失败
            return DetectedVideoLink(platform: rule.platform, kind: rule.kind, id: short ? "" : id, url: short ? "https://" + m[0] : url)
        }
        return nil
    }
}

/// 用户输入的统一分流：视频 → 网盘 → 普通直链
public enum DetectedInput: Sendable, Equatable {
    case share(ParsedShare)
    case video(DetectedVideoLink)
    case direct(String)

    public static func detect(_ text: String) -> DetectedInput? {
        if let v = VideoLinkParser.parse(text) { return .video(v) }
        if let s = ShareLinkParser.parse(text) { return .share(s) }
        if let url = ShareLinkParser.firstURL(in: text), let u = URL(string: url), u.host != nil {
            return .direct(url)
        }
        return nil
    }
}
