import Foundation

/// Incremental JSONL scanners for local agent logs, after CodexBar's
/// `CostUsageScanner` family — simplified, with the simplifications stated.
///
/// What is kept:
/// - Codex `~/.codex/sessions/**/*.jsonl` `token_count` events. Per-turn
///   `last_token_usage` deltas are summed (no watermark bookkeeping); files
///   carrying only cumulative `total_token_usage` are diffed against the
///   persisted per-file totals, rebasing on a backward step (fork) rather than
///   counting negative.
/// - Claude `~/.claude/projects/**/*.jsonl` (+ `~/.config/claude`) `assistant`
///   messages with `usage` blocks, summed as events.
/// - Dedup by turn/message id, falling back to the line's byte offset (stable
///   for append-only logs, which these are).
/// - Resume from a byte offset: only bytes past the last newline are consumed,
///   so a chunk boundary never eats a line.
///
/// What is deliberately not ported: fork-lineage inheritance for missing
/// parents (those turns count as unpriced-but-counted here, never silently
/// dropped), Vertex filtering (still spend), subagent separation (still
/// spend). The tooltip qualifies every figure with `~`: an estimate built from
/// logs, never the vendor's own number.
enum LogScanner {
    /// Tokens for one model on one day.
    struct DayBucket: Codable, Equatable {
        var input: Double = 0
        var cacheRead: Double = 0
        var cacheWrite: Double = 0
        var cacheCreation: Double = 0
        var cacheCreation1h: Double = 0
        var output: Double = 0
        var reasoning: Double = 0
        var requests: Int = 0

        var total: Double { input + output }
    }

    /// Cumulative totals remembered per file for `total_token_usage` diffing.
    struct TotalsState: Codable, Equatable {
        var input: Double = 0
        var cached: Double = 0
        var write: Double = 0
        var output: Double = 0
    }

    struct FileResult {
        /// dayKey -> normalized model -> bucket
        var days: [String: [String: DayBucket]] = [:]
        /// Absolute offset consumed through the last complete newline.
        var bytesRead: UInt64 = 0
        /// Most recent dedup keys, oldest first (persist the tail).
        var tailKeys: [String] = []
        var totals: TotalsState?
        /// Model in force at the end of the scan (persist for resume).
        var lastModel: String?
    }

    static let maxLineBytes = 2 * 1024 * 1024
    static let tailKeyCount = 400

    // MARK: - Roots

