import Foundation
import XCTest
@testable import ConnectOnionKit

/// The Work Room store is the one seam: decoded server frames in, Work Room state out.
@MainActor
final class WorkRoomStoreTests: XCTestCase {

    // MARK: Helpers

    /// A catalog fixture with some fields replaced; a nil value removes the field.
    private func frame(_ name: String, _ changes: [String: JSONValue?] = [:]) throws -> OIPServerFrame {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/frames"),
            "Missing fixture \(name).json"
        )
        var body = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        for (key, value) in changes {
            body[key] = value
        }
        return OIPServerFrame.decode(body)
    }

    private func store(_ frames: OIPServerFrame...) -> WorkRoomStore {
        let store = WorkRoomStore()
        frames.forEach(store.receive)
        return store
    }

    // MARK: Card state

    func testInvocationShowsAsAWorkRoomWithProviderTitleStatusAndSummary() throws {
        let store = store(try frame("provider_invocation"))

        let room = try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
        XCTAssertEqual(room.provider, .codex)
        XCTAssertEqual(room.title, "Build and verify the requested C program")
        XCTAssertEqual(room.status, .running)
        XCTAssertEqual(room.summary, "Working in the selected workspace")
        XCTAssertEqual(store.workRooms.map(\.id), ["codex:call-7"])
    }

    // MARK: State revision gate

    func testNewerRevisionUpdatesOnlyTheFieldsItCarries() throws {
        let store = store(try frame("provider_invocation"), try frame("provider_invocation.terminal"))

        let room = try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
        XCTAssertEqual(room.status, .cancelled)
        XCTAssertEqual(room.summary, "The provider stopped")
        XCTAssertEqual(room.title, "Build and verify the requested C program")
    }

    func testOlderRevisionIsDropped() throws {
        let store = store(
            try frame("provider_invocation", ["stateRevision": .number(2)]),
            try frame("provider_invocation", ["stateRevision": .number(1), "status": .string("failed")])
        )

        XCTAssertEqual(store.workRoom(forToolCallID: "call-7")?.status, .running)
    }

    func testMissingRevisionIsDroppedOnceTheInvocationHasOne() throws {
        let store = store(
            try frame("provider_invocation"),
            try frame("provider_invocation", ["stateRevision": nil, "status": .string("failed")])
        )

        XCTAssertEqual(store.workRoom(forToolCallID: "call-7")?.status, .running)
    }

    func testEqualRevisionIsANoOp() throws {
        let store = store(try frame("provider_invocation"))
        let before = store.workRooms

        store.receive(try frame("provider_invocation", [
            "status": .string("completed"),
            "currentSummary": .string("The provider completed its run")
        ]))

        XCTAssertEqual(store.workRooms, before)
    }

    func testUnversionedInvocationAcceptsAnyUpdate() throws {
        let store = store(
            try frame("provider_invocation", ["stateRevision": nil]),
            try frame("provider_invocation", ["stateRevision": nil, "status": .string("completed")])
        )

        XCTAssertEqual(store.workRoom(forToolCallID: "call-7")?.status, .completed)
    }

    // MARK: Terminal status

    func testFailedInvocationShowsItsErrorSummary() throws {
        let store = store(
            try frame("provider_invocation"),
            try frame("provider_invocation", [
                "stateRevision": .number(2),
                "status": .string("failed"),
                "currentSummary": nil,
                "errorSummary": .string("The provider reported an error")
            ])
        )

        let room = try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
        XCTAssertEqual(room.status, .failed)
        XCTAssertEqual(room.summary, "The provider reported an error")
    }

    func testTerminalStatusNeverKeepsTheRunningSummary() throws {
        let store = store(
            try frame("provider_invocation"),
            try frame("provider_invocation", [
                "stateRevision": .number(2),
                "status": .string("completed"),
                "currentSummary": nil
            ])
        )

        let room = try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
        XCTAssertEqual(room.status, .completed)
        XCTAssertNil(room.summary)
    }
    // MARK: Allowed copy

    func testTitleAndSummaryOffTheAllowListAreDropped() throws {
        let store = store(try frame("provider_invocation", [
            "taskTitle": .string("Write sort.c in /home/dev/project and compile it with gcc"),
            "currentSummary": .string("Running gcc -std=c11 -o sort sort.c")
        ]))

        let room = try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
        XCTAssertNil(room.title)
        XCTAssertNil(room.summary)
    }

    func testClaudeStationCopyFromCoreIsShown() throws {
        let store = store(try frame("provider_invocation", [
            "provider": .string("claude_code"),
            "taskTitle": .string("Claude Code session"),
            "currentSummary": .string("Ready for a browser message"),
            "status": .string("completed")
        ]))

        let room = try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
        XCTAssertEqual(room.provider, .claudeCode)
        XCTAssertEqual(room.title, "Claude Code session")
        XCTAssertEqual(room.summary, "Ready for a browser message")
    }

    func testActivityWhoseTitleAndSummaryAreNotAnAllowedPairIsDropped() throws {
        let store = store(
            try frame("provider_invocation"),
            try frame("provider_activity", ["activityId": .string("raw"), "summary": .string("rm -rf build")]),
            try frame("provider_activity", ["activityId": .string("mismatch"), "title": .string("Run the requested tests")]),
            try frame("provider_activity", ["activityId": .string("allowed")])
        )

        XCTAssertEqual(store.workRoom(forToolCallID: "call-7")?.activities.map(\.activityID), ["allowed"])
    }

    // MARK: Activities and messages

    func testActivitiesAreUpsertedByIDAndOrderedBySequence() throws {
        let store = store(
            try frame("provider_invocation"),
            try frame("provider_activity", ["status": .string("running"), "summary": .string("Preparing workspace file changes")]),
            try frame("provider_activity", [
                "activityId": .string("look"),
                "sequence": .number(1),
                "kind": .string("inspect"),
                "title": .string("Inspect the workspace"),
                "summary": .string("Workspace inspection completed")
            ]),
            try frame("provider_activity")
        )

        let activities = try XCTUnwrap(store.workRoom(forToolCallID: "call-7")?.activities)
        XCTAssertEqual(activities.map(\.activityID), ["look", "create-sort"])
        XCTAssertEqual(activities.last?.status, .completed)
        XCTAssertEqual(activities.last?.summary, "Workspace files updated")
    }

    func testActivityFilesKeepAtMostEightDistinctBaseNames() throws {
        let tooLong = String(repeating: "a", count: 129) + ".c"
        let paths = ["/home/dev/project/src/sort.c", "C:\\work\\sort.c", "", "..", tooLong]
            + (1...9).map { "dir/file\($0).c" }
        let store = store(
            try frame("provider_invocation"),
            try frame("provider_activity", ["files": .array(paths.map(JSONValue.string))])
        )

        XCTAssertEqual(
            store.workRoom(forToolCallID: "call-7")?.activities.first?.files,
            ["sort.c", "file1.c", "file2.c", "file3.c", "file4.c", "file5.c", "file6.c", "file7.c"]
        )
    }

    func testChildEventsBeforeTheirInvocationAreDropped() throws {
        let store = store(try frame("provider_activity"), try frame("provider_message"))
        XCTAssertEqual(store.workRooms, [])

        store.receive(try frame("provider_invocation"))

        let room = try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
        XCTAssertEqual(room.activities, [])
        XCTAssertEqual(room.messages, [])
    }

    func testMessageTextIsTrimmedAndBlankOrOversizedTextIsDropped() throws {
        let store = store(
            try frame("provider_invocation"),
            try frame("provider_message", ["messageId": .string("user:initial"), "role": .string("user"),
                                           "text": .string("  Sort the numbers  \n")]),
            try frame("provider_message", ["messageId": .string("assistant:blank"), "text": .string(" \n ")]),
            try frame("provider_message", ["messageId": .string("assistant:long"),
                                           "text": .string(String(repeating: "x", count: 16_001))])
        )

        let messages = try XCTUnwrap(store.workRoom(forToolCallID: "call-7")?.messages)
        XCTAssertEqual(messages.map(\.text), ["Sort the numbers"])
        XCTAssertEqual(messages.first?.role, .user)
    }
    // MARK: Work Room groups

    /// The catalog's Claude Station example: a continuation with its own revision counter.
    private func stationRoot() throws -> OIPServerFrame {
        try frame("provider_invocation", [
            "provider": .string("claude_code"),
            "invocationId": .string("claude_code:station"),
            "parentToolCallId": .string("claude_station:station-session"),
            "workroomId": .string("claude_code:station"),
            "taskTitle": .string("Claude Code session"),
            "status": .string("completed"),
            "currentSummary": .string("Session ready in the terminal"),
            "stateRevision": .number(4)
        ])
    }

    private func stationContinuation(_ changes: [String: JSONValue?] = [:]) throws -> OIPServerFrame {
        var fields: [String: JSONValue?] = [
            "provider": .string("claude_code"),
            "invocationId": .string("claude_code:web-turn"),
            "parentToolCallId": .string("web-turn"),
            "continuationOf": .string("claude_code:station"),
            "workroomId": .string("claude_code:station"),
            "taskTitle": nil,
            "status": .string("running"),
            "currentSummary": .string("Claude Code is working"),
            "stateRevision": .number(1)
        ]
        fields.merge(changes) { $1 }
        return try frame("provider_invocation", fields)
    }

    func testContinuationJoinsItsWorkRoomGroupAndBecomesCurrent() throws {
        let store = store(try stationRoot(), try stationContinuation())

        XCTAssertEqual(store.workRooms.count, 1)
        let room = try XCTUnwrap(store.workRoom(forToolCallID: "claude_station:station-session"))
        XCTAssertEqual(room.id, "claude_code:station")
        XCTAssertEqual(room.title, "Claude Code session")
        XCTAssertEqual(room.status, .running)
        XCTAssertEqual(room.summary, "Claude Code is working")
    }

    func testOnlyTheRootRendersACardButEveryMemberReplacesItsToolCall() throws {
        let store = store(try stationRoot(), try stationContinuation())

        XCTAssertNil(store.workRoom(forToolCallID: "web-turn"))
        XCTAssertTrue(store.isProviderToolCall("web-turn"))
        XCTAssertTrue(store.isProviderToolCall("claude_station:station-session"))
        XCTAssertFalse(store.isProviderToolCall("call-7"))
    }

    func testInvocationsWithoutWorkroomIDEachGetTheirOwnWorkRoomInArrivalOrder() throws {
        let store = store(
            try frame("provider_invocation", ["invocationId": .string("codex:call-9"), "parentToolCallId": .string("call-9"),
                                              "workroomId": nil]),
            try frame("provider_invocation", ["workroomId": nil])
        )

        XCTAssertEqual(store.workRooms.map(\.id), ["codex:call-9", "codex:call-7"])
    }

    func testMessagesAreDeduplicatedByIDAcrossTheGroup() throws {
        let message: (String, String, String) throws -> OIPServerFrame = { invocation, parent, id in
            try self.frame("provider_message", [
                "provider": .string("claude_code"), "invocationId": .string(invocation),
                "parentToolCallId": .string(parent), "messageId": .string(id)
            ])
        }
        let store = store(
            try stationRoot(),
            try message("claude_code:station", "claude_station:station-session", "assistant:plan"),
            try stationContinuation(),
            try message("claude_code:web-turn", "web-turn", "assistant:plan"),
            try message("claude_code:web-turn", "web-turn", "assistant:reply")
        )

        XCTAssertEqual(
            store.workRoom(forToolCallID: "claude_station:station-session")?.messages.map(\.messageID),
            ["assistant:plan", "assistant:reply"]
        )
    }

    func testContinuationMessagesJoinTheConversationInArrivalOrder() throws {
        let message: (String, String, String, String) throws -> OIPServerFrame = { invocation, parent, id, role in
            try self.frame("provider_message", [
                "provider": .string("claude_code"), "invocationId": .string(invocation),
                "parentToolCallId": .string(parent), "messageId": .string(id), "role": .string(role)
            ])
        }
        let store = store(
            try stationRoot(),
            try message("claude_code:station", "claude_station:station-session", "assistant:plan", "assistant"),
            try stationContinuation(),
            try message("claude_code:web-turn", "web-turn", "user:request-1", "user"),
            try message("claude_code:station", "claude_station:station-session", "assistant:reply", "assistant")
        )

        let room = try XCTUnwrap(store.workRoom(id: "claude_code:station"))
        XCTAssertEqual(room.messages.map(\.messageID), ["assistant:plan", "user:request-1", "assistant:reply"])
        XCTAssertEqual(room.currentTurn.map(\.messageID), ["user:request-1", "assistant:reply"])
        XCTAssertEqual(room.earlierMessages.map(\.messageID), ["assistant:plan"])
    }

    // MARK: Turns

    private func message(_ id: String, _ role: String, _ text: String = "Done.") throws -> OIPServerFrame {
        try frame("provider_message", ["messageId": .string(id), "role": .string(role), "text": .string(text)])
    }

    func testCurrentTurnStartsAtTheLastUserMessageAndEarlierTurnsAreFolded() throws {
        let store = store(
            try frame("provider_invocation"),
            try message("user:initial", "user"),
            try message("assistant:plan", "assistant"),
            try message("user:request-1", "user"),
            try message("assistant:reply", "assistant"),
            try message("assistant:summary", "assistant")
        )

        let room = try XCTUnwrap(store.workRoom(id: "codex:call-7"))
        XCTAssertEqual(room.currentTurn.map(\.messageID), ["user:request-1", "assistant:reply", "assistant:summary"])
        XCTAssertEqual(room.earlierMessages.map(\.messageID), ["user:initial", "assistant:plan"])
    }

    func testWithoutAUserMessageTheWholeConversationIsTheCurrentTurn() throws {
        let store = store(
            try frame("provider_invocation"),
            try message("assistant:plan", "assistant"),
            try message("assistant:reply", "assistant")
        )

        let room = try XCTUnwrap(store.workRoom(id: "codex:call-7"))
        XCTAssertEqual(room.currentTurn.map(\.messageID), ["assistant:plan", "assistant:reply"])
        XCTAssertEqual(room.earlierMessages, [])
    }

    func testUnknownWorkRoomIDGivesNoWorkRoom() throws {
        let store = store(try frame("provider_invocation"))
        XCTAssertNil(store.workRoom(id: "call-7"))
    }

    func testFencedCodeIsSeparatedFromTheProseAroundIt() throws {
        let text = "Built it:\n```sh\ncc -std=c11 -o /tmp/build/sort sort.c\n```\nAll tests pass."
        let store = store(try frame("provider_invocation"), try message("assistant:reply", "assistant", text))

        XCTAssertEqual(store.workRoom(id: "codex:call-7")?.currentTurn.first?.blocks, [
            .text("Built it:"),
            .code("cc -std=c11 -o /tmp/build/sort sort.c"),
            .text("All tests pass.")
        ])
    }

    func testUnclosedFenceKeepsTheRestAsCode() throws {
        let text = "Plain only\n```\nint main(void) {\n    return 0;"
        let store = store(try frame("provider_invocation"), try message("assistant:reply", "assistant", text))

        XCTAssertEqual(store.workRoom(id: "codex:call-7")?.currentTurn.first?.blocks, [
            .text("Plain only"),
            .code("int main(void) {\n    return 0;")
        ])
    }

    // MARK: Current activity and Last completed

    private func activity(_ id: String, _ sequence: Int, _ status: String, _ summary: String) throws -> OIPServerFrame {
        try frame("provider_activity", [
            "activityId": .string(id), "sequence": .number(Double(sequence)), "kind": .string("command"),
            "status": .string(status), "title": .string("Run the requested tests"), "summary": .string(summary),
            "files": nil
        ])
    }

    func testRunningActivityShowsWithOneLastCompletedResultAndTheRestEarlier() throws {
        let store = store(
            try frame("provider_invocation"),
            try activity("test-1", 1, "completed", "Completed the requested tests"),
            try activity("test-2", 2, "completed", "Completed the requested tests"),
            try activity("test-3", 3, "running", "Running the requested tests")
        )

        let room = try XCTUnwrap(store.workRoom(id: "codex:call-7"))
        XCTAssertEqual(room.currentActivity?.activityID, "test-3")
        XCTAssertEqual(room.lastCompleted?.activityID, "test-2")
        XCTAssertEqual(room.earlierActivities.map(\.activityID), ["test-1"])
    }

    func testAFailedStepIsShownAsTheLastResultSoAFailureIsNotHidden() throws {
        let store = store(
            try frame("provider_invocation"),
            try activity("test-1", 1, "completed", "Completed the requested tests"),
            try activity("test-2", 2, "failed", "The requested tests failed"),
            try activity("test-3", 3, "running", "Running the requested tests")
        )

        let room = try XCTUnwrap(store.workRoom(id: "codex:call-7"))
        XCTAssertEqual(room.lastCompleted?.activityID, "test-2")
        XCTAssertEqual(room.lastCompleted?.status, .failed)
    }

    func testNoLastCompletedResultWhileNothingRuns() throws {
        let store = store(
            try frame("provider_invocation"),
            try activity("test-1", 1, "completed", "Completed the requested tests"),
            try activity("test-2", 2, "completed", "Completed the requested tests")
        )

        let room = try XCTUnwrap(store.workRoom(id: "codex:call-7"))
        XCTAssertNil(room.currentActivity)
        XCTAssertNil(room.lastCompleted)
        XCTAssertEqual(room.earlierActivities.map(\.activityID), ["test-1", "test-2"])
    }

    func testAFinishedInvocationHasNoCurrentActivity() throws {
        let store = store(
            try frame("provider_invocation"),
            try activity("test-1", 1, "completed", "Completed the requested tests"),
            try activity("test-2", 2, "running", "Running the requested tests"),
            try frame("provider_invocation.terminal")
        )

        let room = try XCTUnwrap(store.workRoom(id: "codex:call-7"))
        XCTAssertNil(room.currentActivity)
        XCTAssertNil(room.lastCompleted)
        XCTAssertEqual(room.earlierActivities.map(\.activityID), ["test-1", "test-2"])
    }

    func testContinuationActivityRunsAfterTheRootsLastResult() throws {
        let continuationActivity = try frame("provider_activity", [
            "provider": .string("claude_code"), "invocationId": .string("claude_code:web-turn"),
            "parentToolCallId": .string("web-turn"), "activityId": .string("test-1"), "sequence": .number(1),
            "kind": .string("command"), "status": .string("running"), "title": .string("Run the requested tests"),
            "summary": .string("Running the requested tests"), "files": nil
        ])
        let rootActivity = try frame("provider_activity", [
            "provider": .string("claude_code"), "invocationId": .string("claude_code:station"),
            "parentToolCallId": .string("claude_station:station-session")
        ])
        let store = store(try stationRoot(), rootActivity, try stationContinuation(), continuationActivity)

        let room = try XCTUnwrap(store.workRoom(id: "claude_code:station"))
        XCTAssertEqual(room.currentActivity?.invocationID, "claude_code:web-turn")
        XCTAssertEqual(room.lastCompleted?.invocationID, "claude_code:station")
        XCTAssertEqual(room.earlierActivities, [])
    }
}
