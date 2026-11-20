import Foundation
import XCTest
@testable import ConnectOnionKit

/// The Stop Barrier across a relaunch: a second store created over the same storage and scope, with the
/// clock and the storage driven by hand.
@MainActor
final class WorkRoomBarrierPersistenceTests: XCTestCase {

    // MARK: Helpers

    private final class MemoryStorage: WorkRoomBarrierStorage {
        var values: [String: Any] = [:]
        func object(forKey defaultName: String) -> Any? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
        func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    }

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

    private let storage = MemoryStorage()
    private let outbox = Outbox()
    private let timers = Timers()
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private let scope = "0xabc:session-1"

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

    private func makeStore(scope: String? = "0xabc:session-1") -> WorkRoomStore {
        let timers = timers
        let store = WorkRoomStore(
            schedule: { delay, action in timers.pending.append((delay, action)) },
            barrierScope: scope, barrierStorage: storage, now: { [unowned self] in clock }
        )
        let outbox = outbox
        store.transport = WorkRoomTransport(
            frames: OIPClientFrames(
                keyStore: InMemoryPrivateKeyStore(rawKey: Data((0..<32).map { UInt8($0) })),
                to: "0x" + String(repeating: "ab", count: 32)
            ),
            send: { outbox.frames.append($0) }
        )
        return store
    }

    /// A store with `call-7` running at revision 2.
    private func openStore(scope: String? = "0xabc:session-1") throws -> WorkRoomStore {
        let store = makeStore(scope: scope)
        store.receive(try frame("provider_invocation"))
        store.receive(try status("running", revision: 2))
        return store
    }

    /// A relaunch: a new store over the same storage that is shown the same run again.
    private func relaunch(revision: Int = 2) throws -> WorkRoomStore {
        let store = makeStore()
        store.receive(try frame("provider_invocation"))
        store.receive(try status("running", revision: revision))
        return store
    }

    private func stop(_ store: WorkRoomStore) throws -> WorkRoomStop {
        try XCTUnwrap(store.workRoom(forToolCallID: "call-7")).stop
    }

    private func acknowledge(_ store: WorkRoomStore) throws {
        XCTAssertTrue(store.stop(in: "codex:call-7"))
        let sent = try XCTUnwrap(outbox.frames.last)
        store.receive(try frame("PROVIDER_INTERRUPT_ACK.accepted", [
            "requestId": sent["requestId"], "invocationId": .string("codex:call-7"), "stateRevision": .number(2)
        ]))
    }

    private var key: String { WorkRoomBarrierStore.key(scope: scope) }

    private func saved() throws -> [StoredStopBarrier] {
        let data = try XCTUnwrap(storage.values[key] as? Data)
        return try JSONDecoder().decode([StoredStopBarrier].self, from: data)
    }

    // MARK: Forgetting a barrier

    func testForgettingABarrierRemovesItAndLeavesOtherChatsAlone() throws {
        let store = try openStore()
        try acknowledge(store)
        let otherKey = WorkRoomBarrierStore.key(scope: "0xabc:session-2")
        storage.set(storage.values[key], forKey: otherKey)
        XCTAssertNotNil(storage.values[key])

        WorkRoomStore.forgetBarrier(scope: scope, storage: storage)

        XCTAssertNil(storage.values[key])
        XCTAssertNotNil(storage.values[otherKey])
        XCTAssertEqual(try stop(try relaunch()).phase, .idle, "a new store finds no barrier")
    }

    // MARK: Save and restore

    func testBarrierIsSavedBeforeSendingAndOnEveryChangeThenRestoredWithItsRemainingTime() throws {
        let store = try openStore()
        XCTAssertNil(storage.values[key])

        XCTAssertTrue(store.stop(in: "codex:call-7"))
        XCTAssertEqual(try saved(), [StoredStopBarrier(invocationId: "codex:call-7", stateRevision: 2, phase: "requesting")])

        let sent = try XCTUnwrap(outbox.frames.last)
        store.receive(try frame("PROVIDER_INTERRUPT_ACK.accepted", [
            "requestId": sent["requestId"], "invocationId": .string("codex:call-7"), "stateRevision": .number(2)
        ]))
        let entry = try XCTUnwrap(try saved().first)
        XCTAssertEqual(entry.phase, "acknowledged")
        XCTAssertEqual(entry.expiresAt, clock.timeIntervalSince1970 + 15)

        clock += 5
        let restored = try relaunch()
        XCTAssertEqual(try stop(restored).phase, .acknowledged)
        XCTAssertEqual(try stop(restored).barrierText, "Stop requested")
        XCTAssertFalse(try stop(restored).offersStop)
        timers.elapse(.seconds(10))
        XCTAssertEqual(try stop(restored).phase, .unconfirmed, "the time that was left runs out")
    }

    func testARequestingStopComesBackNeedingConfirmation() throws {
        let store = try openStore()
        XCTAssertTrue(store.stop(in: "codex:call-7"))

        let restored = try relaunch()

        XCTAssertEqual(try stop(restored).phase, .unconfirmed)
        XCTAssertEqual(try stop(restored).barrierText, "Status needs confirmation")
        XCTAssertFalse(try stop(restored).offersStop)
        XCTAssertFalse(restored.stop(in: "codex:call-7"))
    }

    func testAnExpiredAcknowledgementComesBackNeedingConfirmation() throws {
        try acknowledge(try openStore())
        clock += 15

        XCTAssertEqual(try stop(try relaunch()).phase, .unconfirmed)
    }

