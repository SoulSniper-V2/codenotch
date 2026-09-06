import AppKit
import SwiftUI

/// The settings sheet, reached from the orb below the notch.
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let providers: () -> [ProviderSummary]
    /// The marketing version, for the footer. Passed in rather than read from
    /// the bundle here so tests can pin it.
    let version: String
    /// Re-read whenever the sheet comes forward. Switching account happens in
    /// another app, so the user is always coming *back* here to see it — which
    /// makes returning focus the exact moment the old value is wrong.
    @State private var accounts: [ProviderSummary] = []
    /// Switching off has to reach the store's archive, not just the preference
    /// — see `UsageStore.signOut(providerID:)`.
    let signOut: (String) -> Void
    /// Switching on takes the user to wherever that account is signed in.
    /// Returns false when there was nothing to open.
    let signIn: (String) -> Bool
    let switchAccount: (String) -> Bool
    /// Re-reads a provider's credential. For a declined keychain prompt that is
    /// the whole remedy: asking again is what puts the prompt back on screen.
    let retry: (String) -> Void
    /// Keeps explicit refresh in the store instead of making this window own
    /// provider fetching. This is the same useful boundary CodexBar uses.
    let refreshAll: () -> Void
    /// Forces the local Claude Code/Codex token ledger to rescan its sources.
    let refreshLedger: () -> Void

    init(preferences: Preferences,
         providers: @escaping () -> [ProviderSummary],
         version: String,
         signOut: @escaping (String) -> Void,
         signIn: @escaping (String) -> Bool,
         switchAccount: @escaping (String) -> Bool,
         retry: @escaping (String) -> Void,
         refreshAll: @escaping () -> Void = {},
         refreshLedger: @escaping () -> Void = {}) {
        self.preferences = preferences
        self.providers = providers
        self.version = version
        self.signOut = signOut
        self.signIn = signIn
        self.switchAccount = switchAccount
        self.retry = retry
        self.refreshAll = refreshAll
        self.refreshLedger = refreshLedger
    }

    var body: some View {
        // One page of grouped sections rather than tabs. Tabs hid three
        // quarters of the settings behind a click, for an app with about a
        // screenful of them in total — the grouping was the thing that was
        // missing, not the separation. A grouped `Form` is what macOS itself
        // uses for this: each section is a titled, rounded group, so the
        // structure is visible all at once instead of navigated to.
        Form {
            Section {
                SettingsHeader(accounts: accounts, version: version)
            }

            Section {
                if needsSetup { setupNote }
                ForEach(accounts) {
                    AccountRow(provider: $0, preferences: preferences,
                               signOut: signOut, signIn: signIn,
                               switchAccount: switchAccount, retry: retry)
                }
                // Beside the switches it explains, not stranded at the end of
                // the page.
                Text("Codenotch never signs in — each reading is borrowed from the "
                     + "tool that already holds the account. Signing out here stops "
                     + "the credential being read and forgets the numbers, but leaves "
                     + "you signed in to that tool. macOS asks once per tool the "
                     + "first time, and again whenever you sign in to a different "
                     + "account; Always Allow keeps it quiet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Integrations")
            }

            // One section, because they are one question: what Codenotch
            // looks like and where it turns up. Split across three headers it
            // read as three unrelated settings, and "Where Codenotch appears"
            // was a header long enough to look like a warning.
            Section("Appearance") {
                Picker("Show", selection: $preferences.notchVisibility) {
                    ForEach(NotchVisibility.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(preferences.notchVisibility.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Edge", selection: $preferences.notchEdge) {
                    ForEach(NotchEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(preferences.notchEdge.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // "App icon", not "Icon": the two rows above it are about the
                // notch, and on its own the word would read as another of them.
                Picker("App icon", selection: $preferences.appPresence) {
                    ForEach(AppPresence.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(preferences.appPresence.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Usage") {
                Picker("Ring metric", selection: $preferences.metricStyle) {
                    ForEach(MetricDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(preferences.metricStyle.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label("Local usage estimates", systemImage: "chart.bar.xaxis")
                    .font(.callout)

                Text("Codenotch scans local Claude Code and Codex logs whenever "
                     + "Settings opens. Estimates "
                     + "are shown in each provider's details and never replace the "
                     + "vendor's quota reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // App lifecycle and version together: both describe this copy of
            // Codenotch rather than what it is reading.
            Section("General") {
                Toggle("Open Codenotch at login", isOn: $preferences.launchAtLogin)
                if let problem = preferences.launchAtLoginProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Version \(version).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("Private by design — no telemetry or update feed.",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .frame(width: SettingsView.width, height: SettingsView.height)
        .onAppear { refreshForPresentation() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in refreshForPresentation() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSNotification.Name("CodenotchRefreshProvider")
        )) { _ in accounts = providers() }
    }

    private func refreshForPresentation() {
        accounts = providers()
        refreshAll()
        refreshLedger()
    }

    /// Wide enough for provider rows and short explanations without making the
    /// settings page feel like a dashboard.
    static let width: CGFloat = 520
    /// Keeps the common controls visible while allowing the grouped form to
    /// scroll naturally when more providers are enabled.
    static let height: CGFloat = 650

    /// Nothing to read from anywhere. On a first launch that is the normal
    /// state, and it is the only moment the sheet has something to explain.
    private var needsSetup: Bool {
        !accounts.isEmpty && accounts.allSatisfy { $0.account == nil }
    }

    /// Names the tools rather than saying "tools already signed in on this
    /// Mac". Someone who uses Claude in a browser reads that sentence, installs
    /// this, sees four blank rings and concludes it is broken — and the
    /// distinction that catches them out is Claude *Code*, not the Claude app.
    static let setupCopy =
        "Codenotch reads usage from tools already signed in on this Mac — it "
        + "never asks for your password. Install and sign in to any of Claude "
        + "Code (the terminal tool, not the Claude app), Cursor, Codex or "
        + "Antigravity, and its ring appears in the notch."

    /// Said before it happens rather than after. A system dialogue asking to
    /// read a *credential*, from an app installed a minute ago, looks alarming
    /// unless it was expected — and choosing Allow instead of Always Allow makes
    /// it return on every read, which is what "it asks every time" turns out to
    /// be.
    static let keychainCopy =
        "macOS will ask once for permission to read Claude Code's and "
        + "Antigravity's saved logins. Choose Always Allow — plain Allow makes "
        + "it ask again every time."

    private var setupNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect an assistant to get started")
                    .font(.callout.weight(.medium))
                Text(SettingsView.setupCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(SettingsView.keychainCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }


}

/// A compact identity strip gives the settings window a home without turning
/// the page into a marketing hero. The connected count is the same account
/// state shown by the rows below, so it remains useful while scrolling.
private struct SettingsHeader: View {
    let accounts: [ProviderSummary]
    let version: String

    private var connectedCount: Int {
        accounts.filter { $0.account != nil }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: RoundedRectangle(
                        cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Codenotch")
                    .font(.title3.weight(.semibold))
                Text("Your assistants, at the edge of the screen")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(accounts.isEmpty ? "—" : "\(connectedCount)/\(accounts.count)")
                    .font(.headline.monospacedDigit())
                Text("connected · v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            accounts.isEmpty
                ? "Codenotch settings, loading integrations"
                : "Codenotch settings, \(connectedCount) of \(accounts.count) integrations connected"
        )
    }
}

/// One provider: whether Codenotch reads it, whose account that is, and where
/// to go if there is nothing to read.
private struct AccountRow: View {
    let provider: ProviderSummary
    @ObservedObject var preferences: Preferences
    let signOut: (String) -> Void
    let signIn: (String) -> Bool
    let switchAccount: (String) -> Bool
    let retry: (String) -> Void

    private var isConnected: Bool { preferences.isConnected(provider.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Centred, not baseline-aligned. A glyph is a `Shape` and has no
            // text baseline, so `.firstTextBaseline` lines its *bottom edge* up
            // with the text's baseline and lifts every icon above its own name.
            // Everything on this row is a single line, so centring is what makes
            // the mark, the name, the button and the switch sit on one axis.
            HStack(alignment: .center, spacing: 10) {
                ProviderGlyphView(glyph: provider.glyph, size: 16)
                    .foregroundStyle(isConnected ? .primary : .tertiary)

                Text(provider.name)
                    .foregroundStyle(isConnected ? .primary : .secondary)

                Spacer(minLength: 8)

                // Prefers the app that owns the account, and falls back to the
                // web page only when there is no app to open.
                //
                // The reading is borrowed from an app on this Mac, so that app
                // is where the account actually lives — and the website is a
                // different session entirely, which will bounce you to a login
                // if the browser is not signed in. Sending someone to a login
                // screen from a row that says "connected" is the wrong answer
                // whenever the real thing is one launch away.
                // The way back from a declined keychain prompt, and the only
                // one: declining is easy to do by reflex, and nothing else on
                // screen will ask macOS again. Shown for providers whose
                // credential actually lives in the keychain — for the others
                // there is no prompt to raise.
                if isConnected, provider.usesKeychain {
                    Button("Allow access…") { retry(provider.id) }
                        .controlSize(.small)
                        .help("Asks macOS for \(provider.name)'s saved login again. "
                              + "Choose Always Allow and it will stop asking.")
                }

                if isConnected, let destination {
                    Button(destination.title) { open(destination) }
                        .controlSize(.small)
                        .help(destination.help)
                }

                Toggle("", isOn: binding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(isConnected
                          ? "Switch off to stop reading \(provider.name) and forget its "
                            + "readings. " + provider.signIn.signOutCaveat
                          : "Switch on to sign in and read \(provider.name) again.")
            }

            detail
                .font(.caption)
                .padding(.leading, 26)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !isConnected {
            Text("Signed out — nothing is read, and no readings are kept.")
                .foregroundStyle(.tertiary)
        } else if let account = provider.account {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account.summary)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if canOpenSignIn {
                        Button("Switch…") { _ = switchAccount(provider.id) }
                            .buttonStyle(.link)
                            .help(provider.signIn.switchHint)
                    }
                }
                // Says where the account actually lives, which is the whole
                // answer to "how do I change it" — not here.
                Text(provider.signIn.switchHint)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 8) {
                Text(provider.signIn.explanation)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = provider.signIn.actionTitle, canOpenSignIn {
                    Button(title) { _ = signIn(provider.id) }
                        .controlSize(.small)
                }

            }
        }
    }

    /// Where this row's "Open" button goes.
    enum Destination {
        case app(URL, name: String)
        case website(URL, host: String)

        var title: String {
            switch self {
            case .app(_, let name):     return "Open \(name)"
            case .website(_, let host): return "Open \(host)"
            }
        }

        var help: String {
            switch self {
            case .app(_, let name):
                return "Opens \(name), which is where this account is signed in."
            case .website(_, let host):
                return "Opens \(host) in your browser. That site has its own sign-in, "
                     + "separate from the credential read here."
            }
        }
    }

    /// The owning app when it is installed, the vendor's page otherwise.
    private var destination: Destination? {
        if case .openApp(let bundleID, let name) = provider.signIn,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return .app(app, name: name)
        }
        // Claude Code is a command with no app to open, so its row is always a
        // link — and claude.ai is genuinely where its usage can be checked.
        if let url = provider.account?.manageURL, let host = url.host {
            return .website(url, host: host)
        }
        return nil
    }

    private func open(_ destination: Destination) {
        switch destination {
        case .app(let url, _):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .website(let url, _):
            NSWorkspace.shared.open(url)
        }
    }

    /// Offering to open an app that isn't installed gives a button that does
    /// nothing — worse than no button.
    private var canOpenSignIn: Bool {
        switch provider.signIn {
        case .modal:
            return true
        case .openApp(let bundleID, _):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        case .guidance:
            return false
        }
    }

    /// One control for both directions: on signs in, off signs out.
    ///
    /// Switching on does more than set a flag — if there is no credential to
    /// read it opens the sign-in there and then, which is the point of managing
    /// this from one place. Switching off is a real sign-out: it forgets the
    /// readings as well as stopping the next one.
    private var binding: Binding<Bool> {
        Binding(
            get: { preferences.isConnected(provider.id) },
            set: { wantsOn in
                if wantsOn {
                    preferences.setConnected(true, for: provider.id)
                    // Nothing to open for Claude Code — but then there is no
                    // account either, so `detail` is already showing what to do.
                    _ = signIn(provider.id)
                } else {
                    signOut(provider.id)
                    preferences.setConnected(false, for: provider.id)
                }
            }
        )
    }

}
