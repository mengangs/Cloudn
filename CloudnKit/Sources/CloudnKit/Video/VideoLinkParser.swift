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

        Rule(platform: .wxchannels, kind: "sph", rx: Rx(#"weixin\.qq\.com/sph/([A-Za-z0-9_]+)"#, ignoreCase: true)),
        Rule(platform: .wxchannels, kind: "sph", rx: Rx(#"channels\.weixin\.qq\.com/finder-preview/pages/sph\?[^#\s]*?\bid=([A-Za-z0-9_]+)"#, ignoreCase: true)),

        // 第二批国内平台：除微视外，分享短链都在各自解析器里展开
        Rule(platform: .ixigua, kind: "share", rx: Rx(#"v\.ixigua\.com/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .ixigua, kind: "video", rx: Rx(#"ixigua\.com/(?:video/|douyin/share/video/)?(\d{8,})"#, ignoreCase: true)),
        Rule(platform: .haokan, kind: "video", rx: Rx(#"haokan\.(?:baidu|hao123)\.com/v\?[^\s]*?\bvid=(\d+)"#, ignoreCase: true)),
        Rule(platform: .weishi, kind: "short", rx: Rx(#"video\.weishi\.qq\.com/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .weishi, kind: "feed", rx: Rx(#"weishi\.qq\.com/[^\s]*?[?&](?:id|feedid)=([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .weishi, kind: "feed", rx: Rx(#"h5\.weishi\.qq\.com/weishi/feed/([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .kge, kind: "play", rx: Rx(#"kg\d?\.qq\.com/(?:node/)?play\?[^\s]*?\bs=([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .huoshan, kind: "share", rx: Rx(#"share\.huoshan\.com/hotsoon/s/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .huoshan, kind: "item", rx: Rx(#"huoshan\.com/[^\s]*?[?&]item_id=(\d+)"#, ignoreCase: true)),
        Rule(platform: .lishipin, kind: "video", rx: Rx(#"pearvideo\.com/(?:video_|detail_)(\d+)"#, ignoreCase: true)),
        // 绿洲是 weibo.cn 的子域，要排在微博规则前面
        Rule(platform: .lvzhou, kind: "status", rx: Rx(#"oasis\.weibo\.cn/v1/h5/share\?[^\s]*?\bsid=([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .meipai, kind: "media", rx: Rx(#"meipai\.com/(?:media|video)/(\d+)"#, ignoreCase: true)),
        Rule(platform: .pipigaoxiao, kind: "post", rx: Rx(#"(?:pipigx|ippzone)\.com/pp/post/(\d+)"#, ignoreCase: true)),
        Rule(platform: .xinpianchang, kind: "video", rx: Rx(#"xinpianchang\.com/(a\d+)"#, ignoreCase: true)),
        Rule(platform: .huya, kind: "video", rx: Rx(#"huya\.com/(?:video/)?play/(\d+)\.html"#, ignoreCase: true)),
        Rule(platform: .cctv, kind: "guid", rx: Rx(#"(?:cctv|cntv)\.(?:com|cn)/video/[A-Za-z0-9]+/([\da-fA-F]{32})"#, ignoreCase: true)),
        Rule(platform: .cctv, kind: "page", rx: Rx(#"(?:cctv|cntv)\.(?:com|cn)/(?:[^\s?#]*/)?([A-Za-z0-9_\-]+)\.s?html"#, ignoreCase: true)),

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
        Rule(platform: .threads, kind: "post", rx: Rx(#"threads\.(?:com|net)/t/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),

        Rule(platform: .vimeo, kind: "video", rx: Rx(#"vimeo\.com/(?:showcase|album)/[^/\s?#]+/video/(\d+)"#, ignoreCase: true)),
        Rule(platform: .vimeo, kind: "video", rx: Rx(#"player\.vimeo\.com/video/(\d+)"#, ignoreCase: true)),
        Rule(platform: .vimeo, kind: "video", rx: Rx(#"(?<![A-Za-z0-9.\-])(?:www\.)?vimeo\.com/(?:[^\s?#]*?/)??(\d+)(?=[/?#]|$)"#, ignoreCase: true)),

        Rule(platform: .dailymotion, kind: "video", rx: Rx(#"dai\.ly/([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .dailymotion, kind: "video", rx: Rx(#"dailymotion\.[a-z]{2,3}/(?:(?:embed|crawler|swf)/)?video/([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .dailymotion, kind: "video", rx: Rx(#"dailymotion\.[a-z]{2,3}/player[^\s?]*\?[^\s]*?\bvideo=([A-Za-z0-9]+)"#, ignoreCase: true)),

        Rule(platform: .twitch, kind: "clip", rx: Rx(#"clips\.twitch\.tv/(?:embed\?[^\s]*?\bclip=)?([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .twitch, kind: "clip", rx: Rx(#"twitch\.tv/(?:[^/\s?#]+/)?clip/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .twitch, kind: "vod", rx: Rx(#"twitch\.tv/(?:videos|[^/\s?#]+/v(?:ideo)?)/(\d+)"#, ignoreCase: true)),
        Rule(platform: .twitch, kind: "vod", rx: Rx(#"player\.twitch\.tv/\?[^\s]*?\bvideo=v?(\d+)"#, ignoreCase: true)),
        // 直播 / 频道页：解析器给出「暂不支持直播」的提示
        Rule(platform: .twitch, kind: "channel", rx: Rx(#"(?<![A-Za-z0-9.\-])(?:www\.|m\.|go\.)?twitch\.tv/([A-Za-z0-9_]+)"#, ignoreCase: true)),

        Rule(platform: .soundcloud, kind: "short", rx: Rx(#"on\.soundcloud\.com/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .soundcloud, kind: "api", rx: Rx(#"api(?:-v2)?\.soundcloud\.com/tracks/(?:soundcloud%3Atracks%3A)?(\d+)"#, ignoreCase: true)),
        // 歌单：解析器给出「暂不支持歌单 / 专辑」
        Rule(platform: .soundcloud, kind: "set", rx: Rx(#"(?<![A-Za-z0-9.\-])(?:www\.|m\.)?soundcloud\.com/([\w\-]+/sets/[\w\-]+)"#, ignoreCase: true)),
        Rule(platform: .soundcloud, kind: "track", rx: Rx(#"(?<![A-Za-z0-9.\-])(?:www\.|m\.)?soundcloud\.com/((?!(?:stations|discover|search|you|upload|charts|pages|terms-of-use|messages|notifications|settings|people|tags|popular)/)[\w\-]+/(?!(?:tracks|albums|sets|reposts|likes|spotlight|comments|popular-tracks|followers|following)(?:[/?#]|$))[\w\-]+(?:/s-[A-Za-z0-9]+)?)"#, ignoreCase: true)),

        Rule(platform: .medium, kind: "short", rx: Rx(#"link\.medium\.com/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .medium, kind: "post", rx: Rx(#"(?<![A-Za-z0-9.\-])(?:[\w\-]+\.)?medium\.com/(?:[^\s?#]+/)?(?:[^/\s?#]*-)?([0-9a-f]{8,12})(?=[/?#]|$)"#, ignoreCase: true)),

        Rule(platform: .bangumi, kind: "subject", rx: Rx(#"(?:bgm\.tv|bangumi\.tv|chii\.in)/(?:subject/topic|rakuen/topic/subject)/(\d+)"#, ignoreCase: true)),
        Rule(platform: .bangumi, kind: "group", rx: Rx(#"(?:bgm\.tv|bangumi\.tv|chii\.in)/(?:group/topic|rakuen/topic/group)/(\d+)"#, ignoreCase: true)),
        Rule(platform: .bangumi, kind: "blog", rx: Rx(#"(?:bgm\.tv|bangumi\.tv|chii\.in)/blog/(\d+)"#, ignoreCase: true)),

        // 以下海外平台的分享短链在各自解析器里逐跳展开（中间会经过规则认不出的地址）
        Rule(platform: .reddit, kind: "share", rx: Rx(#"reddit\.com/r/[^/\s]+/s/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .reddit, kind: "share", rx: Rx(#"(?<![A-Za-z0-9.\-])v\.redd\.it/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .reddit, kind: "post", rx: Rx(#"reddit(?:media)?\.com/(?:(?:r|u|user)/[^/\s?#]+/)?comments/([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .reddit, kind: "post", rx: Rx(#"(?<![A-Za-z0-9.\-])redd\.it/([A-Za-z0-9]+)"#, ignoreCase: true)),

        Rule(platform: .pinterest, kind: "share", rx: Rx(#"(?<![A-Za-z0-9.\-])pin\.it/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .pinterest, kind: "pin", rx: Rx(#"pinterest\.[a-z.]+/pin/(?:[\w\-]+--)?(\d+)"#, ignoreCase: true)),

        Rule(platform: .tumblr, kind: "share", rx: Rx(#"(?<![A-Za-z0-9.\-])tmblr\.co/[A-Za-z0-9_\-]+"#, ignoreCase: true)),
        Rule(platform: .tumblr, kind: "post", rx: Rx(#"[A-Za-z0-9\-]+\.tumblr\.com/(?:post|image|video/[A-Za-z0-9\-]+)/(\d+)"#, ignoreCase: true)),
        Rule(platform: .tumblr, kind: "post", rx: Rx(#"(?<![A-Za-z0-9.\-])(?:www\.)?tumblr\.com/(?:blog/view/)?[A-Za-z0-9\-]+/(\d+)"#, ignoreCase: true)),

        Rule(platform: .imgur, kind: "album", rx: Rx(#"imgur\.com/a/(?:[^/?#\s]+-)?([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .imgur, kind: "gallery", rx: Rx(#"imgur\.com/(?:gallery|t/[^/?#\s]+|topic/[^/?#\s]+|r/[^/?#\s]+)/(?:[^/?#\s]+-)?([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .imgur, kind: "media", rx: Rx(#"(?<![A-Za-z0-9\-])(?:i\.|m\.|www\.)?imgur\.com/(?!(?:a|gallery|t|topic|r|user|upload|signin|register)/)(?:[^/?#\s]+-)?([A-Za-z0-9]{5,})"#, ignoreCase: true)),

        Rule(platform: .bluesky, kind: "post", rx: Rx(#"bsky\.app/profile/[^/\s?#]+/post/([A-Za-z0-9]+)"#, ignoreCase: true)),

        Rule(platform: .snapchat, kind: "share", rx: Rx(#"(?<![A-Za-z0-9.\-])t\.snapchat\.com/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .snapchat, kind: "share", rx: Rx(#"snapchat\.com/t/[A-Za-z0-9]+"#, ignoreCase: true)),
        Rule(platform: .snapchat, kind: "spotlight", rx: Rx(#"snapchat\.com/(?:@[\w.\-]+/)?spotlight/([\w\-]+)"#, ignoreCase: true)),

        // 播放列表排在视频规则前；watch?v=…&list=… 仍按单个视频解析
        Rule(platform: .youtube, kind: "playlist", rx: Rx(#"(?<![A-Za-z0-9\-])(?:(?:www|m|music)\.)?youtube\.com/playlist/?\?(?:[^\s#]*?&)?list=([0-9A-Za-z_\-]+)"#, ignoreCase: true)),
        Rule(platform: .youtube, kind: "video", rx: Rx(#"(?<![A-Za-z0-9\-])youtu\.be/([0-9A-Za-z_\-]{11})(?![0-9A-Za-z_\-])"#, ignoreCase: true)),
        Rule(platform: .youtube, kind: "video", rx: Rx(#"(?<![A-Za-z0-9\-])(?:(?:www|m|music)\.)?youtube(?:-nocookie)?\.com/(?:shorts|live|embed|v|e)/([0-9A-Za-z_\-]{11})(?![0-9A-Za-z_\-])"#, ignoreCase: true)),
        Rule(platform: .youtube, kind: "video", rx: Rx(#"(?<![A-Za-z0-9\-])(?:(?:www|m|music)\.)?youtube\.com/watch/?\?(?:[^\s#]*?&)?v=([0-9A-Za-z_\-]{11})(?![0-9A-Za-z_\-])"#, ignoreCase: true)),

        // 与 FacebookParser.linkRules 保持一致（解析器展开分享链接后用它重新识别）
        Rule(platform: .facebook, kind: "share", rx: Rx(#"(?<![A-Za-z0-9.\-])fb\.watch/([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .facebook, kind: "share", rx: Rx(#"facebook\.com/share/(?:[vrp]/)?([A-Za-z0-9_\-]+)"#, ignoreCase: true)),
        Rule(platform: .facebook, kind: "video", rx: Rx(#"facebook\.com/(?:[^\s?#]*/)?reel/(\d+)"#, ignoreCase: true)),
        Rule(platform: .facebook, kind: "video", rx: Rx(#"facebook\.com/(?:watch(?:/live)?/?|video\.php|video/video\.php|video/embed)\?(?:[^\s#]*?&)?(?:v|video_id)=(\d+)"#, ignoreCase: true)),
        Rule(platform: .facebook, kind: "video", rx: Rx(#"facebook\.com/[^/\s?#]+/videos/(?:[^/\s?#]+/)?(\d+)"#, ignoreCase: true)),
        Rule(platform: .facebook, kind: "photo", rx: Rx(#"facebook\.com/photo(?:\.php)?/?\?(?:[^\s#]*?&)?fbid=(\d+)"#, ignoreCase: true)),
        Rule(platform: .facebook, kind: "photo", rx: Rx(#"facebook\.com/[^/\s?#]+/photos/(?:[^/\s?#]+/)?(\d+)"#, ignoreCase: true)),
        Rule(platform: .facebook, kind: "post", rx: Rx(#"facebook\.com/(?:[^/\s?#]+/posts/|groups/[^/\s?#]+/(?:permalink|posts)/|(?:permalink|story)\.php\?(?:[^\s#]*?&)?story_fbid=)(pfbid[A-Za-z0-9]+|\d+)"#, ignoreCase: true)),

        Rule(platform: .xiaoheihe, kind: "link", rx: Rx(#"xiaoheihe\.cn/(?:v3/)?bbs/app/(?:api/web/share|link)\?[^\s]*?\blink_id=([A-Za-z0-9]+)"#, ignoreCase: true)),
        Rule(platform: .xiaoheihe, kind: "link", rx: Rx(#"xiaoheihe\.cn/(?:app/)?bbs/link/([A-Za-z0-9]+)"#, ignoreCase: true))
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
