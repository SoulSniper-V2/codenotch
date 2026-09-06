import Foundation
import os

/// Reads GitHub Copilot quota using GitHub credentials (CLI, environment, Keychain, or SecretStore).
///
/// Hits `GET https://api.github.com/copilot_internal/user` which provides quota snapshots for
/// premium interactions and chat, along with the quota reset date.
actor CopilotProvider: UsageProvider {
    nonisolated let id = "copilot"
    nonisolated let displayName = "Copilot"
    nonisolated let glyph = ProviderGlyph.copilot

    private let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .modal(name: "Copilot")
    }

    nonisolated func account() -> ProviderAccount? {
        CopilotCredentials.account()
    }

    nonisolated func presentSignIn() {
        Task { @MainActor in
            CopilotLoginFlow.run()
        }
    }

    func signOut() async {
        SecretStore.delete(id: "copilot")
    }

    nonisolated func forgetCachedCredential() {
        // Next read will query Keychain / SecretStore afresh
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let token = CopilotCredentials.token() else { throw UsageProviderError.needsAuth }

        var request = URLRequest(url: endpoint)
        let authPrefix = token.starts(with: "gh") ? "token" : "Bearer"
        request.setValue("\(authPrefix) \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
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
        Log.usage.debug("copilot usage -> \(body.prefix(900), privacy: .public)")

        let windows = try CopilotUsageParser.windows(fromJSON: body)
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("Copilot returned no metered interaction windows.")
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: windows.first?.id ?? "premium"
        )
    }
}

enum CopilotUsageParser {
    static func windows(fromJSON json: String, now: Date = Date()) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        let resetsAt = MiniJSON.date(root["quota_reset_date_utc"] ?? root["quota_reset_date"])
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        var windows: [LimitWindow] = []

        // 1. Premium interactions
        if let premium = snapshots["premium_interactions"] as? [String: Any] {
            if let window = makeWindow(from: premium, id: "premium", label: "Premium", resetsAt: resetsAt, now: now) {
                windows.append(window)
            }
        }

        // 2. Chat
        if let chat = snapshots["chat"] as? [String: Any] {
            if let window = makeWindow(from: chat, id: "chat", label: "Chat", resetsAt: resetsAt, now: now) {
                windows.append(window)
            }
        }

        return windows
    }

    private static func makeWindow(
        from dict: [String: Any],
        id: String,
        label: String,
        resetsAt: Date?,
        now: Date
    ) -> LimitWindow? {
        let unlimited = dict["unlimited"] as? Bool ?? false
        if unlimited {
            return LimitWindow(
                id: id,
                label: label,
                usedFraction: 0,
                resetsAt: resetsAt,
                customSummary: "Unlimited",
                customHeadline: "Unlimited"
            )
        }

        let entitlement = (dict["entitlement"] as? NSNumber)?.doubleValue
        let remaining = (dict["remaining"] as? NSNumber)?.doubleValue
        let percentRemaining = (dict["percent_remaining"] as? NSNumber)?.doubleValue

        var usedFraction: Double? = nil
        if let percentRemaining {
            usedFraction = max(0, min(100, 100 - percentRemaining)) / 100.0
        } else if let entitlement, entitlement > 0, let remaining {
            usedFraction = max(0, min(entitlement, entitlement - remaining)) / entitlement
        }

        guard let usedFraction else { return nil }

        let remainingInt = remaining.map { Int($0.rounded()) }
        let usedInt = (entitlement != nil && remaining != nil) ? Int((entitlement! - remaining!).rounded()) : nil

        let cycleMinutes: Double? = {
            guard let resetsAt, resetsAt > now else { return 43_200 }
            let mins = (resetsAt.timeIntervalSince(now) / 60).rounded()
            return mins > 0 ? max(mins, 43_200) : 43_200
        }()

        return LimitWindow(
            id: id,
            label: label,
            usedFraction: usedFraction,
            remaining: remainingInt,
            used: usedInt,
            resetsAt: resetsAt,
            windowMinutes: cycleMinutes
        )
    }
}
