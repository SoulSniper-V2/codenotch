import XCTest
@testable import Codenotch

/// The token/cost ledger: pricing math, log scanners, formatting.
final class TokenPricingTests: XCTestCase {
    func testCodexPricesKnownModels() {
        // gpt-5: $1.25 in / $10 out / $0.125 cached per 1M.
        let cost = TokenPricing.codexCost(model: "gpt-5", input: 1_000, cached: 200, output: 500)
        XCTAssertEqual(cost ?? -1, 0.006025, accuracy: 1e-9)
    }

    func testTerraPricesFromTheFamilyTable() {
        // gpt-5.6-terra: $2 in / $12 out per 1M, no cache on this turn.
        let cost = TokenPricing.codexCost(model: "gpt-5.6-terra", input: 1_000, cached: 0,
                                          output: 500)
        XCTAssertEqual(cost ?? -1, 1_000 * 2e-6 + 500 * 1.2e-5, accuracy: 1e-9)
    }

    func testUnknownModelsCountTokensButPriceNothing() {
        XCTAssertNil(TokenPricing.codexCost(model: "grok-code-fast-1", input: 1_000, cached: 0, output: 500))
        XCTAssertNil(TokenPricing.claudeCost(model: "some-future-model", input: 1, cacheRead: 0,
                                             cacheCreation: 0, cacheCreation1h: 0, output: 1))
    }

    func testAliasesShareARate() {
        let a = TokenPricing.codexCost(model: "gpt-5-codex", input: 1_000, cached: 0, output: 0)
        let b = TokenPricing.codexCost(model: "gpt-5", input: 1_000, cached: 0, output: 0)
        XCTAssertEqual(a, b)
    }

    func testNormalizationStripsVendorAndDates() {
        XCTAssertEqual(TokenPricing.normalize("claude-sonnet-4-5-20250929"), "claude-sonnet-4-5")
        XCTAssertEqual(TokenPricing.normalize("anthropic.claude-opus-4-5"), "claude-opus-4-5")
        XCTAssertEqual(TokenPricing.normalize("GPT-5-Codex"), "gpt-5-codex")
        XCTAssertEqual(TokenPricing.normalize(nil), "unknown")
    }

    func testClaudeCacheMath() {
        // sonnet 4.5: $3 in / $15 out / $0.30 read / $3.75 write per 1M.
        let cost = TokenPricing.claudeCost(model: "claude-sonnet-4-5", input: 2_000,
                                           cacheRead: 1_000, cacheCreation: 500,
                                           cacheCreation1h: 0, output: 300)
        XCTAssertEqual(cost ?? -1, 0.012675, accuracy: 1e-9)
    }

    func testOneHourCacheCostsDouble() {
        let plain = TokenPricing.claudeCost(model: "claude-sonnet-4-5", input: 0, cacheRead: 0,
                                            cacheCreation: 1_000, cacheCreation1h: 0, output: 0)
        let oneHour = TokenPricing.claudeCost(model: "claude-sonnet-4-5", input: 0, cacheRead: 0,
                                              cacheCreation: 1_000, cacheCreation1h: 1_000, output: 0)
        XCTAssertEqual(plain ?? -1, 0.00375, accuracy: 1e-9)
        XCTAssertEqual(oneHour ?? -1, 0.006, accuracy: 1e-9)
    }
}

final class CostFormatTests: XCTestCase {
    func testCompactTokens() {
        XCTAssertEqual(CostFormat.tokens(950), "950")
        XCTAssertEqual(CostFormat.tokens(12_400), "12.4K")
        XCTAssertEqual(CostFormat.tokens(2_100_000), "2.1M")
        XCTAssertEqual(CostFormat.tokens(340_000_000), "340M")
    }

    func testCostIsQualifiedAsEstimate() {
        XCTAssertEqual(CostFormat.tokensWithCost(2_100_000, cost: 1.24), "2.1M · ~$1.24")
        XCTAssertEqual(CostFormat.tokensWithCost(500, cost: nil), "500")
    }
}

