// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
// 设备指纹持久化，参考 YunX（AGPL-3.0）的 XunleiDeviceFingerprint。
import Foundation

/// 每台设备首次使用时随机生成、此后一直复用的设备标识。
/// 每次登录都换一台「新设备」容易触发平台风控（迅雷 / 光鸭会要求短信或网页验证），
/// 而所有用户共用一个固定抓包指纹又会被连带封禁，所以按设备生成并持久化。
public enum DeviceFingerprint {
    private static let lock = NSLock()
    private static var defaults: UserDefaults { .standard }

    /// 取 key 对应的 n 位十六进制标识，没有则生成并保存
    public static func hex(_ key: String, length: Int = 32) -> String {
        lock.lock()
        defer { lock.unlock() }
        let storageKey = "cloudn.fingerprint." + key
        if let saved = defaults.string(forKey: storageKey), saved.count == length, saved.allSatisfy(\.isHexDigit) { return saved }
        let fresh = String((0..<length).map { _ in "0123456789abcdef".randomElement()! })
        defaults.set(fresh, forKey: storageKey)
        return fresh
    }
}
