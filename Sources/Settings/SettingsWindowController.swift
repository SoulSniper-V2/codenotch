import AppKit
import SwiftUI

/// Hosts the settings sheet in its own window.
///
/// A real window rather than a panel attached to the notch: settings are a place
/// you go, not something you glance at, and a floating panel that follows the
/// notch would be one more thing hovering over the screen edge.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let preferences: Preferences
    /// A closure, not a snapshot. Read once at launch, the account shown here
    /// went stale the moment someone switched account in Cursor — and stayed
    /// stale until the app was restarted.
    private let providers: () -> [ProviderSummary]
    private let signOut: (String) -> Void
    private let signIn: (String) -> Bool
    private let switchAccount: (String) -> Bool
    private let retry: (String) -> Void
    private let refreshAll: () -> Void
    private let refreshLedger: () -> Void
    private let historyPoints: () -> [TokenCostStore.DailyHistoryPoint]
    private let version: String

    init(preferences: Preferences,
         providers: @escaping () -> [ProviderSummary],
         version: String,
         signOut: @escaping (String) -> Void,
         signIn: @escaping (String) -> Bool,
         switchAccount: @escaping (String) -> Bool,
         retry: @escaping (String) -> Void,
         refreshAll: @escaping () -> Void = {},
         refreshLedger: @escaping () -> Void = {},
         historyPoints: @escaping () -> [TokenCostStore.DailyHistoryPoint] = { [] }) {
        self.switchAccount = switchAccount
        self.retry = retry
        self.version = version
        self.preferences = preferences
        self.providers = providers
        self.signOut = signOut
        self.signIn = signIn
        self.refreshAll = refreshAll
        self.refreshLedger = refreshLedger
        self.historyPoints = historyPoints
    }

    /// Bring the window to the front from the notch or the app menu.
    ///
    /// `makeKeyAndOrderFront` plus `activate` is not enough on its own here:
    /// the window can otherwise open behind the app the user is working in.
    /// `orderFrontRegardless` keeps the settings action predictable.
    private func surface(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func show() {
        if let window {
            surface(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: SettingsView.width, height: SettingsView.height),
            // No `fullSizeContentView`: it pulls content up beneath the title
            // bar, and the form's first section header would sit behind it.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codenotch Settings"
        window.contentView = NSHostingView(
            rootView: SettingsView(preferences: preferences,
                                   providers: providers,
                                   version: version,
                                   signOut: signOut,
                                   signIn: signIn,
                                   switchAccount: switchAccount,
                                   retry: retry,
                                   refreshAll: refreshAll,
                                   refreshLedger: refreshLedger,
                                   historyPoints: historyPoints)
        )
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        surface(window)
    }
}
