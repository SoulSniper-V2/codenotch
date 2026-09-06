import XCTest
@testable import Codenotch

final class GroqTests: XCTestCase {
    func testParsesRateLimitHeaders() {
        let headers: [AnyHashable: Any] = [
            "x-ratelimit-limit-requests": "14400",
            "x-ratelimit-remaining-requests": "14350",
            "x-ratelimit-reset-requests": "2s",
            "x-ratelimit-limit-tokens": "18000",
            "x-ratelimit-remaining-tokens": "17500",
            "x-ratelimit-reset-tokens": "1m"
        ]

        let windows = GroqProvider.parseResponse(data: Data(), headers: headers)
        XCTAssertEqual(windows.count, 2)

        let req = try? XCTUnwrap(windows.first { $0.id == "requests" })
        XCTAssertEqual(req?.customHeadline, "14350 left")
        XCTAssertEqual(req?.usedFraction ?? -1, (14400.0 - 14350.0) / 14400.0, accuracy: 0.001)

        let tok = try? XCTUnwrap(windows.first { $0.id == "tokens" })
        XCTAssertEqual(tok?.customHeadline, "17500 left")
        XCTAssertEqual(tok?.usedFraction ?? -1, (18000.0 - 17500.0) / 18000.0, accuracy: 0.001)
    }

    func testFallsBackToModelList() {
        let json = """
        {
          "data": [
            {"id": "llama-3.3-70b-versatile"},
            {"id": "mixtral-8x7b-32768"}
          ]
        }
        """
        let data = json.data(using: .utf8) ?? Data()
        let windows = GroqProvider.parseResponse(data: data, headers: [:])

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.id, "models")
        XCTAssertEqual(windows.first?.customHeadline, "2 models")
    }
}
