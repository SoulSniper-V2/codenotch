import Foundation
import os

/// Tracks search and query quotas for Perplexity AI.
///
/// Authentication uses `PERPLEXITY_API_KEY` or a saved session cookie from `SecretStore`.
actor PerplexityProvider: UsageProvider {
    nonisolated let id = "perplexity"
    nonisolated let displayName = "Perplexity"
    nonisolated let glyph = ProviderGlyph.perplexity

    private let rateLimitURL = URL(string: "https://www.perplexity.ai/rest/rate-limit/all")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Set PERPLEXITY_API_KEY in your environment or save your session in Codenotch secrets.")
    }

    nonisolated func forgetCachedCredential() {}

    nonisolated func account() -> ProviderAccount? {
        if let key = SecretStore.resolveKey(id: "perplexity", envNames: ["PERPLEXITY_API_KEY"]) {
            let masked = key.count > 8 ? "…\(key.suffix(4))" : "Active"
            return ProviderAccount(
                label: "Perplexity (\(masked))",
                plan: "Pro / API",
                source: "API Key",
                manageURL: URL(string: "https://www.perplexity.ai/settings/api")
            )
        }
        if let _ = SecretStore.resolveCookie(id: "perplexity", envNames: ["PERPLEXITY_COOKIE"]) {
            return ProviderAccount(
                label: "Perplexity Web",
                plan: "Pro Session",
                source: "Session Cookie",
                manageURL: URL(string: "https://www.perplexity.ai")
            )
        }
        return nil
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let cookie = SecretStore.resolveCookie(id: "perplexity", envNames: ["PERPLEXITY_COOKIE"])
        let key = SecretStore.resolveKey(id: "perplexity", envNames: ["PERPLEXITY_API_KEY"])

        guard cookie != nil || key != nil else {
            throw UsageProviderError.needsAuth
        }

        var request = URLRequest(url: rateLimitURL)
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        } else if let key {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageProviderError.badResponse(status: 0)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageProviderError.needsAuth
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageProviderError.badResponse(status: http.statusCode)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        let windows = try PerplexityUsage.windows(fromJSON: body)

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: windows.first?.id
        )
    }
}