    static func codexRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return [URL(fileURLWithPath: custom).appendingPathComponent("sessions")]
        }
        let sessions = home.appendingPathComponent(".codex/sessions")
        return [sessions, home.appendingPathComponent(".codex/archived_sessions")]
    }

    static func claudeRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var roots = [home.appendingPathComponent(".claude/projects")]
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            roots.append(URL(fileURLWithPath: dir).appendingPathComponent("projects"))
        } else {
            roots.append(home.appendingPathComponent(".config/claude/projects"))
        }
        return roots
    }

    /// Every `*.jsonl` under the roots, newest first so a per-refresh file cap
    /// always spends itself on the freshest logs.
    static func jsonlFiles(under roots: [URL]) -> [URL] {
        var found: [URL] = []
        let manager = FileManager.default
        for root in roots {
            guard let enumerator = manager.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                found.append(url)
            }
        }
        return found.sorted {
            mtime(of: $0) > mtime(of: $1)
        }
    }

    static func mtime(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    // MARK: - Codex

    /// Scan one Codex rollout from `offset`, consuming at most `maxBytes`.
    ///
    /// Token events carry no model of their own — the model rides on
    /// `turn_context` / `session_meta` / `thread_settings_applied` lines — so
    /// the scan carries the latest one seen in file order and attributes each
    /// turn to it (CodexBar's "turn model context"). Pass the persisted
    /// `lastModel` back in when resuming.
    static func scanCodex(
        url: URL,
        from offset: UInt64 = 0,
        maxBytes: UInt64 = 64 * 1024 * 1024,
        knownKeys: Set<String> = [],
        lastTotals: TotalsState? = nil,
        lastModel: String? = nil,
        fallbackDay: String? = nil
    ) -> FileResult {
        var result = FileResult()
        result.totals = lastTotals
        var seen = knownKeys
        var recent: [String] = []
        var currentModel = lastModel

        let fallback = fallbackDay ?? dayKey(for: mtime(of: url)) ?? "unknown"
        guard let handle = try? FileHandle(forReadingFrom: url) else { return result }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard offset < fileSize else { return result }
        let end = min(fileSize, offset + maxBytes)

        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(end - offset))) ?? Data()
        // Only whole lines: the tail past the last newline stays for next time.
        let text = String(decoding: data, as: UTF8.self)
        guard let lastNewline = text.lastIndex(of: "\n") else { return result }
        let consumable = String(text[..<lastNewline])
        result.bytesRead = offset + UInt64(consumable.utf8.count) + 1

        var cursor = offset
        for rawLine in consumable.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStart = cursor
            cursor += UInt64(rawLine.utf8.count) + 1
            guard !rawLine.isEmpty,
                  rawLine.utf8.count <= maxLineBytes,
                  Self.isCodexRelevant(rawLine),
                  let line = rawLine.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }

            // Model context rides separately from the token events: remember
            // the latest one so the turns below land on the right model.
            if let model = Self.codexModelContext(in: obj) {
                currentModel = model
                continue
            }

            guard (obj["type"] as? String) == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count"
            else { continue }

            let key = codexTurnKey(payload: payload, offset: lineStart)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            recent.append(key)

            let info = payload["info"] as? [String: Any] ?? [:]
            let model = normalizeCodexModel(
                payload["model"] as? String ?? (info["model"] as? String)
                    ?? payload["model_name"] as? String ?? (info["model_name"] as? String)
                    ?? currentModel)
            let day = dayKey(for: parseDate(obj["timestamp"] as? String)) ?? fallback

            if let last = info["last_token_usage"] as? [String: Any] {
                addCodexDelta(&result, day: day, model: model, usage: last)
            } else if let total = info["total_token_usage"] as? [String: Any] {
                diffCodexTotals(&result, day: day, model: model, total: total)
            }
        }
        result.tailKeys = Array((Array(knownKeys.suffix(tailKeyCount / 2)) + recent).suffix(tailKeyCount))
        result.lastModel = currentModel
        return result
    }

    private static func isCodexRelevant(_ line: Substring) -> Bool {
        line.contains("token_count") || line.contains("turn_context")
            || line.contains("thread_settings_applied") || line.contains("session_meta")
    }

    /// The model in force on a context line, if this line is one.
    private static func codexModelContext(in obj: [String: Any]) -> String? {
        guard let type = obj["type"] as? String else { return nil }
        if type == "turn_context" || type == "session_meta",
           let payload = obj["payload"] as? [String: Any],
           let model = payload["model"] as? String, !model.isEmpty {
            return TokenPricing.normalize(model)
        }
        if type == "event_msg",
           let payload = obj["payload"] as? [String: Any],
           (payload["type"] as? String) == "thread_settings_applied",
           let model = payload["model"] as? String, !model.isEmpty {
            return TokenPricing.normalize(model)
        }
        return nil
    }

    private static func codexTurnKey(payload: [String: Any], offset: UInt64) -> String {
        for field in ["turn_id", "turnId", "ordinal"] {
            if let value = payload[field] { return "turn:\(value)" }
        }
        return "off:\(offset)"
    }

    private static func addCodexDelta(_ result: inout FileResult, day: String,
                                     model: String, usage: [String: Any]) {
        let input = number(usage["input_tokens"])
        let cached = max(number(usage["cached_input_tokens"]),
                         number(usage["cache_read_input_tokens"]))
        let write = number(usage["cache_write_input_tokens"])
        let output = number(usage["output_tokens"])
        var reasoning = number(usage["reasoning_output_tokens"])
        reasoning = min(max(reasoning, 0), max(output, 0))
        guard input > 0 || output > 0 else { return }
        var bucket = result.days[day, default: [:]][model] ?? DayBucket()
        bucket.input += input
        bucket.cacheRead += min(cached, input)
        bucket.cacheWrite += min(write, max(input - min(cached, input), 0))
        bucket.output += output
        bucket.reasoning += reasoning
        bucket.requests += 1
        result.days[day, default: [:]][model] = bucket
    }

    private static func diffCodexTotals(_ result: inout FileResult, day: String,
                                       model: String, total: [String: Any]) {
        let input = number(total["input_tokens"])
        let cached = max(number(total["cached_input_tokens"]),
                         number(total["cache_read_input_tokens"]))
        let write = number(total["cache_write_input_tokens"])
        let output = number(total["output_tokens"])
        let previous = result.totals ?? TotalsState()
        // A backward step is a fork or a reset, not negative spend: rebase and
        // count the branch from its own totals.
        let dInput = input >= previous.input ? input - previous.input : input
        let dCached = cached >= previous.cached ? cached - previous.cached : cached
        let dWrite = write >= previous.write ? write - previous.write : write
        let dOutput = output >= previous.output ? output - previous.output : output
        result.totals = TotalsState(input: input, cached: cached, write: write, output: output)
        guard dInput > 0 || dOutput > 0 else { return }
        var bucket = result.days[day, default: [:]][model] ?? DayBucket()
        bucket.input += dInput
        bucket.cacheRead += min(dCached, dInput)
        bucket.cacheWrite += min(dWrite, max(dInput - min(dCached, dInput), 0))
        bucket.output += dOutput
        bucket.requests += 1
        result.days[day, default: [:]][model] = bucket
    }

    private static func normalizeCodexModel(_ raw: String?) -> String {
        TokenPricing.normalize(raw)
    }

    // MARK: - Claude

    /// Scan one Claude project log from `offset`, consuming at most `maxBytes`.
    static func scanClaude(
        url: URL,
        from offset: UInt64 = 0,
        maxBytes: UInt64 = 64 * 1024 * 1024,
        knownKeys: Set<String> = [],
        fallbackDay: String? = nil
    ) -> FileResult {
        var result = FileResult()
        var seen = knownKeys
        var recent: [String] = []

        let fallback = fallbackDay ?? dayKey(for: mtime(of: url)) ?? "unknown"
        guard let handle = try? FileHandle(forReadingFrom: url) else { return result }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard offset < fileSize else { return result }
        let end = min(fileSize, offset + maxBytes)

        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(end - offset))) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard let lastNewline = text.lastIndex(of: "\n") else { return result }
        let consumable = String(text[..<lastNewline])
        result.bytesRead = offset + UInt64(consumable.utf8.count) + 1

        var cursor = offset
        for rawLine in consumable.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStart = cursor
            cursor += UInt64(rawLine.utf8.count) + 1
            guard !rawLine.isEmpty,
                  rawLine.utf8.count <= maxLineBytes,
                  rawLine.contains(#""type":"assistant""#) || rawLine.contains(#""type": "assistant""#),
                  rawLine.contains("usage"),
                  let line = rawLine.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let messageID = message["id"] as? String ?? ""
            let requestID = obj["requestId"] as? String ?? ""
            let key = (!messageID.isEmpty || !requestID.isEmpty)
                ? "msg:\(messageID):\(requestID)" : "off:\(lineStart)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            recent.append(key)

            let input = number(usage["input_tokens"])
            let read = number(usage["cache_read_input_tokens"])
            var creation = number(usage["cache_creation_input_tokens"])
            var creation1h = 0.0
            if let ephemeral = usage["cache_creation"] as? [String: Any] {
                creation1h = number(ephemeral["ephemeral_1h_input_tokens"])
                creation = max(creation, creation1h)
            }
            creation1h = min(creation1h, creation)
            let output = number(usage["output_tokens"])
            guard input > 0 || output > 0 else { continue }

            let model = TokenPricing.normalize(message["model"] as? String)
            let day = dayKey(for: parseDate(obj["timestamp"] as? String)) ?? fallback
            var bucket = result.days[day, default: [:]][model] ?? DayBucket()
            bucket.input += input
            bucket.cacheRead += read
            bucket.cacheCreation += creation
            bucket.cacheCreation1h += creation1h
            bucket.output += output
            bucket.requests += 1
            result.days[day, default: [:]][model] = bucket
        }
        result.tailKeys = Array((Array(knownKeys.suffix(tailKeyCount / 2)) + recent).suffix(tailKeyCount))
        return result
    }

    // MARK: - Shared

    static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Local-calendar day key, CodexBar parity: spend belongs to the day it
    /// happened *here*, not in UTC.
    static func dayKey(for date: Date?) -> String? {
        guard let date else { return nil }
        return dayFormatter.string(from: date)
    }

    static func todayKey(now: Date = Date()) -> String {
        dayFormatter.string(from: now)
    }
}
