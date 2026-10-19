// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import CommonCrypto
import CryptoKit
import Foundation

/// 登录凭据备份：全部账号序列化后用口令加密（PBKDF2-SHA256 派生密钥 + AES-GCM），
/// 导出成文件，可在新设备 / 重装后导入。口令不保存，忘了就无法解密。
enum AuthBackup {
    static let iterations: UInt32 = 200_000
    static let fileExtension = "cloudnauth"

    struct Envelope: Codable {
        var version = 1
        var salt: String
        var iterations: UInt32
        var box: String
    }

    struct Payload: Codable {
        var exportedAt: Date
        var accounts: [String: Account]
        /// 附加账号（多账号）；旧备份没有该字段
        var extras: [String: [Account]]?
    }

    struct Restored {
        var accounts: [AccountKind: Account]
        var extras: [AccountKind: [Account]]
        var count: Int { accounts.count + extras.values.reduce(0) { $0 + $1.count } }
    }

    enum Failure: LocalizedError {
        case emptyPassphrase, badFile, wrongPassphrase

        var errorDescription: String? {
            switch self {
            case .emptyPassphrase: return "请输入口令"
            case .badFile: return "不是有效的 Cloudn 认证备份文件"
            case .wrongPassphrase: return "口令错误，或备份文件已损坏"
            }
        }
    }

    static func export(_ accounts: [AccountKind: Account], extras: [AccountKind: [Account]] = [:], passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw Failure.emptyPassphrase }
        let payload = Payload(exportedAt: Date(), accounts: Dictionary(uniqueKeysWithValues: accounts.map { ($0.key.rawValue, $0.value) }),
                              extras: Dictionary(uniqueKeysWithValues: extras.map { ($0.key.rawValue, $0.value) }))
        let plain = try JSONEncoder().encode(payload)
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try deriveKey(passphrase, salt: salt, iterations: iterations)
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw Failure.badFile }
        let envelope = Envelope(salt: salt.base64EncodedString(), iterations: iterations, box: combined.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func decrypt(_ data: Data, passphrase: String) throws -> Restored {
        guard !passphrase.isEmpty else { throw Failure.emptyPassphrase }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              let salt = Data(base64Encoded: envelope.salt), let combined = Data(base64Encoded: envelope.box),
              envelope.iterations >= 10_000 else { throw Failure.badFile }
        let key = try deriveKey(passphrase, salt: salt, iterations: envelope.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: combined), let plain = try? AES.GCM.open(box, using: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: plain) else { throw Failure.wrongPassphrase }
        var result = Restored(accounts: [:], extras: [:])
        for (raw, account) in payload.accounts {
            if let kind = AccountKind(rawValue: raw) { result.accounts[kind] = account }
        }
        for (raw, list) in payload.extras ?? [:] {
            if let kind = AccountKind(rawValue: raw), !list.isEmpty { result.extras[kind] = list }
        }
        return result
    }

    static func deriveKey(_ passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let password = Array(passphrase.utf8)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { CChar(bitPattern: $0) }, password.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw Failure.badFile }
        return SymmetricKey(data: derived)
    }

    /// 导出文件写到临时目录，交给分享面板
    static func writeTemporaryFile(_ data: Data) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Cloudn-认证备份-\(f.string(from: Date())).\(fileExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}
