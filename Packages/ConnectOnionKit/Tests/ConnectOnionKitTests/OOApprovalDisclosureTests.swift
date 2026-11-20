import XCTest
@testable import ConnectOnionKit

final class OOApprovalDisclosureTests: XCTestCase {
    func testEffectIsKnownOnlyForToolsTheHostShips() {
        XCTAssertEqual(OOApprovalDisclosure.effect(tool: "bash", arguments: [:]), .runsCommand)
        XCTAssertEqual(OOApprovalDisclosure.effect(tool: "run_command", arguments: [:]), .runsCommand)
        XCTAssertEqual(
            OOApprovalDisclosure.effect(tool: "anything", arguments: ["command": .string("ls")]),
            .runsCommand
        )
        XCTAssertEqual(OOApprovalDisclosure.effect(tool: "write", arguments: [:]), .changesFiles)
        XCTAssertEqual(OOApprovalDisclosure.effect(tool: "Write_File", arguments: [:]), .changesFiles)
        XCTAssertEqual(OOApprovalDisclosure.effect(tool: "multi_edit", arguments: [:]), .changesFiles)
        XCTAssertEqual(OOApprovalDisclosure.effect(tool: "web_fetch", arguments: [:]), .usesNetwork)
        XCTAssertEqual(OOApprovalDisclosure.effect(tool: "custom_action", arguments: [:]), .other)
    }

    func testNamesThatOnlyContainAKnownWordAreNotRecognised() {
        let lookalikes = [
            "read_thread", "spreadsheet_reader", "update_spreadsheet", "find_and_replace",
            "update_todo_list", "post_thread", "blocklist_user", "delete_email",
            "create_calendar_event", "send_email", "rewrite_note", "upload_report",
            "remove_user", "fetch_user_profile", "bashful", "runner", "editor"
        ]
        for tool in lookalikes {
            XCTAssertEqual(OOApprovalDisclosure.effect(tool: tool, arguments: [:]), .other, tool)
            XCTAssertEqual(
                OOApprovalDisclosure.consequence(tool: tool, arguments: [:]),
                OOApprovalDisclosure.unrecognisedConsequence,
                tool
            )
        }
    }

    func testAUrlArgumentDoesNotMakeAnUnknownToolANetworkTool() {
        XCTAssertEqual(
            OOApprovalDisclosure.effect(tool: "lookup", arguments: ["url": .string("https://example.test")]),
            .other
        )
    }

    func testTheNeutralLineMakesNoClaimAboutWhatTheToolDoes() {
        let line = OOApprovalDisclosure.unrecognisedConsequence
        XCTAssertFalse(line.contains("Reads only"))
        XCTAssertFalse(line.contains("Nothing is changed"))
        XCTAssertFalse(line.contains("above"))
        XCTAssertTrue(line.contains("Review the parameters"))
    }

    func testScopeNamesWhatTheApprovalCovers() {
        XCTAssertEqual(
            OOApprovalDisclosure.scope(tool: "bash", arguments: ["command": .string("ls")]),
            "This command, once."
        )
        XCTAssertEqual(
            OOApprovalDisclosure.scope(tool: "write", arguments: ["path": .string("/tmp/a.txt")]),
            "This call only, on /tmp/a.txt."
        )
        XCTAssertEqual(
            OOApprovalDisclosure.scope(tool: "web_fetch", arguments: ["url": .string("https://example.test")]),
            "This call only, to https://example.test."
        )
        XCTAssertEqual(OOApprovalDisclosure.scope(tool: "write", arguments: [:]), "This call only.")
        XCTAssertEqual(OOApprovalDisclosure.scope(tool: "custom_action", arguments: [:]), "This call only.")
    }

    func testScopeAndConsequenceAreDifferentLines() {
        let arguments: [String: JSONValue] = ["path": .string("/tmp/a.txt")]
        let scope = OOApprovalDisclosure.scope(tool: "write", arguments: arguments)
        let consequence = OOApprovalDisclosure.consequence(tool: "write", arguments: arguments)
        XCTAssertNotEqual(scope, consequence)
        XCTAssertEqual(consequence, "Changes files on the agent's host. Check the path before you allow it.")
    }

    func testConsequenceForEachKnownKindOfCall() {
        XCTAssertEqual(
            OOApprovalDisclosure.consequence(tool: "web_fetch", arguments: [:]),
            "Sends a request over the network from the agent's host."
        )
        XCTAssertTrue(
            OOApprovalDisclosure.consequence(tool: "bash", arguments: [:]).hasPrefix("Runs on the agent's host")
        )
    }

    func testTrustNamesTheToolBecauseTheHostTrustsTheWholeTool() {
        XCTAssertEqual(OOApprovalDisclosure.trustTitle(tool: "bash"), "Trust all bash calls")
        XCTAssertEqual(OOApprovalDisclosure.trustTitle(tool: "  "), "Trust this tool")
        XCTAssertEqual(
            OOApprovalDisclosure.trustScope(tool: "bash"),
            "Every later request to use bash runs without asking until this session ends, "
                + "whatever it asks to do. You can still stop the response at any time."
        )
        XCTAssertTrue(OOApprovalDisclosure.trustScope(tool: "").contains("this tool"))
    }
}
