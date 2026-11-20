import Foundation
import XCTest
@testable import ConnectOnionKit

/// Provider Input through the Work Room store: the signed frame it sends, what the composer shows,
/// and when the draft goes, with time driven by hand.
@MainActor
final class WorkRoomInputTests: XCTestCase {

    // MARK: Helpers

    private final class Outbox {
        var frames: [[String: JSONValue]] = []
    }

    private final class Timers {
        var pending: [(delay: Duration, action: @MainActor () -> Void)] = []

        @MainActor func elapse(_ delay: Duration) {
            let due = pending.filter { $0.delay == delay }
            pending.removeAll { $0.delay == delay }
            due.forEach { $0.action() }
        }
    }

    private let outbox = Outbox()
    private let timers = Timers()
    private let roomID = "codex:call-7"

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

    private func status(_ status: String, revision: Int?) throws -> OIPServerFrame {
        try frame("provider_invocation", [
            "status": .string(status), "stateRevision": revision.map { .number(Double($0)) }
        ])
    }

    private func ack(
        _ sent: [String: JSONValue]?, accepted: Bool = true, revision: Int? = 2, reason: String? = nil,
        invocationID: String = "codex:call-7"
    ) throws -> OIPServerFrame {
        try frame("PROVIDER_INPUT_ACK", [
            "requestId": .string(sent?["requestId"]?.stringValue ?? "none"),
            "invocationId": .string(invocationID),
            "accepted": .bool(accepted),
            "stateRevision": revision.map { .number(Double($0)) },
            "reason": reason.map(JSONValue.string)
        ])
    }

    /// A store with `call-7` running at revision 2, a transport that records what it sends and a draft.
    private func openStore(transport: Bool = true, draft: String? = "  Add a reverse-order fixture  ") throws -> WorkRoomStore {
        let timers = timers
        let store = WorkRoomStore(schedule: { delay, action in timers.pending.append((delay, action)) })
        let outbox = outbox
        if transport {
            store.transport = WorkRoomTransport(
                frames: OIPClientFrames(
                    keyStore: InMemoryPrivateKeyStore(rawKey: Data((0..<32).map { UInt8($0) })),
                    to: "0x" + String(repeating: "ab", count: 32)
                ),
                send: { outbox.frames.append($0) }
            )
        }
        store.receive(try frame("provider_invocation"))
        store.receive(try status("running", revision: 2))
        if let draft {
            store.setDraft(draft, in: roomID)
        }
        return store
    }

    private func composer(_ store: WorkRoomStore) throws -> WorkRoomComposer {
        try XCTUnwrap(store.workRoom(id: roomID)).composer
    }

    private func continuation(revision: Int = 1) throws -> OIPServerFrame {
        try frame("provider_invocation", [
            "invocationId": .string("codex:turn-2"), "parentToolCallId": .string("call-8"),
            "continuationOf": .string("codex:call-7"), "workroomId": .string("codex:call-7"),
            "status": .string("running"), "stateRevision": .number(Double(revision))
        ])
    }

    // MARK: Request

    func testSendEmitsOneSignedInputForTheCurrentInvocationWithTheRevisionOnScreenAndTheTrimmedText() throws {
        let store = try openStore()
        store.receive(try continuation(revision: 3))

        XCTAssertTrue(store.send(in: roomID))

        let sent = try XCTUnwrap(outbox.frames.first)
        XCTAssertEqual(outbox.frames.count, 1)
        XCTAssertEqual(sent["type"]?.stringValue, "PROVIDER_INPUT")
        XCTAssertEqual(sent["invocationId"]?.stringValue, "codex:turn-2")
        XCTAssertEqual(sent["stateRevision"], .number(3))
        XCTAssertEqual(sent["text"]?.stringValue, "Add a reverse-order fixture")
        XCTAssertNotNil(sent["signature"])
        XCTAssertTrue(try composer(store).isSending)
    }

    func testSendRefusesWithoutARevisionATransportOrUsableText() throws {
        let noTransport = try openStore(transport: false)
        XCTAssertFalse(noTransport.send(in: roomID))

        let noRevision = try openStore()
        noRevision.receive(try frame("provider_invocation", [
            "invocationId": .string("codex:other"), "parentToolCallId": .string("other"),
            "workroomId": .string("codex:other"), "stateRevision": nil
        ]))
        noRevision.setDraft("hello", in: "codex:other")
        XCTAssertFalse(noRevision.send(in: "codex:other"))

        let blank = try openStore(draft: "  \n ")
        XCTAssertFalse(blank.send(in: roomID))

        let tooLong = try openStore(draft: String(repeating: "a", count: 12_001))
        XCTAssertTrue(try composer(tooLong).isOverLimit)
        XCTAssertFalse(tooLong.send(in: roomID))

        XCTAssertFalse(noTransport.send(in: "unknown"))
        XCTAssertTrue(outbox.frames.isEmpty)
    }

