import ConnectOnionKit
import Foundation
import XCTest
@testable import OOChatIOS

// N1.5: socket size and DASHBOARD_SNAPSHOT.
extension HostedAgentConnectionTests {
    func testDefaultSocketAcceptsTheHostsLargestMessage() async throws {
        let connection = HostedAgentConnection(
            key: HostedAgentConnectionKey(agentAddress: agentAddress, conversationID: "size"),
            identityStore: IdentityStore(),
            session: .shared,
            discovery: HostedAgentDiscovery(session: .shared, relayURL: "ws://unused.test", localEndpoints: []),
            connectionStateObserver: HostedAgentConnectionStateObserver()
        )

        let url = try XCTUnwrap(URL(string: "ws://unit.test/ws"))
        let makeSocket = await connection.socketFactory
        let task = try XCTUnwrap(makeSocket(url) as? URLSessionWebSocketTask)

        defer { task.cancel() }

        XCTAssertEqual(task.maximumMessageSize, OIPDashboard.socketMessageBytes)
    }

    func testDashboardSnapshotReachesTheAppAndAnOversizedOneIsTooLarge() async throws {
        let factory = MockHostedAgentSocketFactory()
        let recorder = SessionUpdateRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer)

        _ = try await establish(connection, conversation: makeConversation(id: "dashboard"), factory: factory)

        let socket = try await factory.socket(at: 0)

        try socket.enqueueFrame(["type": .string("DASHBOARD_SNAPSHOT"), "html": .string("<h1>Hi</h1>")])
        try await recorder.wait { $0.contains(.dashboard(.page(html: "<h1>Hi</h1>"))) }

        let oversized = String(repeating: "a", count: OIPDashboard.clientCapBytes + 1)

        try socket.enqueueFrame(["type": .string("DASHBOARD_SNAPSHOT"), "html": .string(oversized)])

        try await recorder.wait(timeout: 10) { $0.contains(.dashboard(.tooLarge(bytes: OIPDashboard.clientCapBytes + 1))) }

        let isConnected = await connection.state == .connected

        XCTAssertTrue(isConnected, "a big page must not drop the chat")

        await connection.close()
    }

    func testRunningSessionIsPolledUntilTheHostSaysOtherwise() async throws {
        let factory = MockHostedAgentSocketFactory()

        let recorder = SessionUpdateRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer, statusPollInterval: 0.02)

        let connect = Task {
            try await connection.ensureConnected(conversation: makeConversation(id: "poll"))
        }

        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("running"), "session_id": .string("poll")])
        _ = try await connect.value

        let first = try await socket.waitForSentFrame(type: "SESSION_STATUS")

        XCTAssertEqual(first["session"], .object(["session_id": .string("poll")]))
        XCTAssertNil(first["signature"], "SESSION_STATUS on a live socket is unsigned")

        try socket.enqueueFrame(["type": .string("SESSION_STATUS"), "session_id": .string("poll"), "status": .string("running")])
        _ = try await socket.waitForSentFrame(type: "SESSION_STATUS", occurrence: 2)

        try socket.enqueueFrame(["type": .string("SESSION_STATUS"), "session_id": .string("poll"), "status": .string("not_found")])

        try await recorder.wait { $0.last == .hostStatus("not_found") }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(try socket.sentFrames().filter { $0["type"]?.stringValue == "SESSION_STATUS" }.count, 2)

        await connection.close()
    }

    func testOwnPromptShowsRunningWithoutPolling() async throws {
        let factory = MockHostedAgentSocketFactory()

        let recorder = SessionUpdateRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer, statusPollInterval: 0.02)
        let conversation = makeConversation(id: "own-run")
        _ = try await establish(connection, conversation: conversation, factory: factory)

        let socket = try await factory.socket(at: 0)

        let prompt = Task {
            try await connection.sendPrompt(conversation: conversation, prompt: "hi", onEvent: nil, onInteraction: nil)
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")

        try await recorder.wait { $0.last == .hostStatus("running") }
        try socket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("done")])
        _ = try await prompt.value
        try await recorder.wait { $0.last == .hostStatus("connected") }

        XCTAssertTrue(try socket.sentFrames().filter { $0["type"]?.stringValue == "SESSION_STATUS" }.isEmpty)

        await connection.close()
    }
}

