import Foundation
import XCTest
@testable import ConnectOnionKit

/// Provider approvals through the Work Room store: what the card and the Work Room may offer, and the one
/// APPROVAL_RESPONSE a decision sends.
@MainActor
final class WorkRoomApprovalTests: XCTestCase {

    // MARK: Helpers

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

    /// The catalog's approval_needed with some `providerApproval` fields replaced; nil removes one.
    private func approval(
        id: String? = "approval-codex-long",
        _ changes: [String: JSONValue?] = [:],
        outer: [String: JSONValue?] = [:]
    ) throws -> OIPServerFrame {
        var body = try fixtureBody("approval_needed.provider")
        body["id"] = id.map(JSONValue.string)
        var nested = try XCTUnwrap(body["providerApproval"]?.objectValue)
        for (key, value) in changes {
            nested[key] = value
        }
        body["providerApproval"] = .object(nested)
        for (key, value) in outer {
            body[key] = value
        }
        return OIPServerFrame.decode(body)
    }

    private func status(_ status: String, revision: Int) throws -> OIPServerFrame {
        try frame("provider_invocation", ["status": .string(status), "stateRevision": .number(Double(revision))])
    }

    private final class Outbox {
        var frames: [[String: JSONValue]] = []
    }

    private let outbox = Outbox()

    /// A store whose `call-7` awaits approval, with a transport that records what it sends.
    private func openStore() throws -> WorkRoomStore {
        let store = WorkRoomStore()
        let outbox = outbox
        store.transport = WorkRoomTransport(
            frames: OIPClientFrames(
                keyStore: InMemoryPrivateKeyStore(rawKey: Data((0..<32).map { UInt8($0) })),
                to: "0x" + String(repeating: "ab", count: 32)
            ),
            send: { outbox.frames.append($0) }
        )
        store.receive(try frame("provider_invocation"))
        store.receive(try status("awaiting_approval", revision: 2))
        return store
    }

    /// The same, with the catalog's approval received, then `extra` frames.
    private func waitingStore(_ extra: OIPServerFrame...) throws -> WorkRoomStore {
        let store = try openStore()
        store.receive(try approval())
        extra.forEach(store.receive)
        return store
    }

    private func room(_ store: WorkRoomStore) throws -> WorkRoom {
        try XCTUnwrap(store.workRoom(forToolCallID: "call-7"))
    }

    // MARK: Verification

    func testVerifiedWorkRoomApprovalOffersAllowAndReject() throws {
        let shown = try XCTUnwrap(room(try waitingStore()).approval)

        XCTAssertEqual(shown.action, "Inspect the workspace")
        XCTAssertEqual(shown.scope, "This Work Room only")
        XCTAssertEqual(shown.reason, "Check the requested workspace result before continuing")
        XCTAssertEqual(shown.risk, "Contained to this Work Room")
        XCTAssertEqual(shown.files, ["sort.c", "test_sort.c"])
        XCTAssertTrue(shown.offersAllow)
        XCTAssertTrue(shown.offersReject)
    }

    func testElevatedAndUnknownScopesOfferNoAllowEvenIfTheHostSaysAllowOnce() throws {
        for (classification, text) in [("elevated", "Outside this Work Room"), ("unknown", "Boundary could not be verified")] {
            let store = try waitingStore(try approval([
                "scopeClassification": .string(classification), "scope": .string(text), "allowOnce": .bool(true)
            ]))

            let shown = try XCTUnwrap(room(store).approval)
            XCTAssertFalse(shown.offersAllow, classification)
            XCTAssertTrue(shown.offersReject, classification)
            XCTAssertFalse(store.decide(.allowOnce, in: "codex:call-7"), classification)
        }
    }

    func testWorkRoomApprovalWithAllowOnceFalseOffersNoAllow() throws {
        let store = try waitingStore(try approval(["allowOnce": .bool(false)]))

        XCTAssertFalse(try XCTUnwrap(room(store).approval).offersAllow)
    }

