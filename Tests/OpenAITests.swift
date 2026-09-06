import XCTest
@testable import Codenotch

final class OpenAITests: XCTestCase {
    private let sampleGrants = """
    {
      "total_granted": 18.0,
      "total_used": 5.25,
      "total_available": 12.75,
      "grants": {
        "data": [
          {
            "grant_amount": 18.0,
            "used_amount": 5.25,
            "expires_at": 1789412669
          }
        ]
      }
    }
    """

    func testParsesCreditGrants() throws {
        let windows = try OpenAIUsageParser.windows(fromJSON: sampleGrants)
        XCTAssertEqual(windows.count, 1)

        let credits = try XCTUnwrap(windows.first)
        XCTAssertEqual(credits.id, "credits")
        XCTAssertEqual(credits.label, "Credit balance")
        XCTAssertEqual(credits.customHeadline, "$12.75")
        XCTAssertTrue(credits.customSummary?.contains("$12.75 remaining") == true)
        XCTAssertTrue(credits.customSummary?.contains("$18.00") == true)
        XCTAssertEqual(credits.usedFraction ?? -1, 5.25 / 18.0, accuracy: 0.001)
        XCTAssertNotNil(credits.resetsAt)
    }
}
