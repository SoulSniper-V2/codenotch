import Foundation

/// What one provider burned, estimated from its local logs.
///
/// A summary exists only when the ledger holds tokens inside the window —
/// providers without logs (Cursor, Grok, Gemini) simply have no section,
/// never a zeroed one. Every figure is an estimate (`~` in the UI): logs
/// undercount cached reads on some builds and forks can double-count a turn.
/// The vendor's own percentage is the truth; this is the receipt.
struct CostSummary: Equatable {
    let todayTokens: Double
    /// Nil when none of today's tokens had a listed price.
    let todayCostUSD: Double?
    let monthTokens: Double
    /// Nil when none of the window's tokens had a listed price.
    let monthCostUSD: Double?

    /// Rows the tooltip draws, leading/trailing pairs.
    var rows: [(String, String)] {
        [
            ("Tokens today", CostFormat.tokensWithCost(todayTokens, cost: todayCostUSD)),
            ("Last 30 days", CostFormat.tokensWithCost(monthTokens, cost: monthCostUSD)),
        ]
    }

    var lineCount: Int { rows.count }
}

enum CostFormat {
    /// 950 · 12.4K · 2.1M · 1.2B, no decimals under a thousand.
    static func tokens(_ value: Double) -> String {
        switch value {
        case ..<1_000: return "\(Int(value.rounded()))"
        case ..<1_000_000: return trimmed(value / 1_000) + "K"
        case ..<1_000_000_000: return trimmed(value / 1_000_000) + "M"
        default: return trimmed(value / 1_000_000_000) + "B"
        }
    }

    static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// "2.1M · ~$1.24", or just "2.1M" when nothing was priced.
    static func tokensWithCost(_ value: Double, cost: Double?) -> String {
        guard let cost else { return tokens(value) }
        return "\(tokens(value)) · ~\(usd(cost))"
    }

    private static func trimmed(_ value: Double) -> String {
        value >= 100 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
    }
}

/// Owns the token ledger: scans local agent logs, prices them, persists.
///
/// CodexBar keeps this in SQLite with a 25k-row budget; at this app's scale a
/// versioned JSON ledger in Application Support does the same job with no
/// schema to migrate: per-file cursors (mtime, size, parsed bytes) make
/// refreshes incremental, per-file per-day buckets make them exact, and the
/// whole file is a few hundred KB.
///
/// Refreshes run at most every 15 minutes and never on the main thread; the
/// store publishes only the resulting summaries.
@MainActor
final class TokenCostStore: ObservableObject {
    struct FileLedger: Codable {
        /// "codex" or "claude" — decides the pricing function, not the files:
        /// the roots are what attribute spend, never the model name.
        var provider: String
        var mtime: Double
        var size: UInt64
        var parsedBytes: UInt64
        var tailKeys: [String]
        var totals: LogScanner.TotalsState?
        /// Model in force at the last scanned byte, for resume.
        var lastModel: String?
        /// dayKey -> normalized model -> bucket
        var days: [String: [String: LogScanner.DayBucket]]
    }

    private struct Persisted: Codable {
        var version: Int
        var files: [String: FileLedger]
    }

    @Published private(set) var summaries: [String: CostSummary] = [:]
    @Published private(set) var lastScan: Date?

    static let refreshInterval: TimeInterval = 15 * 60
    static let maxFilesPerRefresh = 300
    static let retentionDays = 92
    /// Bumped when the ledger shape changes (v2: per-bucket cache writes +
    /// file model context). Old files are rescanned, never migrated.
    private static let version = 2

    private var ledgers: [String: FileLedger] = [:]
    private var loaded = false
    private var lastRefresh: Date?
    private var lastSave: Date?

    func refresh(disabledProviders: Set<String> = [], force: Bool = false) async {
        if !loaded { load(); loaded = true }
        let now = Date()
        if !force, let last = lastRefresh, now.timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        lastRefresh = now

        let snapshot = ledgers
        let scanned = await Task.detached(priority: .utility) {
            Self.scan(ledgers: snapshot, disabled: disabledProviders, now: now)
        }.value
        ledgers = scanned.ledgers
        summaries = scanned.summaries
        lastScan = now
        saveIfDirty()
    }

    // MARK: - Scan (off the main thread)

    private struct ScanResult {
        var ledgers: [String: FileLedger]
        var summaries: [String: CostSummary]
    }

