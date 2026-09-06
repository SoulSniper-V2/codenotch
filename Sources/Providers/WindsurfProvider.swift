import Foundation
import os

/// Local plan status and quota reader for the Windsurf editor.
///
/// Windsurf caches plan and quota metrics in its local globalStorage database:
/// `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb` under
/// key `windsurf.settings.cachedPlanInfo`.
actor WindsurfProvider: UsageProvider {
    nonisolated let id = "windsurf"
    nonisolated let displayName = "Windsurf"
    nonisolated let glyph = ProviderGlyph.windsurf

    private let dbURL: URL?

    init(dbURL: URL? = nil) {
        self.dbURL = dbURL
    }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "com.exafunction.windsurf", name: "Windsurf")
    }

    nonisolated func forgetCachedCredential() {}

    nonisolated func account() -> ProviderAccount? {
        guard let info = loadPlanInfo() else { return nil }
        let plan = info.planName ?? "Windsurf"
        return ProviderAccount(
            label: plan,
            plan: plan,
            source: "Windsurf (local)",
            manageURL: URL(string: "https://windsurf.com/subscription/usage")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        guard let info = Self.readPlanInfo(from: resolvedDBURL()) else {
            throw UsageProviderError.needsAuth
        }

        let windows = Self.windows(from: info)
        guard !windows.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: .ok,
            windows: windows,
            headlineID: windows.first?.id
        )
    }

    private func resolvedDBURL() -> URL {
        if let dbURL { return dbURL }
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: "\(home)/Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
    }

    private nonisolated func loadPlanInfo() -> WindsurfPlanInfo? {
        let home = NSHomeDirectory()
        let url = dbURL ?? URL(fileURLWithPath: "\(home)/Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        return Self.readPlanInfo(from: url)
    }

    static func readPlanInfo(from url: URL) -> WindsurfPlanInfo? {
        guard let db = SQLiteStore.open(url) else { return nil }
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        let rows = SQLiteStore.rows(in: db, sql: sql, bind: "windsurf.settings.cachedPlanInfo")
        guard let jsonString = rows.first, let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(WindsurfPlanInfo.self, from: data)
    }

    static func windows(from info: WindsurfPlanInfo) -> [LimitWindow] {
        var windows: [LimitWindow] = []

        if let quota = info.quotaUsage {
            if let dailyRemaining = quota.dailyRemainingPercent {
                let used = max(0, min(1.0, (100.0 - dailyRemaining) / 100.0))
                let resetsAt = quota.dailyResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                windows.append(LimitWindow(
                    id: "daily",
                    label: "Daily limit",
                    usedFraction: used,
                    resetsAt: resetsAt,
                    windowMinutes: 1440
                ))
            }

            if let weeklyRemaining = quota.weeklyRemainingPercent {
                let used = max(0, min(1.0, (100.0 - weeklyRemaining) / 100.0))
                let resetsAt = quota.weeklyResetAtUnix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                windows.append(LimitWindow(
                    id: "weekly",
                    label: "Weekly limit",
                    usedFraction: used,
                    resetsAt: resetsAt,
                    windowMinutes: 10080
                ))
            }
        }

        if windows.isEmpty, let usage = info.usage {
            if let total = usage.messages, total > 0, let used = usage.usedMessages {
                let fraction = Double(used) / Double(total)
                windows.append(LimitWindow(
                    id: "messages",
                    label: "Messages",
                    usedFraction: min(1.0, fraction),
                    remaining: usage.remainingMessages ?? (total - used),
                    used: used,
                    customSummary: "\(used) of \(total) messages used",
                    customHeadline: "\(usage.remainingMessages ?? (total - used)) left"
                ))
            } else if let remaining = usage.remainingMessages {
                windows.append(LimitWindow(
                    id: "remaining",
                    label: "Messages",
                    remaining: remaining,
                    customSummary: "\(remaining) messages remaining",
                    customHeadline: "\(remaining) left"
                ))
            }
        }

        return windows
    }
}

public struct WindsurfPlanInfo: Codable, Sendable {
    public let planName: String?
    public let startTimestamp: Int64?
    public let endTimestamp: Int64?
    public let usage: UsageDetails?
    public let quotaUsage: QuotaUsageDetails?

    public struct UsageDetails: Codable, Sendable {
        public let messages: Int?
        public let usedMessages: Int?
        public let remainingMessages: Int?
        public let flowActions: Int?
        public let usedFlowActions: Int?
        public let remainingFlowActions: Int?
        public let flexCredits: Int?
        public let usedFlexCredits: Int?
        public let remainingFlexCredits: Int?
    }

    public struct QuotaUsageDetails: Codable, Sendable {
        public let dailyRemainingPercent: Double?
        public let weeklyRemainingPercent: Double?
        public let dailyResetAtUnix: Int64?
        public let weeklyResetAtUnix: Int64?
    }
}
