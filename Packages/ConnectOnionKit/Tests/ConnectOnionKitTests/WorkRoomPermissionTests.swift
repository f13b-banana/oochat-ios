import Foundation
import XCTest
@testable import ConnectOnionKit

/// Permission Profiles through the Work Room store: which catalog a Work Room shows, the signed change it
/// sends, and when the profile really changes, with time driven by hand.
@MainActor
final class WorkRoomPermissionTests: XCTestCase {

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

    private func fixture(_ name: String, _ changes: [String: JSONValue?] = [:]) throws -> [String: JSONValue] {
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
        OIPServerFrame.decode(try fixture(name, changes))
    }

    /// The Codex invocation fixture with its catalog changed, or its frame fields changed.
    private func codex(
        catalog changes: [String: JSONValue?] = [:], frame frameChanges: [String: JSONValue?] = [:]
    ) throws -> OIPServerFrame {
        var catalog = try XCTUnwrap(try fixture("provider_invocation.permission.codex")["providerPermission"]?.objectValue)
        for (key, value) in changes {
            catalog[key] = value
        }
        var all = frameChanges
        all["providerPermission"] = .object(catalog)
        return try frame("provider_invocation.permission.codex", all)
    }

    /// The Codex catalog with one option's fields changed.
    private func codexOption(_ index: Int, _ changes: [String: JSONValue?]) throws -> OIPServerFrame {
        var options = try XCTUnwrap(
            try fixture("provider_invocation.permission.codex")["providerPermission"]?.objectValue?["options"]?.arrayValue
        )
        var option = try XCTUnwrap(options[index].objectValue)
        for (key, value) in changes {
            option[key] = value
        }
        options[index] = .object(option)
        return try codex(catalog: ["options": .array(options)])
    }

    /// An accepted ack whose catalog is the ack fixture's, with the catalog fields changed.
    private func acceptedAck(
        _ sent: [String: JSONValue]?, revision: Int? = 2, catalog changes: [String: JSONValue?]? = [:]
    ) throws -> OIPServerFrame {
        var permission = try XCTUnwrap(try fixture("PROVIDER_PERMISSION_ACK.accepted")["providerPermission"]?.objectValue)
        for (key, value) in changes ?? [:] {
            permission[key] = value
        }
        return try frame("PROVIDER_PERMISSION_ACK.accepted", [
            "requestId": .string(sent?["requestId"]?.stringValue ?? "none"),
            "stateRevision": revision.map { .number(Double($0)) },
            "providerPermission": changes == nil ? nil : .object(permission)
        ])
    }

    private func rejected(_ sent: [String: JSONValue]?, reason: String) throws -> OIPServerFrame {
        try frame(reason == "stale_revision" ? "PROVIDER_PERMISSION_ACK" : "PROVIDER_PERMISSION_ACK.\(reason)", [
            "requestId": .string(sent?["requestId"]?.stringValue ?? "none"), "invocationId": .string("codex:call-7")
        ])
    }

    private func store(_ first: OIPServerFrame, transport: Bool = true) throws -> WorkRoomStore {
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
        store.receive(first)
        return store
    }

    private func openStore() throws -> WorkRoomStore {
        try store(try codex())
    }

    /// The Claude catalog with Bypass permissions selectable, as under a Full Access ceiling.
    private func claudeWithBypassSelectable() throws -> OIPServerFrame {
        var catalog = try XCTUnwrap(try fixture("provider_invocation.permission.claude")["providerPermission"]?.objectValue)
        var options = try XCTUnwrap(catalog["options"]?.arrayValue)
        var bypass = try XCTUnwrap(options[4].objectValue)
        bypass["selectable"] = .bool(true)
        bypass["disabledReason"] = nil
        options[4] = .object(bypass)
        catalog["options"] = .array(options)
        return try frame("provider_invocation.permission.claude", ["providerPermission": .object(catalog)])
    }

    private func permission(_ store: WorkRoomStore) throws -> WorkRoomPermission {
        try XCTUnwrap(store.workRoom(id: roomID)?.permission)
    }

