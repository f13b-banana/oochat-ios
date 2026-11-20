import Foundation
import XCTest
@testable import ConnectOnionKit

/// The Scoped Stop through the Work Room store: the signed frame it sends and what the Work Room
/// shows from the request to the terminal event, with time driven by hand.
@MainActor
final class WorkRoomStopTests: XCTestCase {

    // MARK: Helpers

    private final class Outbox {
        var frames: [[String: JSONValue]] = []
    }

    private final class Timers {
        var pending: [(delay: Duration, action: @MainActor () -> Void)] = []

        /// Runs every timer that was set for this delay, as if that much time had passed.
        @MainActor func elapse(_ delay: Duration) {
            let due = pending.filter { $0.delay == delay }
            pending.removeAll { $0.delay == delay }
            due.forEach { $0.action() }
        }
    }

    private let outbox = Outbox()
    private let timers = Timers()

    private func fixtureBody(_ name: String) throws -> [String: JSONValue] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/frames"),
            "Missing fixture \(name).json"
        )
        return try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    private func frame(_ name: String, _ changes: [String: JSONValue?] = [:]) throws -> OIPServerFrame {
        var body = try fixtureBody(name)
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
        _ sent: [String: JSONValue]? = nil, accepted: Bool = true, revision: Int? = 2, reason: String? = nil,
        requestID: String? = nil, invocationID: String = "codex:call-7"
    ) throws -> OIPServerFrame {
        try frame("PROVIDER_INTERRUPT_ACK.accepted", [
            "requestId": .string(requestID ?? sent?["requestId"]?.stringValue ?? "none"),
            "invocationId": .string(invocationID),
            "accepted": .bool(accepted),
            "stateRevision": revision.map { .number(Double($0)) },
            "reason": reason.map(JSONValue.string)
        ])
    }

    /// A store with `call-7` running at revision 2 and a transport that records what it sends.
    private func openStore(transport: Bool = true) throws -> WorkRoomStore {
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
        return store
    }

    private func room(_ store: WorkRoomStore) throws -> WorkRoom {
        try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
    }

    private func approvalFrame() throws -> OIPServerFrame {
        try frame("approval_needed.provider", ["id": .string("approval-codex-long")])
    }

    /// A store that sent a Stop and got the accepted ack.
    private func stoppedStore() throws -> WorkRoomStore {
        let store = try openStore()
        XCTAssertTrue(store.stop(in: "codex:call-7"))
        store.receive(try ack(outbox.frames[0]))
        return store
    }

    // MARK: Request

    func testStopSendsOneSignedInterruptWithTheRevisionOnScreenAndDisablesStop() throws {
        let store = try openStore()
        XCTAssertTrue(try room(store).stop.offersStop)

        XCTAssertTrue(store.stop(in: "codex:call-7"))

        let sent = try XCTUnwrap(outbox.frames.first)
        XCTAssertEqual(outbox.frames.count, 1)
        XCTAssertEqual(sent["type"]?.stringValue, "PROVIDER_INTERRUPT")
        XCTAssertEqual(sent["invocationId"]?.stringValue, "codex:call-7")
        XCTAssertEqual(sent["stateRevision"], .number(2))
        XCTAssertNotNil(sent["signature"])
        XCTAssertEqual(try room(store).stop.phase, .requesting)
        XCTAssertTrue(try room(store).stop.isRequesting)
        XCTAssertFalse(try room(store).stop.offersStop)
        XCTAssertFalse(store.stop(in: "codex:call-7"), "one Stop in flight at a time")
        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testStopRefusesWithoutARevisionOrATransportOrAnUnfinishedRun() throws {
        let noRevision = try openStore()
        noRevision.receive(try frame("provider_invocation", ["invocationId": .string("codex:other"),
                                                              "parentToolCallId": .string("other"),
                                                              "workroomId": .string("codex:other"),
                                                              "stateRevision": nil]))
        XCTAssertFalse(noRevision.stop(in: "codex:other"))
        XCTAssertFalse(try XCTUnwrap(noRevision.workRoom(forToolCallID: "other")).stop.offersStop)

        let noTransport = try openStore(transport: false)
        XCTAssertFalse(noTransport.stop(in: "codex:call-7"))
        XCTAssertEqual(try room(noTransport).stop.phase, .idle)
        XCTAssertFalse(try room(noTransport).stop.offersStop)
        let reason = try XCTUnwrap(try room(noTransport).stop.unavailableReason)
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("cancel") || reason.localizedCaseInsensitiveContains("interrupt"))
        noTransport.transport = try openStore().transport
        XCTAssertTrue(try room(noTransport).stop.offersStop)
        XCTAssertNil(try room(noTransport).stop.unavailableReason)
        noTransport.transport = nil

        let finished = try openStore()
        finished.receive(try frame("provider_invocation.terminal"))
        XCTAssertFalse(finished.stop(in: "codex:call-7"))
        XCTAssertFalse(try room(finished).stop.offersStop)

        XCTAssertFalse(finished.stop(in: "unknown"))
        XCTAssertTrue(outbox.frames.isEmpty)
    }

    // MARK: Lifecycle

    func testAcceptedAckHoldsTheBarrierUntilATerminalEventRestoresControls() throws {
        let store = try stoppedStore()

        XCTAssertEqual(try room(store).stop.phase, .acknowledged)
        XCTAssertEqual(try room(store).stop.barrierText, "Stop requested")
        XCTAssertFalse(try room(store).stop.offersStop)
        XCTAssertFalse(store.stop(in: "codex:call-7"))

        store.receive(try frame("provider_invocation.terminal"))
        timers.elapse(.seconds(15))

        XCTAssertEqual(try room(store).stop.phase, .idle)
        XCTAssertNil(try room(store).stop.barrierText)
        XCTAssertEqual(try room(store).status, .cancelled)
    }

    func testDelayedAckStillAcknowledgesBeforeTheTimeout() throws {
        let store = try openStore()
        store.stop(in: "codex:call-7")

        store.receive(try ack(outbox.frames[0]))
        timers.elapse(.seconds(10))

        XCTAssertEqual(try room(store).stop.phase, .acknowledged)
    }

    func testAnErrorWithTheStopsRequestIDNeedsConfirmationInsteadOfWaiting() throws {
        let store = try openStore()
        XCTAssertTrue(store.stop(in: "codex:call-7"))
        let sent = try XCTUnwrap(outbox.frames[0]["requestId"]?.stringValue)

        store.receive(try frame("ERROR", ["request_id": .string("other")]))
        XCTAssertEqual(try room(store).stop.phase, .requesting)

        store.receive(try frame("ERROR", ["request_id": .string(sent)]))
        XCTAssertEqual(try room(store).stop.phase, .unconfirmed)
        XCTAssertEqual(try room(store).stop.barrierText, "Status needs confirmation")
        XCTAssertFalse(try room(store).stop.offersStop)
    }

    func testNoTerminalEventWithinFifteenSecondsNeedsConfirmationAndStaysClosed() throws {
        let store = try stoppedStore()

        timers.elapse(.seconds(15))

        XCTAssertEqual(try room(store).stop.phase, .unconfirmed)
        XCTAssertEqual(try room(store).stop.barrierText, "Status needs confirmation")
        XCTAssertFalse(try room(store).stop.offersStop)
        XCTAssertFalse(store.stop(in: "codex:call-7"))

        store.receive(try frame("provider_invocation.terminal"))
        XCTAssertEqual(try room(store).stop.phase, .idle)
    }

    func testNewerRevisionReleasesTheBarrierButAnEqualOrOlderReplayCannot() throws {
        let store = try stoppedStore()

        store.receive(try status("running", revision: 2))
        store.receive(try status("running", revision: 1))
        XCTAssertEqual(try room(store).stop.phase, .acknowledged)

        store.receive(try status("running", revision: 3))
        XCTAssertEqual(try room(store).stop.phase, .idle)
        XCTAssertTrue(try room(store).stop.offersStop)
    }

    func testAStaleTerminalReplayCannotReleaseTheBarrier() throws {
        let store = try stoppedStore()

        store.receive(try frame("provider_invocation.terminal", ["stateRevision": .number(2)]))

        XCTAssertEqual(try room(store).stop.phase, .acknowledged)
        XCTAssertEqual(try room(store).status, .running)
    }

    // MARK: Refusals

    func testRejectedAckExplainsWhyAndRestoresStopForEveryReason() throws {
        let reasons = ["not_active", "invalid_request", "invalid_revision", "state_changed",
                       "state_unconfirmed", "something_new", nil]
        var seen = Set<String>()
        for reason in reasons {
            outbox.frames.removeAll()
            let store = try openStore()
            store.stop(in: "codex:call-7")

            store.receive(try ack(outbox.frames[0], accepted: false, reason: reason))

            let stop = try room(store).stop
            XCTAssertEqual(stop.phase, .idle, "\(String(describing: reason))")
            XCTAssertTrue(stop.offersStop)
            let text = try XCTUnwrap(stop.rejection)
            XCTAssertFalse(text.lowercased().contains("cancel") || text.lowercased().contains("interrupt"), text)
            seen.insert(text)
        }
        XCTAssertEqual(seen.count, 6, "five known reasons and one generic line")
    }

    func testRetryAfterARejectionClearsTheExplanation() throws {
        let store = try openStore()
        store.stop(in: "codex:call-7")
        store.receive(try ack(outbox.frames[0], accepted: false, reason: "state_changed"))

        XCTAssertTrue(store.stop(in: "codex:call-7"))

        XCTAssertNil(try room(store).stop.rejection)
        XCTAssertEqual(outbox.frames.count, 2)
    }

    func testAcceptedAckWithAnotherRevisionHoldsTheBarrierAsUnconfirmed() throws {
        for revision in [1, 3, nil] as [Int?] {
            outbox.frames.removeAll()
            let store = try openStore()
            store.stop(in: "codex:call-7")

            store.receive(try ack(outbox.frames[0], revision: revision))

            let stop = try room(store).stop
            XCTAssertEqual(stop.phase, .unconfirmed, "\(String(describing: revision))")
            XCTAssertEqual(stop.barrierText, "Status needs confirmation")
            XCTAssertFalse(stop.offersStop)
            XCTAssertNil(stop.rejection)
        }
    }

    func testUncorrelatedAcksAreIgnored() throws {
        let store = try openStore()
        store.stop(in: "codex:call-7")
        let sent = outbox.frames[0]

        store.receive(try ack(sent, requestID: "someone-else"))
        store.receive(try ack(sent, invocationID: "codex:other"))
        store.receive(try ack(sent, requestID: ""))
        store.receive(try ack(sent, accepted: false, reason: "not_active", requestID: "someone-else"))

        XCTAssertEqual(try room(store).stop.phase, .requesting)
        XCTAssertNil(try room(store).stop.rejection)
    }

    func testAckWithNothingInFlightIsIgnored() throws {
        let store = try openStore()

        store.receive(try ack(nil, requestID: "interrupt-1"))

        XCTAssertEqual(try room(store).stop.phase, .idle)
        XCTAssertNil(try room(store).stop.rejection)
    }

    func testASecondAckForTheSameRequestIsIgnored() throws {
        let store = try stoppedStore()

        store.receive(try ack(outbox.frames[0], accepted: false, reason: "not_active"))

        XCTAssertEqual(try room(store).stop.phase, .acknowledged)
        XCTAssertNil(try room(store).stop.rejection)
    }

    // MARK: Timeout and disconnect

    func testNoAckWithinTenSecondsNeedsConfirmationBecauseTheHostMayHaveActed() throws {
        let store = try openStore()
        store.stop(in: "codex:call-7")

        timers.elapse(.seconds(10))

        XCTAssertEqual(try room(store).stop.phase, .unconfirmed)
        XCTAssertFalse(try room(store).stop.offersStop)
        XCTAssertFalse(store.stop(in: "codex:call-7"))

        store.receive(try ack(outbox.frames[0]))
        XCTAssertEqual(try room(store).stop.phase, .unconfirmed, "a late ack does not reopen it")
        XCTAssertEqual(outbox.frames.count, 1, "never retried")
    }

    func testDisconnectWhileRequestingFailsTheStopVisiblyAndNeverRetries() throws {
        let store = try openStore()
        store.stop(in: "codex:call-7")

        store.connectionDidDrop()

        XCTAssertEqual(try room(store).stop.phase, .unconfirmed)
        XCTAssertEqual(try room(store).stop.barrierText, "Status needs confirmation")
        XCTAssertFalse(store.stop(in: "codex:call-7"))
        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testDisconnectWithoutAStopChangesNothing() throws {
        let store = try openStore()

        store.connectionDidDrop()

        XCTAssertEqual(try room(store).stop.phase, .idle)
    }

    // MARK: Approval

    func testAcceptedStopClearsTheApprovalAndHidesAReplayedOne() throws {
        let store = try openStore()
        store.receive(try status("awaiting_approval", revision: 3))
        store.receive(try approvalFrame())
        XCTAssertNotNil(try room(store).approval)
        store.stop(in: "codex:call-7")
        store.receive(try ack(outbox.frames[0], revision: 3))

        XCTAssertNil(try room(store).approval)
        store.receive(try approvalFrame())
        XCTAssertNil(try room(store).approval, "an equal-revision replay stays hidden")
        XCTAssertFalse(store.decide(.reject, in: "codex:call-7"))

        timers.elapse(.seconds(15))
        store.receive(try approvalFrame())
        XCTAssertNil(try room(store).approval, "and stays hidden while status needs confirmation")
    }

    func testNoApprovalCanBeAnsweredWhileAStopExistsAndARefusalBringsItBack() throws {
        let store = try openStore()
        store.receive(try status("awaiting_approval", revision: 3))
        store.receive(try approvalFrame())

        store.stop(in: "codex:call-7")
        XCTAssertNil(try room(store).approval)
        XCTAssertFalse(store.decide(.reject, in: "codex:call-7"))

        store.receive(try ack(outbox.frames[0], accepted: false, reason: "state_changed"))
        XCTAssertTrue(try XCTUnwrap(room(store).approval).offersAllow)
    }

    func testANewerRevisionReleasesAStopThatIsStillRequesting() throws {
        let store = try openStore()
        store.stop(in: "codex:call-7")
        XCTAssertEqual(try room(store).stop.phase, .requesting)

        store.receive(try status("running", revision: 3))
        XCTAssertEqual(try room(store).stop.phase, .idle)
        XCTAssertTrue(try room(store).stop.offersStop)
    }
}
