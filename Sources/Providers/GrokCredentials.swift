import Foundation

/// Credential for Grok, borrowed from the Grok CLI's own login.
///
/// `grok login` writes `~/.grok/auth.json` (or `$GROK_HOME/auth.json`): a map
/// from scope URL to entries carrying a bearer `key`. CodexBar prefers the
/// SuperGrok OIDC entry (`https://auth.x.ai::…`) and falls back to the sign-in
/// entry — the same order is kept here, so both tools read the same account.
///
/// Nothing is ever refreshed or written: the CLI owns the session, and the next
/// `grok login` rotates it. An absent or keyless file means signed out.
enum GrokCredentials {
    /// Which account a Grok reading belongs to, for the settings row.
    static func account(from url: URL? = nil) -> ProviderAccount? {
        if let entry = entry(from: url) {
            return ProviderAccount(
                label: entry.email,
                plan: nil,
                source: "Grok CLI",
                manageURL: URL(string: "https://grok.com/?_s=usage")
            )
        }
        if let key = SecretStore.resolveKey(id: "grok", envNames: ["GROK_API_KEY", "XAI_API_KEY"]) {
            let masked = key.count > 10 ? "\(key.prefix(7))…\(key.suffix(3))" : "Configured"
            return ProviderAccount(
                label: masked,
                plan: "Grok",
                source: "API Key",
                manageURL: URL(string: "https://console.x.ai")
            )
        }
        return nil
    }

    /// The bearer token for the proxy billing endpoint, if there is one.
    static func token(from url: URL? = nil) -> String? {
        if let key = SecretStore.resolveKey(id: "grok", envNames: ["GROK_API_KEY", "XAI_API_KEY"]) {
            return key
        }
        return entry(from: url)?.key
    }

    static var authURL: URL {
        if let home = ProcessInfo.processInfo.environment["GROK_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
    }

    private struct Entry {
        let key: String
        let email: String?
    }

    private static func entry(from url: URL? = nil) -> Entry? {
        guard let data = try? Data(contentsOf: url ?? authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // SuperGrok OIDC first, the sign-in entry as fallback — CodexBar's
        // order, so both apps agree on whose quota this is.
        let scopes = Array(root.keys)
        let ordered = scopes.filter { $0.hasPrefix("https://auth.x.ai::") }
            + scopes.filter { !$0.hasPrefix("https://auth.x.ai::") }
        for scope in ordered {
            guard let item = root[scope] as? [String: Any],
                  let key = item["key"] as? String, !key.isEmpty,
                  !key.hasPrefix("cookie:"),
                  !key.hasPrefix("xai-"),
                  !key.contains("=")
            else { continue }
            return Entry(key: key, email: item["email"] as? String)
        }
        return nil
    }
}
