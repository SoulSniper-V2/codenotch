import Foundation

/// Detects quota transitions (resets and low-quota warnings) across snapshot updates.
@MainActor
final class QuotaAlertManager {
    enum AlertType: Equatable {
        case reset(providerName: String, windowLabel: String)
        case lowQuota(providerName: String, windowLabel: String, remainingPercent: Int)
    }

    private let preferences: Preferences
    private let notifications: AppNotifications
    var onCelebration: (() -> Void)?

    private var previousSnapshots: [String: ProviderSnapshot] = [:]
    private var deliveredAlertKeys: Set<String> = []

    init(
        preferences: Preferences,
        notifications: AppNotifications = .shared
    ) {
        self.preferences = preferences
        self.notifications = notifications
    }

    /// Process a new list of snapshots from UsageStore.
    func processSnapshots(_ snapshots: [ProviderSnapshot]) {
        for snapshot in snapshots {
            let previous = previousSnapshots[snapshot.id]
            let alerts = Self.evaluate(
                current: snapshot,
                previous: previous,
                thresholdPercent: preferences.quotaWarningThreshold,
                deliveredKeys: deliveredAlertKeys
            )

            for (alert, key) in alerts {
                deliveredAlertKeys.insert(key)
                switch alert {
                case .reset(let providerName, let windowLabel):
                    if preferences.notifyOnReset {
                        notifications.post(
                            id: "reset-\(snapshot.id)",
                            title: "\(providerName) Quota Reset",
                            body: "\(windowLabel) has reset. Full capacity restored."
                        )
                    }
                    if preferences.confettiEnabled {
                        onCelebration?()
                    }

                case .lowQuota(let providerName, let windowLabel, let percent):
                    if preferences.notifyOnLowQuota {
                        notifications.post(
                            id: "low-\(snapshot.id)",
                            title: "\(providerName) Running Low",
                            body: "\(windowLabel) is down to \(percent)% remaining."
                        )
                    }
                }
            }
            previousSnapshots[snapshot.id] = snapshot
        }
    }

    /// Pure evaluation function exposed for unit testing.
    static func evaluate(
        current: ProviderSnapshot,
        previous: ProviderSnapshot?,
        thresholdPercent: Int,
        deliveredKeys: Set<String>
    ) -> [(AlertType, String)] {
        var results: [(AlertType, String)] = []

        guard let currentWindow = current.headline else { return results }
        let prevWindow = previous?.headline

        // Check for Reset
        let wasExhausted = (previous?.block != nil)
            || (prevWindow?.usedFraction.map { $0 >= 0.98 } ?? false)
            || (prevWindow?.remaining == 0)

        let isNowPlentiful = (current.block == nil)
            && ((currentWindow.usedFraction.map { $0 <= 0.60 } ?? false)
                || ((currentWindow.remaining ?? 0) > 0 && wasExhausted))

        if wasExhausted && isNowPlentiful {
            let resetKey = "reset-\(current.id)-\(currentWindow.id)-\(Int(currentWindow.resetsAt?.timeIntervalSince1970 ?? 0))"
            if !deliveredKeys.contains(resetKey) {
                results.append((.reset(providerName: current.displayName, windowLabel: currentWindow.label), resetKey))
            }
        }

        // Check for Low Quota Warning
        if let currentFraction = currentWindow.usedFraction, currentFraction < 0.99 {
            let remainingPercent = max(0, Int(((1.0 - currentFraction) * 100).rounded()))
            if remainingPercent <= thresholdPercent && thresholdPercent > 0 {
                let prevRemaining = prevWindow?.usedFraction.map { max(0, Int(((1.0 - $0) * 100).rounded())) }
                let justCrossed = prevRemaining == nil || prevRemaining! > thresholdPercent

                let warningKey = "low-\(current.id)-\(currentWindow.id)-\(Int(currentWindow.resetsAt?.timeIntervalSince1970 ?? 0))"
                if justCrossed && !deliveredKeys.contains(warningKey) {
                    results.append((
                        .lowQuota(providerName: current.displayName, windowLabel: currentWindow.label, remainingPercent: remainingPercent),
                        warningKey
                    ))
                }
            }
        }

        return results
    }
}
