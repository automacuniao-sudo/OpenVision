import Foundation
import Security

final class SpotifyTokenStore {
    static let shared = SpotifyTokenStore()

    private let service = "com.jarvis.spotify"
    private let tokenAccount = "oauth_tokens"
    private let pendingAccount = "oauth_pending"

    private init() {}

    func saveTokens(_ tokens: SpotifyTokenBundle) throws {
        try save(tokens, account: tokenAccount)
    }

    func loadTokens() -> SpotifyTokenBundle? {
        load(SpotifyTokenBundle.self, account: tokenAccount)
    }

    func clearTokens() {
        delete(account: tokenAccount)
    }

    func savePendingAuthorization(_ pending: SpotifyPendingAuthorization) throws {
        try save(pending, account: pendingAccount)
    }

    func loadPendingAuthorization() -> SpotifyPendingAuthorization? {
        load(SpotifyPendingAuthorization.self, account: pendingAccount)
    }

    func clearPendingAuthorization() {
        delete(account: pendingAccount)
    }

    func clearAll() {
        clearTokens()
        clearPendingAuthorization()
    }

    private func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        query.removeAll()
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}
