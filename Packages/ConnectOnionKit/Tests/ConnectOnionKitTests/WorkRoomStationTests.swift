import Foundation
import XCTest
@testable import ConnectOnionKit

/// Opening a Claude Station through the Work Room store: detecting the Station and session-sync, Pairing
/// with its signed PROVIDER_STATION_ATTACH, and the Station's own Work Room, with time driven by hand.
@MainActor
final class WorkRoomStationTests: XCTestCase {

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

    private func connected(_ name: String) throws -> OIPConnected {
        guard case .connected(let value) = try frame(name) else {
            throw XCTSkip("\(name) is not a CONNECTED frame")
        }
        return value
    }

    private func transport() -> WorkRoomTransport {
        let outbox = outbox
        return WorkRoomTransport(
            frames: OIPClientFrames(
                keyStore: InMemoryPrivateKeyStore(rawKey: Data((0..<32).map { UInt8($0) })),
                to: "0x" + String(repeating: "ab", count: 32)
            ),
            send: { outbox.frames.append($0) }
        )
    }

    /// A store connected to a host that advertised session-sync, with a transport that records what it sends.
    private func openStore(
        syncAdvertised: Bool = true, transport hasTransport: Bool = true, rememberedCode: String? = nil
    ) throws -> WorkRoomStore {
        let timers = timers
        let store = WorkRoomStore(schedule: { delay, action in timers.pending.append((delay, action)) })
        if hasTransport {
            store.transport = transport()
        }
        if let rememberedCode {
            store.rememberOnboardingCode(rememberedCode)
        }
        store.receiveSnapshot(try connected(syncAdvertised ? "CONNECTED.session_sync" : "CONNECTED"))
        return store
    }

    private func attachAck(_ name: String, to sent: [String: JSONValue]?, _ changes: [String: JSONValue?] = [:]) throws
        -> OIPServerFrame {
        var all = changes
        all["request_id"] = .string(sent?["request_id"]?.stringValue ?? "none")
        all["requestId"] = .string(sent?["request_id"]?.stringValue ?? "none")
        return try frame(name, all)
    }

    private func pair(_ store: WorkRoomStore, code: String = "test-pairing-code") -> [String: JSONValue]? {
        _ = store.pairStation(code: code)
        return outbox.frames.last
    }

    // MARK: session-sync and Station detection

    func testSessionSyncIsDetectedOnlyWhenConnectedAdvertisesItAtVersion01() throws {
        XCTAssertTrue(try connected("CONNECTED.session_sync").advertisesSessionSync)
        XCTAssertFalse(try connected("CONNECTED").advertisesSessionSync)
        guard case .connected(let wrongVersion) = OIPServerFrame.decode(try fields("CONNECTED.session_sync", [
            "protocol": .object(["name": .string("oip"), "extensions": .object(["session-sync": .string("0.2")])])
        ])) else {
            return XCTFail("expected CONNECTED")
        }
        XCTAssertFalse(wrongVersion.advertisesSessionSync)
    }

    func testAnAgentProfileMarksAClaudeStationOnlyForClaudeCode() throws {
        guard case .agentProfile(let station) = try frame("AGENT_PROFILE.station"),
              case .agentProfile(let ordinary) = try frame("AGENT_PROFILE"),
              case .agentProfile(let unknown) = try frame("AGENT_PROFILE.station", ["provider_station": .string("other")]) else {
            return XCTFail("expected AGENT_PROFILE")
        }
        XCTAssertEqual(station.providerStation, .claudeCode)
        XCTAssertTrue(station.isClaudeStation)
        XCTAssertFalse(ordinary.isClaudeStation)
        XCTAssertFalse(unknown.isClaudeStation)
    }

