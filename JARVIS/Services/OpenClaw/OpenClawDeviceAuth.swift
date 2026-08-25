import CryptoKit
import Foundation
import Security

struct JARVISOpenClawDeviceIdentity {
    let deviceId: String
    let publicKeyBase64URL: String
    let privateKey: Curve25519.Signing.PrivateKey

    func sign(_ payload: String) throws -> String {
        let signature = try privateKey.signature(for: Data(payload.utf8))
        return Self.base64URL(signature)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum JARVISOpenClawDeviceAuthStore {
    private static let service = "com.automacuniao.jarvis.openclaw"
    private static let privateKeyAccount = "device-private-key-v1"

    static func loadOrCreateIdentity() throws -> JARVISOpenClawDeviceIdentity {
        let privateKey: Curve25519.Signing.PrivateKey
        if let stored = read(account: privateKeyAccount) {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
        } else {
            let generated = Curve25519.Signing.PrivateKey()
            try write(generated.rawRepresentation, account: privateKeyAccount)
            privateKey = generated
        }

        let publicData = privateKey.publicKey.rawRepresentation
        let deviceId = SHA256.hash(data: publicData)
            .map { String(format: "%02x", $0) }
            .joined()
        let publicKey = base64URL(publicData)
        return JARVISOpenClawDeviceIdentity(
            deviceId: deviceId,
            publicKeyBase64URL: publicKey,
            privateKey: privateKey)
    }

    static func loadDeviceToken(for gateway: URL) -> String? {
        guard let data = read(account: deviceTokenAccount(for: gateway)) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func saveDeviceToken(_ token: String, for gateway: URL) throws {
        guard let data = token.data(using: .utf8) else { return }
        try write(data, account: deviceTokenAccount(for: gateway))
    }

    static func clearDeviceToken(for gateway: URL) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceTokenAccount(for: gateway),
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func deviceTokenAccount(for gateway: URL) -> String {
        let normalized = gateway.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "device-token-v1-\(digest)"
    }

    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
