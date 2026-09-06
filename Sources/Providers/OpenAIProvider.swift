import Foundation
import os

/// Reads OpenAI API credit grants and balances.
///
/// Authentication uses `OPENAI_API_KEY` from the environment or `SecretStore`.
/// Queries `GET https://api.openai.com/v1/dashboard/billing/credit_grants`.
actor OpenAIProvider: UsageProvider {
    nonisolated let id = "openai"
    nonisolated let displayName = "OpenAI"
    nonisolated let glyph = ProviderGlyph.openai

    private let endpoint = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Set OPENAI_API_KEY in your environment or save it in Codenotch secrets.")
    }

    nonisolated func account() -> ProviderAccount? {
        guard let token = Self.token() else { return nil }
        let masked = token.count > 10 ? "\(token.prefix(7))…\(token.suffix(3))" : "Configured"
        return ProviderAccount(
            label: masked,
            plan: "OpenAI Platform",
            source: "API Key",
            manageURL: URL(string: "https://platform.openai.com/billing")
        )
    }

    static func token() -> String? {
        SecretStore.resolveKey(id: "openai", envNames: ["OPENAI_API_KEY"])
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let token = Self.token() else { throw UsageProviderError.needsAuth }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codenotch", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            throw UsageProviderError.rateLimited(retryAfter: 60)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        Log.usage.debug("openai credit_grants -> \(body.prefix(900), privacy: .public)")

        let windows = try OpenAIUsageParser.windows(fromJSON: body)
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("OpenAI returned no active credit grants.")
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

enum OpenAIUsageParser {
    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        guard let totalGranted = MiniJSON.double(root["total_granted"]) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let totalUsed = MiniJSON.double(root["total_used"]) ?? 0
        let totalAvailable = MiniJSON.double(root["total_available"]) ?? max(0, totalGranted - totalUsed)

        var earliestExpiry: Date? = nil
        if let grants = root["grants"] as? [String: Any],
           let items = grants["data"] as? [[String: Any]] {
            for item in items {
                if let expiry = MiniJSON.date(item["expires_at"]) {
                    if earliestExpiry == nil || expiry < earliestExpiry! {
                        earliestExpiry = expiry
                    }
                }
            }
        }

        let usedFraction = totalGranted > 0 ? min(1.0, max(0.0, totalUsed / totalGranted)) : 0.0
        let availableFormatted = String(format: "$%.2f", totalAvailable)
        let grantedFormatted = String(format: "$%.2f", totalGranted)

        return [
            LimitWindow(
                id: "credits",
                label: "Credit balance",
                usedFraction: usedFraction,
                resetsAt: earliestExpiry,
                customSummary: "\(availableFormatted) remaining of \(grantedFormatted)",
                customHeadline: availableFormatted
            )
        ]
    }
}
