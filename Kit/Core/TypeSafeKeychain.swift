import Foundation
import Security

/// Keychain (not UserDefaults) storage for the TypeSafe API key, because it is a credential.
enum TypeSafeKeychain {
    private static let service = "ai.typesafe"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let key = String(data: data, encoding: .utf8),
            !key.isEmpty
        else { return nil }
        return key
    }

    /// Update in place when a key already exists, insert otherwise.
    @discardableResult
    static func save(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        // attributesToUpdate may only carry real attributes; search keys such as kSecClass
        // are rejected by SecItemUpdate on macOS. The insert path stays on the plain
        // login keychain: kSecUseDataProtectionKeychain needs entitlements this app
        // does not carry (verified: errSecMissingEntitlement without them).
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
