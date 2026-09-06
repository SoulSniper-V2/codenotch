import Foundation

/// Human wording for `UsagePace`, ported from CodexBar's `UsagePaceText`.
///
/// Left label: pace vs expectation — "On pace" / "N% in deficit" (burning
/// faster than the window) / "N% in reserve" (headroom).
/// Right label: outcome — "Lasts until reset" (with a headroom hint when far
/// under pace) or "Runs out in X" / "Projected empty in X" for sessions.
enum PaceText {
    /// Left-hand pace label for a limit window.
    static func leftLabel(for pace: UsagePace) -> String {
        let delta = Int(abs(pace.deltaPercent).rounded())
        if delta == 0 { return "On pace" }
        switch pace.stage {
        case .onTrack:
            return "On pace"
        case .slightlyAhead, .ahead, .farAhead:
            return "\(delta)% in deficit"
        case .slightlyBehind, .behind, .farBehind:
            return "\(delta)% in reserve"
        }
    }

    /// Right-hand outcome label. `isSession` uses CodexBar's session wording
    /// ("Projected empty in …"), otherwise the weekly wording ("Runs out in …").
    static func rightLabel(for pace: UsagePace, isSession: Bool,
                           now: Date = Date()) -> String? {
        if pace.willLastToReset { return lastsLabel(for: pace) }
        guard let eta = pace.etaSeconds else { return nil }
        let text = durationText(seconds: eta)
        if text == "now" { return isSession ? "Projected empty now" : "Runs out now" }
        return isSession ? "Projected empty in \(text)" : "Runs out in \(text)"
    }

    /// Combined "left · right" line for the tooltip, or nil when no pace.
    static func line(for window: LimitWindow, now: Date = Date()) -> String? {
        guard let pace = UsagePace.estimate(for: window, now: now) else { return nil }
        let left = leftLabel(for: pace)
        if let right = rightLabel(for: pace, isSession: window.isSessionWindow, now: now) {
            return "\(left) · \(right)"
        }
        return left
    }

    // MARK: - Details

    private static func lastsLabel(for pace: UsagePace) -> String {
        // CodexBar's headroom hint: far under pace with real headroom earns an
        // explicit multiplier rather than a bare "lasts".
        if pace.deltaPercent < -15,
           let multiplier = pace.speedMultiplierToReset,
           multiplier >= 1.5 {
            return "Lasts until reset · 1.5× headroom"
        }
        return "Lasts until reset"
    }

    /// Compact duration: "now", "N min", "H hr M min" / "H hr", "D day(s)".
    static func durationText(seconds: TimeInterval) -> String {
        if seconds <= 0 { return "now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
        }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }
}

// MARK: - Window helpers

extension LimitWindow {
    /// Session-like windows use CodexBar's session wording for the ETA.
    var isSessionWindow: Bool {
        let id = id.lowercased()
        let label = label.lowercased()
        if id.contains("session") || id == "primary" { return true }
        if label.contains("session") || label.contains("5h") { return true }
        // Short windows (<= 8h) read as sessions even when named otherwise.
        if let minutes = effectiveWindowMinutes, minutes <= 480 { return true }
        return false
    }

    /// Window length in minutes when the provider stated it, for pace math.
    var inferredWindowMinutes: Int? {
        LimitWindow.minutes(forID: id, label: label)
    }

    var effectiveWindowMinutes: Int? {
        if let windowMinutes, windowMinutes > 0 { return Int(windowMinutes) }
        return inferredWindowMinutes
    }

    /// Known window lengths by provider id/label. Session = 5h (300m),
    /// weekly = 7d (10080m), monthly ≈ 30d (43200m), daily = 1440m.
    static func minutes(forID id: String, label: String) -> Int? {
        let key = "\(id) \(label)".lowercased()
        if key.contains("monthly") || key.contains("30d") || key.contains("30-day") { return 43_200 }
        if key.contains("weekly") || key.contains("7d") || key.contains("7-day")
            || key.contains("all models") || key.contains("weekly_all")
            || key.contains("weekly_all_models") { return 10_080 }
        if key.contains("daily") || key.contains("24h") { return 1_440 }
        if key.contains("session") || key.contains("5h") || key == "primary" || key.contains("primary")
            || key.contains("current session") { return 300 }
        if key.contains("secondary") || key.contains("longer window") { return 10_080 }
        if key.contains("sonnet") || key.contains("opus") { return 10_080 }
        if key.contains("included") || key.contains("api usage") || key.contains("on demand")
            || key.contains("on_demand") || key.contains("billing") { return 43_200 }
        return nil
    }
}
