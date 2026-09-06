import XCTest
@testable import Codenotch

final class ActivitySummaryTests: XCTestCase {
    private func session(_ state: AgentSession.State, name: String = "s") -> AgentSession {
        AgentSession(id: name, name: name, detail: "Terminal · \(name)",
                     state: state, waitingFor: nil, since: Date())
    }

    func testNothingRunningMeansNoCell() {
        XCTAssertNil(ActivitySummary(sessions: []))
    }

    /// Blocked outranks busy: it is the only state that is asking you for
    /// something, so it must not be hidden behind a session that is merely busy.
    func testWaitingOutranksWorking() {
        let summary = ActivitySummary(sessions: [session(.busy), session(.waiting), session(.idle)])
        XCTAssertEqual(summary?.state, .waiting)
        XCTAssertEqual(summary?.label, "waiting")
    }

    func testWorkingOutranksIdle() {
        XCTAssertEqual(ActivitySummary(sessions: [session(.idle), session(.busy)])?.state, .working)
    }

    func testAllIdleReadsAsIdle() {
        XCTAssertEqual(ActivitySummary(sessions: [session(.idle), session(.idle)])?.state, .idle)
    }

    /// Working must not borrow a colour from the usage scale — the indicator
    /// sits inside a ring whose colour already means something else.
    func testWorkingIsNeutralAndWaitingIsNot() {
        XCTAssertEqual(ActivitySummary(sessions: [session(.busy)])?.color, Palette.textPrimary)
        XCTAssertEqual(ActivitySummary(sessions: [session(.waiting)])?.color, Palette.watch)
    }
}

/// Cursor publishes no session registry, so its working state is read out of the
/// editor's `composerHeaders` rows. These pin what counts as working.
@MainActor
final class CursorActivityTests: XCTestCase {
    private func session(_ json: String) -> AgentSession? {
        CursorActivityMonitor.session(fromHeader: json)
    }

    /// `unfinishedRunAt` is set while a run is in flight and cleared when it ends.
    func testAnUnfinishedRunIsBusy() throws {
        let s = try XCTUnwrap(session("""
        {"composerId":"abc","name":"General chat","subtitle":"Read SKILL.md",
         "unfinishedRunAt":1787981829823,"hasBlockingPendingActions":false}
        """))
        XCTAssertEqual(s.state, .busy)
        XCTAssertEqual(s.name, "General chat")
        XCTAssertEqual(s.detail, "Read SKILL.md")
    }

    /// A finished run is not a session worth a row — an editor with a long chat
    /// history is not a pile of things happening.
    func testAFinishedRunIsNotListed() {
        XCTAssertNil(session(#"{"composerId":"abc","hasBlockingPendingActions":false}"#))
    }

    /// Blocked outranks busy: it is the only state asking for something.
    func testBlockingActionsOutrankARunningTurn() throws {
        let s = try XCTUnwrap(session("""
        {"composerId":"abc","unfinishedRunAt":1787981829823,"hasBlockingPendingActions":true}
        """))
        XCTAssertEqual(s.state, .waiting)
        XCTAssertEqual(s.waitingFor, "needs your input")
    }

    func testAPendingPlanAlsoCountsAsWaiting() throws {
        let s = try XCTUnwrap(session(#"{"composerId":"abc","hasPendingPlan":true}"#))
        XCTAssertEqual(s.state, .waiting)
    }

    /// Ids are namespaced, so a Cursor composer can never collide with a Claude pid.
    func testIdsAreNamespaced() throws {
        let s = try XCTUnwrap(session(#"{"composerId":"abc","unfinishedRunAt":1}"#))
        XCTAssertEqual(s.id, "cursor.abc")
    }

    func testRejectsRubbish() {
        XCTAssertNil(session("not json"))
        XCTAssertNil(session(#"{"noComposerId":true,"unfinishedRunAt":1}"#))
    }
}
