import XCTest
@testable import Codenotch

/// Cursor's Grok Bot ("Sand") allowance — the GROKBOT inside Cursor that
/// CodexBar shows as an extra `cursor-grok-bot` window.
final class CursorSandTests: XCTestCase {
    private let response = """
    {"currentPeriodStart":"2026-08-31T00:00:00.000Z",
     "nextResetTimestampUtc":"2026-09-07T00:00:00.000Z",
     "usagePercent":34.5,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true}
    """

    func testReadsTheWeeklyBotAllowance() throws {
        let window = try XCTUnwrap(CursorSandUsage.window(fromJSON: response))
        XCTAssertEqual(window.id, "cursor-grok-bot")
        XCTAssertEqual(window.label, "Grok Bot")
        XCTAssertEqual(window.usedFraction ?? -1, 0.345, accuracy: 0.0001)
        XCTAssertEqual(window.summary, "35% Used · 65% left")
    }

    func testResetComesFromThePeriodEnd() throws {
        let window = try XCTUnwrap(CursorSandUsage.window(fromJSON: response))
        let reset = try XCTUnwrap(window.resetsAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(calendar.component(.month, from: reset), 9)
        XCTAssertEqual(calendar.component(.day, from: reset), 7)
    }

    func testWindowLengthComesFromThePeriod() throws {
        let window = try XCTUnwrap(CursorSandUsage.window(fromJSON: response))
        XCTAssertEqual(window.windowMinutes ?? -1, 10_080, accuracy: 0.01,
                       "a week-long period paces like a weekly window")
    }

    /// No included allowance (free plans): no row, not a zero row.
    func testNoAllowanceMeansNoWindow() {
        let json = """
        {"currentPeriodStart":"2026-08-31T00:00:00.000Z",
         "nextResetTimestampUtc":"2026-09-07T00:00:00.000Z",
         "usagePercent":0,"hasAvailableUsage":false,"hasNonZeroIncludedLimit":false}
        """
        XCTAssertNil(CursorSandUsage.window(fromJSON: json))
    }

    func testRejectsRubbish() {
        XCTAssertNil(CursorSandUsage.window(fromJSON: "not json"))
        XCTAssertNil(CursorSandUsage.window(fromJSON: "{}"))
    }
}

/// The standalone Grok (SuperGrok) provider: proxy billing shape.
final class GrokBillingTests: XCTestCase {
    private let response = """
    {"config":{"creditUsagePercent":12.5,
      "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
        "start":"2026-08-06T00:00:00Z","end":"2026-08-13T00:00:00Z"},
      "billingPeriodEnd":"2026-08-13T00:00:00Z",
      "onDemandCap":{"val":1000},"onDemandUsed":{"val":250}},
     "subscriptionTier":"SuperGrok Heavy"}
    """

    func testReadsTheCreditPool() throws {
        let window = try XCTUnwrap(GrokBilling.window(fromJSON: response))
        XCTAssertEqual(window.id, "credits")
        XCTAssertEqual(window.label, "Credits")
        XCTAssertEqual(window.usedFraction ?? -1, 0.125, accuracy: 0.0001)
    }

    func testWindowLengthComesFromThePeriod() throws {
        let window = try XCTUnwrap(GrokBilling.window(fromJSON: response))
        XCTAssertEqual(window.windowMinutes ?? -1, 10_080, accuracy: 0.01)
    }

    /// No pool percentage: on-demand used/cap is the honest fallback.
    func testFallsBackToOnDemand() throws {
        let json = """
        {"config":{"currentPeriod":{"start":"2026-08-06T00:00:00Z","end":"2026-08-13T00:00:00Z"},
          "onDemandCap":{"val":1000},"onDemandUsed":{"val":250}}}
        """
        let window = try XCTUnwrap(GrokBilling.window(fromJSON: json))
        XCTAssertEqual(window.id, "on_demand")
        XCTAssertEqual(window.usedFraction ?? -1, 0.25, accuracy: 0.0001)
    }

    /// Neither pool nor cap: unknown must not render as a 0% ring.
    func testUnknownPoolMeansNoWindow() {
        XCTAssertNil(GrokBilling.window(fromJSON: #"{"config":{}}"#))
        XCTAssertNil(GrokBilling.window(fromJSON: "not json"))
    }
}

/// `~/.grok/auth.json` reading: OIDC entry wins, sign-in entry is fallback.
final class GrokCredentialsTests: XCTestCase {
    private func file(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPrefersTheOIDCEntry() throws {
        let url = try file("""
        {"https://accounts.x.ai/sign-in":{"key":"tok-old","email":"old@x.c"},
         "https://auth.x.ai::client123":{"key":"tok-new","email":"new@x.c"}}
        """)
        XCTAssertEqual(GrokCredentials.token(from: url), "tok-new")
        XCTAssertEqual(GrokCredentials.account(from: url)?.label, "new@x.c")
    }

    func testFallsBackToTheSignInEntry() throws {
        let url = try file("""
        {"https://accounts.x.ai/sign-in":{"key":"tok-old","email":"old@x.c"}}
        """)
        XCTAssertEqual(GrokCredentials.token(from: url), "tok-old")
    }

    func testSkipsKeylessEntries() throws {
        let url = try file("""
        {"https://auth.x.ai::client123":{"email":"new@x.c"},
         "https://accounts.x.ai/sign-in":{"key":"tok-old"}}
        """)
        XCTAssertEqual(GrokCredentials.token(from: url), "tok-old")
    }

    func testMissingFileMeansSignedOut() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).json")
        XCTAssertNil(GrokCredentials.token(from: missing))
        XCTAssertNil(GrokCredentials.account(from: missing))
    }
}
