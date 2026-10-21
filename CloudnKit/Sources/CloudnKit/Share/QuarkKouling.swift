// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 参考 YunX（AGPL-3.0）的 StarSeaApi / StarSeaConstants。
import Foundation

/// 夸克 / UC 中文口令（如「绝对有效 咐置松君杂货铺叩苓」）→ 分享链接。
///
/// 夸克 / UC 口令由官方服务签发、只有夸克 / UC App 自己能还原，没有公开接口，本地也解不出来。
/// 这里问一次第三方「星海」口令解析服务拿分享 ID（pwdId），再合成 `pan.quark.cn/s/<pwdId>` /
/// `drive.uc.cn/s/<pwdId>`，之后提取码、登录态、列目录、取链全部走本地既有的夸克 / UC 流程。
///
/// ★ 只用 `step=parse`：只拿 pwdId，不索取 stoken、不发送任何账号凭据。
/// ★ 隐私：口令原文会发往第三方（不是夸克 / UC 自己的服务器），调用方必须先征得用户同意；
///   这里也刻意不记录口令内容。
///
/// 和迅雷口令从文字上分不开（都是一串中文），建议顺序：
/// 文字里带夸克 / UC 标记（`mentionsQuarkOrUC`）的直接问这里；
/// 否则能按迅雷口令处理的（`XunleiKouling.looksLikeKouling`）先问迅雷（平台自己的接口、免授权），
/// 迅雷没有对应分享、或带空格标点不像迅雷口令的，再经用户同意问这里。
public enum QuarkKouling {
    /// 第三方服务名，给 UI 的同意提示用
    public static let serviceName = "星海"
    static let resolveURL = "https://starsea-api.qwq.pics/api/resolve"
    /// 服务端按 IP 限流（60 次 / 分钟）；仓库开源、Key 本就公开，服务端轮换后同步改这里
    static let apiKey = "8bfbe163c670ae500aca5f3b2f060ecc8463e1eb1691ba8d"
    /// 口令都很短，超过这个长度多半是整段文案，不该发给第三方
    static let maxLength = 120
    /// 失败要快：UI 可能还要回退去问迅雷
    static let timeout: TimeInterval = 15
    /// 整段被成对符号包起来时去掉外层
    static let wrappers: [(Character, Character)] = [("「", "」"), ("『", "』"), ("【", "】"), ("“", "”"), ("\"", "\""), ("《", "》")]
    /// 夸克 / UC 口令里常见的标记：引导文案里的 App 名、`/~xxxx~:/` 形式的口令码
    static let markerRx = Rx(#"夸克|UC\s*(?:浏览器|网盘|APP)|/~[A-Za-z0-9]+~:/"#, ignoreCase: true)
    /// pwdId 只接受字母数字：服务端返回的是外部数据，合成链接前要校验（也保证 ShareLinkParser 能认出来）
    static let pwdIdRx = Rx(#"^[A-Za-z0-9]{4,64}$"#)

    /// 文本像夸克 / UC 口令时返回去掉两侧空白与外层括号后的口令，否则 nil。
    ///
    /// 判定：非空、不超过 `maxLength`、本身不含链接（含链接说明本地识别没认出来，问了也没用），
    /// 且至少有一个汉字或带夸克 / UC 标记（纯英文数字的随手输入不该发给第三方）。
    /// 口令里的「打开夸克APP…」之类引导文案**不去掉**：服务端靠这些标记词判断是夸克还是 UC。
    /// 调用方需先确认 `DetectedInput.detect` 没认出链接。
    public static func extract(_ text: String) -> String? {
        var t = text.trimmed
        for (open, close) in wrappers where t.count >= 2 && t.first == open && t.last == close {
            let inner = String(t.dropFirst().dropLast())
            // 只在外层这一对确实是整体包裹时才去（内部不再出现同种括号）
            if !inner.contains(open) && !inner.contains(close) { t = inner.trimmed }
            break
        }
        guard !t.isEmpty, t.count <= maxLength else { return nil }
        let lower = t.lowercased()
        guard !lower.contains("http://"), !lower.contains("https://") else { return nil }
        let hasHan = t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        guard hasHan || mentionsQuarkOrUC(t) else { return nil }
        return t
    }

    /// 文字里有夸克 / UC 的标记（App 名或 `/~xxxx~:/` 口令码）：可以跳过迅雷直接问这里
    public static func mentionsQuarkOrUC(_ text: String) -> Bool {
        markerRx.first(in: text, group: 0) != nil
    }

    /// 平台标记 + 分享 ID → 分享链接（未知平台按夸克兜底）
    public static func shareURL(platform: String, pwdId: String) -> String {
        platform.lowercased() == "uc" ? "https://drive.uc.cn/s/\(pwdId)" : "https://pan.quark.cn/s/\(pwdId)"
    }

    /// 解析请求：`platform=auto` 让服务端按机器码 / 标记词判定夸克还是 UC
    static func request(for kouling: String) -> HTTPRequest {
        let body = OrderedJSON.object([("clipboard", .string(kouling)), ("platform", .string("auto")), ("step", .string("parse"))])
        return HTTPRequest(url: resolveURL, method: "POST", headers: [
            ("X-API-Key", apiKey), ("Accept", "application/json"), ("Content-Type", "application/json")
        ], body: Data(body.text.utf8), timeout: timeout)
    }

    /// 解析响应 → 分享链接。业务失败与 HTTP 状态码分离：非 2xx 也可能带着可读的原因，所以先看 body
    static func shareURL(status: Int, body: Data) throws -> String {
        let json = JSON(data: body) ?? JSON(nil)
        guard json["success"].bool else {
            throw CloudnError(failureMessage(status: status, server: json["msg"].string))
        }
        let data = json["data"]
        guard data.isObject else { throw CloudnError("口令解析失败：响应缺少 data") }
        let pwdId = data["pwdId"].string.trimmed
        guard !pwdId.isEmpty else { throw CloudnError("口令解析失败：未取到分享 ID") }
        guard pwdIdRx.first(in: pwdId, group: 0) != nil else { throw CloudnError("口令解析失败：分享 ID 格式异常") }
        return shareURL(platform: data["platform"].string, pwdId: pwdId)
    }

    static func failureMessage(status: Int, server: String) -> String {
        if !server.trimmed.isEmpty { return server.trimmed }
        switch status {
        case 400: return "口令为空或格式不对"
        case 401, 403: return "口令解析服务鉴权失败，请更新应用"
        case 404: return "口令解析服务暂不可用"
        case 413: return "口令过长"
        case 429: return "口令解析服务繁忙，请稍后再试"
        case 200..<300: return "无法识别该口令"
        default: return "口令解析失败（HTTP \(status)）"
        }
    }

    /// 口令 → 分享链接（夸克 `pan.quark.cn` / UC `drive.uc.cn`，不含提取码，提取码仍走分享页输入）。
    /// 失败时抛 `CloudnError`，信息可直接展示。**会把口令原文发给第三方，调用前先征得用户同意。**
    public static func resolve(_ kouling: String, client: HTTPClient = .shared) async throws -> String {
        guard let text = extract(kouling) else { throw CloudnError("不像夸克 / UC 口令") }
        let r = try await client.send(request(for: text))
        return try shareURL(status: r.status, body: r.body)
    }
}
