import Foundation
import os

/// High-speed inference and rate-limit tracking for Groq.
///
/// Authentication uses `GROQ_API_KEY` from the environment or `SecretStore`.
actor GroqProvider: UsageProvider {
    nonisolated let id = "groq"
    nonisolated let displayName = "Groq"
    nonisolated let glyph = ProviderGlyph.groq

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/models")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Set GROQ_API_KEY in your environment or save it in Codenotch secrets.")
    }

    nonisolated func forgetCachedCredential() {}

    nonisolated func account() -> ProviderAccount? {
        guard let key = SecretStore.resolveKey(id: "groq", envNames: ["GROQ_API_KEY"]) else {
            return nil
        }
        let masked = key.count > 8 ? "…\(key.suffix(4))" : "Active"
        return ProviderAccount(
            label: "Groq (\(masked))",
            plan: "LPU Inference",
            source: "API Key",
            manageURL: URL(string: "https://console.groq.com/keys")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let apiKey = SecretStore.resolveKey(id: "groq", envNames: ["GROQ_API_KEY"]) else {
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

        let windows = Self.parseResponse(data: data, headers: http.allHeaderFields)
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

    static func parseResponse(data: Data, headers: [AnyHashable: Any]) -> [LimitWindow] {
        var windows: [LimitWindow] = []

        var headerDict: [String: String] = [:]
        for (k, v) in headers {
            if let keyStr = k as? String, let valStr = v as? String {
                headerDict[keyStr.lowercased()] = valStr
            }
        }

        if let limitReqStr = headerDict["x-ratelimit-limit-requests"],
           let remReqStr = headerDict["x-ratelimit-remaining-requests"],
           let limitReq = Double(limitReqStr), limitReq > 0,
           let remReq = Double(remReqStr) {
            let used = max(0, min(1.0, (limitReq - remReq) / limitReq))
            let resetsAt = parseResetDuration(headerDict["x-ratelimit-reset-requests"])
            windows.append(LimitWindow(
                id: "requests",
                label: "Requests / min",
                usedFraction: used,
                remaining: Int(remReq),
                resetsAt: resetsAt,
                customSummary: "\(Int(remReq)) of \(Int(limitReq)) remaining",
                customHeadline: "\(Int(remReq)) left"
            ))
        }

        if let limitTokStr = headerDict["x-ratelimit-limit-tokens"],
           let remTokStr = headerDict["x-ratelimit-remaining-tokens"],
           let limitTok = Double(limitTokStr), limitTok > 0,
           let remTok = Double(remTokStr) {
            let used = max(0, min(1.0, (limitTok - remTok) / limitTok))
            let resetsAt = parseResetDuration(headerDict["x-ratelimit-reset-tokens"])
            windows.append(LimitWindow(
                id: "tokens",
                label: "Tokens / min",
                usedFraction: used,
                remaining: Int(remTok),
                resetsAt: resetsAt,
                customSummary: "\(Int(remTok)) of \(Int(limitTok)) remaining",
                customHeadline: "\(Int(remTok)) left"
            ))
        }

        if windows.isEmpty {
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = root["data"] as? [[String: Any]] {
                windows.append(LimitWindow(
                    id: "models",
                    label: "Groq LPU",
                    usedFraction: 0,
                    customSummary: "Ultra-fast inference ready",
                    customHeadline: "\(list.count) models"
                ))
            } else {
                windows.append(LimitWindow(
                    id: "status",
                    label: "Groq LPU",
                    usedFraction: 0,
                    customSummary: "Connected to Groq Cloud",
                    customHeadline: "Ready"
                ))
            }
        }

        return windows
    }

    private static func parseResetDuration(_ str: String?) -> Date? {
        guard let str, !str.isEmpty else { return nil }
        var seconds: Double = 0
        if str.hasSuffix("ms"), let val = Double(str.dropLast(2)) {
            seconds = val / 1000.0
        } else if str.hasSuffix("s"), let val = Double(str.dropLast(1)) {
            seconds = val
        } else if str.hasSuffix("m"), let val = Double(str.dropLast(1)) {
            seconds = val * 60.0
        }
        return seconds > 0 ? Date().addingTimeInterval(seconds) : nil
    }
}