    private func continuation(_ changes: [String: JSONValue?] = [:]) throws -> OIPServerFrame {
        var all: [String: JSONValue?] = [
            "invocationId": .string("codex:turn-2"), "parentToolCallId": .string("call-8"),
            "continuationOf": .string("codex:call-7"), "workroomId": .string("codex:call-7"),
            "status": .string("completed"), "stateRevision": .number(3)
        ]
        for (key, value) in changes {
            all[key] = value
        }
        return try frame("provider_invocation", all)
    }

    // MARK: Catalog

    func testAValidCatalogIsKeptWithTheProvidersOwnLabelsAndTheHostsReasonForADisabledOption() throws {
        let selector = try permission(try openStore())

        XCTAssertEqual(selector.options.map(\.label), ["Read Only", "Ask for approval", "Approve for me", "Full Access"])
        XCTAssertEqual(selector.activeLabel, "Ask for approval")
        let full = try XCTUnwrap(selector.options.last)
        XCTAssertTrue(full.isElevated)
        XCTAssertFalse(full.isSelectable)
        XCTAssertEqual(full.disabledReason, "Host permission ceiling is Auto.")
        XCTAssertFalse(selector.offers(full))
        XCTAssertTrue(selector.offers(selector.options[2]))
    }

    func testAClaudeCatalogShowsClaudeCodesFiveNames() throws {
        let store = try store(try frame("provider_invocation.permission.claude"))
        let room = try XCTUnwrap(store.workRoom(id: "claude_code:call-9"))

        XCTAssertEqual(
            room.permission?.options.map(\.label), ["Plan", "Default", "Accept edits", "Auto", "Bypass permissions"]
        )
        XCTAssertEqual(room.permission?.activeLabel, "Default")
    }

    func testAnInvalidOptionDropsTheWholeCatalog() throws {
        let bad: [(Int, [String: JSONValue?])] = [
            (0, ["label": .string("")]),
            (0, ["label": .string(String(repeating: "a", count: 65))]),
            (0, ["label": .string("Read\nOnly")]),
            (0, ["description": .string(String(repeating: "a", count: 201))]),
            (0, ["id": .string("has space")]),
            (0, ["id": .string("codex:workspace-ask")]),
            (0, ["nativeProfileId": .string("bad id")]),
            (0, ["reviewer": .string("robot")]),
            (0, ["risk": .string("extreme")]),
            (0, ["selectable": .string("yes")]),
            (3, ["disabledReason": nil]),
            (3, ["disabledReason": .string(String(repeating: "a", count: 161))])
        ]
        for (index, changes) in bad {
            let store = try store(try codexOption(index, changes))
            XCTAssertNil(store.workRoom(id: roomID)?.permission, "\(index) \(changes)")
            XCTAssertNotNil(store.workRoom(id: roomID), "the invocation itself is still shown")
        }
    }

    func testABadCatalogShapeDropsIt() throws {
        let bad: [[String: JSONValue?]] = [
            ["activeOptionId": .string("codex:full-access")],
            ["activeOptionId": .string("codex:missing")],
            ["provider": .string("claude_code")],
            ["appliesTo": .string("this_turn")],
            ["options": .array([])],
            ["effectiveRevision": nil]
        ]
        for changes in bad {
            XCTAssertNil(try store(try codex(catalog: changes)).workRoom(id: roomID)?.permission, "\(changes)")
        }
    }

    func testMoreThanTwelveOptionsDropTheCatalog() throws {
        let option = try XCTUnwrap(
            try fixture("provider_invocation.permission.codex")["providerPermission"]?.objectValue?["options"]?.arrayValue?[1]
        )
        let options = (0..<13).map { index -> JSONValue in
            var fields = option.objectValue ?? [:]
            fields["id"] = .string("codex:option-\(index)")
            return .object(fields)
        }
        let tooMany = try store(try codex(catalog: ["options": .array(options), "activeOptionId": .string("codex:option-0")]))
        XCTAssertNil(tooMany.workRoom(id: roomID)?.permission)

        let twelve = try store(try codex(catalog: [
            "options": .array(Array(options.prefix(12))), "activeOptionId": .string("codex:option-0")
        ]))
        XCTAssertEqual(twelve.workRoom(id: roomID)?.permission?.options.count, 12)
    }