    func testOnlyOneInputIsInFlightAndTheDraftCannotChangeMeanwhile() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        XCTAssertFalse(store.send(in: roomID))
        store.setDraft("something else", in: roomID)

        XCTAssertEqual(outbox.frames.count, 1)
        XCTAssertEqual(try composer(store).draft, "  Add a reverse-order fixture  ")
    }

    func testOnlyProviderInputFramesAreEverEmitted() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        store.receive(try ack(outbox.frames[0], accepted: false, reason: "not_active"))
        store.setDraft("again", in: roomID)
        XCTAssertTrue(store.send(in: roomID))

        XCTAssertEqual(outbox.frames.count, 2)
        XCTAssertTrue(outbox.frames.allSatisfy { $0["type"]?.stringValue == "PROVIDER_INPUT" })
    }

    // MARK: Answer

    func testAnAcceptedAckThatEchoesTheRevisionClearsTheDraft() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        store.receive(try ack(outbox.frames[0]))

        XCTAssertEqual(try composer(store).draft, "")
        XCTAssertFalse(try composer(store).isSending)
        XCTAssertNil(try composer(store).rejection)
    }

    func testAnAcceptedAckWithAWrongOrMissingRevisionKeepsTheDraftAndSaysWhy() throws {
        for revision in [3, nil] as [Int?] {
            let store = try openStore()
            outbox.frames = []
            XCTAssertTrue(store.send(in: roomID))
            store.receive(try ack(outbox.frames[0], revision: revision))

            XCTAssertEqual(try composer(store).draft, "  Add a reverse-order fixture  ")
            XCTAssertNotNil(try composer(store).rejection)
            XCTAssertFalse(try composer(store).isSending)
        }
    }

    func testARejectedAckKeepsTheDraftWithPlainCopyForEachReason() throws {
        let reasons = [
            "not_active", "unsupported_provider", "state_changed", "state_unconfirmed",
            "provider_start_failed", "terminal_owns_session", "invalid_request", "invalid_revision", "something_new"
        ]
        var copies = Set<String>()
        for reason in reasons {
            let store = try openStore()
            outbox.frames = []
            XCTAssertTrue(store.send(in: roomID))
            store.receive(try ack(outbox.frames[0], accepted: false, revision: nil, reason: reason))

            XCTAssertEqual(try composer(store).draft, "  Add a reverse-order fixture  ")
            let copy = try XCTUnwrap(try composer(store).rejection)
            copies.insert(copy)
            XCTAssertFalse(copy.contains("_"), "plain copy, not the reason code")
            XCTAssertNil(try composer(store).unavailableReason, "the draft can be sent again")
        }
        XCTAssertEqual(copies.count, reasons.count, "each reason has its own line, the unknown one the generic line")
    }

    func testAnErrorWithTheRequestIDFailsTheMessageInsteadOfWaitingSixtySeconds() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        let sent = try XCTUnwrap(outbox.frames[0]["requestId"]?.stringValue)

        store.receive(try frame("ERROR", ["request_id": .string("other")]))
        XCTAssertTrue(try composer(store).isSending)

        store.receive(try frame("ERROR", ["request_id": .string(sent)]))
        XCTAssertFalse(try composer(store).isSending)
        XCTAssertEqual(try composer(store).rejection, WorkRoomInputRules.rejectionText(reason: nil))
        XCTAssertEqual(try composer(store).draft, "  Add a reverse-order fixture  ")
    }

    func testAnotherWorkRoomShowsWhyItCannotSendWhileOneMessageWaits() throws {
        let store = try openStore()
        store.receive(try frame("provider_invocation", [
            "invocationId": .string("codex:other"), "workroomId": .string("codex:other"),
            "status": .string("running"), "stateRevision": .number(2)
        ]))
        store.setDraft("Hello", in: "codex:other")
        let other = { try XCTUnwrap(store.workRoom(id: "codex:other")).composer }

        XCTAssertTrue(store.send(in: roomID))

        XCTAssertFalse(try other().canSend)
        XCTAssertEqual(try other().unavailableReason, "Another Work Room is waiting for the host's answer.")
        store.receive(try ack(outbox.frames[0]))
        XCTAssertTrue(try other().canSend)
    }

    func testAnAckForAnotherRequestOrInvocationIsIgnored() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        store.receive(try ack(["requestId": .string("other")]))
        store.receive(try ack(outbox.frames[0], invocationID: "codex:elsewhere"))

        XCTAssertTrue(try composer(store).isSending)
        XCTAssertEqual(try composer(store).draft, "  Add a reverse-order fixture  ")
    }

    func testSixtySecondsWithoutAnAckKeepsTheDraftAndALateAckIsIgnored() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        timers.elapse(.seconds(60))

        XCTAssertFalse(try composer(store).isSending)
        XCTAssertEqual(try composer(store).draft, "  Add a reverse-order fixture  ")
        XCTAssertNotNil(try composer(store).rejection)

        store.receive(try ack(outbox.frames[0]))
        XCTAssertEqual(try composer(store).draft, "  Add a reverse-order fixture  ")
        XCTAssertEqual(outbox.frames.count, 1, "never retried")
    }

    func testAStaleTimerDoesNotFailALaterInput() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        store.receive(try ack(outbox.frames[0], accepted: false, reason: "not_active"))
        XCTAssertTrue(store.send(in: roomID))
        let firstTimer = timers.pending.removeFirst()
        firstTimer.action()
        XCTAssertTrue(try composer(store).isSending, "the first timer's request is long gone, the second still runs")
    }

    func testADroppedConnectionKeepsTheDraftAndSaysWhy() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        store.connectionDidDrop()

        let composer = try composer(store)
        XCTAssertEqual(composer.draft, "  Add a reverse-order fixture  ")
        XCTAssertFalse(composer.isSending)
        XCTAssertNotNil(composer.rejection)
        XCTAssertEqual(composer.unavailableReason, "Messages are available while the agent is connected.")
    }

    // MARK: Availability

    func testTheComposerIsDisabledWithAReasonInEachSituation() throws {
        let store = try openStore()
        XCTAssertNil(try composer(store).unavailableReason)
        XCTAssertTrue(try composer(store).canSend)

        let offline = try openStore(transport: false)
        XCTAssertEqual(try composer(offline).unavailableReason, "Messages are available while the agent is connected.")
        XCTAssertFalse(try composer(offline).canSend)

        XCTAssertTrue(store.send(in: roomID))
        XCTAssertEqual(try composer(store).unavailableReason, "Sending your message")
        store.receive(try ack(outbox.frames[0]))

        let unsupported = try openStore()
        unsupported.receive(try frame("provider_invocation", [
            "invocationId": .string("codex:other"), "parentToolCallId": .string("other"),
            "workroomId": .string("codex:other"), "stateRevision": nil
        ]))
        XCTAssertEqual(
            try XCTUnwrap(unsupported.workRoom(id: "codex:other")).composer.unavailableReason,
            "This host does not support messages to this run yet."
        )
    }

    func testTheComposerIsDisabledWhileAStopExists() throws {
        let store = try openStore()
        store.setDraft("ok", in: roomID)
        XCTAssertTrue(store.stop(in: roomID))
        XCTAssertNotNil(try composer(store).unavailableReason)
        XCTAssertFalse(store.send(in: roomID))
        XCTAssertEqual(try composer(store).unavailableReason, "Stopping this run. Messages are paused until it ends.")
    }

    func testTheComposerIsDisabledWhileAnApprovalDecisionIsPending() throws {
        let store = try openStore()
        store.receive(try status("awaiting_approval", revision: 3))
        store.receive(try frame("approval_needed.provider", ["id": .string("approval-codex-long")]))

        XCTAssertEqual(try composer(store).unavailableReason, "Answer the approval first, then send a message.")
        XCTAssertFalse(store.send(in: roomID))

        XCTAssertTrue(store.decide(.reject, in: roomID))
        XCTAssertNil(try composer(store).unavailableReason)
    }

    // MARK: Continuation

    func testSendingToAFinishedInvocationIsAllowedAndTheContinuationJoinsTheRoomAsCurrent() throws {
        let store = try openStore()
        store.receive(try status("completed", revision: 3))
        XCTAssertTrue(try composer(store).canSend)

        XCTAssertTrue(store.send(in: roomID))
        XCTAssertEqual(outbox.frames[0]["invocationId"]?.stringValue, "codex:call-7")
        XCTAssertEqual(outbox.frames[0]["stateRevision"], .number(3))

        store.receive(try continuation())
        store.receive(try ack(outbox.frames[0], revision: 3))

        XCTAssertEqual(store.workRooms.count, 1)
        let room = try XCTUnwrap(store.workRoom(id: roomID))
        XCTAssertEqual(room.status, .running)
        XCTAssertEqual(room.composer.draft, "")

        store.setDraft("next", in: roomID)
        XCTAssertTrue(store.send(in: roomID))
        XCTAssertEqual(outbox.frames[1]["invocationId"]?.stringValue, "codex:turn-2")
        XCTAssertEqual(outbox.frames[1]["stateRevision"], .number(1))
    }

    // MARK: Dictation

    func testDictationJoinsTheTrimmedTranscriptionToTheDraftWithOneSpace() throws {
        let store = try openStore(draft: nil)
        XCTAssertTrue(store.appendDictation("  first thought \n", in: roomID))
        XCTAssertEqual(try composer(store).draft, "first thought")

        XCTAssertTrue(store.appendDictation("second", in: roomID))
        XCTAssertEqual(try composer(store).draft, "first thought second")

        store.setDraft("typed  \n", in: roomID)
        XCTAssertTrue(store.appendDictation(" spoken ", in: roomID))
        XCTAssertEqual(try composer(store).draft, "typed spoken")
    }

    func testDictationNeverSendsAndBlankOrUnknownTextChangesNothing() throws {
        let store = try openStore(draft: "keep me")
        XCTAssertFalse(store.appendDictation(" \n ", in: roomID))
        XCTAssertFalse(store.appendDictation("words", in: "codex:unknown"))
        XCTAssertEqual(try composer(store).draft, "keep me")

        XCTAssertTrue(store.appendDictation("more", in: roomID))
        XCTAssertTrue(outbox.frames.isEmpty)
        XCTAssertFalse(try composer(store).isSending)
    }

    func testDictationPastTheLimitIsKeptAndBlocksSendUntilShortened() throws {
        let store = try openStore(draft: String(repeating: "a", count: 11_990))
        XCTAssertTrue(store.appendDictation(String(repeating: "b", count: 20), in: roomID))
        XCTAssertTrue(try composer(store).isOverLimit)
        XCTAssertFalse(try composer(store).canSend)
        XCTAssertFalse(store.send(in: roomID))
        XCTAssertTrue(outbox.frames.isEmpty)

        store.setDraft("short", in: roomID)
        XCTAssertTrue(try composer(store).canSend)
    }

    func testDictationIsIgnoredWhileTheRoomsMessageWaitsForTheHost() throws {
        let store = try openStore()
        XCTAssertTrue(store.send(in: roomID))
        XCTAssertFalse(store.appendDictation("late words", in: roomID))
        XCTAssertEqual(try composer(store).draft, "  Add a reverse-order fixture  ")
    }

    func testTheMicIsAvailableInExactlyTheSituationsSendIsExceptForAnEmptyDraft() throws {
        let store = try openStore(draft: nil)
        XCTAssertTrue(try composer(store).canDictate)
        XCTAssertFalse(try composer(store).canSend)

        store.setDraft("hello", in: roomID)
        XCTAssertEqual(try composer(store).canDictate, try composer(store).canSend)

        let offline = try openStore(transport: false)
        XCTAssertFalse(try composer(offline).canDictate)

        let stopping = try openStore()
        XCTAssertTrue(stopping.stop(in: roomID))
        XCTAssertFalse(try composer(stopping).canDictate)

        let deciding = try openStore()
        deciding.receive(try status("awaiting_approval", revision: 3))
        deciding.receive(try frame("approval_needed.provider", ["id": .string("approval-codex-long")]))
        XCTAssertFalse(try composer(deciding).canDictate)

        let sending = try openStore()
        XCTAssertTrue(sending.send(in: roomID))
        XCTAssertFalse(try composer(sending).canDictate)

        let unsupported = try openStore(draft: nil)
        unsupported.receive(try frame("provider_invocation", [
            "invocationId": .string("codex:other"), "parentToolCallId": .string("other"),
            "workroomId": .string("codex:other"), "stateRevision": nil
        ]))
        XCTAssertFalse(try XCTUnwrap(unsupported.workRoom(id: "codex:other")).composer.canDictate)
    }
}
