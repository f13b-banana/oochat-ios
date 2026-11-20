import Foundation
import XCTest
@testable import ConnectOnionKit

/// Handing Control of a Claude Station between the terminal and this device through the Work Room store:
/// `provider_session` and its own revision counter, the signed PROVIDER_CONTROL, and the composer that follows
/// Control, with time driven by hand.
@MainActor
final class WorkRoomControlTests: XCTestCase {

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
    private let stationID = "claude_code:station:station-session"

    private func fields(_ name: String, _ changes: [String: JSONValue?] = [:]) throws -> [String: JSONValue] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/frames"),
            "Missing fixture \(name).json"
        )
        var body = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        for (key, value) in changes {
            body[key] = value
        }
        return body
    }

    private func frame(_ name: String, _ changes: [String: JSONValue?] = [:]) throws -> OIPServerFrame {
        OIPServerFrame.decode(try fields(name, changes))
    }

    /// A paired store on a host that advertised session-sync, holding the Station's invocation.
    private func openStore(sync: Bool = true, transport: Bool = true, paired: Bool = true) throws -> WorkRoomStore {
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
        guard case .connected(let connected) = try frame(sync ? "CONNECTED.session_sync" : "CONNECTED") else {
            throw XCTSkip("not a CONNECTED frame")
        }
        store.receiveSnapshot(connected)
        store.receive(try frame("provider_invocation.station"))
        if paired {
            _ = store.pairStation(code: "test-pairing-code")
            let id = outbox.frames.last?["request_id"]?.stringValue ?? "none"
            store.receive(try frame("PROVIDER_STATION_ATTACH_ACK", ["request_id": .string(id), "requestId": .string(id)]))
            outbox.frames.removeAll()
        }
        return store
    }

    private func session(
        _ owner: String = "terminal", _ phase: String = "local_observing", revision: Int = 2
    ) throws -> OIPServerFrame {
        try frame("provider_session", ["owner": .string(owner), "phase": .string(phase), "stateRevision": .number(Double(revision))])
    }

    /// A store where the terminal has Control at control revision 2.
    private func terminalStore() throws -> WorkRoomStore {
        let store = try openStore()
        store.receive(try session())
        return store
    }

    private func control(_ store: WorkRoomStore) -> WorkRoomControl? {
        store.stationWorkRoom?.control
    }

    private func controlAck(
        _ name: String = "PROVIDER_CONTROL_ACK", to sent: [String: JSONValue]?, _ changes: [String: JSONValue?] = [:]
    ) throws -> OIPServerFrame {
        var all = changes
        all["request_id"] = .string(sent?["request_id"]?.stringValue ?? "none")
        all["requestId"] = .string(sent?["request_id"]?.stringValue ?? "none")
        return try frame(name, all)
    }

    @discardableResult
    private func take(_ store: WorkRoomStore) -> [String: JSONValue]? {
        _ = store.changeControl(.take, in: stationID)
        return outbox.frames.last
    }

    // MARK: provider_session

    func testProviderSessionDecodesTheFixtureAndRejectsInvalidFields() throws {
        XCTAssertEqual(
            try frame("provider_session"),
            .providerSession(OIPProviderSession(
                invocationID: stationID, parentToolCallID: "claude_station:station-session",
                owner: .terminal, phase: .localObserving, stateRevision: 2
            ))
        )
        let bad: [[String: JSONValue?]] = [
            ["owner": .string("host")], ["owner": nil], ["phase": .string("paused")], ["phase": nil],
            ["stateRevision": .number(0)], ["stateRevision": nil], ["stateRevision": .string("2")],
            ["invocationId": nil], ["invocationId": .string("")]
        ]
        for changes in bad {
            guard case .unknown = try frame("provider_session", changes) else {
                return XCTFail("\(changes) should not decode")
            }
        }
    }

    func testProviderSessionSetsControlOnTheKnownStationInvocation() throws {
        let store = try openStore()
        XCTAssertNil(control(store))

        store.receive(try session())

        XCTAssertEqual(control(store)?.owner, .terminal)
        XCTAssertEqual(control(store)?.ownerLabel, "Terminal")
        XCTAssertEqual(control(store)?.phase, .localObserving)
    }

    func testProviderSessionForAnUnknownInvocationIsDropped() throws {
        let store = try openStore()

        store.receive(try frame("provider_session", ["invocationId": .string("claude_code:station:other")]))

        XCTAssertNil(control(store))
    }

    func testOlderAndEqualControlRevisionsAreDropped() throws {
        let store = try terminalStore()

        store.receive(try session("browser", "remote_controlling", revision: 1))
        XCTAssertEqual(control(store)?.owner, .terminal)
        store.receive(try session("browser", "remote_controlling", revision: 2))
        XCTAssertEqual(control(store)?.owner, .terminal)

        store.receive(try session("browser", "remote_controlling", revision: 3))
        XCTAssertEqual(control(store)?.owner, .browser)
        XCTAssertEqual(control(store)?.ownerLabel, "This device")
    }

    func testControlRevisionIsSeparateFromTheInvocationRevision() throws {
        let store = try openStore()
        // The invocation is at revision 1; a control revision of 1 is still the first one and is kept.
        store.receive(try session(revision: 1))
        XCTAssertEqual(control(store)?.owner, .terminal)

        store.receive(try frame("provider_invocation.station", ["stateRevision": .number(9)]))
        store.receive(try session("browser", "remote_controlling", revision: 2))
        XCTAssertEqual(control(store)?.owner, .browser)
    }

    func testPhasesHaveLabelsOnlyWhileSomethingIsChanging() throws {
        let store = try terminalStore()
        XCTAssertNil(control(store)?.phaseLabel)

        store.receive(try session("browser", "handover_to_remote", revision: 3))
        XCTAssertEqual(control(store)?.phaseLabel, "Handing control to this device")
    }

    // MARK: Snapshots

    private func snapshot(_ station: [String: JSONValue?]) throws -> OIPConnected {
        var item = try fields("provider_invocation.station", ["stateRevision": .number(5)])
        for (key, value) in station {
            item[key] = value
        }
        guard case .connected(let connected) = try frame("CONNECTED.snapshot", ["chat_items": .array([.object(item)])]) else {
            throw XCTSkip("not a CONNECTED frame")
        }
        return connected
    }

    func testASnapshotCarriesTheControlTripleOnlyWhenAllThreeAreValid() throws {
        let full: [String: JSONValue?] = [
            "controlOwner": .string("browser"), "controlPhase": .string("remote_controlling"), "controlRevision": .number(4)
        ]
        let store = try openStore()
        store.receiveSnapshot(try snapshot(["controlOwner": .string("browser"), "controlRevision": .number(4)]))
        XCTAssertNil(control(store))

        store.receiveSnapshot(try snapshot(full.merging(["controlRevision": .number(0)]) { $1 }))
        XCTAssertNil(control(store))

        store.receiveSnapshot(try snapshot(full.merging(["stateRevision": .number(6)]) { $1 }))
        XCTAssertEqual(control(store)?.owner, .browser)
    }

    func testASnapshotNeverTakesControlBackwards() throws {
        let store = try terminalStore()
        store.receive(try session("browser", "remote_controlling", revision: 4))

        store.receiveSnapshot(try snapshot([
            "controlOwner": .string("terminal"), "controlPhase": .string("local_observing"), "controlRevision": .number(3)
        ]))

        XCTAssertEqual(control(store)?.owner, .browser)
    }

    func testASnapshotControlIsNotHeldBackByAnEqualInvocationRevision() throws {
        let store = try terminalStore()
        store.receive(try session("browser", "remote_controlling", revision: 4))
        store.receiveSnapshot(try snapshot(["stateRevision": .number(5)]))

        store.receiveSnapshot(try snapshot([
            "stateRevision": .number(5),
            "controlOwner": .string("browser"), "controlPhase": .string("handover_to_local"), "controlRevision": .number(6)
        ]))

        XCTAssertEqual(control(store)?.phase, .handoverToLocal)
    }

    // MARK: Taking and returning Control

    func testTakeSendsOneSignedFrameWithTheControlRevisionAndThePairedSession() throws {
        let store = try terminalStore()
        store.receive(try frame("provider_invocation.station", ["stateRevision": .number(9)]))

        XCTAssertTrue(store.changeControl(.take, in: stationID))

        XCTAssertEqual(outbox.frames.count, 1)
        let sent = try XCTUnwrap(outbox.frames.first)
        XCTAssertEqual(sent["type"]?.stringValue, OIPFrameType.providerControl)
        XCTAssertEqual(sent["sessionId"]?.stringValue, "station-session")
        XCTAssertEqual(sent["action"]?.stringValue, "take")
        XCTAssertEqual(sent["stateRevision"]?.intValue, 2)
        XCTAssertFalse(try XCTUnwrap(sent["request_id"]?.stringValue).isEmpty)
        XCTAssertNotNil(sent["signature"])
        XCTAssertEqual(control(store)?.pending, .take)
    }

    func testControlChangesOnlyAfterTheMatchingAcceptedAck() throws {
        let store = try terminalStore()
        let sent = take(store)

        store.receive(try controlAck(to: ["request_id": .string("someone-else")]))
        store.receive(try controlAck(to: sent, ["action": .string("release")]))
        XCTAssertEqual(control(store)?.owner, .terminal)
        XCTAssertEqual(control(store)?.pending, .take)

        store.receive(try controlAck(to: sent))
        XCTAssertEqual(control(store)?.owner, .browser)
        XCTAssertEqual(control(store)?.phase, .remoteControlling)
        XCTAssertNil(control(store)?.pending)
        XCTAssertNil(control(store)?.failure)
    }

    func testAProviderSessionAtTheAcknowledgedRevisionAfterwardsIsANoOp() throws {
        let store = try terminalStore()
        store.receive(try controlAck(to: take(store)))

        store.receive(try session("terminal", "local_observing", revision: 3))
        XCTAssertEqual(control(store)?.owner, .browser)

        store.receive(try session("terminal", "local_starting", revision: 4))
        XCTAssertEqual(control(store)?.owner, .terminal)
    }

    func testAProviderSessionThatArrivesBeforeTheAckKeepsTheNewerState() throws {
        let store = try terminalStore()
        let sent = take(store)
        store.receive(try session("browser", "remote_controlling", revision: 3))

        store.receive(try controlAck(to: sent))

        XCTAssertEqual(control(store)?.owner, .browser)
        XCTAssertNil(control(store)?.pending)
    }

    func testReturnToTerminalSendsReleaseWithTheNewControlRevision() throws {
        let store = try terminalStore()
        store.receive(try controlAck(to: take(store)))
        outbox.frames.removeAll()

        XCTAssertTrue(store.changeControl(.release, in: stationID))

        let sent = try XCTUnwrap(outbox.frames.first)
        XCTAssertEqual(sent["action"]?.stringValue, "release")
        XCTAssertEqual(sent["stateRevision"]?.intValue, 3)

        store.receive(try controlAck(to: sent, ["action": .string("release"), "stateRevision": .number(4)]))
        XCTAssertEqual(control(store)?.owner, .browser)
        XCTAssertEqual(control(store)?.phase, .handoverToLocal)
        XCTAssertEqual(store.stationWorkRoom?.composer.unavailableReason, WorkRoomControlRules.changingHands)
    }

    func testAnErrorWithTheSameRequestIDRejectsTheChange() throws {
        let store = try terminalStore()
        let sent = take(store)

        store.receive(try frame("ERROR", ["request_id": .string("another")]))
        XCTAssertEqual(control(store)?.pending, .take)

        store.receive(try frame("ERROR", ["request_id": sent?["request_id"]]))
        XCTAssertNil(control(store)?.pending)
        XCTAssertEqual(control(store)?.failure, WorkRoomControlRules.refused)
        XCTAssertEqual(control(store)?.owner, .terminal)
    }

    func testEachRejectionReasonShowsItsOwnPlainCopy() throws {
        var seen = Set<String>()
        for reason in ["invalid_request", "stale_or_unowned", "not_ready", "handover_timeout", "provider_busy"] {
            let store = try terminalStore()
            let sent = take(store)

            store.receive(try controlAck("PROVIDER_CONTROL_ACK.\(reason)", to: sent))

            let text = try XCTUnwrap(control(store)?.failure, reason)
            XCTAssertEqual(text, WorkRoomControlRules.rejectionText(reason: reason))
            XCTAssertNotEqual(text, WorkRoomControlRules.rejectionText(reason: "something_new"), reason)
            XCTAssertTrue(seen.insert(text).inserted, "\(reason) repeats another reason's copy")
            XCTAssertEqual(control(store)?.owner, .terminal, reason)
            XCTAssertNil(control(store)?.pending, reason)
        }
        XCTAssertEqual(WorkRoomControlRules.rejectionText(reason: nil), "The host did not change who has control.")
    }

    func testAnAcceptedAckWithoutAPositiveRevisionDoesNotChangeControl() throws {
        for revision: JSONValue? in [nil, .number(0), .string("3")] {
            let store = try terminalStore()
            let sent = take(store)

            store.receive(try controlAck(to: sent, ["stateRevision": revision]))

            XCTAssertEqual(control(store)?.owner, .terminal)
            XCTAssertEqual(control(store)?.failure, WorkRoomControlRules.unverified)
        }
    }

    func testNoAnswerInThirtySecondsFailsTheChange() throws {
        let store = try terminalStore()
        let sent = take(store)
        XCTAssertTrue(timers.pending.contains { $0.delay == .seconds(30) })

        timers.elapse(.seconds(30))

        XCTAssertNil(control(store)?.pending)
        XCTAssertEqual(control(store)?.failure, WorkRoomControlRules.timedOut)
        // A late answer changes nothing.
        store.receive(try controlAck(to: sent))
        XCTAssertEqual(control(store)?.owner, .terminal)
    }

    func testADroppedConnectionFailsThePendingChange() throws {
        let store = try terminalStore()
        let sent = take(store)

        store.connectionDidDrop()
        store.receive(try controlAck(to: sent))

        XCTAssertNil(control(store)?.pending)
        XCTAssertEqual(control(store)?.failure, WorkRoomControlRules.connectionDropped)
        XCTAssertEqual(control(store)?.owner, .terminal)
    }

    func testOnlyOneChangeIsInFlight() throws {
        let store = try terminalStore()
        XCTAssertTrue(store.changeControl(.take, in: stationID))

        XCTAssertFalse(store.changeControl(.take, in: stationID))
        XCTAssertFalse(store.changeControl(.release, in: stationID))

        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testControlDoesNotNeedSessionSync() throws {
        let store = try openStore(sync: false)
        store.receive(try session())

        XCTAssertNil(control(store)?.unavailableReason)
        XCTAssertTrue(store.changeControl(.take, in: stationID))
        XCTAssertEqual(outbox.frames.last?["type"]?.stringValue, "PROVIDER_CONTROL")
    }

    func testAChangeIsRefusedWithoutWhatItNeeds() throws {
        let noTransport = try openStore(transport: false)
        noTransport.receive(try session())
        XCTAssertFalse(noTransport.changeControl(.take, in: stationID))

        let unpaired = try openStore(paired: false)
        unpaired.receive(try session())
        XCTAssertFalse(unpaired.changeControl(.take, in: stationID))

        let noRevision = try openStore()
        XCTAssertFalse(noRevision.changeControl(.take, in: stationID))

        XCTAssertTrue(outbox.frames.isEmpty)
    }

    func testTheSideThatAlreadyHasControlCannotAskForIt() throws {
        let store = try terminalStore()
        XCTAssertFalse(store.changeControl(.release, in: stationID))

        store.receive(try session("browser", "handover_to_remote", revision: 3))
        XCTAssertFalse(store.changeControl(.take, in: stationID))
        XCTAssertFalse(store.changeControl(.release, in: stationID))

        XCTAssertTrue(outbox.frames.isEmpty)
    }

    func testTheButtonsFollowWhoHasControl() throws {
        let store = try terminalStore()
        XCTAssertEqual(control(store)?.canTake, true)
        XCTAssertEqual(control(store)?.canRelease, false)

        store.receive(try session("browser", "remote_controlling", revision: 3))
        XCTAssertEqual(control(store)?.canTake, false)
        XCTAssertEqual(control(store)?.canRelease, true)

        store.connectionDidDrop()
        XCTAssertEqual(control(store)?.canRelease, false)
        XCTAssertNotNil(control(store)?.unavailableReason)
    }

    // MARK: The composer follows Control

    func testTheComposerIsDisabledWhileTheTerminalHasControlAndEnabledAfterTake() throws {
        let store = try terminalStore()
        XCTAssertEqual(store.stationWorkRoom?.composer.unavailableReason, WorkRoomControlRules.terminalHasControl)
        store.setDraft("hello", in: stationID)
        XCTAssertFalse(store.send(in: stationID))

        store.receive(try controlAck(to: take(store)))

        XCTAssertNil(store.stationWorkRoom?.composer.unavailableReason)
        store.setDraft("hello", in: stationID)
        XCTAssertTrue(store.send(in: stationID))
        XCTAssertEqual(outbox.frames.last?["type"]?.stringValue, OIPFrameType.providerInput)
    }

    func testTheMicIsDisabledWhileTheTerminalHasControlAndEnabledAfterTake() throws {
        let store = try terminalStore()
        XCTAssertEqual(store.stationWorkRoom?.composer.canDictate, false)

        store.receive(try controlAck(to: take(store)))
        XCTAssertEqual(store.stationWorkRoom?.composer.canDictate, true)
    }

    func testTheComposerIsDisabledWhileControlIsUnknownOrChangingHands() throws {
        let store = try openStore()
        XCTAssertEqual(store.stationWorkRoom?.composer.unavailableReason, WorkRoomControlRules.controlUnknown)

        store.receive(try session("browser", "handover_to_remote", revision: 3))
        XCTAssertEqual(store.stationWorkRoom?.composer.unavailableReason, WorkRoomControlRules.changingHands)
    }

    func testTheComposerIsDisabledWithTheEndedCopyOnceTheSessionHasEnded() throws {
        let store = try openStore()
        store.receive(try session("browser", "completed", revision: 3))
        XCTAssertEqual(store.stationWorkRoom?.composer.unavailableReason, WorkRoomControlRules.sessionEnded)
    }

    func testAnOrdinaryWorkRoomComposerIsNotAffectedByControl() throws {
        let store = try openStore()
        store.receive(try frame("provider_invocation"))

        let room = try XCTUnwrap(store.workRooms.first { !$0.isClaudeStation })

        XCTAssertNil(room.control)
        XCTAssertNil(room.composer.unavailableReason)
    }

    func testTerminalOwnsSessionIsRefusedWithTheSameCopyAsTheDisabledComposer() throws {
        let store = try terminalStore()
        store.receive(try controlAck(to: take(store)))
        store.setDraft("hello", in: stationID)
        XCTAssertTrue(store.send(in: stationID))
        let sent = try XCTUnwrap(outbox.frames.last)

        store.receive(try frame("PROVIDER_INPUT_ACK.terminal_owns_session", [
            "requestId": sent["requestId"], "invocationId": .string(stationID)
        ]))

        XCTAssertEqual(store.stationWorkRoom?.composer.rejection, WorkRoomControlRules.terminalHasControl)
        XCTAssertEqual(store.stationWorkRoom?.composer.draft, "hello")
    }
}
