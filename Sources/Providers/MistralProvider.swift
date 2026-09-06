import Foundation
import os

/// Model availability and status tracker for Mistral AI and Codestral.
///
/// Authentication uses `MISTRAL_API_KEY` or `CODESTRAL_API_KEY` from the environment or `SecretStore`.
actor MistralProvider: UsageProvider {
    nonisolated let id = "mistral"
    nonisolated let displayName = "Mistral"
    nonisolated let glyph = ProviderGlyph.mistral

    private let endpoint = URL(string: "https://api.mistral.ai/v1/models")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Set MISTRAL_API_KEY or CODESTRAL_API_KEY in your environment or save it in Codenotch secrets.")
    }

    nonisolated func forgetCachedCredential() {}

    nonisolated func account() -> ProviderAccount? {
        guard let key = SecretStore.resolveKey(id: "mistral", envNames: ["MISTRAL_API_KEY", "CODESTRAL_API_KEY"]) else {
            return nil
        }
        let masked = key.count > 8 ? "…\(key.suffix(4))" : "Active"
        return ProviderAccount(
            label: "Mistral (\(masked))",
            plan: "Codestral / API",
            source: "API Key",
            manageURL: URL(string: "https://console.mistral.ai/api-keys")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let apiKey = SecretStore.resolveKey(id: "mistral", envNames: ["MISTRAL_API_KEY", "CODESTRAL_API_KEY"]) else {
            throw UsageProviderError.needsAuth
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

        let windows = Self.parseModels(from: data)
        guard !windows.isEmpty else {
            throw UsageProviderError.badResponse(status: http.statusCode)
        }

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

    static func parseModels(from data: Data) -> [LimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            return []
        }

        let modelIDs = list.compactMap { $0["id"] as? String }
        let hasCodestral = modelIDs.contains { $0.localizedCaseInsensitiveContains("codestral") }

        var windows: [LimitWindow] = []
        if hasCodestral {
            windows.append(LimitWindow(
                id: "codestral",
                label: "Codestral",
                usedFraction: 0,
                customSummary: "Code completion & reasoning active",
                customHeadline: "Available"
            ))
        }

        windows.append(LimitWindow(
            id: "models",
            label: "Model catalog",
            usedFraction: 0,
            remaining: modelIDs.count,
            customSummary: "Mistral Large & European models",
            customHeadline: "\(modelIDs.count) models"
        ))

        return windows
    }
}
