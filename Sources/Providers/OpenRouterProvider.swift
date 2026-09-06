import Foundation
import os

/// Reads OpenRouter credits and API key limits.
///
/// Authentication uses `OPENROUTER_API_KEY` from the environment or `SecretStore`.
/// Queries:
/// - `GET https://openrouter.ai/api/v1/credits`: returns `total_credits` and `total_usage`
/// - `GET https://openrouter.ai/api/v1/key`: returns key metadata, limits, and period usage
actor OpenRouterProvider: UsageProvider {
    nonisolated let id = "openrouter"
    nonisolated let displayName = "OpenRouter"
    nonisolated let glyph = ProviderGlyph.openrouter

    private let creditsEndpoint = URL(string: "https://openrouter.ai/api/v1/credits")!
    private let keyEndpoint = URL(string: "https://openrouter.ai/api/v1/key")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Set OPENROUTER_API_KEY in your environment or save it in Codenotch secrets.")
    }

    nonisolated func account() -> ProviderAccount? {
        guard let token = Self.token() else { return nil }
        let masked = token.count > 10 ? "\(token.prefix(7))…\(token.suffix(3))" : "Configured"
        return ProviderAccount(
            label: masked,
            plan: "OpenRouter",
            source: "API Key",
            manageURL: URL(string: "https://openrouter.ai/activity")
        )
    }

    static func token() -> String? {
        SecretStore.resolveKey(id: "openrouter", envNames: ["OPENROUTER_API_KEY"])
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let token = Self.token() else { throw UsageProviderError.needsAuth }

        var request = URLRequest(url: creditsEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codenotch", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (creditsData, creditsResponse) = try await session.data(for: request)
        let creditsStatus = (creditsResponse as? HTTPURLResponse)?.statusCode ?? 0

        if creditsStatus == 401 || creditsStatus == 403 { throw UsageProviderError.needsAuth }
        if creditsStatus == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(creditsStatus) else {
            throw UsageProviderError.badResponse(status: creditsStatus)
        }

        let creditsBody = String(data: creditsData, encoding: .utf8) ?? ""
        Log.usage.debug("openrouter credits -> \(creditsBody.prefix(900), privacy: .public)")

        // Fetch key details (best effort)
        var keyRequest = URLRequest(url: keyEndpoint)
        keyRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        keyRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        keyRequest.setValue("Codenotch", forHTTPHeaderField: "User-Agent")
        keyRequest.timeoutInterval = 5

        let keyBody: String? = await {
            guard let (data, resp) = try? await session.data(for: keyRequest),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return text
        }()

        let windows = OpenRouterUsageParser.windows(creditsJSON: creditsBody, keyJSON: keyBody)
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("OpenRouter returned no active balance or quota.")
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: windows.first?.id ?? "credits"
        )
    }
}

enum OpenRouterUsageParser {
    static func windows(creditsJSON: String, keyJSON: String?) -> [LimitWindow] {
        var windows: [LimitWindow] = []

        // Credits / Balance
        if let creditsData = creditsJSON.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: creditsData) as? [String: Any],
           let data = root["data"] as? [String: Any] {
            let totalCredits = MiniJSON.double(data["total_credits"]) ?? 0
            let totalUsage = MiniJSON.double(data["total_usage"]) ?? 0
            let balance = max(0, totalCredits - totalUsage)

            let balanceFormatted = String(format: "$%.2f", balance)
            windows.append(LimitWindow(
                id: "credits",
                label: "Credits balance",
                usedFraction: totalCredits > 0 ? min(1.0, max(0.0, totalUsage / totalCredits)) : 0,
                customSummary: "\(balanceFormatted) remaining · \(String(format: "$%.2f", totalUsage)) used",
                customHeadline: balanceFormatted
            ))
        }

        // Key limits
        if let keyJSON,
           let keyData = keyJSON.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: keyData) as? [String: Any],
           let data = root["data"] as? [String: Any] {
            let limit = MiniJSON.double(data["limit"])
            let limitRemaining = MiniJSON.double(data["limit_remaining"])
            let usage = MiniJSON.double(data["usage"])

            if let limit, limit > 0 {
                let used = (limitRemaining != nil) ? max(0, limit - limitRemaining!) : (usage ?? 0)
                let fraction = min(1.0, max(0.0, used / limit))
                windows.append(LimitWindow(
                    id: "key_limit",
                    label: "API key limit",
                    usedFraction: fraction,
                    customSummary: "\(String(format: "$%.2f", used)) of \(String(format: "$%.2f", limit)) limit",
                    customHeadline: String(format: "$%.2f", limit - used)
                ))
            }

            if let daily = MiniJSON.double(data["usage_daily"]), daily > 0 {
                windows.append(LimitWindow(
                    id: "usage_daily",
                    label: "Today's spend",
                    customSummary: String(format: "$%.2f spent today", daily),
                    customHeadline: String(format: "$%.2f", daily)
                ))
            }
        }

        return windows
    }
}