    func testACatalogWhoseRevisionIsNotTheFramesRevisionIsDropped() throws {
        XCTAssertNil(try store(try codex(catalog: ["effectiveRevision": .number(2)])).workRoom(id: roomID)?.permission)
        XCTAssertNil(try store(try codex(frame: ["stateRevision": .number(2)])).workRoom(id: roomID)?.permission)
        XCTAssertNil(try store(try codex(frame: ["stateRevision": nil])).workRoom(id: roomID)?.permission)
    }

    func testASnapshotCatalogIsValidatedLikeALiveOne() throws {
        let valid = try XCTUnwrap(try fixture("provider_invocation.permission.codex")["providerPermission"])
        func snapshot(_ catalog: JSONValue, revision: Int) throws -> OIPConnected {
            guard case .connected(var connected) = try frame("CONNECTED.snapshot") else {
                throw XCTSkip("CONNECTED.snapshot did not decode")
            }
            var items = try XCTUnwrap(connected.chatItems)
            var invocation = try XCTUnwrap(items[1].objectValue)
            invocation["stateRevision"] = .number(Double(revision))
            invocation["providerPermission"] = catalog
            items[1] = .object(invocation)
            connected = OIPConnected(
                sessionID: connected.sessionID, status: connected.status, hostProtocol: nil, sessionModes: nil,
                serverNewer: connected.serverNewer, session: nil, chatItems: items
            )
            return connected
        }
        let kept = WorkRoomStore()
        kept.receiveSnapshot(try snapshot(valid, revision: 1))
        XCTAssertEqual(kept.workRoom(forToolCallID: "call-7")?.permission?.activeLabel, "Ask for approval")

        let dropped = WorkRoomStore()
        dropped.receiveSnapshot(try snapshot(valid, revision: 2))
        XCTAssertNotNil(dropped.workRoom(forToolCallID: "call-7"))
        XCTAssertNil(dropped.workRoom(forToolCallID: "call-7")?.permission)
    }

    // MARK: Fallback for a finished invocation

