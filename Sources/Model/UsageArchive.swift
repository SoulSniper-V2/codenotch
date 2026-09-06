import Foundation

/// The last good reading for each provider, remembered across launches.
///
/// Without this, a cold start that cannot reach the endpoint — rate limited,
/// offline, token expired — shows nothing at all, which is the least useful
/// thing the notch could do. A remembered reading is dimmed and dated, but a
/// dated number you can see beats a blank ring.
struct UsageArchive {
    private struct Entry: Codable {
        let id: String
        let displayName: String
        let glyph: ProviderGlyph
        let fidelity: Fidelity
        let windows: [LimitWindow]
        let fetchedAt: Date
    }

    private let defaults: UserDefaults
    private let key = "lastGoodReadings"
    private let backoffKey = "backoffUntil"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Back-off

    /// When the endpoint may next be called, remembered across launches.
    ///
    /// Without this, every relaunch starts with a clean slate and fires a
    /// request immediately — so a development loop of `make run` walks straight
    /// into the rate limit it is being punished by, and keeps the punishment
    /// alive. Which is exactly what happened.
    func loadBackoffUntil() -> Date? {
        guard let date = defaults.object(forKey: backoffKey) as? Date, date > Date() else {
            return nil
        }
        return date
    }

    func saveBackoffUntil(_ date: Date?) {
        if let date {
            defaults.set(date, forKey: backoffKey)
        } else {
            defaults.removeObject(forKey: backoffKey)
        }
    }

    func load() -> [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [:] }

        var result: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)] = [:]
        for entry in entries {
            let snapshot = ProviderSnapshot(
                id: entry.id,
                displayName: entry.displayName,
                glyph: entry.glyph,
                fidelity: entry.fidelity,
                status: .stale(since: entry.fetchedAt),
                windows: entry.windows
            )
            result[entry.id] = (snapshot, entry.fetchedAt)
        }
        return result
    }

    func save(_ readings: [String: (snapshot: ProviderSnapshot, fetchedAt: Date)]) {
        let entries = readings.values.map {
            Entry(
                id: $0.snapshot.id,
                displayName: $0.snapshot.displayName,
                glyph: $0.snapshot.glyph,
                fidelity: $0.snapshot.fidelity,
                windows: $0.snapshot.windows,
                fetchedAt: $0.fetchedAt
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Drop what we remember about one provider.
    ///
    /// Signing out has to reach this, or the notch keeps showing the last
    /// reading — dimmed and dated, but still that account's numbers, still on
    /// screen after the next launch.
    func forget(_ providerID: String) {
        var readings = load()
        readings.removeValue(forKey: providerID)
        save(readings)
    }
}
