import Foundation
import XCTest
@testable import ConnectOnionKit

/// A frame the transport could not write ends its request at once instead of looking sent.
@MainActor
final class WorkRoomSendFailureTests: XCTestCase {
    private let roomID = "codex:call-7"
    /// Each send's failure callback, in send order.
    private var failures: [@MainActor () -> Void] = []
    private var sent: [[String: JSONValue]] = []

    private func frame(_ name: String, _ changes: [String: JSONValue?] = [:]) throws -> OIPServerFrame {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/frames"))
        var body = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        for (key, value) in changes {
            body[key] = value
        }
        return OIPServerFrame.decode(body)
    }

    /// `call-7` at revision 2 with `status`, on a transport that keeps every failure callback.
    private func store(status: String) throws -> WorkRoomStore {
        let store = WorkRoomStore(schedule: { _, _ in })
        store.transport = WorkRoomTransport(
            frames: OIPClientFrames(
                keyStore: InMemoryPrivateKeyStore(rawKey: Data((0..<32).map { UInt8($0) })),
                to: "0x" + String(repeating: "ab", count: 32)
            ),
            sendReportingFailure: { [unowned self] frame, failed in
                sent.append(frame)
                failures.append(failed)
            }
        )
        store.receive(try frame("provider_invocation"))
        store.receive(try frame("provider_invocation", ["status": .string(status), "stateRevision": .number(2)]))
        return store
    }

    func testAnApprovalWhoseAnswerWasNotSentIsOpenAgain() throws {
        let store = try store(status: "awaiting_approval")
        store.receive(try frame("approval_needed.provider", ["id": .string("approval-codex-long")]))
        XCTAssertTrue(store.decide(.allowOnce, in: roomID))
        XCTAssertEqual(store.workRoom(id: roomID)?.approval?.phase, .settled(.allowOnce))

        failures.last?()

        XCTAssertEqual(store.workRoom(id: roomID)?.approval?.phase, .pending)
        XCTAssertTrue(store.decide(.reject, in: roomID))
    }

    func testAMessageThatWasNotSentKeepsItsDraftAndSaysSo() throws {
        let store = try store(status: "running")
        store.setDraft("hello", in: roomID)
        XCTAssertTrue(store.send(in: roomID))

        failures.last?()

        let composer = try XCTUnwrap(store.workRoom(id: roomID)?.composer)
        XCTAssertFalse(composer.isSending)
        XCTAssertEqual(composer.draft, "hello")
        XCTAssertEqual(composer.rejection, WorkRoomRequest.notSent)
    }

    func testAStopThatWasNotSentFailsClosed() throws {
        let store = try store(status: "running")
        XCTAssertTrue(store.stop(in: roomID))

        failures.last?()

        XCTAssertEqual(store.workRoom(id: roomID)?.stop.phase, .unconfirmed)
    }

    func testAFailureReportedAfterTheAnswerChangesNothing() throws {
        let store = try store(status: "running")
        store.setDraft("hello", in: roomID)
        XCTAssertTrue(store.send(in: roomID))
        let requestID = try XCTUnwrap(sent.last?["requestId"]?.stringValue)
        store.receive(try frame("PROVIDER_INPUT_ACK", [
            "requestId": .string(requestID), "invocationId": .string(roomID),
            "accepted": .bool(true), "stateRevision": .number(2)
        ]))

        failures.last?()

        XCTAssertNil(store.workRoom(id: roomID)?.composer.rejection)
        XCTAssertEqual(store.workRoom(id: roomID)?.composer.draft, "")
    }
}
