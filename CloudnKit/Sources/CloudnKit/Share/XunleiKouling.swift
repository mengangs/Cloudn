// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 XunleiKouling / XunleiApi.parseKouling。
import Foundation

/// 迅雷中文口令（如「张三丰资源」）→ 带提取码的分享链接。
///
/// 口令是「分享链接 + 提取码」的打包形式：把口令当关键词请求迅雷搜索的跳转接口，
/// `ext.kouling_type == "share_page"` 时 `location` 就是带 pwd 的分享页地址（明文）；
/// 口令没有对应资源时只返回搜索页地址。免登录。
public enum XunleiKouling {
    static let jumpAPI = "https://api-shoulei-ssl.xunlei.com/xlppc.searcher.api/jump"
    /// 需要迅雷客户端标识的 UA，普通浏览器 UA 会被导向搜索页而不是分享页
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/108.0.5359.215 Safari/537.36 TBC/1.3.3.999 Thunder/12.4.4.3740"
    static let origin = "https://sl-m-ssl.xunlei.com"
    static let maxLength = 64
    /// 口令两侧常见的装饰符号
    static let decorations = Set("「」『』【】《》〈〉“”‘’\"'`()（）[]{}<>.,，。;；:：!！?？、| \t\n\r")
    static let shareRx = Rx(#"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, ignoreCase: true)
    static let pwdRx = Rx(#"[?&]pwd=([A-Za-z0-9]+)"#)

    /// 去掉两侧空白与装饰符号
    public static func normalize(_ text: String) -> String {
        var s = Substring(text)
        while let c = s.first, decorations.contains(c) { s.removeFirst() }
        while let c = s.last, decorations.contains(c) { s.removeLast() }
        return String(s)
    }

    /// 是否值得按口令去解析：非空、不太长、只含字母 / 数字且至少有一个汉字。
    /// 带空格或标点的多半是整段文案，纯英文 / 数字也不是中文口令。调用方需先确认它不是链接。
    public static func looksLikeKouling(_ text: String) -> Bool {
        let t = normalize(text)
        guard !t.isEmpty, t.count <= maxLength, t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    /// 口令按 UTF-8 百分号编码（只保留 ASCII 字母数字，CharacterSet.alphanumerics 会把汉字当成合法字符）
    static func jumpURL(_ keyword: String) -> String {
        let ascii = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let wd = keyword.addingPercentEncoding(withAllowedCharacters: ascii) ?? keyword
        return "\(jumpAPI)?noredirect=1&t=20&wd=\(wd)&tn=15007414_5_dg&src=lm&ls=sm3016480&lm_extend=ctype:31"
    }

    /// 从 location 取干净的分享链接，丢掉渠道参数；不是迅雷分享页返回 nil
    public static func shareURL(fromLocation location: String) -> String? {
        guard let id = shareRx.first(in: location), !id.isEmpty else { return nil }
        if let pwd = pwdRx.first(in: location), !pwd.isEmpty { return "https://pan.xunlei.com/s/\(id)?pwd=\(pwd)" }
        return "https://pan.xunlei.com/s/\(id)"
    }

    /// 口令 → 分享链接
    public static func resolve(_ text: String, client: HTTPClient = .shared) async throws -> String {
        let keyword = normalize(text)
        let r = try await client.send(.get(jumpURL(keyword), headers: [
            ("User-Agent", userAgent), ("Accept", "*/*"), ("Origin", origin), ("Referer", origin + "/"), ("Accept-Language", "zh-CN")
        ]))
        guard r.isSuccess else { throw CloudnError("口令解析失败（HTTP \(r.status)）") }
        guard let json = r.json, json.isObject else { throw CloudnError("口令解析失败：响应格式异常") }
        guard json["ext"]["kouling_type"].string == "share_page", let url = shareURL(fromLocation: json["location"].string) else {
            throw CloudnError("口令「\(keyword)」没有对应的迅雷分享")
        }
        return url
    }
}
