import Foundation
import XCTest
@testable import ConnectOnionKit

final class OIPExecCommandTests: XCTestCase {

    // MARK: Parsing

    func testOrdinaryTextIsNotACommand() {
        XCTAssertEqual(OIPExecCommand.parse("hello"), .notACommand)
        XCTAssertEqual(OIPExecCommand.parse("please /exec bash"), .notACommand)
        XCTAssertEqual(OIPExecCommand.parse("/execute the plan"), .notACommand)
    }

    func testToolWithNoArguments() {
        XCTAssertEqual(OIPExecCommand.parse("/exec whoami"), .command(OIPExecCommand(tool: "whoami")))
        XCTAssertEqual(OIPExecCommand.parse("  /exec   whoami  "), .command(OIPExecCommand(tool: "whoami")))
    }

    func testNameValueArgumentsAreStrings() {
        XCTAssertEqual(
            OIPExecCommand.parse("/exec bash command=ls timeout=5"),
            .command(OIPExecCommand(tool: "bash", args: ["command": .string("ls"), "timeout": .string("5")]))
        )
    }

    func testQuotedValuesKeepTheirSpaces() {
        XCTAssertEqual(arguments("/exec bash command=\"ls -la /tmp\""), ["command": .string("ls -la /tmp")])
        XCTAssertEqual(arguments("/exec bash command='echo hi'"), ["command": .string("echo hi")])
        XCTAssertEqual(arguments("/exec bash note=\"\""), ["note": .string("")])
    }

    func testAValueMayContainAnEqualsSign() {
        XCTAssertEqual(arguments("/exec bash command=a=b"), ["command": .string("a=b")])
    }

    func testBareExecShowsUsage() {
        XCTAssertEqual(OIPExecCommand.parse("/exec"), .invalid(OIPExecCommand.usage))
        XCTAssertEqual(OIPExecCommand.parse("/exec   "), .invalid(OIPExecCommand.usage))
    }

    func testAnArgumentInPlaceOfTheToolIsRejected() {
        XCTAssertTrue(invalidMessage("/exec command=ls").contains("Name the tool first"))
    }

    func testAWordWithoutNameValueShapeIsRejectedByName() {
        XCTAssertTrue(invalidMessage("/exec bash ls").contains("\"ls\" is not name=value"))
        XCTAssertTrue(invalidMessage("/exec bash =ls").contains("\"=ls\" is not name=value"))
    }

    func testAnUnclosedQuoteIsRejected() {
        XCTAssertTrue(invalidMessage("/exec bash command=\"ls").contains("Close the quote"))
    }

    func testArgumentSummaryIsSortedNameValuePairs() {
        let command = OIPExecCommand(tool: "bash", args: ["b": .string("2"), "a": .string("1")])
        XCTAssertEqual(command.argumentSummary, "a=1 b=2")
        XCTAssertEqual(OIPExecCommand(tool: "pwd").argumentSummary, "")
    }

    // MARK: Display text

    func testSuccessShowsTheToolOutput() {
        let reply = OIPExecResult(execID: "e", tool: "bash", status: "success", result: "max", error: nil, durationMS: 4)
        XCTAssertTrue(reply.isSuccess)
        XCTAssertEqual(reply.displayText, "max")
    }

    func testSuccessWithNoOutputSaysSo() {
        let reply = OIPExecResult(execID: "e", tool: "bash", status: "success", result: "", error: nil, durationMS: nil)
        XCTAssertEqual(reply.displayText, "(no output)")
    }

    func testFailureShowsTheHostsReason() {
        let reply = OIPExecResult(execID: "e", tool: "bash", status: "error", result: nil, error: "blocked: cat", durationMS: 3)
        XCTAssertFalse(reply.isSuccess)
        XCTAssertEqual(reply.displayText, "blocked: cat")
    }

    func testFailureWithoutAReasonStillExplainsItself() {
        let reply = OIPExecResult(execID: "e", tool: nil, status: "error", result: nil, error: nil, durationMS: nil)
        XCTAssertEqual(reply.displayText, "The agent reported \"error\" without saying why.")
    }

    func testAnUnfamiliarStatusIsAFailureButKeepsItsText() {
        let reply = OIPExecResult(execID: "e", tool: "bash", status: "ok", result: "fine", error: nil, durationMS: nil)
        XCTAssertFalse(reply.isSuccess, "only \"success\" is a pass")
        XCTAssertEqual(reply.displayText, "fine")
    }

    func testVeryLongOutputIsCutAndSaysHowMuchWasHidden() {
        let long = String(repeating: "x", count: OIPExecResult.displayLimit + 250)
        let reply = OIPExecResult(execID: "e", tool: "bash", status: "success", result: long, error: nil, durationMS: nil)
        XCTAssertTrue(reply.displayText.hasPrefix(String(repeating: "x", count: OIPExecResult.displayLimit)))
        XCTAssertTrue(reply.displayText.hasSuffix("250 more characters not shown"))
    }

    // MARK: Helpers

    private func arguments(_ text: String) -> [String: JSONValue]? {
        guard case .command(let command) = OIPExecCommand.parse(text) else {
            return nil
        }
        return command.args
    }

    private func invalidMessage(_ text: String) -> String {
        guard case .invalid(let message) = OIPExecCommand.parse(text) else {
            XCTFail("expected .invalid for \(text)")
            return ""
        }
        return message
    }
}
