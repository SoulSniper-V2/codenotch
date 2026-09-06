import Foundation
import Security

/// Asking about a keychain item without asking for what is inside it.
///
/// The access control on another app's item guards its **data**, not its
/// attributes: `kSecReturnAttributes` is answered from the item's metadata and
/// never raises the "wants to access your confidential information" dialogue,
/// where `kSecReturnData` always may. `security find-generic-password` versus
/// the same command with `-w` is the same distinction from the shell.
///
/// That is what makes it worth asking often. The expensive read — the one that
/// can interrupt someone — then only has to happen when this says the item has
/// actually changed.
enum KeychainItem {
    /// When the owning app last wrote this item, or nil if there is no such
    /// item or macOS declined to say.
    static func modifiedAt(service: String, account: String? = nil) -> Date? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount] = account }

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [CFString: Any]
        else { return nil }
        return attributes[kSecAttrModificationDate] as? Date
    }
}
