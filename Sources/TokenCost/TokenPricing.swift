import Foundation

/// Per-model prices and cost math, ported from CodexBar's `CostUsagePricing`.
///
/// Only models with publicly listed rates are priced; everything else still
/// counts tokens but reports no cost rather than a guessed one. Rates are
/// $/token (multiply by 1M for the familiar $/1M tokens).
///
/// Normalisation matches CodexBar: lowercase, strip vendor prefixes
/// (`openai/`, `anthropic.`), drop Vertex suffixes (`@…`), strip trailing
/// date tags (`-20250929`, `-2025-09-29`).
enum TokenPricing {
    struct Rates {
        let input: Double
        let output: Double
        /// Price of re-reading cached input. Nil means billed at the input rate.
        let cacheRead: Double?
        /// Price of writing the cache. Nil means billed at the input rate.
        let cacheWrite: Double?
        /// Long-context threshold on counted input tokens, with the rates past it.
        let threshold: Double?
        let aboveInput: Double?
        let aboveOutput: Double?
        let aboveCacheRead: Double?
        let aboveCacheWrite: Double?

        init(input: Double, output: Double,
             cacheRead: Double? = nil, cacheWrite: Double? = nil,
             threshold: Double? = nil,
             aboveInput: Double? = nil, aboveOutput: Double? = nil,
             aboveCacheRead: Double? = nil, aboveCacheWrite: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.threshold = threshold
            self.aboveInput = aboveInput
            self.aboveOutput = aboveOutput
            self.aboveCacheRead = aboveCacheRead
            self.aboveCacheWrite = aboveCacheWrite
        }
    }

    /// Exact table. `$X` comments are $/1M tokens for readability.
    ///
    /// The `gpt-5.6-*` rows mirror CodexBar's bundled table (long-context
    /// threshold 272k like the rest of the family): they are the models real
    /// Codex rollouts report, so leaving them unpriced would zero out the
    /// cost beside most of a Codex user's tokens.
    private static let table: [String: Rates] = [
        // Codex models
        "gpt-5":      .init(input: 1.25e-6, output: 1e-5, cacheRead: 1.25e-7),   // $1.25 / $10
        "gpt-5-mini": .init(input: 2.5e-7, output: 2e-6, cacheRead: 2.5e-8),     // $0.25 / $2
        "gpt-5.6-terra": .init(
            input: 2e-6, output: 1.2e-5, cacheRead: 2e-7, cacheWrite: 2.5e-6,    // $2 / $12
            threshold: 272_000,
            aboveInput: 4e-6, aboveOutput: 1.8e-5,
            aboveCacheRead: 4e-7, aboveCacheWrite: 5e-6),
        "gpt-5.6-luna": .init(
            input: 2e-7, output: 1.2e-6, cacheRead: 2e-8, cacheWrite: 2.5e-7,    // $0.20 / $1.20
            threshold: 272_000,
            aboveInput: 4e-7, aboveOutput: 1.8e-6,
            aboveCacheRead: 4e-8, aboveCacheWrite: 5e-7),
        // Claude models
        "claude-sonnet-4-5": .init(
            input: 3e-6, output: 1.5e-5, cacheRead: 3e-7, cacheWrite: 3.75e-6,   // $3 / $15
            threshold: 200_000,
            aboveInput: 6e-6, aboveOutput: 2.25e-5,
            aboveCacheRead: 6e-7, aboveCacheWrite: 7.5e-6),
        "claude-opus-4-5": .init(
            input: 5e-6, output: 2.5e-5, cacheRead: 5e-7, cacheWrite: 6.25e-6),  // $5 / $25
        "claude-opus-4-1": .init(
            input: 1.5e-5, output: 7.5e-5, cacheRead: 1.5e-6, cacheWrite: 1.875e-5), // $15 / $75
        "claude-haiku-4-5": .init(
            input: 1e-6, output: 5e-6, cacheRead: 1e-7, cacheWrite: 1.25e-6),    // $1 / $5
    ]

    /// Model names billed at another key's rates (same price, other label).
    private static let aliases: [String: String] = [
        "gpt-5-codex": "gpt-5",
        "gpt-5.1": "gpt-5",
        "gpt-5.1-codex": "gpt-5",
        "claude-sonnet-4-5-20250929": "claude-sonnet-4-5",
        "claude-opus-4-5-20251101": "claude-opus-4-5",
        "claude-haiku-4-5-20251001": "claude-haiku-4-5",
    ]

    /// Canonical key for a raw model string, for bucketing a day's tokens.
    static func normalize(_ raw: String?) -> String {
        guard var model = raw?.lowercased(), !model.isEmpty else { return "unknown" }
        for prefix in ["openai/", "anthropic.", "anthropic/"] where model.hasPrefix(prefix) {
            model.removeFirst(prefix.count)
        }
        if let at = model.firstIndex(of: "@") { model = String(model[..<at]) }
        model = model.replacingOccurrences(of: "-\\d{8}$", with: "", options: .regularExpression)
        model = model.replacingOccurrences(of: "-\\d{4}-\\d{2}-\\d{2}$", with: "", options: .regularExpression)
        return model
    }

    static func rates(for normalizedModel: String) -> Rates? {
        if let exact = table[normalizedModel] { return exact }
        if let alias = aliases[normalizedModel] { return table[alias] }
        return nil
    }

    /// Codex-style turn: cached input is a subset of input, cache writes a
    /// subset of the rest (CodexBar parity). Long-context rates apply past
    /// the threshold, as the vendor bills them.
    static func codexCost(model: String, input: Double, cached: Double,
                          write: Double = 0, output: Double) -> Double? {
        guard let rates = rates(for: model) else { return nil }
        let cachedClamped = min(max(cached, 0), max(input, 0))
        let fresh = max(input - cachedClamped, 0)
        let written = min(max(write, 0), fresh)
        let freshUncached = fresh - written
        if let threshold = rates.threshold, input > threshold {
            return freshUncached * (rates.aboveInput ?? rates.input)
                + written * (rates.aboveCacheWrite ?? rates.cacheWrite ?? rates.input)
                + cachedClamped * (rates.aboveCacheRead ?? rates.cacheRead ?? rates.input)
                + output * (rates.aboveOutput ?? rates.output)
        }
        return freshUncached * rates.input
            + written * (rates.cacheWrite ?? rates.input)
            + cachedClamped * (rates.cacheRead ?? rates.input)
            + output * rates.output
    }

    /// Claude-style event: cache creation is billed at the write rate (1h cache
    /// at twice the input rate, CodexBar parity), reads at the read rate.
    static func claudeCost(model: String, input: Double, cacheRead: Double,
                           cacheCreation: Double, cacheCreation1h: Double,
                           output: Double) -> Double? {
        guard let rates = rates(for: model) else { return nil }
        let write = rates.cacheWrite ?? rates.input
        let read = rates.cacheRead ?? rates.input
        let creation1h = min(max(cacheCreation1h, 0), max(cacheCreation, 0))
        let creation5m = max(cacheCreation - creation1h, 0)
        if let threshold = rates.threshold,
           input + cacheRead + cacheCreation > threshold {
            return input * (rates.aboveInput ?? rates.input)
                + cacheRead * (rates.aboveCacheRead ?? read)
                + creation5m * (rates.aboveCacheWrite ?? write)
                + creation1h * 2 * (rates.aboveInput ?? rates.input)
                + output * (rates.aboveOutput ?? rates.output)
        }
        return input * rates.input
            + cacheRead * read
            + creation5m * write
            + creation1h * 2 * rates.input
            + output * rates.output
    }
}
