import Combine
import Foundation
import ServiceManagement
import os

/// How metrics are presented on provider rings and cells: used vs. remaining.
enum MetricDisplayMode: String, CaseIterable, Identifiable {
    case remaining
    case used

    var id: String { rawValue }
    var title: String {
        switch self {
        case .remaining: return "% Remaining"
        case .used: return "% Used"
        }
    }
    var explanation: String {
        switch self {
        case .remaining: return "Rings show quota left to spend before the window resets."
        case .used: return "Rings show quota consumed within the current window."
        }
    }
}

/// What the user has chosen, kept in `UserDefaults`.
@MainActor
final class Preferences: ObservableObject {
    /// Providers the user has switched off. Stored as the *disconnected* set
    /// rather than the connected one, so a provider added in a later version is
    /// on by default instead of silently staying dark.
    ///
    /// Switching one off is not merely hiding it: the store stops fetching it,
    /// so its credential is never read at all.
    @Published var disconnectedProviders: Set<String> {
        didSet { defaults.set(Array(disconnectedProviders), forKey: Keys.disconnected) }
    }

    /// How much of itself the notch shows at rest.
    @Published var notchVisibility: NotchVisibility {
        didSet { defaults.set(notchVisibility.rawValue, forKey: Keys.visibility) }
    }

    /// Which screen edge the notch is welded to.
    @Published var notchEdge: NotchEdge {
        didSet { defaults.set(notchEdge.rawValue, forKey: Keys.edge) }
    }

    /// Where the app itself shows up: Dock, menu bar, or nowhere.
    @Published var appPresence: AppPresence {
        didSet { defaults.set(appPresence.rawValue, forKey: Keys.presence) }
    }

    /// Which way rings and percentages are drawn: remaining or used.
    @Published var metricStyle: MetricDisplayMode {
        didSet { defaults.set(metricStyle.rawValue, forKey: Keys.metricStyle) }
    }

