import XCTest
import SwiftUI
@testable import Codenotch

/// Renders the tooltip with a session in every state.
///
/// Partly a smoke test — a card that fails to lay out fails here rather than on
/// someone's screen — and partly a way to actually look at it: set
/// `TOOLTIP_RENDER_PATH` and the frame is written there.
@MainActor
final class TooltipRenderTests: XCTestCase {
    private func session(_ name: String, _ state: AgentSession.State,
                         minutes: Int) -> AgentSession {
        AgentSession(id: name, name: name, detail: "Terminal · usage-notch",
                     state: state, waitingFor: state == .waiting ? "your answer" : nil,
                     since: Date().addingTimeInterval(Double(-minutes) * 60))
    }

    func testTheCardLaysOutEverySessionState() throws {
        let snapshot = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "session", label: "Session", usedFraction: 0.47)]
        )
        let activity = ActivitySummary(sessions: [
            session("codenotch-6f", .idle, minutes: 0),
            session("agent-web-2f", .busy, minutes: 1),
            session("codenotch-18", .waiting, minutes: 3)
        ])

        let view = TooltipCard(snapshot: snapshot, activity: activity, now: Date())
            .padding(20)
            .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)

        // Three sessions of two lines each, under the window rows: a card that
        // silently collapsed would still render, just far too short.
        XCTAssertGreaterThan(image.size.height, NotchLayout.cardWidth * 0.5,
                             "the card laid out far shorter than three sessions need")
        XCTAssertGreaterThan(image.size.width, NotchLayout.cardWidth)

        if let path = ProcessInfo.processInfo.environment["TOOLTIP_RENDER_PATH"] {
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    func testCursorTooltipLayout() throws {
        let now = Date()
        let reset = now.addingTimeInterval(20 * 86400)
        let windows = [
            LimitWindow(id: "included", label: "Included usage", usedFraction: 1.0,
                        resetsAt: reset, windowMinutes: 44640),
            LimitWindow(id: "api", label: "API usage", usedFraction: 1.0,
                        resetsAt: reset, windowMinutes: 44640),
            LimitWindow(id: "cursor-grok-bot", label: "Grok Bot", usedFraction: 0.0246,
                        resetsAt: reset, windowMinutes: 5945)
        ]
        let snapshot = ProviderSnapshot(
            id: "cursor",
            displayName: "Cursor",
            glyph: .cursor,
            fidelity: .official,
            status: .ok,
            windows: windows
        )

        let accurateHeight = NotchLayout.cardHeight(windows: windows, sessionCount: 0, costLineCount: 0, now: now)
        let legacyHeight = NotchLayout.cardHeight(windowCount: 3, sessionCount: 0, costLineCount: 0)
        print("ACCURATE HEIGHT: \(accurateHeight), LEGACY HEIGHT: \(legacyHeight)")
        XCTAssertLessThan(accurateHeight, legacyHeight, "Accurate height should be noticeably less than legacy height when windows have no pace line")

        let view = TooltipCard(snapshot: snapshot, activity: nil, cost: nil, now: now)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        print("CURSOR RENDERED IMAGE SIZE: \(image.size)")

        let path = "/tmp/cursor_tooltip.png"
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}