final class LogScannerTests: XCTestCase {
    private func tempFile(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func codexLine(turn: String, model: String = "gpt-5",
                           input: Double, cached: Double, output: Double,
                           stamp: String = "2026-09-05T10:00:00.000Z") -> String {
        """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count",\
        "turn_id":"\(turn)","model":"\(model)",\
        "info":{"last_token_usage":{"input_tokens":\(Int(input)),\
        "cached_input_tokens":\(Int(cached)),"output_tokens":\(Int(output))}}}}
        """
    }

    func testCodexDeltasAreSummed() throws {
        let url = try tempFile([
            codexLine(turn: "t1", input: 1000, cached: 200, output: 500),
            codexLine(turn: "t2", input: 2000, cached: 0, output: 1000),
        ])
        let result = LogScanner.scanCodex(url: url)
        let day = try XCTUnwrap(LogScanner.dayKey(for: LogScanner.parseDate("2026-09-05T10:00:00.000Z")))
        let bucket = try XCTUnwrap(result.days[day]?["gpt-5"])
        XCTAssertEqual(bucket.input, 3000)
        XCTAssertEqual(bucket.cacheRead, 200)
        XCTAssertEqual(bucket.output, 1500)
        XCTAssertEqual(bucket.requests, 2)
    }

    /// A re-emitted turn (same id) counts once.
    func testCodexDedupesTurns() throws {
        let line = codexLine(turn: "t1", input: 1000, cached: 0, output: 500)
        let url = try tempFile([line, line])
        let result = LogScanner.scanCodex(url: url)
        let day = try XCTUnwrap(result.days.keys.first)
        XCTAssertEqual(result.days[day]?["gpt-5"]?.requests, 1)
    }

    /// Cumulative-only files diff against remembered totals; a backward step
    /// is a fork, rebased rather than counted negative.
    func testCodexTotalsDiffAndRebase() throws {
        func totalLine(input: Double, cached: Double, output: Double) -> String {
            """
            {"timestamp":"2026-09-05T10:00:00.000Z","type":"event_msg",\
            "payload":{"type":"token_count","model":"gpt-5",\
            "info":{"total_token_usage":{"input_tokens":\(Int(input)),\
            "cached_input_tokens":\(Int(cached)),"output_tokens":\(Int(output))}}}}
            """
        }
        let url = try tempFile([
            totalLine(input: 100, cached: 10, output: 50),
            totalLine(input: 150, cached: 20, output: 90),
            totalLine(input: 100, cached: 5, output: 30),
        ])
        let result = LogScanner.scanCodex(url: url)
        let day = try XCTUnwrap(result.days.keys.first)
        let bucket = try XCTUnwrap(result.days[day]?["gpt-5"])
        XCTAssertEqual(bucket.input, 100 + 50 + 100)
        XCTAssertEqual(bucket.output, 50 + 40 + 30)
    }

    /// Resuming from a cursor reads only the new bytes.
    func testCodexResumeIsIncremental() throws {
        let url = try tempFile([codexLine(turn: "t1", input: 1000, cached: 0, output: 100)])
        let first = LogScanner.scanCodex(url: url)
        XCTAssertGreaterThan(first.bytesRead, 0)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: (codexLine(turn: "t2", input: 500, cached: 0, output: 50) + "\n")
            .data(using: .utf8)!)
        try handle.close()

        let second = LogScanner.scanCodex(url: url, from: first.bytesRead,
                                          knownKeys: Set(first.tailKeys))
        let day = try XCTUnwrap(second.days.keys.first)
        XCTAssertEqual(second.days[day]?["gpt-5"]?.input, 500)
        XCTAssertEqual(second.days[day]?["gpt-5"]?.requests, 1)
    }

    func testClaudeEventsAreSummed() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-09-05T11:00:00.000Z",\
        "sessionId":"s1","requestId":"r1",\
        "message":{"id":"m1","model":"claude-sonnet-4-5-20250929",\
        "usage":{"input_tokens":2000,"cache_read_input_tokens":1000,\
        "cache_creation_input_tokens":500,"output_tokens":300}}}
        """
        let url = try tempFile([line, line])  // same id twice: deduped
        let result = LogScanner.scanClaude(url: url)
        let day = try XCTUnwrap(result.days.keys.first)
        let bucket = try XCTUnwrap(result.days[day]?["claude-sonnet-4-5"])
        XCTAssertEqual(bucket.input, 2000)
        XCTAssertEqual(bucket.cacheRead, 1000)
        XCTAssertEqual(bucket.cacheCreation, 500)
        XCTAssertEqual(bucket.output, 300)
        XCTAssertEqual(bucket.requests, 1)
    }

    func testClaudeSkipsNonAssistantLines() throws {
        let url = try tempFile([
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"model":"x"}}"#,  // no usage
        ])
        XCTAssertTrue(LogScanner.scanClaude(url: url).days.isEmpty)
    }

    /// Token events carry no model; `turn_context` sets it for the turns that
    /// follow — the shape real rollouts use.
    func testCodexTurnsInheritModelContext() throws {
        let context = """
        {"timestamp":"2026-09-05T10:00:00.000Z","type":"turn_context",\
        "payload":{"turn_id":"t0","model":"gpt-5.6-terra"}}
        """
        let turn = """
        {"timestamp":"2026-09-05T10:01:00.000Z","type":"event_msg",\
        "payload":{"type":"token_count","turn_id":"t1",\
        "info":{"last_token_usage":{"input_tokens":1000,\
        "cached_input_tokens":0,"output_tokens":100}}}}
        """
        let url = try tempFile([context, turn])
        let result = LogScanner.scanCodex(url: url)
        let day = try XCTUnwrap(result.days.keys.first)
        XCTAssertNil(result.days[day]?["unknown"])
        let bucket = try XCTUnwrap(result.days[day]?["gpt-5.6-terra"])
        XCTAssertEqual(bucket.input, 1000)
        XCTAssertEqual(result.lastModel, "gpt-5.6-terra")
    }
}