    /// Notify when an exhausted quota rolls over.
    @Published var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Keys.notifyOnReset) }
    }

    /// Warn when quota drops below the warning threshold.
    @Published var notifyOnLowQuota: Bool {
        didSet { defaults.set(notifyOnLowQuota, forKey: Keys.notifyOnLowQuota) }
    }

    /// Percentage remaining threshold for low quota warning (e.g. 20%).
    @Published var quotaWarningThreshold: Int {
        didSet { defaults.set(quotaWarningThreshold, forKey: Keys.quotaWarningThreshold) }
    }

    /// Global hotkey (⌃⌥Space) toggles/peeks the notch.
    @Published var globalHotkeyEnabled: Bool {
        didSet { defaults.set(globalHotkeyEnabled, forKey: Keys.globalHotkeyEnabled) }
    }

    /// Celebrate quota reset with confetti.
    @Published var confettiEnabled: Bool {
        didSet { defaults.set(confettiEnabled, forKey: Keys.confettiEnabled) }
    }

    /// The preferred limit window to show for Antigravity provider (automatic, 5h, or weekly).
    @Published var antigravityHeadlineLimit: AntigravityHeadlineLimit {
        didSet { defaults.set(antigravityHeadlineLimit.rawValue, forKey: Keys.antigravityHeadlineLimit) }
    }

    /// The version whose changes have already been shown.
    ///
    /// Written when the What's New dialogue is dismissed rather than when it
    /// opens, so a crash in between cannot swallow the one launch it was going
    /// to appear on.
    @Published var lastSeenVersion: String? {
        didSet { defaults.set(lastSeenVersion, forKey: Keys.lastSeenVersion) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != Self.isRegisteredForLogin else { return }
            applyLaunchAtLogin()
        }
    }

    /// Set when the login-item request was refused, so the UI can say so rather
    /// than quietly flipping the switch back.
    @Published private(set) var launchAtLoginProblem: String?

    private let defaults: UserDefaults
    private enum Keys {
        /// The old name. Kept so existing choices survive the rename.
        static let disconnected = "hiddenProviders"
        static let hasLaunched = "hasLaunchedBefore"
        static let visibility = "notchVisibility"
        static let presence = "appPresence"
        static let edge = "notchEdge"
        static let lastSeenVersion = "lastSeenVersion"
        static let metricStyle = "metricDisplayMode"
        static let notifyOnReset = "notifyOnReset"
        static let notifyOnLowQuota = "notifyOnLowQuota"
        static let quotaWarningThreshold = "quotaWarningThreshold"
        static let globalHotkeyEnabled = "globalHotkeyEnabled"
        static let confettiEnabled = "confettiEnabled"
        static let antigravityHeadlineLimit = "antigravityHeadlineLimit"
    }

    nonisolated static func storedAntigravityHeadlineLimit(
        defaults: UserDefaults = .standard
    ) -> AntigravityHeadlineLimit {
        guard let value = defaults.string(forKey: Keys.antigravityHeadlineLimit),
              let limit = AntigravityHeadlineLimit(rawValue: value)
        else { return .automatic }
        return limit
    }

    /// True the very first time this copy runs, and never again.
    ///
    /// Deliberately *not* inferred from "there are no readings yet" — that is
    /// also true of someone who switched every provider off, and re-introducing
    /// them to the app every launch would be worse than never introducing them
    /// at all.
    let isFirstLaunch: Bool

    /// The bundle identifier before the app was renamed to Codenotch.
    ///
    /// A bundle id is the name of the defaults domain, so renaming the app
    /// silently moved every setting to a new, empty one — connection choices,
    /// the notch's mode, the archived readings, all apparently lost. Copying
    /// the old domain across once is the difference between a rename and what
    /// looks like a reset.
    nonisolated private static let previousDomain = "com.vinz.usagenotch"

    static func migrateFromPreviousName(into defaults: UserDefaults = .standard,
                                        from domain: String = previousDomain) {
        // The emptiness test has to be about the object being written to, not
        // about `Bundle.main` — under test those are different domains, and the
        // first version happily copied real settings into a test's scratch
        // suite. `hasLaunched` is the sentinel: `Preferences.init` sets it, so
        // its absence means nothing has ever used this domain.
        guard defaults.object(forKey: Keys.hasLaunched) == nil,
              let old = defaults.persistentDomain(forName: domain), !old.isEmpty
        else { return }

        for (key, value) in old { defaults.set(value, forKey: key) }
        Log.usage.info("migrated \(old.count) settings from the previous app name")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isFirstLaunch = !defaults.bool(forKey: Keys.hasLaunched)
        defaults.set(true, forKey: Keys.hasLaunched)
        self.disconnectedProviders = Set(defaults.stringArray(forKey: Keys.disconnected) ?? [])
        // Absent means never chosen, which is the hover behaviour the app was
        // designed around — not hidden, which would make a fresh install look
        // like it failed to start.
        self.notchVisibility = defaults.string(forKey: Keys.visibility)
            .flatMap(NotchVisibility.init(rawValue:)) ?? .onHover
        // Absent means never chosen. The Dock is the default because it is the
        // findable one — a new user who cannot see the app anywhere has no way
        // to learn it is running.
        self.appPresence = defaults.string(forKey: Keys.presence)
            .flatMap(AppPresence.init(rawValue:)) ?? .dock
        // The right edge is where the notch has always been, and it is the one
        // side of a Mac that no system chrome claims by default.
        self.notchEdge = defaults.string(forKey: Keys.edge)
            .flatMap(NotchEdge.init(rawValue:)) ?? .right
        // Absent means nothing has been shown yet, which is true of a fresh
        // install — so the current release reads as new to it.
        self.lastSeenVersion = defaults.string(forKey: Keys.lastSeenVersion)
        // Read from the system rather than from our own store: the user can turn
        // this off in System Settings, and a remembered `true` would then be a lie.
        self.launchAtLogin = Self.isRegisteredForLogin
        self.metricStyle = defaults.string(forKey: Keys.metricStyle)
            .flatMap(MetricDisplayMode.init(rawValue:)) ?? .used
        self.notifyOnReset = defaults.object(forKey: Keys.notifyOnReset) as? Bool ?? true
        self.notifyOnLowQuota = defaults.object(forKey: Keys.notifyOnLowQuota) as? Bool ?? true
        self.quotaWarningThreshold = defaults.object(forKey: Keys.quotaWarningThreshold) as? Int ?? 20
        self.globalHotkeyEnabled = defaults.object(forKey: Keys.globalHotkeyEnabled) as? Bool ?? true
        self.confettiEnabled = defaults.object(forKey: Keys.confettiEnabled) as? Bool ?? true
        self.antigravityHeadlineLimit = defaults.string(forKey: Keys.antigravityHeadlineLimit)
            .flatMap(AntigravityHeadlineLimit.init(rawValue:)) ?? .automatic
    }

    func isConnected(_ providerID: String) -> Bool {
        !disconnectedProviders.contains(providerID)
    }

    func setConnected(_ connected: Bool, for providerID: String) {
        if connected {
            disconnectedProviders.remove(providerID)
        } else {
            disconnectedProviders.insert(providerID)
        }
    }

    /// Forget everything this app has stored and quit.
    ///
    /// Deleting an app on macOS leaves `~/Library` untouched, so reinstalling
    /// brings back the old readings, the old connection choices and the old
    /// first-launch flag — which is exactly what makes a reinstall look broken.
    /// Nothing but the app itself can clean that up, so the app has to offer it.
    ///
    /// Not tied to uninstalling: a reinstall is indistinguishable from an
    /// update, and wiping data on every app update would be catastrophic.
    /// It has to be something the user asks for.
    static func eraseAllData() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.soulsniper.codenotch"
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        for relative in ["Caches/\(bundleID)",
                         "WebKit/\(bundleID)",
                         "HTTPStorages/\(bundleID)",
                         "HTTPStorages/\(bundleID).binarycookies",
                         "Saved Application State/\(bundleID).savedState"] {
            if let url = library?.appendingPathComponent(relative) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Login item

    static var isRegisteredForLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginProblem = nil
        } catch {
            // Commonly refused for an app running from a build directory rather
            // than /Applications, which is worth saying plainly.
            Log.usage.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginProblem = "macOS refused this — try moving Codenotch to /Applications."
            launchAtLogin = Self.isRegisteredForLogin
        }
    }
}
