import XCTest
@testable import Codenotch

/// The CodexBar burn-rate estimator, ported into the notch UI.
///
/// Pinned to CodexBar's `UsagePace` semantics: linear expectation over the
/// window, stage thresholds at |d| 2/6/12, ETA from current burn, and the
/// deficit (ahead) / reserve (behind) wording.
final class UsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func window(used: Double, minutes: Double? = 300,
                        resetsIn: TimeInterval) -> LimitWindow {
        LimitWindow(id: "session", label: "Current session",
                    usedFraction: used,
                    resetsAt: now.addingTimeInterval(resetsIn),
                    windowMinutes: minutes)
    }

    func testDeficitWhenAheadOfPace() {
        // 5h window, 1h left (80% elapsed), 95% burned -> ~15% ahead.
        let pace = UsagePace.estimate(for: window(used: 0.95, resetsIn: 3600), now: now)
        let unwrapped = try? XCTUnwrap(pace)
        XCTAssertNotNil(unwrapped)
        XCTAssertEqual(PaceText.leftLabel(for: unwrapped!), "15% in deficit")
        XCTAssertFalse(unwrapped!.willLastToReset)
        XCTAssertNotNil(unwrapped!.etaSeconds)
    }

    func testReserveWhenBehindPace() {
        // 5h window, 1h left (80% elapsed), 20% burned -> well behind.
        let pace = try? XCTUnwrap(UsagePace.estimate(for: window(used: 0.20, resetsIn: 3600), now: now))
        XCTAssertNotNil(pace)
        XCTAssertTrue(PaceText.leftLabel(for: pace!).contains("in reserve"))
        XCTAssertTrue(pace!.willLastToReset)
    }

    func testOnPaceNearExpectation() {
        // 80% elapsed, 80% burned -> on pace.
        let pace = try? XCTUnwrap(UsagePace.estimate(for: window(used: 0.80, resetsIn: 3600), now: now))
        XCTAssertEqual(pace?.stage, .onTrack)
        XCTAssertEqual(PaceText.leftLabel(for: pace!), "On pace")
    }

    func testNoPaceWithoutReset() {
        let w = LimitWindow(id: "session", label: "Current session",
                            usedFraction: 0.5, windowMinutes: 300)
        XCTAssertNil(UsagePace.estimate(for: w, now: now))
        XCTAssertNil(PaceText.line(for: w, now: now))
    }

    func testNoPaceWithoutKnownLength() {
        let w = LimitWindow(id: "mystery", label: "Mystery quota",
                            usedFraction: 0.5,
                            resetsAt: now.addingTimeInterval(3600))
        XCTAssertNil(UsagePace.estimate(for: w, now: now))
    }

    func testNoPaceWhenWindowTooFresh() {
        // 5h window just started: <3% elapsed, projection would be noise.
        let pace = UsagePace.estimate(for: window(used: 0.01, resetsIn: 5 * 3600 - 60), now: now)
        XCTAssertNil(pace, "expected gate below 3% elapsed")
    }

    func testNoPaceWhenExhausted() {
        XCTAssertNil(UsagePace.estimate(for: window(used: 1.0, resetsIn: 3600), now: now))
    }

    func testSessionWordingVsWeeklyWording() {
        // Session window running out: "Projected empty in …".
        let sessionPace = UsagePace(
            stage: .ahead, deltaPercent: 10, expectedUsedPercent: 80,
            actualUsedPercent: 90, etaSeconds: 1800,
            willLastToReset: false, speedMultiplierToReset: 0.5)
        XCTAssertEqual(PaceText.rightLabel(for: sessionPace, isSession: true, now: now),
                       "Projected empty in 30 min")
        XCTAssertEqual(PaceText.rightLabel(for: sessionPace, isSession: false, now: now),
                       "Runs out in 30 min")
    }

    func testHeadroomHintWhenFarUnderPace() {
        let pace = UsagePace(
            stage: .farBehind, deltaPercent: -40, expectedUsedPercent: 80,
            actualUsedPercent: 40, etaSeconds: nil,
            willLastToReset: true, speedMultiplierToReset: 2.0)
        XCTAssertEqual(PaceText.rightLabel(for: pace, isSession: false, now: now),
                       "Lasts until reset · 1.5× headroom")
    }

    func testLastsWithoutHeadroomHint() {
        let pace = UsagePace(
            stage: .behind, deltaPercent: -8, expectedUsedPercent: 50,
            actualUsedPercent: 42, etaSeconds: nil,
            willLastToReset: true, speedMultiplierToReset: 1.2)
        XCTAssertEqual(PaceText.rightLabel(for: pace, isSession: false, now: now),
                       "Lasts until reset")
    }

    func testWeeklyWindowUsesInferredLength() {
        // No explicit minutes, but the id says weekly -> 10080m.
        let resetsAt = now.addingTimeInterval(2 * 24 * 3600) // 2d left of 7d
        let w = LimitWindow(id: "weekly_all", label: "All models",
                            usedFraction: 0.9, resetsAt: resetsAt)
        let pace = try? XCTUnwrap(UsagePace.estimate(for: w, now: now))
        XCTAssertNotNil(pace)
        XCTAssertTrue(PaceText.leftLabel(for: pace!).contains("deficit"))
    }

    func testCodexWindowMinutesFlowThrough() throws {
        // window_minutes from the rollout drives the estimate, not the label.
        let rollout = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{\
        "primary":{"used_percent":90,"window_minutes":300,"resets_at":1788003600}}}}
        """
        let windows = try CodexUsage.windows(
            fromRollout: rollout,
            now: Date(timeIntervalSince1970: 1_788_000_000))
        XCTAssertEqual(windows.first?.windowMinutes, 300)
        let pace = UsagePace.estimate(
            for: windows.first!, now: Date(timeIntervalSince1970: 1_788_000_000))
        XCTAssertNotNil(pace)
    }

    func testDurationText() {
        XCTAssertEqual(PaceText.durationText(seconds: 0), "now")
        XCTAssertEqual(PaceText.durationText(seconds: 1500), "25 min")
        XCTAssertEqual(PaceText.durationText(seconds: 3600), "1 hr")
        XCTAssertEqual(PaceText.durationText(seconds: 5400), "1 hr 30 min")
        XCTAssertEqual(PaceText.durationText(seconds: 3 * 24 * 3600), "3 days")
    }
}
