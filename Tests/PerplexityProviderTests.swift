import XCTest
@testable import Codenotch

final class PerplexityProviderTests: XCTestCase {
    private let sampleJSON = """
    {
      "free_queries": {
        "available": true,
        "remaining_detail": { "kind": "exact", "remaining": 10 }
      },
      "remaining_pro": 5,
      "remaining_research": 2,
      "remaining_agentic_research": 0,
      "remaining_labs": 0
    }
    """

    func testParsesPerplexityWindows() throws {
        let windows = try PerplexityUsage.windows(fromJSON: sampleJSON)
        XCTAssertEqual(windows.count, 5)

        let pro = try XCTUnwrap(windows.first { $0.id == "remaining_pro" })
        XCTAssertEqual(pro.label, "Pro searches")
        XCTAssertEqual(pro.remaining, 5)

        let research = try XCTUnwrap(windows.first { $0.id == "remaining_research" })
        XCTAssertEqual(research.label, "Research")
        XCTAssertEqual(research.remaining, 2)

        let free = try XCTUnwrap(windows.first { $0.id == "free_queries" })
        XCTAssertEqual(free.label, "Free queries")
        XCTAssertEqual(free.remaining, 10)
    }
}