    func testApprovalThatFailsAnyCheckIsDroppedAndOffersNothing() throws {
        let failures: [[String: JSONValue?]] = [
            ["scopeClassification": .string("galactic")],
            ["scope": .string("Everywhere")],
            ["scope": .string("Outside this Work Room")],
            ["action": .string("Delete everything")],
            ["reason": .string("Because")],
            ["allowOnce": nil],
            ["allowSession": .string("no")],
            ["scopeClassification": nil]
        ]
        for changes in failures {
            let store = try waitingStore(try approval(changes))

            XCTAssertNil(try room(store).approval, "\(changes)")
            XCTAssertFalse(store.decide(.reject, in: "codex:call-7"), "\(changes)")
        }
        XCTAssertTrue(outbox.frames.isEmpty)
    }

    func testFileNamesAreBaseNamesAtMostEightDistinct() throws {
        let tooLong = String(repeating: "a", count: 129) + ".c"
        let paths = ["/home/dev/src/sort.c", "sort.c", tooLong] + (1...9).map { "dir/file\($0).c" }
        let store = try waitingStore(try approval(["files": .array(paths.map(JSONValue.string))]))

        XCTAssertEqual(
            try XCTUnwrap(room(store).approval).files,
            ["sort.c", "file1.c", "file2.c", "file3.c", "file4.c", "file5.c", "file6.c", "file7.c"]
        )
    }

    func testApprovalForAnInvocationNotKnownIsIgnored() throws {
        for outer: [String: JSONValue?] in [
            ["invocationId": .string("codex:other")],
            ["parentToolCallId": .string("call-8")],
            ["provider": .string("claude_code")],
            ["provider": nil]
        ] {
            let store = try openStore()
            store.receive(try approval(outer: outer))

            XCTAssertNil(try room(store).approval, "\(outer)")
        }
    }

    func testApprovalIsActiveOnlyWhileTheInvocationAwaitsApproval() throws {
        let store = try waitingStore()
        store.receive(try status("running", revision: 3))

        let shown = try XCTUnwrap(room(store).approval)
        XCTAssertFalse(shown.offersAllow)
        XCTAssertFalse(shown.offersReject)
        XCTAssertFalse(store.decide(.reject, in: "codex:call-7"))
        XCTAssertTrue(outbox.frames.isEmpty)
    }

    // MARK: Shared resolution

    func testDecidingTwiceSendsOneAPPROVALRESPONSEWithTheApprovalID() throws {
        let store = try waitingStore()

        XCTAssertTrue(store.decide(.allowOnce, in: "codex:call-7"))
        XCTAssertFalse(store.decide(.reject, in: "codex:call-7"))

        XCTAssertEqual(outbox.frames.count, 1)
        let sent = try XCTUnwrap(outbox.frames.first)
        XCTAssertEqual(sent["type"], .string("APPROVAL_RESPONSE"))
        XCTAssertEqual(sent["approved"], .bool(true))
        XCTAssertEqual(sent["scope"], .string("once"))
        XCTAssertEqual(sent["request_id"], .string("approval-codex-long"))
        XCTAssertNil(sent["mode"])
        XCTAssertNotNil(sent["signature"])
        XCTAssertEqual(try XCTUnwrap(room(store).approval).phase, .settled(.allowOnce))
        XCTAssertFalse(try XCTUnwrap(room(store).approval).offersAllow)
    }

    func testRejectSendsRejectHardAndSettlesBothSurfaces() throws {
        let store = try waitingStore()

        XCTAssertTrue(store.decide(.reject, in: "codex:call-7"))

        let sent = try XCTUnwrap(outbox.frames.first)
        XCTAssertEqual(sent["approved"], .bool(false))
        XCTAssertEqual(sent["mode"], .string("reject_hard"))
        XCTAssertEqual(sent["scope"], .string("once"))
        XCTAssertEqual(sent["request_id"], .string("approval-codex-long"))
        XCTAssertEqual(try XCTUnwrap(room(store).approval).resolution, "Rejected")
        XCTAssertFalse(try XCTUnwrap(room(store).approval).offersReject)
    }

    func testApprovalWithoutAnIDIsAnsweredWithoutARequestID() throws {
        let store = try waitingStore(try approval(id: nil))

        XCTAssertTrue(store.decide(.allowOnce, in: "codex:call-7"))

        XCTAssertEqual(outbox.frames.count, 1)
        XCTAssertNil(outbox.frames.first?["request_id"])
    }

    func testDecisionWithNoTransportIsRefusedAndStaysOpen() throws {
        let store = try waitingStore()
        store.connectionDidDrop()

        XCTAssertFalse(store.decide(.allowOnce, in: "codex:call-7"))

        XCTAssertTrue(try XCTUnwrap(room(store).approval).offersAllow)
        XCTAssertTrue(outbox.frames.isEmpty)
    }

