import Foundation
import Security

/// API keys live in the user's login keychain, one generic-password item per provider.
enum Keychain {
    private static let service = AppInfo.bundleID
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    /// Forgets cached values so the next read goes to the Keychain again.
    static func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cache = [:]
    }

    static func get(_ account: String) -> String? {
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            lock.lock()
            cache[account] = ""
            lock.unlock()
            return nil
        }
        lock.lock()
        cache[account] = value
        lock.unlock()
        return value.isEmpty ? nil : value
    }

    static func set(_ value: String, for account: String) {
        delete(account)
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "ScreenLocalizer API key (\(account))",
            kSecValueData as String: Data(trimmed.utf8),
        ]
        SecItemAdd(attrs as CFDictionary, nil)
        lock.lock()
        cache[account] = trimmed
        lock.unlock()
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock()
        cache[account] = ""
        lock.unlock()
    }
}
