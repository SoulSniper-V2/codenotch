import XCTest
@testable import Codenotch

final class OpenRouterTests: XCTestCase {
    private let sampleCredits = """
    {
      "data": {
        "total_credits": 25.0,
        "total_usage": 5.50
      }
    }
    """

    private let sampleKey = """
    {
      "data": {
        "label": "Work Key",
        "limit": 100.0,
        "limit_remaining": 75.0,
        "usage": 25.0,
        "usage_daily": 3.25,
        "usage_weekly": 12.50,
        "usage_monthly": 25.0
      }
    }
    """

    func testParsesCreditsAndKeyLimits() throws {
        let windows = OpenRouterUsageParser.windows(creditsJSON: sampleCredits, keyJSON: sampleKey)
        XCTAssertEqual(windows.count, 3)

        let credits = try XCTUnwrap(windows.first { $0.id == "credits" })
        XCTAssertEqual(credits.customHeadline, "$19.50")
        XCTAssertTrue(credits.customSummary?.contains("$19.50 remaining") == true)
        XCTAssertEqual(credits.usedFraction ?? -1, 0.22, accuracy: 0.01)

        let keyLimit = try XCTUnwrap(windows.first { $0.id == "key_limit" })
        XCTAssertEqual(keyLimit.customHeadline, "$75.00")
        XCTAssertEqual(keyLimit.usedFraction ?? -1, 0.25, accuracy: 0.01)

        let daily = try XCTUnwrap(windows.first { $0.id == "usage_daily" })
        XCTAssertEqual(daily.customHeadline, "$3.25")
    }

    func testParsesCreditsOnlyWhenKeyIsNil() throws {
        let windows = OpenRouterUsageParser.windows(creditsJSON: sampleCredits, keyJSON: nil)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].customHeadline, "$19.50")
    }
}
