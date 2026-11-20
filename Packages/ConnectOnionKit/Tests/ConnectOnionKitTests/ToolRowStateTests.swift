import XCTest
@testable import ConnectOnionKit

final class ToolRowStateTests: XCTestCase {
    func testEachStateHasItsWords() {
        XCTAssertEqual(ToolRowState.awaitingApproval.label, "Awaiting approval")
        XCTAssertEqual(ToolRowState.interrupted.label, "Interrupted")
        XCTAssertEqual(ToolRowState.skipped.label, "Skipped")
        XCTAssertEqual(
            ToolRowState.awaitingApproval.accessibilityLabel(toolName: "Bash"),
            "Bash, waiting for your approval"
        )
        XCTAssertEqual(
            ToolRowState.interrupted.accessibilityLabel(toolName: "Bash"),
            "Bash, interrupted before it finished"
        )
    }

    // Nothing moves while it waits on you, so only running uses a spinner instead of a glyph.
    func testOnlyStillStatesHaveAGlyph() {
        XCTAssertEqual(ToolRowState.awaitingApproval.systemImage, "hand.raised.fill")
        XCTAssertEqual(ToolRowState.interrupted.systemImage, "stop.circle")
        XCTAssertEqual(ToolRowState.skipped.systemImage, "minus.circle")
        XCTAssertNil(ToolRowState.running.systemImage)
        XCTAssertNil(ToolRowState.completed.systemImage)
    }

    func testOnlyRunningAndAwaitingCanStillChange() {
        let open = ToolRowState.allCases.filter { !$0.isSettled }
        XCTAssertEqual(open, [.running, .awaitingApproval])
    }

    func testAGroupShowsItsMostUrgentState() {
        XCTAssertEqual(ToolRowState.summary(of: [.completed, .awaitingApproval, .running]), .awaitingApproval)
        XCTAssertEqual(ToolRowState.summary(of: [.completed, .running]), .running)
        XCTAssertEqual(ToolRowState.summary(of: [.skipped, .failed, .completed]), .failed)
        XCTAssertEqual(ToolRowState.summary(of: [.completed, .skipped, .interrupted]), .interrupted)
        XCTAssertEqual(ToolRowState.summary(of: [.completed, .skipped]), .skipped)
        XCTAssertNil(ToolRowState.summary(of: []))
    }

    func testGroupTitleWhileSomethingIsOpen() {
        XCTAssertEqual(ToolRowState.groupTitle(for: [.completed, .awaitingApproval]), "Waiting for your approval")
        XCTAssertEqual(ToolRowState.groupTitle(for: [.running]), "Running 1 tool")
        XCTAssertEqual(ToolRowState.groupTitle(for: [.completed, .running]), "Running 2 tools")
        XCTAssertNil(ToolRowState.groupTitle(for: [.completed, .interrupted]))
    }
}
