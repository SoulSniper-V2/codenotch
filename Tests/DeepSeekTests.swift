import XCTest
@testable import Codenotch

final class DeepSeekTests: XCTestCase {
    private let sampleBalance = """
    {
      "is_available": true,
      "balance_infos": [
        {
          "currency": "USD",
          "total_balance": "24.50",
          "granted_balance": "5.00",
          "topped_up_balance": "19.50"
        }
      ]
    }
    """

    func testParsesBalanceInfo() throws {
        let windows = try DeepSeekUsageParser.windows(fromJSON: sampleBalance)
        XCTAssertEqual(windows.count, 1)

        let balance = try XCTUnwrap(windows.first)
        XCTAssertEqual(balance.label, "USD Balance")
        XCTAssertEqual(balance.customHeadline, "$24.50")
        XCTAssertTrue(balance.customSummary?.contains("$24.50 balance") == true)
        XCTAssertTrue(balance.customSummary?.contains("$5.00 granted") == true)
        XCTAssertTrue(balance.customSummary?.contains("$19.50 topped up") == true)
    }

    func testCNYCurrencySymbol() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "100.00",
              "granted_balance": "0.00",
              "topped_up_balance": "100.00"
            }
          ]
        }
        """
        let windows = try DeepSeekUsageParser.windows(fromJSON: json)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].customHeadline, "¥100.00")
    }
}