// Mirrored Turn: a turn another device started on this session, seen live.
extension HostedAgentConnectionTests {
    private struct MirrorFixture {
        let connection: HostedAgentConnection
        let recorder: MirrorRecorder
        let socket: MockHostedAgentWebSocket
        let conversation: Conversation
    }

    private func mirrorFixture(id: String) async throws -> MirrorFixture {
        let factory = MockHostedAgentSocketFactory()
        let recorder = MirrorRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer)
        let conversation = makeConversation(id: id)
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        return MirrorFixture(connection: connection, recorder: recorder, socket: socket, conversation: conversation)
    }

    func testUserMessageFromAnotherDeviceStartsAMirroredTurnThatStreamsToItsEnd() async throws {
        let mirror = try await mirrorFixture(id: "mirror-live")
        let (connection, recorder, socket, conversation) = (mirror.connection, mirror.recorder, mirror.socket, mirror.conversation)
        let events = MirrorRecorder()

        try socket.enqueueFrame([
            "type": .string("user_message"), "content": .string("Translate hello"), "session_id": .string("mirror-live")
        ])
        try await recorder.wait { $0.contains(.mirroredTurn(prompt: "Translate hello")) }

        let turn = Task {
            try await connection.attachMirroredTurn(
                conversation: conversation,
                onEvent: { events.events.append($0) },
                onInteraction: nil
            )
        }
        try socket.enqueueFrame(["type": .string("tool_call"), "id": .string("t1"), "name": .string("search"), "args": .object([:])])
        try socket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("Hola")])

        let result = try await turn.value
        XCTAssertEqual(result.output, "Hola")
        XCTAssertEqual(events.events, [.toolCall(id: "t1", name: "search", arguments: [:])])
        await connection.close()
    }

    func testFramesThatArriveBeforeTheTurnIsAttachedAreReplayedInOrder() async throws {
        let mirror = try await mirrorFixture(id: "mirror-early")
        let (connection, recorder, socket, conversation) = (mirror.connection, mirror.recorder, mirror.socket, mirror.conversation)
        let events = MirrorRecorder()

        try socket.enqueueFrame(["type": .string("user_message"), "content": .string("hi")])
        try socket.enqueueFrame(["type": .string("tool_call"), "id": .string("t1"), "name": .string("a"), "args": .object([:])])
        try socket.enqueueFrame(["type": .string("tool_result"), "id": .string("t1"), "name": .string("a"), "result": .string("ok")])
        try socket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("done")])
        try await recorder.wait { $0.contains { if case .mirroredTurn = $0 { return true } else { return false } } }
        try await Task.sleep(nanoseconds: 50_000_000)

        let result = try await connection.attachMirroredTurn(
            conversation: conversation,
            onEvent: { events.events.append($0) },
            onInteraction: nil
        )
        XCTAssertEqual(result.output, "done")
        XCTAssertEqual(events.events, [
            .toolCall(id: "t1", name: "a", arguments: [:]),
            .toolResult(id: "t1", name: "a", output: "ok", state: .completed)
        ])
        await connection.close()
    }

    func testReleasingTheMirrorBufferStopsHoldingFramesBack() async throws {
        let mirror = try await mirrorFixture(id: "mirror-release")
        let (connection, recorder, socket, conversation) = (mirror.connection, mirror.recorder, mirror.socket, mirror.conversation)
        try socket.enqueueFrame(["type": .string("user_message"), "content": .string("declined")])
        try await recorder.wait { $0.contains { if case .mirroredTurn = $0 { return true } else { return false } } }
        let held = await connection.mirrorBuffer
        XCTAssertNotNil(held)

        await connection.releaseMirrorBuffer()

        let released = await connection.mirrorBuffer
        XCTAssertNil(released)
        do {
            _ = try await connection.attachMirroredTurn(conversation: conversation, onEvent: nil, onInteraction: nil)
            XCTFail("nothing is held for a declined turn")
        } catch HostedAgentClientError.closed {
        }
        await connection.close()
    }

    func testStoppingAMirroredTurnInterruptsTheHost() async throws {
        let mirror = try await mirrorFixture(id: "mirror-stop")
        let (connection, recorder, socket, conversation) = (mirror.connection, mirror.recorder, mirror.socket, mirror.conversation)
        try socket.enqueueFrame(["type": .string("user_message"), "content": .string("long job")])
        try await recorder.wait { $0.contains { if case .mirroredTurn = $0 { return true } else { return false } } }

        let turn = Task {
            try await connection.attachMirroredTurn(conversation: conversation, onEvent: nil, onInteraction: nil)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        turn.cancel()

        _ = try await socket.waitForSentFrame(type: "INTERRUPT")
        do {
            _ = try await turn.value
            XCTFail("a stopped turn must not complete")
        } catch is CancellationError {
        }
    }

    func testAnApprovalOnAMirroredTurnIsAnsweredFromThisDevice() async throws {
        let mirror = try await mirrorFixture(id: "mirror-approve")
        let (connection, recorder, socket, conversation) = (mirror.connection, mirror.recorder, mirror.socket, mirror.conversation)
        try socket.enqueueFrame(["type": .string("user_message"), "content": .string("write it")])
        try await recorder.wait { $0.contains { if case .mirroredTurn = $0 { return true } else { return false } } }
        let turn = Task {
            try await connection.attachMirroredTurn(
                conversation: conversation,
                onEvent: nil,
                onInteraction: { _ in .approval(.allowOnce) }
            )
        }
        try socket.enqueueFrame([
            "type": .string("approval_needed"), "id": .string("ap1"),
            "tool": .string("write_file")
        ])
        let response = try await socket.waitForSentFrame(type: "APPROVAL_RESPONSE")
        XCTAssertEqual(try signedPayload(of: response)["request_id"], .string("ap1"))
        try socket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("written")])
        _ = try await turn.value
        await connection.close()
    }

    func testAMirroredTurnNobodyAttachesToExpiresAndLaterTurnsAreStillSeen() async throws {
        let factory = MockHostedAgentSocketFactory()
        let recorder = MirrorRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer, mirrorAttachGrace: 0.05)
        _ = try await establish(connection, conversation: makeConversation(id: "mirror-expire"), factory: factory)
        let socket = try await factory.socket(at: 0)

        try socket.enqueueFrame(["type": .string("user_message"), "content": .string("first")])
        try await recorder.wait { $0.contains(.mirroredTurn(prompt: "first")) }
        try await Task.sleep(nanoseconds: 300_000_000)

        try socket.enqueueFrame(["type": .string("user_message"), "content": .string("second")])
        try await recorder.wait { $0.contains(.mirroredTurn(prompt: "second")) }
        await connection.close()
    }

    func testOpeningAChatWhoseTurnIsStillRunningJoinsIt() async throws {
        let factory = MockHostedAgentSocketFactory()
        let recorder = MirrorRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer)
        let connect = Task { try await connection.ensureConnected(conversation: makeConversation(id: "join")) }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame([
            "type": .string("CONNECTED"), "status": .string("running"), "session_id": .string("join"),
            "chat_items": .array([
                .object(["type": .string("user"), "content": .string("earlier")]),
                .object(["type": .string("agent"), "content": .string("answer")]),
                .object(["type": .string("user"), "content": .string("still going")])
            ])
        ])
        _ = try await connect.value
        try await recorder.wait { $0.contains(.mirroredTurn(prompt: "still going")) }
        await connection.close()
    }

    func testOpeningAChatThatMovedOnReportsTheHostsItems() async throws {
        let factory = MockHostedAgentSocketFactory()
        let recorder = MirrorRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer)
        let connect = Task { try await connection.ensureConnected(conversation: makeConversation(id: "moved")) }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        let items: [JSONValue] = [
            .object(["type": .string("user"), "content": .string("q")]),
            .object(["type": .string("agent"), "content": .string("a")])
        ]
        try socket.enqueueFrame([
            "type": .string("CONNECTED"), "status": .string("connected"), "session_id": .string("moved"),
            "chat_items": .array(items)
        ])
        _ = try await connect.value
        try await recorder.wait { $0.contains(.caughtUp(items: items)) }
        await connection.close()
    }

    func testAMirroredPromptIsIgnoredWhileThisDeviceHasItsOwnTurnPending() async throws {
        let mirror = try await mirrorFixture(id: "mirror-own")
        let (connection, recorder, socket, conversation) = (mirror.connection, mirror.recorder, mirror.socket, mirror.conversation)
        let own = Task {
            try await connection.sendPrompt(conversation: conversation, prompt: "mine", onEvent: nil, onInteraction: nil)
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        try socket.enqueueFrame(["type": .string("user_message"), "content": .string("theirs")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(recorder.updates.contains(.mirroredTurn(prompt: "theirs")))
        try socket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("ok")])
        _ = try await own.value
        await connection.close()
    }
}