    // MARK: Settled stays settled

    func testReplayOfTheSameApprovalNeverReEnablesASettledDecision() throws {
        let store = try waitingStore()
        store.decide(.allowOnce, in: "codex:call-7")

        store.receive(try approval())
        store.receive(try status("awaiting_approval", revision: 4))
        store.receive(try approval())

        let shown = try XCTUnwrap(room(store).approval)
        XCTAssertEqual(shown.phase, .settled(.allowOnce))
        XCTAssertFalse(shown.offersAllow)
        XCTAssertFalse(store.decide(.reject, in: "codex:call-7"))
        XCTAssertEqual(outbox.frames.count, 1)
    }

    func testANewApprovalReplacesASettledOne() throws {
        let store = try waitingStore()
        store.decide(.allowOnce, in: "codex:call-7")

        store.receive(try status("awaiting_approval", revision: 4))
        store.receive(try approval(id: "approval-2"))

        let shown = try XCTUnwrap(room(store).approval)
        XCTAssertEqual(shown.id, "approval-2")
        XCTAssertTrue(shown.offersAllow)

        store.receive(try approval())
        XCTAssertEqual(try XCTUnwrap(room(store).approval).id, "approval-2")
    }

    func testTerminalFrameClearsTheApproval() throws {
        let store = try waitingStore()
        store.decide(.allowOnce, in: "codex:call-7")

        store.receive(try frame("provider_invocation.terminal", ["stateRevision": .number(5)]))

        XCTAssertNil(try room(store).approval)
        store.receive(try approval())
        XCTAssertNil(try room(store).approval)
    }

    // MARK: STALE_ANSWER

    func testStaleAnswerMarksTheApprovalAnsweredElsewhereAndItIsNeverSent() throws {
        let store = try waitingStore(try frame("ERROR.stale_answer", ["request_id": .string("approval-codex-long")]))

        let shown = try XCTUnwrap(room(store).approval)
        XCTAssertEqual(shown.phase, .answeredElsewhere)
        XCTAssertEqual(shown.resolution, "Already answered elsewhere")
        XCTAssertFalse(shown.offersReject)
        XCTAssertFalse(store.decide(.reject, in: "codex:call-7"))
        XCTAssertTrue(outbox.frames.isEmpty)

        store.receive(try approval())
        XCTAssertEqual(try XCTUnwrap(room(store).approval).phase, .answeredElsewhere)
    }

    func testStaleAnswerForAnotherRequestChangesNothing() throws {
        let store = try waitingStore(try frame("ERROR.stale_answer"))

        XCTAssertEqual(try XCTUnwrap(room(store).approval).phase, .pending)
    }

    // MARK: Ownership

    private func body(_ frame: OIPServerFrame) throws -> [String: JSONValue] {
        guard case .event(_, _, let body) = frame else {
            throw XCTSkip("not an event")
        }
        return body
    }

    func testStoreOwnsAVerifiedApprovalBeforeAndAfterReceiveAndAfterItIsSettled() throws {
        let store = try openStore()
        let verified = try body(try approval())

        XCTAssertTrue(store.ownsApproval(verified))
        store.receive(try approval())
        XCTAssertTrue(store.ownsApproval(verified))
        store.decide(.allowOnce, in: "codex:call-7")
        XCTAssertTrue(store.ownsApproval(verified))
        store.receive(try frame("provider_invocation.terminal", ["stateRevision": .number(5)]))
        XCTAssertTrue(store.ownsApproval(verified))
    }

    func testStoreOwnsAVerifiedApprovalWithNoID() throws {
        let store = try openStore()

        XCTAssertTrue(store.ownsApproval(try body(try approval(id: nil))))
    }

    func testStoreDoesNotOwnUnverifiedUnmatchedOrGenericApprovals() throws {
        let store = try openStore()

        XCTAssertFalse(store.ownsApproval(try body(try approval(["action": .string("Delete everything")]))))
        XCTAssertFalse(store.ownsApproval(try body(try approval(outer: ["invocationId": .string("codex:other")]))))
        XCTAssertFalse(store.ownsApproval(try fixtureBody("approval_needed")))
    }
}
