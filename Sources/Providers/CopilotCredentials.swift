import Foundation
import Security

/// Credential resolver for GitHub Copilot.
///
/// Priority:
/// 1. Environment variables (`COPILOT_API_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN`)
///    or `SecretStore` entry for "copilot" (saved via device flow or settings).
/// 2. Copilot CLI Keychain entry: `service: "copilot-cli"`.
/// 3. GitHub CLI hosts configuration: `~/.config/gh/hosts.yml`
/// 4. GitHub CLI Keychain (`gh:github.com` or `github.com`), with `go-keyring-base64` decoding.
/// 5. GitHub CLI process fallback (`gh auth token`).
enum CopilotCredentials {
    struct Credential {
        let token: String
        let user: String?
        let source: String
    }

    static func account() -> ProviderAccount? {
        guard let cred = resolve() else { return nil }
        return ProviderAccount(
            label: cred.user,
            plan: "Copilot",
            source: cred.source,
            manageURL: URL(string: "https://github.com/settings/copilot")
        )
    }

    static func token() -> String? {
        resolve()?.token
    }

    static func resolve(hostsURL: URL? = nil) -> Credential? {
        // 1. Env or SecretStore
        if let key = SecretStore.resolveKey(id: "copilot", envNames: ["COPILOT_API_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"]) {
            return Credential(token: key, user: nil, source: "API / Device Flow")
        }

        // 2. Copilot CLI Keychain entry
        if let cli = readKeychainItem(service: "copilot-cli") {
            return Credential(token: cli.token, user: cli.user, source: "Copilot CLI")
        }

        // 3. GitHub CLI hosts.yml
        if let gh = fromHostsYAML(url: hostsURL ?? defaultHostsURL) {
            return gh
        }

        // 4. GitHub CLI Keychain
        if let kc = fromKeychain() {
            return kc
        }

        // 5. GitHub CLI process fallback
        if let proc = fromGitHubCLIProcess() {
            return proc
        }

        return nil
    }

    static var defaultHostsURL: URL {
        if let ghConfig = ProcessInfo.processInfo.environment["GH_CONFIG_DIR"], !ghConfig.isEmpty {
            return URL(fileURLWithPath: ghConfig).appendingPathComponent("hosts.yml")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/gh/hosts.yml")
    }

    /// Lightweight line-based YAML parser for GitHub CLI's `hosts.yml`.
    static func fromHostsYAML(url: URL) -> Credential? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseHostsYAML(content)
    }

    static func parseHostsYAML(_ content: String) -> Credential? {
        let lines = content.components(separatedBy: .newlines)
        var insideGitHub = false
        var foundToken: String?
        var foundUser: String?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if !rawLine.hasPrefix(" ") && !rawLine.hasPrefix("\t") {
                if line.hasPrefix("github.com:") {
                    insideGitHub = true
                } else {
                    if insideGitHub && foundToken != nil { break }
                    insideGitHub = false
                }
                continue
            }

            guard insideGitHub else { continue }

            if line.hasPrefix("oauth_token:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    foundToken = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            } else if line.hasPrefix("user:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    foundUser = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }

        guard let token = foundToken, !token.isEmpty else { return nil }
        return Credential(token: token, user: foundUser, source: "GitHub CLI")
    }

    private static func fromKeychain() -> Credential? {
        let candidates = [
            "gh:github.com",
            "github.com",
            "copilot",
            "github-copilot"
        ]
        for service in candidates {
            if let item = readKeychainItem(service: service) {
                return Credential(token: item.token, user: item.user, source: "GitHub CLI")
            }
        }
        return nil
    }

    static func readKeychainItem(service: String) -> (token: String, user: String?)? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let dict = item as? [String: Any] else {
            return nil
        }
        guard let data = dict[kSecValueData as String] as? Data,
              let rawSecret = String(data: data, encoding: .utf8),
              let token = decodeTokenString(rawSecret) else {
            return nil
        }
        let rawAcct = dict[kSecAttrAccount as String] as? String
        return (token: token, user: extractUsername(from: rawAcct))
    }

    static func decodeTokenString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("go-keyring-base64:") {
            let b64 = String(trimmed.dropFirst("go-keyring-base64:".count))
            if let data = Data(base64Encoded: b64),
               let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !str.isEmpty {
                return str
            }
            return nil
        }
        if trimmed.hasPrefix("go-keyring-") {
            return nil
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func extractUsername(from account: String?) -> String? {
        guard let account = account?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty else {
            return nil
        }
        if account.contains(":") {
            let part = account.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (part?.isEmpty == false) ? part : account
        }
        return account
    }

    private static func fromGitHubCLIProcess() -> Credential? {
        let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let ghBinary = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghBinary)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty, token.starts(with: "gh") else { return nil }
            return Credential(token: token, user: nil, source: "GitHub CLI")
        } catch {
            return nil
        }
    }
}