    func testAFinishedContinuationWithoutACatalogShowsTheNewestValidCatalogOfTheGroup() throws {
        let store = try openStore()
        store.receive(try continuation())

        let selector = try permission(store)
        XCTAssertEqual(selector.activeLabel, "Ask for approval")
        XCTAssertNil(selector.unavailableReason)
        XCTAssertTrue(selector.offers(selector.options[2]))
        XCTAssertTrue(store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID))
        XCTAssertEqual(outbox.frames.first?["invocationId"]?.stringValue, "codex:turn-2")
        XCTAssertEqual(outbox.frames.first?["stateRevision"], .number(3))
    }

    func testAnAcceptedAckOnAFinishedContinuationSwitchesTheActiveLabel() throws {
        let store = try openStore()
        store.receive(try continuation())
        store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)

        var catalog = try XCTUnwrap(try fixture("PROVIDER_PERMISSION_ACK.accepted")["providerPermission"]?.objectValue)
        catalog["effectiveRevision"] = .number(4)
        store.receive(try frame("PROVIDER_PERMISSION_ACK.accepted", [
            "requestId": .string(outbox.frames.first?["requestId"]?.stringValue ?? "none"),
            "invocationId": .string("codex:turn-2"), "stateRevision": .number(4), "providerPermission": .object(catalog)
        ]))

        XCTAssertEqual(try permission(store).activeLabel, "Approve for me")
        XCTAssertNil(try permission(store).pendingID)
        XCTAssertNil(try permission(store).failure)
    }

    func testAContinuationsOwnCatalogWinsOverTheFallback() throws {
        let store = try openStore()
        var catalog = try XCTUnwrap(try fixture("provider_invocation.permission.codex")["providerPermission"]?.objectValue)
        catalog["activeOptionId"] = .string("codex:read-only")
        catalog["effectiveRevision"] = .number(3)
        store.receive(try continuation(["providerPermission": .object(catalog)]))

        let selector = try permission(store)
        XCTAssertEqual(selector.activeLabel, "Read Only")
        XCTAssertNil(selector.unavailableReason)
        XCTAssertTrue(store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID))
        XCTAssertEqual(outbox.frames.first?["invocationId"]?.stringValue, "codex:turn-2")
        XCTAssertEqual(outbox.frames.first?["stateRevision"], .number(3))
    }

    func testACatalogFromAnotherProviderIsNotAFallback() throws {
        let store = try openStore()
        store.receive(try continuation(["provider": .string("claude_code")]))

        XCTAssertEqual(store.workRoom(id: roomID)?.provider, .codex)
        XCTAssertNil(store.workRoom(id: roomID)?.permission)
    }

    func testAnotherWorkRoomsCatalogIsNotAFallback() throws {
        let store = try openStore()
        store.receive(try continuation(["workroomId": .string("codex:other")]))

        XCTAssertNil(store.workRoom(id: "codex:other")?.permission)
    }

    // MARK: Request

    func testChangeEmitsOneSignedFrameForTheCurrentInvocationWithTheObservedRevisionAndOption() throws {
        let store = try openStore()

        XCTAssertTrue(store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID))

        let sent = try XCTUnwrap(outbox.frames.first)
        XCTAssertEqual(outbox.frames.count, 1)
        XCTAssertEqual(sent["type"]?.stringValue, "PROVIDER_PERMISSION_CHANGE")
        XCTAssertEqual(sent["invocationId"]?.stringValue, "codex:call-7")
        XCTAssertEqual(sent["stateRevision"], .number(1))
        XCTAssertEqual(sent["optionId"]?.stringValue, "codex:workspace-auto")
        XCTAssertEqual(sent["confirmRisk"], .bool(false))
        XCTAssertNotNil(sent["signature"])
        let selector = try permission(store)
        XCTAssertEqual(selector.pendingID, "codex:workspace-auto")
        XCTAssertEqual(selector.activeLabel, "Ask for approval", "the label shows the old profile while pending")
        XCTAssertEqual(selector.pendingLabel, "Approve for me")
    }

    func testAnElevatedOptionNeedsTheRiskConfirmation() throws {
        let store = try store(try claudeWithBypassSelectable())
        let room = "claude_code:call-9"

        XCTAssertFalse(store.changePermission(to: "claude:bypass-permissions", confirmRisk: false, in: room))
        XCTAssertEqual(outbox.frames.count, 0)
        XCTAssertTrue(store.changePermission(to: "claude:bypass-permissions", confirmRisk: true, in: room))
        XCTAssertEqual(outbox.frames.first?["confirmRisk"], .bool(true))
    }

    func testAnOptionTheHostSaysIsNotSelectableIsRefused() throws {
        let store = try openStore()

        XCTAssertFalse(store.changePermission(to: "codex:full-access", confirmRisk: true, in: roomID))
        XCTAssertEqual(outbox.frames.count, 0)
    }

    func testChangeRefusesTheActiveOptionAnUnknownOptionAndNoTransport() throws {
        let store = try openStore()
        XCTAssertFalse(store.changePermission(to: "codex:workspace-ask", confirmRisk: false, in: roomID))
        XCTAssertFalse(store.changePermission(to: "codex:nothing", confirmRisk: false, in: roomID))
        XCTAssertFalse(store.changePermission(to: "codex:read-only", confirmRisk: false, in: "codex:unknown"))

        let offline = try self.store(try codex(), transport: false)
        XCTAssertFalse(offline.changePermission(to: "codex:read-only", confirmRisk: false, in: roomID))
        XCTAssertEqual(outbox.frames.count, 0)
    }

    func testChangeUsesTheInvocationsNewerRevisionWhenItsCatalogIsOlder() throws {
        let store = try openStore()
        store.receive(try frame("provider_invocation", ["stateRevision": .number(2)]))

        XCTAssertNil(try permission(store).unavailableReason)
        XCTAssertTrue(store.changePermission(to: "codex:read-only", confirmRisk: false, in: roomID))
        XCTAssertEqual(outbox.frames.first?["stateRevision"], .number(2))
    }

    func testOnlyOneChangeIsInFlight() throws {
        let store = try openStore()
        XCTAssertTrue(store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID))

        XCTAssertFalse(store.changePermission(to: "codex:read-only", confirmRisk: false, in: roomID))
        XCTAssertEqual(outbox.frames.count, 1)
        XCTAssertNotNil(try permission(store).unavailableReason)
    }

    // MARK: Answer

    func testAnAcceptedAckWithANewerRevisionAndTheRequestedActiveOptionChangesTheProfileInPlace() throws {
        let store = try openStore()
        store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)

        store.receive(try acceptedAck(outbox.frames.first))

        let selector = try permission(store)
        XCTAssertEqual(selector.activeLabel, "Approve for me")
        XCTAssertNil(selector.pendingID)
        XCTAssertNil(selector.failure)
        // The host's follow-up at the same revision is a no-op, and the next change observes revision 2.
        store.receive(try frame("provider_invocation", [
            "stateRevision": .number(2), "providerPermission": try fixture("PROVIDER_PERMISSION_ACK.accepted")["providerPermission"]
        ]))
        XCTAssertEqual(try permission(store).activeLabel, "Approve for me")
        XCTAssertTrue(store.changePermission(to: "codex:workspace-ask", confirmRisk: false, in: roomID))
        XCTAssertEqual(outbox.frames.last?["stateRevision"], .number(2))
    }

    func testAnAckThatIsNotNewerOrNotVerifiedKeepsTheOldProfileWithAReason() throws {
        let unverified = WorkRoomPermission.unverified
        let cases: [(String, (_ sent: [String: JSONValue]?) throws -> OIPServerFrame)] = [
            ("equal revision", { try self.acceptedAck($0, revision: 1, catalog: ["effectiveRevision": .number(1)]) }),
            ("older revision", { try self.acceptedAck($0, revision: 0, catalog: ["effectiveRevision": .number(0)]) }),
            ("no revision", { try self.acceptedAck($0, revision: nil) }),
            ("catalog at another revision", { try self.acceptedAck($0, catalog: ["effectiveRevision": .number(3)]) }),
            ("invalid catalog", { try self.acceptedAck($0, catalog: ["options": .array([])]) }),
            ("no catalog", { try self.acceptedAck($0, catalog: nil) }),
            ("another active option", { try self.acceptedAck($0, catalog: ["activeOptionId": .string("codex:workspace-ask")]) })
        ]
        for (name, make) in cases {
            outbox.frames = []
            let store = try openStore()
            store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)

            store.receive(try make(outbox.frames.first))

            let selector = try permission(store)
            XCTAssertEqual(selector.activeLabel, "Ask for approval", name)
            XCTAssertNil(selector.pendingID, name)
            XCTAssertEqual(selector.failure, .init(optionID: "codex:workspace-auto", text: unverified), name)
        }
    }

    func testARejectedAckKeepsTheOldProfileAndSaysWhyInPlainWords() throws {
        let reasons = [
            "ceiling_denied", "confirmation_required", "operator_required", "unsupported_option",
            "stale_revision", "not_owner", "not_found", "unavailable", "invalid_request", "invalid_revision"
        ]
        var texts = Set<String>()
        for reason in reasons {
            outbox.frames = []
            let store = try openStore()
            store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)

            store.receive(try rejected(outbox.frames.first, reason: reason))

            let selector = try permission(store)
            XCTAssertEqual(selector.activeLabel, "Ask for approval", reason)
            let text = try XCTUnwrap(selector.failure?.text, reason)
            XCTAssertNotEqual(text, WorkRoomPermission.rejectionText(reason: "something_new"), reason)
            XCTAssertFalse(text.contains("_"), reason)
            texts.insert(text)
            // Retry is possible: the selector is free again.
            XCTAssertTrue(store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID), reason)
        }
        XCTAssertEqual(texts.count, reasons.count)
    }

    func testAnUnknownRejectionReasonGetsTheGenericLine() throws {
        let store = try openStore()
        store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)
        var body = try fixture("PROVIDER_PERMISSION_ACK.ceiling_denied")
        body["requestId"] = outbox.frames.first?["requestId"]
        body["invocationId"] = .string(roomID)
        body["reason"] = .string("brand_new_reason")
        store.receive(OIPServerFrame.decode(body))

        XCTAssertEqual(try permission(store).failure?.text, "The host did not accept the change.")
    }

    func testAnAckForAnotherRequestOrInvocationIsIgnored() throws {
        let store = try openStore()
        store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)

        store.receive(try acceptedAck(["requestId": .string("other")]))
        var other = try fixture("PROVIDER_PERMISSION_ACK.accepted")
        other["requestId"] = outbox.frames.first?["requestId"]
        other["invocationId"] = .string("codex:elsewhere")
        store.receive(OIPServerFrame.decode(other))

        let selector = try permission(store)
        XCTAssertEqual(selector.pendingID, "codex:workspace-auto")
        XCTAssertEqual(selector.activeLabel, "Ask for approval")
    }

    func testAnErrorWithTheRequestIDFailsTheChangeAndKeepsTheOldProfile() throws {
        let store = try openStore()
        store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)
        let sent = try XCTUnwrap(outbox.frames.first?["requestId"]?.stringValue)

        store.receive(try frame("ERROR", ["request_id": .string("other")]))
        XCTAssertEqual(try permission(store).pendingID, "codex:workspace-auto")

        store.receive(try frame("ERROR", ["request_id": .string(sent)]))
        let selector = try permission(store)
        XCTAssertNil(selector.pendingID)
        XCTAssertEqual(selector.activeLabel, "Ask for approval")
        XCTAssertEqual(selector.failure?.text, WorkRoomPermission.rejectionText(reason: nil))
    }

    func testNoAnswerInTenSecondsKeepsTheOldProfileAndALateAckIsIgnored() throws {
        let store = try openStore()
        store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)
        let sent = outbox.frames.first

        timers.elapse(.seconds(10))

        var selector = try permission(store)
        XCTAssertNil(selector.pendingID)
        XCTAssertEqual(selector.failure?.text, WorkRoomPermission.timedOut)
        store.receive(try acceptedAck(sent))
        selector = try permission(store)
        XCTAssertEqual(selector.activeLabel, "Ask for approval")
        XCTAssertEqual(outbox.frames.count, 1, "nothing is retried")
    }

    func testADisconnectFailsThePendingChangeAndKeepsTheOldProfile() throws {
        let store = try openStore()
        store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)

        store.connectionDidDrop()

        let selector = try permission(store)
        XCTAssertNil(selector.pendingID)
        XCTAssertEqual(selector.activeLabel, "Ask for approval")
        XCTAssertEqual(selector.failure?.text, WorkRoomPermission.connectionDropped)
        XCTAssertNotNil(selector.unavailableReason, "no change while the agent is not connected")
    }

    func testAnAcceptedAckAfterANewerFrameAlreadyArrivedDoesNotGoBackwards() throws {
        let store = try openStore()
        store.changePermission(to: "codex:workspace-auto", confirmRisk: false, in: roomID)
        var catalog = try XCTUnwrap(try fixture("PROVIDER_PERMISSION_ACK.accepted")["providerPermission"]?.objectValue)
        catalog["effectiveRevision"] = .number(3)
        store.receive(try frame("provider_invocation", [
            "stateRevision": .number(3), "providerPermission": .object(catalog)
        ]))

        store.receive(try acceptedAck(outbox.frames.first))

        XCTAssertNil(try permission(store).pendingID)
        XCTAssertTrue(store.changePermission(to: "codex:workspace-ask", confirmRisk: false, in: roomID))
        XCTAssertEqual(outbox.frames.last?["stateRevision"], .number(3))
    }
}