    func testPairingDoesNotNeedSessionSync() throws {
        let store = try openStore(syncAdvertised: false)

        XCTAssertTrue(store.stationPairing.canPair)
        XCTAssertNil(store.stationPairing.unavailableReason)
        XCTAssertTrue(store.pairStation(code: "test-pairing-code"))
        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testPairingNeedsAConnectionAndSaysSoInPlainWords() throws {
        let offline = try openStore(transport: false)

        XCTAssertFalse(offline.stationPairing.canPair)
        XCTAssertEqual(
            offline.stationPairing.unavailableReason,
            "There is no connection to the agent right now. Pairing needs one."
        )
        XCTAssertFalse(offline.pairStation(code: "test-pairing-code"))
    }

    // MARK: One code, used twice

    func testARememberedCodeAttachesByItselfOnceTheConnectionIsReady() throws {
        let timers = timers
        let store = WorkRoomStore(schedule: { delay, action in timers.pending.append((delay, action)) })
        store.rememberOnboardingCode(" test-pairing-code ")
        XCTAssertTrue(store.stationPairing.hasRememberedCode)
        XCTAssertFalse(store.stationPairing.needsCode)

        store.transport = transport()
        XCTAssertTrue(outbox.frames.isEmpty, "no CONNECTED yet")
        store.receiveSnapshot(try connected("CONNECTED"))

        XCTAssertEqual(outbox.frames.count, 1)
        XCTAssertEqual(outbox.frames.first?["type"]?.stringValue, "PROVIDER_STATION_ATTACH")
        XCTAssertEqual(outbox.frames.first?["payload"]?.objectValue?["pairingCode"]?.stringValue, "test-pairing-code")
        XCTAssertEqual(store.stationPairing.state, .pairing)
        XCTAssertFalse(store.stationPairing.hasRememberedCode)
        XCTAssertFalse(store.stationPairing.needsCode)
    }

    func testTheAutomaticAttachRunsOnlyOnce() throws {
        let store = try openStore(rememberedCode: "test-pairing-code")
        store.receiveSnapshot(try connected("CONNECTED"))
        store.transport = transport()

        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testARememberedCodeWaitsForTheTransportAndPairsWhenItArrives() throws {
        let store = try openStore(transport: false, rememberedCode: "test-pairing-code")
        XCTAssertTrue(outbox.frames.isEmpty)

        store.transport = transport()

        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testPairingViewIsNeededOnlyWhenTheAutomaticAttachFails() throws {
        let store = try openStore(rememberedCode: "wrong-code")
        let sent = try XCTUnwrap(outbox.frames.last)
        XCTAssertFalse(store.stationPairing.needsCode)

        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK.invalid_pairing_code", to: sent))

        XCTAssertTrue(store.stationPairing.needsCode)
        XCTAssertTrue(store.pairStation(code: "right-code"))
    }

    func testWithNothingRememberedThePairingViewIsNeeded() throws {
        XCTAssertTrue(try openStore().stationPairing.needsCode)
    }

    // MARK: A Station refuses ordinary chat

    func testProviderStationOnlyMarksTheAgentAsAStationAndIsNotAFailure() throws {
        let store = try openStore()
        XCTAssertFalse(store.isStationHost)
        guard case .error(let error) = try frame("ERROR", [
            "code": .string("provider_station_only"), "message": .string("Use the Claude Work Room")
        ]) else {
            return XCTFail("expected ERROR")
        }
        XCTAssertTrue(error.isProviderStationOnly)

        store.receive(.error(error))

        XCTAssertTrue(store.isStationHost)
        XCTAssertEqual(store.stationPairing.state, .unpaired)
    }

    func testAnOrdinaryErrorIsNotProviderStationOnly() throws {
        guard case .error(let error) = try frame("ERROR") else {
            return XCTFail("expected ERROR")
        }
        XCTAssertFalse(error.isProviderStationOnly)
    }

    // MARK: ATTACH

    func testPairingSendsOneSignedAttachWithTheCodeAndARequestID() throws {
        let store = try openStore()

        XCTAssertTrue(store.pairStation(code: "  test-pairing-code \n"))

        let sent = try XCTUnwrap(outbox.frames.first)
        XCTAssertEqual(outbox.frames.count, 1)
        XCTAssertEqual(sent["type"]?.stringValue, "PROVIDER_STATION_ATTACH")
        XCTAssertEqual(sent["pairingCode"]?.stringValue, "test-pairing-code")
        XCTAssertFalse(try XCTUnwrap(sent["request_id"]?.stringValue).isEmpty)
        XCTAssertNotNil(sent["signature"])
        let payload = try XCTUnwrap(sent["payload"]?.objectValue)
        XCTAssertEqual(payload["pairingCode"]?.stringValue, "test-pairing-code")
        XCTAssertEqual(payload["request_id"], sent["request_id"])
        XCTAssertNil(payload["requestId"])
        XCTAssertEqual(store.stationPairing.state, .pairing)
        XCTAssertNotNil(store.stationPairing.unavailableReason)
    }

    func testAnEmptyCodeSendsNothing() throws {
        let store = try openStore()
        XCTAssertFalse(store.pairStation(code: "  "))
        XCTAssertTrue(outbox.frames.isEmpty)
        XCTAssertEqual(store.stationPairing.state, .unpaired)
    }

    func testAnAcceptedAckPairsWithTheSessionID() throws {
        let store = try openStore()
        let sent = pair(store)

        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK", to: sent))

        XCTAssertEqual(store.stationPairing.state, .paired(sessionID: "station-session"))
        XCTAssertEqual(store.stationPairing.sessionID, "station-session")
        XCTAssertFalse(store.stationPairing.canPair)
        XCTAssertFalse(store.pairStation(code: "test-pairing-code"))
        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testAnAckForAnotherRequestIsIgnored() throws {
        let store = try openStore()
        _ = pair(store)

        store.receive(try frame("PROVIDER_STATION_ATTACH_ACK", ["request_id": .string("someone-else")]))

        XCTAssertEqual(store.stationPairing.state, .pairing)
    }

    func testAnAckWithoutASessionIDDoesNotPair() throws {
        let store = try openStore()
        let sent = pair(store)

        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK", to: sent, ["sessionId": nil]))

        guard case .failed = store.stationPairing.state else {
            return XCTFail("expected failed, got \(store.stationPairing.state)")
        }
        XCTAssertNil(store.stationPairing.sessionID)
    }

    func testAnInvalidPairingCodeFailsWithPlainCopyAndCanBeRetried() throws {
        let store = try openStore()
        let sent = pair(store)

        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK.invalid_pairing_code", to: sent))

        XCTAssertEqual(store.stationPairing.state, .failed(reason: StationPairingRules.rejectionText(reason: "invalid_pairing_code")))
        XCTAssertTrue(store.stationPairing.canPair)
        XCTAssertTrue(store.pairStation(code: "second-try"))
        XCTAssertEqual(outbox.frames.count, 2)
    }

    func testInvalidRequestAndUnknownReasonsGetDifferentPlainCopy() throws {
        let store = try openStore()
        let first = pair(store)
        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK.invalid_request", to: first))
        let invalidRequest = store.stationPairing.state

        let second = pair(store)
        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK.invalid_request", to: second, ["reason": .string("brand_new")]))

        XCTAssertEqual(invalidRequest, .failed(reason: StationPairingRules.rejectionText(reason: "invalid_request")))
        XCTAssertEqual(store.stationPairing.state, .failed(reason: StationPairingRules.rejectionText(reason: nil)))
        XCTAssertNotEqual(invalidRequest, store.stationPairing.state)
    }

    func testAnErrorWithTheSameRequestIDRejectsTheAttachAndOthersAreIgnored() throws {
        let store = try openStore()
        let sent = pair(store)

        store.receive(try frame("ERROR", ["request_id": .string("someone-else")]))
        XCTAssertEqual(store.stationPairing.state, .pairing)

        store.receive(try frame("ERROR", ["request_id": sent?["request_id"]]))
        XCTAssertEqual(store.stationPairing.state, .failed(reason: StationPairingRules.refused))
    }

    func testOnlyOneAttachIsInFlight() throws {
        let store = try openStore()
        _ = pair(store)

        XCTAssertFalse(store.pairStation(code: "another-code"))

        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testTheHostGets30SecondsThenPairingFailsAndALateAckIsIgnored() throws {
        let store = try openStore()
        let sent = pair(store)

        timers.elapse(.seconds(30))
        XCTAssertEqual(store.stationPairing.state, .failed(reason: StationPairingRules.timedOut))

        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK", to: sent))
        XCTAssertEqual(store.stationPairing.state, .failed(reason: StationPairingRules.timedOut))
    }

    func testAStaleTimerAfterAnAnswerChangesNothing() throws {
        let store = try openStore()
        let sent = pair(store)
        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK", to: sent))

        timers.elapse(.seconds(30))

        XCTAssertEqual(store.stationPairing.state, .paired(sessionID: "station-session"))
    }

    func testADisconnectFailsTheAttachAndNothingIsRetried() throws {
        let store = try openStore()
        _ = pair(store)

        store.connectionDidDrop()

        XCTAssertEqual(store.stationPairing.state, .failed(reason: StationPairingRules.connectionDropped))
        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testAPairedStationStaysPairedWhenTheConnectionDrops() throws {
        let store = try openStore()
        store.receive(try attachAck("PROVIDER_STATION_ATTACH_ACK", to: pair(store)))

        store.connectionDidDrop()

        XCTAssertEqual(store.stationPairing.state, .paired(sessionID: "station-session"))
    }

    // MARK: The Station's Work Room

    func testTheStationWorkRoomIsFoundDirectlyAndShowsTheStationCopy() throws {
        let store = try openStore()
        XCTAssertNil(store.stationWorkRoom)

        store.receive(try frame("provider_invocation.station"))

        let room = try XCTUnwrap(store.stationWorkRoom)
        XCTAssertTrue(room.isClaudeStation)
        XCTAssertEqual(room.id, "claude_code:station:station-session")
        XCTAssertEqual(room.provider, .claudeCode)
        XCTAssertEqual(room.title, "Claude Code session")
        XCTAssertEqual(room.summary, "Session ready in the terminal")
        XCTAssertEqual(room.status, .running)
    }

    func testEveryStationSummaryRendersAndOffTheListCopyDoesNot() throws {
        let store = try openStore()
        var revision = 1.0
        for summary in [
            "Running in the terminal", "Claude Code is working", "Ready for a browser message", "Session ready in the terminal"
        ] {
            store.receive(try frame("provider_invocation.station", [
                "currentSummary": .string(summary), "stateRevision": .number(revision)
            ]))
            XCTAssertEqual(store.stationWorkRoom?.summary, summary)
            revision += 1
        }
        let fresh = try openStore()
        fresh.receive(try frame("provider_invocation.station", [
            "currentSummary": .string("Anything else"), "taskTitle": .string("Something else")
        ]))
        XCTAssertNil(fresh.stationWorkRoom?.summary)
        XCTAssertNil(fresh.stationWorkRoom?.title)
    }

    func testAnOrdinaryClaudeWorkRoomIsNotAStation() throws {
        let store = try openStore()
        store.receive(try frame("provider_invocation", [
            "provider": .string("claude_code"), "invocationId": .string("claude_code:call-1"),
            "parentToolCallId": .string("call-1"), "workroomId": .string("claude_code:call-1")
        ]))

        XCTAssertNil(store.stationWorkRoom)
        XCTAssertEqual(store.workRooms.count, 1)
    }

    // MARK: A fresh Station and replays

    private func provisional(_ revision: Int = 1) throws -> OIPServerFrame {
        try frame("provider_session", ["stateRevision": .number(Double(revision))])
    }

    func testAFreshStationGetsAWorkRoomFromProviderSessionAlone() throws {
        let store = try openStore()

        store.receive(try provisional())

        let room = try XCTUnwrap(store.stationWorkRoom)
        XCTAssertEqual(room.provider, .claudeCode)
        XCTAssertEqual(room.id, "claude_code:station:station-session")
        XCTAssertEqual(room.title, "Claude Code session")
        XCTAssertNil(room.summary)
        XCTAssertEqual(room.control?.owner, .terminal)
        XCTAssertFalse(room.composer.isSupported, "no revision until a provider_invocation arrives")
        XCTAssertTrue(store.isStationHost)
    }

    func testAProviderSessionForAnotherInvocationMakesNoWorkRoom() throws {
        let store = try openStore()

        store.receive(try frame("provider_session", ["invocationId": .string("claude_code:call-1")]))

        XCTAssertEqual(store.workRooms, [])
    }

    func testTheStationInvocationFillsInTheRoomMadeFromProviderSession() throws {
        let store = try openStore()
        store.receive(try provisional())

        store.receive(try frame("provider_invocation.station"))

        let room = try XCTUnwrap(store.stationWorkRoom)
        XCTAssertEqual(store.workRooms.count, 1)
        XCTAssertEqual(room.summary, "Session ready in the terminal")
        XCTAssertEqual(room.control?.owner, .terminal)
    }

    func testAFullStationReplayTwiceChangesNothing() throws {
        let replay = [
            try frame("provider_invocation.station"),
            try frame("provider_activity", [
                "provider": .string("claude_code"), "invocationId": .string("claude_code:station:station-session"),
                "parentToolCallId": .string("claude_station:station-session")
            ]),
            try frame("provider_message", [
                "provider": .string("claude_code"), "invocationId": .string("claude_code:station:station-session"),
                "parentToolCallId": .string("claude_station:station-session"), "workroomId": nil
            ]),
            try provisional(2)
        ]
        let store = try openStore()
        replay.forEach(store.receive)
        let once = store.workRooms

        replay.forEach(store.receive)

        XCTAssertEqual(store.workRooms, once)
        XCTAssertEqual(once.first?.messages.count, 1)
        XCTAssertEqual(once.first?.activities.count, 1)
    }

    func testAStationHasNoPermissionProfileSelector() throws {
        let store = try openStore()
        store.receive(try frame("provider_invocation.permission.claude", [
            "invocationId": .string("claude_code:station:station-session"),
            "parentToolCallId": .string("claude_station:station-session"),
            "workroomId": .string("claude_code:station:station-session")
        ]))

        XCTAssertNotNil(store.stationWorkRoom)
        XCTAssertNil(store.stationWorkRoom?.permission)
    }
}
