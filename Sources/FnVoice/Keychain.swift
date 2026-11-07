import Foundation
import Security

/// Stores the LLM API key as a generic password. An empty value deletes the item, so
/// clearing the field in Settings really removes the key.
enum Keychain {
    static let service = "com.local.fnvoice.llm"
    static let account = "apiKey"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func readAPIKey() -> String {
        (try? loadAPIKey()) ?? ""
    }

    /// The stored key, "" when none is stored. Throws when one may exist but couldn't be read:
    /// with the self-signed build, each rebuild asks for the login password, and a denied or
    /// dismissed prompt lands here.
    static func loadAPIKey() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    struct KeychainError: Error {
        let status: OSStatus
        var message: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)" }
    }

    @discardableResult
    static func writeAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(baseQuery as CFDictionary)
        if trimmed.isEmpty { return true }
        var item = baseQuery
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