@MainActor
private final class MirrorRecorder {
    let observer = HostedAgentConnectionStateObserver()
    var events: [HostedAgentEvent] = []
    private(set) var updates: [HostedAgentSessionUpdate] = []

    init() {
        observer.updateHandler = { [weak self] _, update in
            self?.updates.append(update)
        }
    }

    func wait(timeout: TimeInterval = 2, until condition: ([HostedAgentSessionUpdate]) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(updates) {
            guard Date() < deadline else { throw HostedAgentTestError.timedOut }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

// OUTPUT and SESSION_STATUS are read by the kit's OIPServerFrame.decode.
extension HostedAgentConnectionTests {
    func testOutputWithoutAResultFailsThePromptInsteadOfInventingAReply() async throws {
        try await assertOutputFailsPrompt(
            ["type": .string("OUTPUT"), "message": .string("not the wire shape")],
            id: "no-result"
        )
    }

    func testOutputWithANonStringResultFailsThePrompt() async throws {
        try await assertOutputFailsPrompt(
            ["type": .string("OUTPUT"), "result": .object(["answer": .string("42")])],
            id: "object-result"
        )
    }

    func testMalformedOutputWithNoPromptWaitingKeepsTheConnection() async throws {
        let factory = MockHostedAgentSocketFactory()
        let recorder = SessionUpdateRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer)
        _ = try await establish(connection, conversation: makeConversation(id: "idle-bad-output"), factory: factory)
        let socket = try await factory.socket(at: 0)

        try socket.enqueueFrame(["type": .string("OUTPUT"), "message": .string("no result")])
        try socket.enqueueFrame(["type": .string("SESSION_STATUS"), "session_id": .string("x"), "status": .string("connected")])
        try await recorder.wait { $0.last == .hostStatus("connected") }

        let isConnected = await connection.state == .connected

        XCTAssertTrue(isConnected, "a bad OUTPUT with no prompt waiting must not drop the socket")
        await connection.close()
    }

    private func assertOutputFailsPrompt(_ frame: [String: JSONValue], id: String) async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: id)
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)

