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
        Rule(platform: .bilibili, kind: "video", rx: Rx(#"bilibili\.com/video/(BV[0-9a-zA-Z]{10}|av\d+)"#, ignoreCase: true)),
        Rule(platform: .bilibili, kind: "dynamic", rx: Rx(#"t\.bilibili\.com/(?:h5/dynamic/detail/)?(\d{10,20})"#, ignoreCase: true)),
        Rule(platform: .bilibili, kind: "dynamic", rx: Rx(#"bilibili\.com/opus/(\d{10,20})"#, ignoreCase: true)),
        Rule(platform: .bilibili, kind: "dynamic", rx: Rx(#"m\.bilibili\.com/dynamic/(\d{10,20})"#, ignoreCase: true)),

        // 先认回答再认问题：回答链接里也带 /question/
        Rule(platform: .zhihu, kind: "answer", rx: Rx(#"zhihu\.com/question/\d+/answer/(\d+)"#, ignoreCase: true)),
        Rule(platform: .zhihu, kind: "answer", rx: Rx(#"zhihu\.com/answer/(\d+)"#, ignoreCase: true)),
        Rule(platform: .zhihu, kind: "question", rx: Rx(#"zhihu\.com/question/(\d+)"#, ignoreCase: true)),
        Rule(platform: .zhihu, kind: "article", rx: Rx(#"zhuanlan\.zhihu\.com/p/(\d+)"#, ignoreCase: true)),
        Rule(platform: .zhihu, kind: "pin", rx: Rx(#"zhihu\.com/pin/(\d+)"#, ignoreCase: true)),
        Rule(platform: .zhihu, kind: "story", rx: Rx(#"daily\.zhihu\.com/story/(\d+)"#, ignoreCase: true)),

        Rule(platform: .pixiv, kind: "artwork", rx: Rx(#"pixiv\.net/(?:[a-z]{2}/)?artworks/(\d+)"#, ignoreCase: true)),
        Rule(platform: .pixiv, kind: "artwork", rx: Rx(#"pixiv\.net/member_illust\.php\?[^\s]*illust_id=(\d+)"#, ignoreCase: true)),

        // 以下国内平台的分享短链在各自解析器里展开，不走统一的短链流程
        Rule(platform: .toutiao, kind: "share", rx: Rx(#"toutiao\.com/is/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .toutiao, kind: "item", rx: Rx(#"toutiao\.com/(?:(?:article|video|w|group|item)/|a|i)(\d+)"#, ignoreCase: true)),

        Rule(platform: .tieba, kind: "post", rx: Rx(#"tieba\.baidu\.com/p/(\d+)"#, ignoreCase: true)),

        Rule(platform: .weixin, kind: "article", rx: Rx(#"mp\.weixin\.qq\.com/s/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .weixin, kind: "params", rx: Rx(#"mp\.weixin\.qq\.com/s\?[^\s]*?__biz=([^&\s#]+)"#, ignoreCase: true)),

        Rule(platform: .douban, kind: "topic", rx: Rx(#"douban\.com/(?:group/)?topic/(\d+)"#, ignoreCase: true)),
        Rule(platform: .douban, kind: "topic", rx: Rx(#"douban\.com/doubanapp/dispatch\?[^\s]*?uri=(?:/|%2F)?(?:group(?:/|%2F))?topic(?:/|%2F)(\d+)"#, ignoreCase: true)),
        Rule(platform: .douban, kind: "share", rx: Rx(#"douban\.com/doubanapp/dispatch"#, ignoreCase: true)),
        Rule(platform: .douban, kind: "share", rx: Rx(#"douc\.cc/([A-Za-z0-9]+)"#, ignoreCase: true)),

        Rule(platform: .coolapk, kind: "feed", rx: Rx(#"coolapk(?:1s)?\.com/feed/(\d+)"#, ignoreCase: true)),
        Rule(platform: .coolapk, kind: "picture", rx: Rx(#"coolapk(?:1s)?\.com/picture/(\d+)"#, ignoreCase: true)),

        Rule(platform: .pipix, kind: "share", rx: Rx(#"h5\.pipix\.com/s/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .pipix, kind: "item", rx: Rx(#"h5\.pipix\.com/(?:ppx/)?item/(\d+)"#, ignoreCase: true)),

        Rule(platform: .zuiyou, kind: "post", rx: Rx(#"(?:share\.xiaochuankeji\.cn|share\.izuiyou\.com)/hybrid/share/post\?[^\s]*?\bpid=(\d+)"#, ignoreCase: true)),

        Rule(platform: .twitter, kind: "short", rx: Rx(#"(?<![A-Za-z0-9.\-])t\.co/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .twitter, kind: "status", rx: Rx(#"(?<![A-Za-z0-9\-])(?:www\.|mobile\.)?(?:twitter|x|fixupx|fxtwitter|vxtwitter|fixvx)\.com/(?:i/web/|[A-Za-z0-9_]+/)status(?:es)?/(\d+)"#, ignoreCase: true)),

        Rule(platform: .tiktok, kind: "short", rx: Rx(#"(?:vt|vm)\.tiktok\.com/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .tiktok, kind: "short", rx: Rx(#"tiktok\.com/t/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .tiktok, kind: "video", rx: Rx(#"tiktok\.com/@[^/\s?]*/(?:video|photo)/(\d+)"#, ignoreCase: true)),
        Rule(platform: .tiktok, kind: "video", rx: Rx(#"tiktok\.com/(?:v|embed(?:/v2)?)/(\d+)"#, ignoreCase: true)),

        // share 短链要排在作品规则前面，否则 share/reel/X 会被当成作品
        Rule(platform: .instagram, kind: "short", rx: Rx(#"instagram\.com/share/(?:reel/|p/)?[A-Za-z0-9_\-]+"#, ignoreCase: true)),
        Rule(platform: .instagram, kind: "post", rx: Rx(#"(?:instagram\.com|instagr\.am)/(?:[A-Za-z0-9_.]+/)?(?:p|reels?|tv)/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),

        Rule(platform: .threads, kind: "short", rx: Rx(#"threads\.(?:com|net)/share/[A-Za-z0-9_\-/]+"#, ignoreCase: true)),
        Rule(platform: .threads, kind: "post", rx: Rx(#"threads\.(?:com|net)/@[\w.]+/post/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .threads, kind: "post", rx: Rx(#"threads\.(?:com|net)/t/([A-Za-z0-9_\-]+)"#, ignoreCase: true))
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
    case github(GitHubLink)
    case direct(String)
    /// 磁力链接（或单独的 40 位特征码）
    case magnet(MagnetLink)

    public static func detect(_ text: String) -> DetectedInput? {
        if let m = MagnetLink.find(in: text) { return .magnet(m) }
        if let v = VideoLinkParser.parse(text) { return .video(v) }
        if let s = ShareLinkParser.parse(text) { return .share(s) }
        if let g = GitHubLink.parse(text) { return .github(g) }
        if let url = ShareLinkParser.firstURL(in: text), let u = URL(string: url), u.host != nil {
            return .direct(url)
        }
        return nil
    }
}
