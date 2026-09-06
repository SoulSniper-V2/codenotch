import Foundation

/// Grok Bot (Cursor calls it "Sand") weekly included usage.
///
/// Cursor meters its Grok bot separately from the monthly plan allowance:
/// `POST /api/dashboard/get-sand-usage-status` with the same session cookie as
/// `/api/usage-summary`. CodexBar reads this as an extra rate window
/// (`cursor-grok-bot`); without it the notch shows the plan percentage while
/// Grok answers are what is actually running out.
///
/// A missing or failed response must never fail Cursor usage — it is a second
/// allowance on the same account, not the account itself.
enum CursorSandUsage {
    static let windowID = "cursor-grok-bot"
    static let windowTitle = "Grok Bot"
    static let endpointPath = "/api/dashboard/get-sand-usage-status"

    private struct Response: Decodable {
        let currentPeriodStart: String?
        let nextResetTimestampUtc: String?
        let usagePercent: Double?
        let hasAvailableUsage: Bool?
        let hasNonZeroIncludedLimit: Bool?
    }

    /// Weekly Grok Bot window, or nil when the account has no included Bot
    /// allowance (free plans, or Bot never enabled).
    static func window(fromJSON json: String) -> LimitWindow? {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.hasNonZeroIncludedLimit == true,
              let percent = response.usagePercent
        else { return nil }

        let start = parseISO8601(response.currentPeriodStart)
        let resetsAt = parseISO8601(response.nextResetTimestampUtc)
        return LimitWindow(
            id: windowID,
            label: windowTitle,
            usedFraction: percent / 100,
            resetsAt: resetsAt,
            windowMinutes: minutesBetween(start, resetsAt)
        )
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