        let prompt = Task {
            try await connection.sendPrompt(conversation: conversation, prompt: "hi", onEvent: nil, onInteraction: nil)
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        try socket.enqueueFrame(frame)

        do {
            _ = try await prompt.value
            XCTFail("An unreadable OUTPUT must not resolve the prompt")
        } catch {
            guard case .badFrame? = error as? HostedAgentClientError else {
                return XCTFail("Expected badFrame, got \(error)")
            }
        }
    }

    func testSessionStatusWithoutAStatusIsIgnored() async throws {
        let factory = MockHostedAgentSocketFactory()
        let recorder = SessionUpdateRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer)
        _ = try await establish(connection, conversation: makeConversation(id: "bare-status"), factory: factory)
        let socket = try await factory.socket(at: 0)

        try socket.enqueueFrame(["type": .string("SESSION_STATUS"), "session": .object(["session_id": .string("x")])])
        try socket.enqueueFrame(["type": .string("SESSION_STATUS"), "session_id": .string("x"), "status": .string("connected")])
        try await recorder.wait { $0.last == .hostStatus("connected") }

        XCTAssertEqual(recorder.updates, [.hostStatus("new"), .hostStatus("connected")])
        await connection.close()
    }
}

/// observer session updates
@MainActor
private final class SessionUpdateRecorder {
    let observer = HostedAgentConnectionStateObserver()

    private(set) var updates: [HostedAgentSessionUpdate] = []

    init() {
        observer.updateHandler = { [weak self] _, update in
            self?.updates.append(update)
        }
    }

    func wait(timeout: TimeInterval = 1, until condition: ([HostedAgentSessionUpdate]) -> Bool) async throws {

        let deadline = Date().addingTimeInterval(timeout)

        while !condition(updates) {
            guard Date() < deadline else {
                throw HostedAgentTestError.timedOut
            }

            try await Task.sleep(nanoseconds: 2000000)
        }
    }
}
