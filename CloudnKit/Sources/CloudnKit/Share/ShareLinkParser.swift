// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 识别规则参考 YunX（AGPL-3.0）的 ShareLinkParser。
import Foundation

/// 从分享链接或整段分享文案中提取分享 id、提取码与平台。
public enum ShareLinkParser {
    static let urlRx = Rx(#"https?://[^\s]+"#)
    static let trailing = "。，,；;)]}\"'、！？…）】"

    private static let quark = Rx(#"pan\.quark\.cn/s/([A-Za-z0-9]+)"#, ignoreCase: true)
    private static let uc = Rx(#"drive\.uc\.cn/s/([A-Za-z0-9]+)"#, ignoreCase: true)
    private static let xunlei = Rx(#"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, ignoreCase: true)
    private static let baidu = Rx(#"pan\.baidu\.com/s/(1[A-Za-z0-9_-]+)"#, ignoreCase: true)
    private static let c139 = Rx(#"yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"#, ignoreCase: true)
    private static let pan123 = Rx(#"123(?:865|pan|684|912)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"#, ignoreCase: true)
    private static let pan123Sub = Rx(#"share\.123pan\.cn/123pan/([A-Za-z0-9-]+)"#, ignoreCase: true)
    private static let pan123Srr = Rx(#"api/srr\?sk=([A-Za-z0-9-]+)"#, ignoreCase: true)
    private static let pan115 = Rx(#"115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)"#, ignoreCase: true)
    private static let pan115Command = Rx(#"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#, ignoreCase: true)
    private static let guangya = Rx(#"guangyapan\.com/s/([A-Za-z0-9_-]+)"#, ignoreCase: true)
    /// 优享版要先于蓝奏云判断：www.ilanzou.com 里也含 lanzou.com
    private static let ilanzou = Rx(#"(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"#, ignoreCase: true)
    private static let lanzou = Rx(#"(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux])\.(?:com|net|org|cn)/(?:[A-Za-z0-9_-]+/)?([A-Za-z0-9]+)"#, ignoreCase: true)

    private static let aliyun = Rx(#"(?:alipan|aliyundrive)\.com/s/([A-Za-z0-9]+)"#, ignoreCase: true)
    private static let onedrive = Rx(#"^https?://(?:1drv\.ms/|onedrive\.live\.com/|[A-Za-z0-9-]+\.sharepoint\.com/:[a-z]:/)"#, ignoreCase: true)

    private static let pwdInURL = Rx(#"[?&]pwd=([A-Za-z0-9]+)"#)
    private static let pwdIn115URL = Rx(#"[?&]password=([A-Za-z0-9]+)"#)
    private static let pwdInLanzouURL = Rx(#"[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"#, ignoreCase: true)
    private static let pwdInText = Rx(#"(?:提取码|访问码|密码|pwd)\s*[：:]\s*([A-Za-z0-9]{3,8})"#, ignoreCase: true)

    /// 从文本中取第一条 http(s) 链接（去掉尾随标点）
    public static func firstURL(in text: String) -> String? {
        urlRx.first(in: text.trimmed, group: 0)?.trimmingTrailing(trailing)
    }

    /// 文字里写的提取码（「提取码：abcd」），不看链接参数
    public static func textPassword(in text: String) -> String? { pwdInText.first(in: text) }

    public static func parse(_ text: String) -> ParsedShare? {
        guard let url = firstURL(in: text) else { return nil }
        let textPwd = pwdInText.first(in: text)

        func make(_ id: String, _ platform: SharePlatform, pwdRx: Rx = pwdInURL) -> ParsedShare {
            ParsedShare(shareId: id, pwd: pwdRx.first(in: url) ?? textPwd, platform: platform, url: url)
        }

        if let id = quark.first(in: url) { return make(id, .quark) }
        if let id = uc.first(in: url) { return make(id, .uc) }
        if let id = xunlei.first(in: url) { return make(id, .xunlei) }
        // 百度 surl 去掉开头的 "1"（verify/list 接口用 1 之后的部分）
        if let id = baidu.first(in: url) { return make(String(id.dropFirst()), .baidu) }
        if let id = c139.first(in: url) { return make(id, .c139) }
        if let id = pan123.first(in: url) ?? pan123Sub.first(in: url) ?? pan123Srr.first(in: url) { return make(id, .pan123) }
        if let id = pan115.first(in: url) { return make(id, .pan115, pwdRx: pwdIn115URL) }
        if let m = pan115Command.firstMatch(in: url) {
            return ParsedShare(shareId: m[1], pwd: m[2], platform: .pan115, url: url)
        }
        if let id = guangya.first(in: url) { return make(id, .guangya) }
        if let id = ilanzou.first(in: url) { return make(id, .ilanzou, pwdRx: pwdInLanzouURL) }
        if let id = lanzou.first(in: url) { return make(id, .lanzou, pwdRx: pwdInLanzouURL) }
        if let id = aliyun.first(in: url) { return make(id, .aliyun) }
        if let target = GoogleDriveResolver.target(of: url) { return ParsedShare(shareId: target.id, pwd: nil, platform: .gdrive, url: url) }
        // OneDrive 的分享 id 就是链接本身（接口用 base64 编码后的完整链接）
        if onedrive.matches(url) { return ParsedShare(shareId: url, pwd: textPwd, platform: .onedrive, url: url) }
        // 新平台的识别规则写在各自的解析器里：返回分享 id 与链接里自带的提取码
        let others: [(SharePlatform, (String) -> (id: String, pwd: String?)?)] = [
            (.pikpak, PikPakResolver.shareTarget), (.cloud189, Cloud189Resolver.shareTarget), (.dropbox, DropboxResolver.shareTarget),
            (.ctfile, CtFileResolver.shareTarget),
        ]
        for (platform, target) in others {
            if let t = target(url) { return ParsedShare(shareId: t.id, pwd: t.pwd ?? textPwd, platform: platform, url: url) }
        }
        return nil
    }
}
