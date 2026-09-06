import AppKit
import Combine
import Foundation
import SQLite3

/// Reads what Cursor's agents are doing from the editor's own state store.
///
/// Cursor publishes no session registry the way Claude Code does, but its
/// `composerHeaders` rows carry the two facts that matter:
///
/// - `unfinishedRunAt` — set while a run is in flight, cleared when it finishes.
/// - `hasBlockingPendingActions` / `hasPendingPlan` — set when it wants you.
///
/// The database is in **WAL mode**, so it must be opened without `immutable`:
/// that flag tells SQLite to ignore the write-ahead log, which means reading
/// whatever was true at the last checkpoint. It is the difference between a
/// spinner that tracks the agent and one that lags minutes behind.
@MainActor
final class CursorActivityMonitor: ObservableObject, AgentActivityMonitor {
    @Published private(set) var sessions: [AgentSession] = []
    var sessionsPublisher: AnyPublisher<[AgentSession], Never> { $sessions.eraseToAnyPublisher() }

    private let store: URL
    private let interval: TimeInterval
    private var timer: Timer?

    init(store: URL = CursorCredentials.storeURL, interval: TimeInterval = 2) {
        self.store = store
        self.interval = interval
    }

    func start() {
        rescan()
        // Polled rather than watched: the interesting writes land in the WAL
        // sidecar, and a directory event tells us a byte moved, not that a run
        // started. Two seconds is well inside "did that finish yet?".
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func rescan() {
        let found = Self.read(store: store)
        guard found != sessions else { return }
        sessions = found
    }

    static func read(store: URL) -> [AgentSession] {
        guard let db = SQLiteStore.open(store) else { return [] }
        defer { sqlite3_close(db) }

        let values = SQLiteStore.rows(
            in: db,
            sql: "SELECT value FROM composerHeaders WHERE isArchived = 0 ORDER BY recency DESC LIMIT 40"
        )
        return values.compactMap(session(fromHeader:)).sorted { $0.since > $1.since }
    }

    /// Only sessions that are *doing* something are worth a row — an editor
    /// with forty idle chats in its history is not forty things happening.
    static func session(fromHeader json: String) -> AgentSession? {
        guard let data = json.data(using: .utf8),
              let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = head["composerId"] as? String
        else { return nil }

        let blocked = (head["hasBlockingPendingActions"] as? Bool) == true
            || (head["hasPendingPlan"] as? Bool) == true
        let running = (head["unfinishedRunAt"] as? NSNumber)?.doubleValue

        let state: AgentSession.State
        if blocked { state = .waiting }
        else if running != nil { state = .busy }
        else { return nil }

        let millis = running
            ?? (head["lastUpdatedAt"] as? NSNumber)?.doubleValue
            ?? (head["createdAt"] as? NSNumber)?.doubleValue

        return AgentSession(
            id: "cursor.\(id)",
            name: (head["name"] as? String) ?? "Untitled chat",
            detail: (head["subtitle"] as? String) ?? "Cursor",
            state: state,
            waitingFor: blocked ? "needs your input" : nil,
            since: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        )
    }
}
