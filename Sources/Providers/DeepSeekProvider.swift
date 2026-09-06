import Foundation
import os

/// Reads DeepSeek credit balances via the user balance API.
///
/// Authentication uses `DEEPSEEK_API_KEY` from the environment or `SecretStore`.
/// Queries `GET https://api.deepseek.com/user/balance`.
actor DeepSeekProvider: UsageProvider {
    nonisolated let id = "deepseek"
    nonisolated let displayName = "DeepSeek"
    nonisolated let glyph = ProviderGlyph.deepseek

    private let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Set DEEPSEEK_API_KEY in your environment or save it in Codenotch secrets.")
    }

    nonisolated func account() -> ProviderAccount? {
        guard let token = Self.token() else { return nil }
        let masked = token.count > 10 ? "\(token.prefix(7))…\(token.suffix(3))" : "Configured"
        return ProviderAccount(
            label: masked,
            plan: "DeepSeek",
            source: "API Key",
            manageURL: URL(string: "https://platform.deepseek.com/api_keys")
        )
    }

    static func token() -> String? {
        SecretStore.resolveKey(id: "deepseek", envNames: ["DEEPSEEK_API_KEY"])
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
        Log.usage.debug("deepseek balance -> \(body.prefix(900), privacy: .public)")

        let windows = try DeepSeekUsageParser.windows(fromJSON: body)
        guard !windows.isEmpty else {
            throw UsageProviderError.nothingMetered("DeepSeek returned no active balance.")
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: windows.first?.id ?? "balance"
        )
    }
}

enum DeepSeekUsageParser {
    static func windows(fromJSON json: String) throws -> [LimitWindow] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }

        var windows: [LimitWindow] = []
        let balanceInfos = root["balance_infos"] as? [[String: Any]] ?? []

        for (index, info) in balanceInfos.enumerated() {
            let currency = (info["currency"] as? String)?.uppercased() ?? "USD"
            let symbol = currency == "CNY" ? "¥" : "$"
            let total = MiniJSON.double(info["total_balance"]) ?? 0
            let granted = MiniJSON.double(info["granted_balance"]) ?? 0
            let toppedUp = MiniJSON.double(info["topped_up_balance"]) ?? 0

            let formattedTotal = String(format: "%@%.2f", symbol, total)
            var summaryParts = ["\(formattedTotal) balance"]
            if granted > 0 { summaryParts.append(String(format: "%@%.2f granted", symbol, granted)) }
            if toppedUp > 0 { summaryParts.append(String(format: "%@%.2f topped up", symbol, toppedUp)) }

            windows.append(LimitWindow(
                id: "balance_\(index)",
                label: "\(currency) Balance",
                customSummary: summaryParts.joined(separator: " · "),
                customHeadline: formattedTotal
            ))
        }

        return windows
    }
}
