import Foundation
import os

/// Reads Grok (SuperGrok) quota as the account the *Grok CLI* is signed into.
///
/// The shape mirrors CodexBar's Grok proxy fetch: `GET
/// cli-chat-proxy.grok.com/v1/billing?format=credits` with the OIDC bearer
/// from `~/.grok/auth.json`. The answer is a credit pool percentage plus the
/// current period's end — no token counts, no dollar conversion, exactly what
/// grok.com's own usage page shows.
///
/// No CLI subprocess, no cookie import, no gRPC fallback: the proxy answers
/// for every licensed account, and each of those would be a second credential
/// to borrow. What is missing is said plainly (`nothingMetered`) rather than
/// guessed at.
actor GrokProvider: UsageProvider {
    nonisolated let id = "grok"
    nonisolated let displayName = "Grok"
    nonisolated let glyph = ProviderGlyph.grok

    private let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Install the Grok CLI (x.ai/cli) and run `grok login` in your terminal.")
    }

    nonisolated func account() -> ProviderAccount? { GrokCredentials.account() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let token = GrokCredentials.token() else { throw UsageProviderError.needsAuth }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codenotch", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 || status == 403 { throw UsageProviderError.needsAuth }
        if status == 429 {
            throw UsageProviderError.rateLimited(
                retryAfter: (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60)
        }
        guard (200..<300).contains(status) else {
            throw UsageProviderError.badResponse(status: status)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        Log.usage.debug("grok billing -> \(body.prefix(900), privacy: .public)")

        guard let window = GrokBilling.window(fromJSON: body) else {
            throw UsageProviderError.nothingMetered(
                "Grok answered without a usable credit pool — the account may have no SuperGrok quota")
        }
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [window],
            headlineID: window.id
        )
    }
}

/// The proxy's billing answer.
///
/// Recorded shape (CodexBar's `GrokCreditsProxyFetcher`):
/// ```json
/// {"config":{"creditUsagePercent":12.5,
///   "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
///     "start":"2026-08-06T00:00:00Z","end":"2026-08-13T00:00:00Z"},
///   "billingPeriodEnd":"2026-08-13T00:00:00Z",
///   "onDemandCap":{"val":1000},"onDemandUsed":{"val":250}},
///  "subscriptionTier":"SuperGrok Heavy"}
/// ```
enum GrokBilling {
    private struct Response: Decodable {
        struct Amount: Decodable { let val: Double? }
        struct Period: Decodable { let start: String?; let end: String? }
        struct Config: Decodable {
            let creditUsagePercent: Double?
            let currentPeriod: Period?
            let billingPeriodEnd: String?
            let onDemandCap: Amount?
            let onDemandUsed: Amount?
        }
        let config: Config?
    }

    /// The credit-pool window: `creditUsagePercent` first, else on-demand
    /// used/cap. Nil when neither yields a percentage — an unknown pool must
    /// not render as a 0% ring.
    static func window(fromJSON json: String) -> LimitWindow? {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let config = response.config
        else { return nil }

        let resetsAt = parseISO8601(config.currentPeriod?.end)
            ?? parseISO8601(config.billingPeriodEnd)
        let minutes = minutesBetween(parseISO8601(config.currentPeriod?.start), resetsAt)

        if let percent = config.creditUsagePercent {
            return LimitWindow(
                id: "credits",
                label: "Credits",
                usedFraction: (percent / 100).clamped01,
                resetsAt: resetsAt,
                windowMinutes: minutes
            )
        }
        if let used = config.onDemandUsed?.val,
           let cap = config.onDemandCap?.val, cap > 0 {
            return LimitWindow(
                id: "on_demand",
                label: "On-demand",
                usedFraction: (used / cap).clamped01,
                resetsAt: resetsAt,
                windowMinutes: minutes
            )
        }
        return nil
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func minutesBetween(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end, end > start else { return nil }
        let minutes = (end.timeIntervalSince(start) / 60).rounded()
        return minutes > 0 ? minutes : nil
    }
}

private extension Double {
    var clamped01: Double { min(max(self, 0), 1) }
}
