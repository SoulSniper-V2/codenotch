import XCTest
@testable import Codenotch

final class WindsurfTests: XCTestCase {
    private let samplePlanJSON = """
    {
      "planName": "Pro",
      "startTimestamp": 1725580800,
      "endTimestamp": 1728172800,
      "usage": {
        "messages": 500,
        "usedMessages": 125,
        "remainingMessages": 375,
        "flowActions": 100,
        "usedFlowActions": 15,
        "remainingFlowActions": 85,
        "flexCredits": 500,
        "usedFlexCredits": 50,
        "remainingFlexCredits": 450
      },
      "quotaUsage": {
        "dailyRemainingPercent": 75.0,
        "weeklyRemainingPercent": 88.0,
        "dailyResetAtUnix": 1725667200,
        "weeklyResetAtUnix": 1726185600
      }
    }
    """

    func testParsesQuotaUsage() throws {
        let data = try XCTUnwrap(samplePlanJSON.data(using: .utf8))
        let info = try JSONDecoder().decode(WindsurfPlanInfo.self, from: data)
        XCTAssertEqual(info.planName, "Pro")

        let windows = WindsurfProvider.windows(from: info)
        XCTAssertEqual(windows.count, 2)

        let daily = try XCTUnwrap(windows.first { $0.id == "daily" })
        XCTAssertEqual(daily.label, "Daily limit")
        XCTAssertEqual(daily.usedFraction ?? -1, 0.25, accuracy: 0.01)
        XCTAssertNotNil(daily.resetsAt)

        let weekly = try XCTUnwrap(windows.first { $0.id == "weekly" })
        XCTAssertEqual(weekly.label, "Weekly limit")
        XCTAssertEqual(weekly.usedFraction ?? -1, 0.12, accuracy: 0.01)
        XCTAssertNotNil(weekly.resetsAt)
    }

    func testFallsBackToMessageLimits() throws {
        let json = """
        {
          "planName": "Free",
          "usage": {
            "messages": 100,
            "usedMessages": 40,
            "remainingMessages": 60
          }
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let info = try JSONDecoder().decode(WindsurfPlanInfo.self, from: data)
        let windows = WindsurfProvider.windows(from: info)

        XCTAssertEqual(windows.count, 1)
        let msg = try XCTUnwrap(windows.first)
        XCTAssertEqual(msg.id, "messages")
        XCTAssertEqual(msg.usedFraction ?? -1, 0.40, accuracy: 0.01)
        XCTAssertEqual(msg.customHeadline, "60 left")
    }
}
