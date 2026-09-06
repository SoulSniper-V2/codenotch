import XCTest
@testable import Codenotch

@MainActor
final class QuotaAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSnapshot(
        id: String = "claude",
        displayName: String = "Claude",
        usedFraction: Double? = 0.30,
        remaining: Int? = nil,
        resetsAt: Date? = nil,
        block: UsageBlock? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: .claude,
            fidelity: .derived,
            status: .ok,
            windows: [
                LimitWindow(
                    id: "5h",
                    label: "5-hour limit",
                    usedFraction: usedFraction,
                    remaining: remaining,
                    resetsAt: resetsAt ?? now.addingTimeInterval(3600)
                )
            ],
            headlineID: "5h",
            block: block
        )
    }

    func testNoAlertWhenUsageIsNormal() {
        let current = makeSnapshot(usedFraction: 0.30)
        let alerts = QuotaAlertManager.evaluate(
            current: current,
            previous: nil,
            thresholdPercent: 20,
            deliveredKeys: []
        )
        XCTAssertTrue(alerts.isEmpty)
    }

    func testLowQuotaWarningTriggeredWhenCrossingThreshold() {
        let prev = makeSnapshot(usedFraction: 0.75) // 25% remaining
        let current = makeSnapshot(usedFraction: 0.88) // 12% remaining

        let alerts = QuotaAlertManager.evaluate(
            current: current,
            previous: prev,
            thresholdPercent: 20,
            deliveredKeys: []
        )

        XCTAssertEqual(alerts.count, 1)
        if case .lowQuota(let provider, let windowLabel, let pct) = alerts[0].0 {
            XCTAssertEqual(provider, "Claude")
            XCTAssertEqual(windowLabel, "5-hour limit")
            XCTAssertEqual(pct, 12)
        } else {
            XCTFail("Expected lowQuota alert")
        }
    }

    func testLowQuotaWarningDeduplicated() {
        let prev = makeSnapshot(usedFraction: 0.75)
        let current = makeSnapshot(usedFraction: 0.90)

        let resetTimestamp = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        let warningKey = "low-claude-5h-\(resetTimestamp)"

        let alerts = QuotaAlertManager.evaluate(
            current: current,
            previous: prev,
            thresholdPercent: 20,
            deliveredKeys: [warningKey]
        )

        XCTAssertTrue(alerts.isEmpty)
    }

    func testResetTriggeredAfterBlockOrExhaustion() {
        let prev = makeSnapshot(
            id: "codex",
            displayName: "Codex",
            usedFraction: 1.0,
            resetsAt: now.addingTimeInterval(60)
        )

        let nextResetTime = now.addingTimeInterval(5 * 3600)
        let current = makeSnapshot(
            id: "codex",
            displayName: "Codex",
            usedFraction: 0.0,
            resetsAt: nextResetTime
        )

        let alerts = QuotaAlertManager.evaluate(
            current: current,
            previous: prev,
            thresholdPercent: 20,
            deliveredKeys: []
        )

        XCTAssertEqual(alerts.count, 1)
        if case .reset(let provider, let windowLabel) = alerts[0].0 {
            XCTAssertEqual(provider, "Codex")
            XCTAssertEqual(windowLabel, "5-hour limit")
        } else {
            XCTFail("Expected reset alert")
        }
    }

    func testDailyHistoryPointsRollup() {
        let store = TokenCostStore()
        let points = store.historyPoints(daysBack: 7)
        XCTAssertEqual(points.count, 7)
        for point in points {
            XCTAssertFalse(point.id.isEmpty)
            XCTAssertFalse(point.dayLabel.isEmpty)
        }
    }
}
