import Foundation
import Security

/// This app's own secrets: API keys and session cookies pasted in Settings.
///
/// Separate from every borrowed credential. The tools own their sessions and
/// keep them; these items belong to Codenotch, created here, read back here —
/// so macOS has no reason to prompt for them the way it does for another
/// app's login. One generic-password item per provider id (cookies under
/// `<id>.cookie`), in the login keychain.
enum SecretStore {
    private static let service = "com.soulsniper.codenotch.secrets"

    static func load(id: String) -> String? {
        load(account: id)
    }

    static func loadCookie(id: String) -> String? {
        load(account: "\(id).cookie")
    }

    static func save(_ secret: String, id: String) {
        save(secret, account: id)
    }

    static func saveCookie(_ secret: String, id: String) {
        save(secret, account: "\(id).cookie")
    }

    static func delete(id: String) {
        delete(account: id)
        delete(account: "\(id).cookie")
    }

    /// Env vars first (CodexBar-compatible names, CI-friendly), then Settings.
    static func resolveKey(id: String, envNames: [String]) -> String? {
        for name in envNames {
            if let value = ProcessInfo.processInfo.environment[name]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")),
               !value.isEmpty {
                return value
            }
        }
        return load(id: id)
    }

    static func resolveCookie(id: String, envNames: [String]) -> String? {
        for name in envNames {
            if let value = ProcessInfo.processInfo.environment[name]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return loadCookie(id: id)
    }

    // MARK: - Keychain

    private static func load(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8), !secret.isEmpty
        else { return nil }
        return secret
    }

    private static func save(_ secret: String, account: String) {
        guard let data = secret.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