    private nonisolated static func scan(ledgers: [String: FileLedger],
                             disabled: Set<String>, now: Date) -> ScanResult {
        var ledgers = ledgers
        let monthCutoff = cutoffKey(daysBack: 29, now: now)
        let pruneCutoff = cutoffKey(daysBack: retentionDays - 1, now: now)

        let jobs: [(provider: String, roots: [URL], kind: Kind)] = [
            ("codex", LogScanner.codexRoots(), .codex),
            ("claude", LogScanner.claudeRoots(), .claude),
        ]

        for job in jobs {
            guard !disabled.contains(job.provider) else { continue }
            let files = LogScanner.jsonlFiles(under: job.roots)
            let onDisk = Set(files.map(\.path))
            // Logs rotate: ledgers for vanished files go with them.
            ledgers = ledgers.filter {
                $0.value.provider != job.provider || onDisk.contains($0.key)
            }

            var scanned = 0
            for url in files {
                if scanned >= maxFilesPerRefresh { break }
                let path = url.path
                let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                if var ledger = ledgers[path],
                   ledger.mtime == mtime, ledger.size == size {
                    continue  // cursor still valid: nothing new to read
                }
                scanned += 1

                let previous = ledgers[path]
                let resumeFrom = (previous != nil && size >= (previous?.size ?? 0))
                    ? (previous?.parsedBytes ?? 0) : 0
                let result: LogScanner.FileResult
                switch job.kind {
                case .codex:
                    result = LogScanner.scanCodex(
                        url: url, from: resumeFrom,
                        knownKeys: Set(previous?.tailKeys ?? []),
                        lastTotals: resumeFrom > 0 ? previous?.totals : nil,
                        lastModel: resumeFrom > 0 ? previous?.lastModel : nil)
                case .claude:
                    result = LogScanner.scanClaude(
                        url: url, from: resumeFrom,
                        knownKeys: Set(previous?.tailKeys ?? []))
                }

                var merged = previous?.days ?? [:]
                for (day, models) in result.days {
                    for (model, bucket) in models {
                        var base = merged[day, default: [:]][model] ?? LogScanner.DayBucket()
                        base.input += bucket.input
                        base.cacheRead += bucket.cacheRead
                        base.cacheWrite += bucket.cacheWrite
                        base.cacheCreation += bucket.cacheCreation
                        base.cacheCreation1h += bucket.cacheCreation1h
                        base.output += bucket.output
                        base.reasoning += bucket.reasoning
                        base.requests += bucket.requests
                        merged[day, default: [:]][model] = base
                    }
                }
                // A shrunk file was rotated: its old bytes are gone, so its old
                // buckets go with them and the scan starts over.
                if resumeFrom == 0 { merged = result.days }
                for day in merged.keys where day < pruneCutoff { merged.removeValue(forKey: day) }

                ledgers[path] = FileLedger(
                    provider: job.provider, mtime: mtime, size: size,
                    parsedBytes: result.bytesRead,
                    tailKeys: result.tailKeys,
                    totals: result.totals ?? previous?.totals,
                    lastModel: result.lastModel ?? previous?.lastModel,
                    days: merged)
            }
        }

        // Drop summaries for switched-off providers: off means unread.
        var summaries: [String: CostSummary] = [:]
        for job in jobs where !disabled.contains(job.provider) {
            if let summary = summarize(ledgers: ledgers, provider: job.provider,
                                       kind: job.kind, monthCutoff: monthCutoff,
                                       today: LogScanner.todayKey(now: now)) {
                summaries[job.provider] = summary
            }
        }
        return ScanResult(ledgers: ledgers, summaries: summaries)
    }

    private enum Kind { case codex, claude }

    private nonisolated static func summarize(ledgers: [String: FileLedger], provider: String,
                                 kind: Kind, monthCutoff: String,
                                 today: String) -> CostSummary? {
        var todayTokens = 0.0, todayCost = 0.0, todayPriced = false
        var monthTokens = 0.0, monthCost = 0.0, monthPriced = false
        var any = false

        for ledger in ledgers.values where ledger.provider == provider {
            for (day, models) in ledger.days where day >= monthCutoff {
                for (model, bucket) in models {
                    any = true
                    let tokens = bucket.total
                    let cost: Double?
                    switch kind {
                    case .codex:
                        cost = TokenPricing.codexCost(
                            model: model, input: bucket.input,
                            cached: bucket.cacheRead, write: bucket.cacheWrite,
                            output: bucket.output)
                    case .claude:
                        cost = TokenPricing.claudeCost(
                            model: model, input: bucket.input, cacheRead: bucket.cacheRead,
                            cacheCreation: bucket.cacheCreation,
                            cacheCreation1h: bucket.cacheCreation1h, output: bucket.output)
                    }
                    monthTokens += tokens
                    if let cost { monthCost += cost; monthPriced = true }
                    if day == today {
                        todayTokens += tokens
                        if let cost { todayCost += cost; todayPriced = true }
                    }
                }
            }
        }
        guard any, monthTokens > 0 else { return nil }
        return CostSummary(
            todayTokens: todayTokens,
            todayCostUSD: todayPriced ? todayCost : nil,
            monthTokens: monthTokens,
            monthCostUSD: monthPriced ? monthCost : nil)
    }

    private nonisolated static func cutoffKey(daysBack: Int, now: Date) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -daysBack, to: now) ?? now
        return LogScanner.todayKey(now: day)
    }

    // MARK: - Persistence

    private static func storeURL() -> URL? {
        let bundle = Bundle.main.bundleIdentifier ?? "com.soulsniper.codenotch"
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent(bundle).appendingPathComponent("tokencost.json")
    }

    private func load() {
        guard let url = Self.storeURL(),
              let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data),
              persisted.version == Self.version
        else { return }
        ledgers = persisted.files
    }

    private func saveIfDirty() {
        let now = Date()
        if let last = lastSave, now.timeIntervalSince(last) < 30 { return }
        lastSave = now
        guard let url = Self.storeURL() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let persisted = Persisted(version: Self.version, files: ledgers)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
