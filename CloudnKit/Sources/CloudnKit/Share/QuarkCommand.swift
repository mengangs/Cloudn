// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 夸克 / UC 中文口令解析，参考 YunX（AGPL-3.0）的 StarSeaApi / StarSeaConstants。
import Foundation

/// 夸克 / UC 中文口令（如「绝对有效 咐置松君杂货铺叩苓」）→ 分享链接。
///
/// 口令无法在本地还原，需要问一次第三方「星海」口令解析服务拿分享 ID（pwdId），
/// 再合成 `pan.quark.cn/s/<pwdId>` / `drive.uc.cn/s/<pwdId>`，后续提取码、登录态、列目录、取链全部走本地既有流程。
/// 只用 `step=parse`：不索取 stoken、不发送任何账号凭据。口令原文会发往第三方，所以这里不记录口令内容。
public enum QuarkCommand {
    public static let serviceName = "星海"
    static let resolveURL = "https://starsea-api.qwq.pics/api/resolve"
    static let apiKey = "8bfbe163c670ae500aca5f3b2f060ecc8463e1eb1691ba8d"
    /// 口令都很短，超过这个长度多半是整段文案，不该发给第三方
    static let maxLength = 120

    /// 是否值得当口令去问：非空、不太长、本身不含链接（含链接说明本地识别没认出来，问了也没用）
    public static func looksLikeCommand(_ text: String) -> Bool {
        let t = text.trimmed
        guard !t.isEmpty, t.count <= maxLength else { return false }
        let lower = t.lowercased()
        return !lower.contains("http://") && !lower.contains("https://")
    }

    /// 平台标记 + 分享 ID → 分享链接
    public static func shareURL(platform: String, pwdId: String) -> String {
        platform.lowercased() == "uc" ? "https://drive.uc.cn/s/\(pwdId)" : "https://pan.quark.cn/s/\(pwdId)"
    }

    /// 口令 → 分享链接；失败时错误信息可直接展示
    public static func resolve(_ command: String, client: HTTPClient = .shared) async throws -> String {
        let body = OrderedJSON.object([("clipboard", .string(command.trimmed)), ("platform", .string("auto")), ("step", .string("parse"))])
        let r = try await client.send(HTTPRequest(url: resolveURL, method: "POST", headers: [
            ("X-API-Key", apiKey), ("Accept", "application/json"), ("Content-Type", "application/json")
        ], body: Data(body.text.utf8)))
        // 业务失败与 HTTP 状态码分离：非 2xx 也可能带着可读的原因
        let json = r.json ?? JSON(nil)
        guard json["success"].bool else { throw CloudnError(failureMessage(status: r.status, server: json["msg"].string)) }
        let pwdId = json["data"]["pwdId"].string
        guard !pwdId.isEmpty else { throw CloudnError("口令解析失败：未取到分享 ID") }
        return shareURL(platform: json["data"]["platform"].string, pwdId: pwdId)
    }

    static func failureMessage(status: Int, server: String) -> String {
        if !server.isEmpty { return server }
        switch status {
        case 400: return "口令为空或格式不对"
        case 401: return "口令解析服务鉴权失败，请更新应用"
        case 404: return "口令解析服务暂不可用"
        case 413: return "口令过长"
        case 429: return "口令解析服务繁忙，请稍后再试"
        default: return "口令解析失败（HTTP \(status)）"
        }
    }
}