    func testAnAcknowledgementWithoutAValidRevisionComesBackNeedingConfirmation() throws {
        for revision in [JSONValue.null, .number(0), .number(-3)] {
            let entry: [String: JSONValue] = [
                "invocationId": .string("codex:call-7"), "phase": .string("acknowledged"),
                "stateRevision": revision, "expiresAt": .number(clock.timeIntervalSince1970 + 10)
            ]
            storage.values[key] = try JSONEncoder().encode([entry])

            XCTAssertEqual(try stop(try relaunch()).phase, .unconfirmed)
        }
    }

    func testARestoredBarrierIsReleasedByANewerRevisionOrAnEnd() throws {
        try acknowledge(try openStore())

        let newer = try relaunch(revision: 3)
        XCTAssertEqual(try stop(newer).phase, .idle)
        XCTAssertNil(storage.values[key])

        try acknowledge(try openStore())
        let ended = makeStore()
        ended.receive(try frame("provider_invocation.terminal"))
        XCTAssertEqual(try stop(ended).phase, .idle)
        XCTAssertNil(storage.values[key])

        try acknowledge(try openStore())
        let equal = try relaunch(revision: 2)
        XCTAssertEqual(try stop(equal).phase, .acknowledged, "an equal revision replay does not release it")
    }

    func testReleasingTheBarrierDeletesTheEntry() throws {
        let store = try openStore()
        try acknowledge(store)
        XCTAssertNotNil(storage.values[key])

        store.receive(try frame("provider_invocation.terminal"))

        XCTAssertNil(storage.values[key])
        XCTAssertEqual(try stop(try relaunch()).phase, .idle)
    }

    func testARefusedStopLeavesNothingSaved() throws {
        let store = try openStore()
        XCTAssertTrue(store.stop(in: "codex:call-7"))
        let sent = try XCTUnwrap(outbox.frames.last)
        store.receive(try frame("PROVIDER_INTERRUPT_ACK.accepted", [
            "requestId": sent["requestId"], "invocationId": .string("codex:call-7"),
            "accepted": .bool(false), "reason": .string("not_active"), "stateRevision": nil
        ]))

        XCTAssertNil(storage.values[key])
    }

    func testStoresWithDifferentScopesDoNotSeeEachOther() throws {
        try acknowledge(try openStore())

        let other = try openStore(scope: "0xabc:session-2")
        XCTAssertEqual(try stop(other).phase, .idle)
        XCTAssertTrue(try stop(other).offersStop)

        let unscoped = try openStore(scope: nil)
        XCTAssertEqual(try stop(unscoped).phase, .idle)
    }

    func testMovingTheBarrierToAnotherScopeRestoresItThereAndLeavesNothingBehind() throws {
        let store = try openStore()
        try acknowledge(store)

        store.moveBarrier(toScope: "0xabc:session-2")

        XCTAssertNil(storage.values[key])
        let restored = try openStore(scope: "0xabc:session-2")
        XCTAssertEqual(try stop(restored).phase, .acknowledged)
        XCTAssertFalse(try stop(restored).offersStop)
        XCTAssertEqual(try stop(try openStore()).phase, .idle)
    }

    // MARK: Untrusted storage

    private func assertUntrusted(_ stored: Any, file: StaticString = #filePath, line: UInt = #line) throws {
        storage.values[key] = stored
        let store = makeStore()
        store.receive(try status("running", revision: 2))
        store.receive(try frame("provider_invocation", [
            "invocationId": .string("codex:call-8"), "parentToolCallId": .string("call-8"),
            "workroomId": .string("codex:call-8"), "stateRevision": .number(4), "status": .string("running")
        ]))
        for (call, id) in [("call-7", "codex:call-7"), ("call-8", "codex:call-8")] {
            let room = try XCTUnwrap(store.workRoom(forToolCallID: call), file: file, line: line)
            XCTAssertEqual(room.stop.phase, .unconfirmed, id, file: file, line: line)
            XCTAssertEqual(room.stop.barrierText, "Status needs confirmation", file: file, line: line)
            XCTAssertFalse(room.stop.offersStop, file: file, line: line)
        }

        store.receive(try status("running", revision: 3))
        XCTAssertEqual(try stop(store).phase, .idle, "a newer revision clears it", file: file, line: line)
        store.receive(try frame("provider_invocation.terminal", [
            "invocationId": .string("codex:call-8"), "parentToolCallId": .string("call-8"), "stateRevision": .number(5)
        ]))
        XCTAssertEqual(try XCTUnwrap(store.workRoom(forToolCallID: "call-8")).stop.phase, .idle, file: file, line: line)
    }

    func testCorruptJSONMarksEveryLiveInvocationAsNeedingConfirmation() throws {
        try assertUntrusted(Data("{not json".utf8))
    }

    func testAWrongShapeOrTypeMarksEveryLiveInvocationAsNeedingConfirmation() throws {
        try assertUntrusted(Data(#"{"invocationId":"codex:call-7"}"#.utf8))
        try assertUntrusted(Data(#"[{"invocationId":"codex:call-7","phase":"sleeping"}]"#.utf8))
        try assertUntrusted(Data(#"[{"invocationId":"","phase":"requesting"}]"#.utf8))
        try assertUntrusted("a string, not data")
    }

    func testDuplicateEntriesMarkEveryLiveInvocationAsNeedingConfirmation() throws {
        let entry = #"{"invocationId":"codex:call-7","stateRevision":2,"phase":"requesting"}"#
        try assertUntrusted(Data("[\(entry),\(entry)]".utf8))
    }
}
