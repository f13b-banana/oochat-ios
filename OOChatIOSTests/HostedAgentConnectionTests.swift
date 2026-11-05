import CryptoKit
import Foundation
import ConnectOnionKit
import XCTest
@testable import OOChatIOS

@MainActor
final class HostedAgentConnectionTests: XCTestCase {
    private let endpoint = ResolvedEndpoint(
        wsURL: URL(string: "ws://unit.test/ws")!,
        kind: .direct,
        label: "Unit Test Agent"
    )

    func testEnsureConnectedSendsSignedFrameUpdatesSessionAndReusesSocket() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(
            id: "conversation-connect",
            mode: .plan,
            serverSession: ["server_value": .string("kept"), "ulw_turns": .number(8)]
        )

        let connectTask = Task {
            try await connection.ensureConnected(conversation: conversation)
        }
        let socket = try await factory.socket(at: 0)
        let connectFrame = try await socket.waitForSentFrame(type: "CONNECT")

        XCTAssertTrue(socket.isResumed)
        XCTAssertEqual(connectFrame["to"]?.stringValue, agentAddress)
        XCTAssertEqual(connectFrame["session_id"]?.stringValue, conversation.id)
        XCTAssertEqual(connectFrame["timestamp"]?.numberValue?.rounded(), connectFrame["timestamp"]?.numberValue)
        XCTAssertEqual(connectFrame["protocol"], .object(OIP.descriptor))
        guard case .object(let session)? = connectFrame["session"] else {
            return XCTFail("CONNECT must carry a session object")
        }
        XCTAssertEqual(session["mode"]?.stringValue, ChatMode.plan.rawValue)
        XCTAssertEqual(session["server_value"]?.stringValue, "kept")
        XCTAssertNil(session["ulw_turns"])

        try socket.enqueueFrame(
            [
                "type": .string("CONNECTED"),
                "status": .string("ready"),
                "session": .object(["mode": .string("plan"), "server": .bool(true)]),
                "session_id": .string("server-session-id")
            ],
            asData: true
        )

        let result = try await connectTask.value
        XCTAssertNil(result.output)
        XCTAssertEqual(result.endpointLabel, endpoint.label)
        XCTAssertEqual(result.serverSession?["server"], .bool(true))
        XCTAssertEqual(result.serverSession?["session_id"]?.stringValue, "server-session-id")

        let reused = try await connection.ensureConnected(conversation: conversation)
        XCTAssertEqual(reused.endpointLabel, endpoint.label)
        XCTAssertEqual(factory.count, 1)
        XCTAssertEqual(try socket.sentFrames().count, 1)

        await connection.close()
        XCTAssertEqual(socket.closeCode, .goingAway)
    }

    func testConcurrentConnectWaitersShareHandshakeAndCancellationIsScoped() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "shared-connect")

        let cancelledWaiter = Task {
            try await connection.ensureConnected(conversation: conversation)
        }
        let successfulWaiter = Task {
            try await connection.ensureConnected(conversation: conversation)
        }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")

        cancelledWaiter.cancel()
        await assertCancellation(from: cancelledWaiter)
        XCTAssertNil(socket.closeCode)

        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("new")])
        let successfulResult = try await successfulWaiter.value
        XCTAssertEqual(successfulResult.endpointLabel, endpoint.label)
        XCTAssertEqual(factory.count, 1)
        await connection.close()

        let loneFactory = MockHostedAgentSocketFactory()
        let loneConnection = makeConnection(factory: loneFactory)
        let loneWaiter = Task {
            try await loneConnection.ensureConnected(conversation: makeConversation(id: "lone-connect"))
        }
        let loneSocket = try await loneFactory.socket(at: 0)
        _ = try await loneSocket.waitForSentFrame(type: "CONNECT")
        loneWaiter.cancel()
        await assertCancellation(from: loneWaiter)
        XCTAssertEqual(loneSocket.closeCode, .goingAway)
    }

    func testConnectNormalizesResolverSocketAndFrameFailures() async throws {
        let resolverFactory = MockHostedAgentSocketFactory()
        let resolverFailure = makeConnection(
            factory: resolverFactory,
            resolver: { _ in throw HostedAgentTestError.failed }
        )
        await assertClientError(.closed) {
            try await resolverFailure.ensureConnected(conversation: self.makeConversation(id: "resolver-error"))
        }

        let preservedFactory = MockHostedAgentSocketFactory()
        let preservedFailure = makeConnection(
            factory: preservedFactory,
            resolver: { _ in throw HostedAgentClientError.timeout }
        )
        await assertClientError(.timeout) {
            try await preservedFailure.ensureConnected(conversation: self.makeConversation(id: "known-error"))
        }

        let sendFactory = MockHostedAgentSocketFactory { $0.failNextSend() }
        let sendFailure = makeConnection(factory: sendFactory)
        let sendTask = Task {
            try await sendFailure.ensureConnected(conversation: makeConversation(id: "send-error"))
        }
        await assertClientError(.closed, from: sendTask)

        let badFrameFactory = MockHostedAgentSocketFactory()
        let badFrameConnection = makeConnection(factory: badFrameFactory)
        let badFrameTask = Task {
            try await badFrameConnection.ensureConnected(conversation: makeConversation(id: "bad-frame"))
        }
        let badFrameSocket = try await badFrameFactory.socket(at: 0)
        _ = try await badFrameSocket.waitForSentFrame(type: "CONNECT")
        badFrameSocket.enqueueText("not json")
        await assertClientError(.closed, from: badFrameTask)

        let receiveFactory = MockHostedAgentSocketFactory()
        let receiveFailure = makeConnection(factory: receiveFactory)
        let receiveTask = Task {
            try await receiveFailure.ensureConnected(conversation: makeConversation(id: "receive-error"))
        }
        let receiveSocket = try await receiveFactory.socket(at: 0)
        _ = try await receiveSocket.waitForSentFrame(type: "CONNECT")
        receiveSocket.enqueueError()
        await assertClientError(.closed, from: receiveTask)
    }

    func testConnectAndLivenessTimeoutsCloseSilentSockets() async throws {
        let connectFactory = MockHostedAgentSocketFactory()
        let connectTimeout = makeConnection(
            factory: connectFactory,
            connectTimeout: 0.02,
            livenessTimeout: 1,
            livenessCheckInterval: 0.01
        )
        let connectTask = Task {
            try await connectTimeout.ensureConnected(conversation: makeConversation(id: "connect-timeout"))
        }
        let connectSocket = try await connectFactory.socket(at: 0)
        _ = try await connectSocket.waitForSentFrame(type: "CONNECT")
        await assertClientError(.timeout, from: connectTask)
        XCTAssertEqual(connectSocket.closeCode, .goingAway)

        let livenessFactory = MockHostedAgentSocketFactory()
        let livenessTimeout = makeConnection(
            factory: livenessFactory,
            connectTimeout: 1,
            livenessTimeout: 0.015,
            livenessCheckInterval: 0.005
        )
        let conversation = makeConversation(id: "liveness-timeout")
        _ = try await establish(livenessTimeout, conversation: conversation, factory: livenessFactory)
        let livenessSocket = try await livenessFactory.socket(at: 0)
        try await waitUntil { livenessSocket.closeCode == .goingAway }
    }

    func testPromptHandlesPingEventsEveryInteractionAndOutput() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "prompt-success", mode: .safe)
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        var events: [HostedAgentEvent] = []
        var interactions: [HostedAgentInteraction] = []

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "hello agent",
                images: ["data:image/png;base64,AA=="],
                files: [
                    HostedAgentFilePayload(
                        name: "note.txt",
                        data: "data:text/plain;base64,SGk="
                    )
                ],
                onEvent: { events.append($0) },
                onInteraction: { interaction in
                    interactions.append(interaction)
                    switch interaction {
                    case .approval:
                        return .approval(.allowSession)
                    case .ulwCheckpoint:
                        return .ulwCheckpoint(.continueWork(turns: 4))
                    case .planReview:
                        return .planReview(.requestChanges(feedback: "add tests"))
                    case .askUser:
                        return .askUser(.answer("Sydney"))
                    }
                }
            )
        }

        let input = try await socket.waitForSentFrame(type: "INPUT")
        XCTAssertEqual(input["prompt"]?.stringValue, "hello agent")
        XCTAssertNil(input["mode"], "The host reads the mode from the session, not from INPUT.")
        XCTAssertEqual(input["to"]?.stringValue, agentAddress)
        XCTAssertNotNil(input["input_id"]?.stringValue)
        XCTAssertEqual(
            input["images"],
            .array([.string("data:image/png;base64,AA==")])
        )
        XCTAssertEqual(
            input["files"],
            .array([
                .object([
                    "name": .string("note.txt"),
                    "data": .string("data:text/plain;base64,SGk=")
                ])
            ])
        )

        try socket.enqueueFrame(["type": .string("PING")])
        _ = try await socket.waitForSentFrame(type: "PONG")

        try socket.enqueueFrame(
            ["type": .string("tool_call"), "tool_id": .string("tool-1"), "name": .string("shell")]
        )
        try socket.enqueueFrame(
            ["type": .string("tool_result"), "tool_id": .string("tool-1"), "result": .string("done")]
        )
        try socket.enqueueFrame(["type": .string("mode_changed"), "mode": .string("plan")])

        try socket.enqueueFrame(
            ["type": .string("approval_needed"), "id": .string("approval-1"), "tool": .string("shell")]
        )
        let approvalResponse = try await socket.waitForSentFrame(type: "APPROVAL_RESPONSE")
        // 16.3-> each answer names the id of the prompt it answers inside the signed payload
        XCTAssertEqual(try signedPayload(of: approvalResponse)["request_id"], .string("approval-1"))
        try socket.enqueueFrame(
            [
                "type": .string("ulw_turns_reached"),
                "id": .string("ulw-1"),
                "turns_used": .number(10),
                "max_turns": .number(10)
            ]
        )
        _ = try await socket.waitForSentFrame(type: "ULW_RESPONSE")
        try socket.enqueueFrame(
            ["type": .string("plan_review"), "id": .string("plan-1"), "plan_content": .string("Step 1")]
        )
        _ = try await socket.waitForSentFrame(type: "PLAN_REVIEW_RESPONSE")
        try socket.enqueueFrame(
            ["type": .string("ask_user"), "id": .string("ask-1"), "question": .string("Where?")]
        )
        let askResponse = try await socket.waitForSentFrame(type: "ASK_USER_RESPONSE")
        XCTAssertEqual(askResponse["answer"]?.stringValue, "Sydney")
        XCTAssertEqual(try signedPayload(of: askResponse)["request_id"], .string("ask-1"))

        await connection.waitForPendingInteractionResponses()
        try socket.enqueueFrame(
            [
                "type": .string("OUTPUT"),
                "result": .string("final answer"),
                "session_id": .string("updated-session")
            ]
        )
        let result = try await promptTask.value
        XCTAssertEqual(result.output, "final answer")
        XCTAssertEqual(result.serverSession?["session_id"]?.stringValue, "updated-session")
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(interactions.count, 4)
        await connection.close()
    }

    func testPromptRejectsConcurrentSendAndCancellationClosesRoundTrip() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "busy")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)

        let firstPrompt = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "first",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")

        await assertClientError(.busy) {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "second",
                onEvent: nil,
                onInteraction: nil
            )
        }

        firstPrompt.cancel()
        await assertCancellation(from: firstPrompt)
        XCTAssertEqual(socket.closeCode, .goingAway)
    }

    func testMalformedAndMismatchedInteractionsFailSafely() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "malformed-interactions")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "needs approval",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")

        try socket.enqueueFrame(["type": .string("approval_needed"), "id": .string("broken")])
        let decline = try await socket.waitForSentFrame(type: "APPROVAL_RESPONSE")
        XCTAssertEqual(decline["approved"], .bool(false))

        try socket.enqueueFrame(["type": .string("ask_user"), "id": .string("also-broken")])
        await assertClientError(.badFrame, from: promptTask)

        let mismatchFactory = MockHostedAgentSocketFactory()
        let mismatchConnection = makeConnection(factory: mismatchFactory)
        let mismatchConversation = makeConversation(id: "mismatched-interaction")
        _ = try await establish(
            mismatchConnection,
            conversation: mismatchConversation,
            factory: mismatchFactory
        )
        let mismatchSocket = try await mismatchFactory.socket(at: 0)
        let mismatchPrompt = Task {
            try await mismatchConnection.sendPrompt(
                conversation: mismatchConversation,
                prompt: "mismatch",
                onEvent: nil,
                onInteraction: { _ in .askUser(.answer("wrong kind")) }
            )
        }
        _ = try await mismatchSocket.waitForSentFrame(type: "INPUT")
        try mismatchSocket.enqueueFrame(
            ["type": .string("approval_needed"), "id": .string("approval"), "tool": .string("shell")]
        )
        await assertClientError(.badFrame, from: mismatchPrompt)
    }

    func testSupersededAndCancelledAskUserSendNoWireResponse() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "no-response-interactions")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        var interactionCount = 0
        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "two interactions",
                onEvent: nil,
                onInteraction: { interaction in
                    interactionCount += 1
                    switch interaction {
                    case .approval:
                        return .superseded
                    case .askUser:
                        return .askUser(.cancel)
                    default:
                        return .superseded
                    }
                }
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        let sentBeforeInteractions = try socket.sentFrames().count
        try socket.enqueueFrame(
            ["type": .string("approval_needed"), "id": .string("a"), "tool": .string("shell")]
        )
        try socket.enqueueFrame(
            ["type": .string("ask_user"), "id": .string("q"), "question": .string("Question?")]
        )
        try await waitUntil { interactionCount == 2 }
        await connection.waitForPendingInteractionResponses()
        XCTAssertEqual(try socket.sentFrames().count, sentBeforeInteractions)

        try socket.enqueueFrame(["type": .string("OUTPUT"), "message": .string("done")])
        let promptResult = try await promptTask.value
        XCTAssertEqual(promptResult.output, "done")
        await connection.close()
    }

    func testServerAndPingSendErrorsFailPendingPrompt() async throws {
        let serverFactory = MockHostedAgentSocketFactory()
        let serverConnection = makeConnection(factory: serverFactory)
        let serverConversation = makeConversation(id: "server-error")
        _ = try await establish(serverConnection, conversation: serverConversation, factory: serverFactory)
        let serverSocket = try await serverFactory.socket(at: 0)
        let serverPrompt = Task {
            try await serverConnection.sendPrompt(
                conversation: serverConversation,
                prompt: "server error",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await serverSocket.waitForSentFrame(type: "INPUT")
        try serverSocket.enqueueFrame(["type": .string("ERROR"), "error": .string("denied")])
        do {
            _ = try await serverPrompt.value
            XCTFail("Expected server error")
        } catch let error as HostedAgentClientError {
            guard case .server(let message) = error else {
                return XCTFail("Expected server error, got \(error)")
            }
            XCTAssertEqual(message, "denied")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let pingFactory = MockHostedAgentSocketFactory()
        let pingConnection = makeConnection(factory: pingFactory)
        let pingConversation = makeConversation(id: "ping-error")
        _ = try await establish(pingConnection, conversation: pingConversation, factory: pingFactory)
        let pingSocket = try await pingFactory.socket(at: 0)
        let pingPrompt = Task {
            try await pingConnection.sendPrompt(
                conversation: pingConversation,
                prompt: "ping",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await pingSocket.waitForSentFrame(type: "INPUT")
        pingSocket.failNextSend()
        try pingSocket.enqueueFrame(["type": .string("PING")])
        await assertClientError(.closed, from: pingPrompt)
    }

    func testPromptResumesOnNewSocketWhileAgentStillRunning() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 3)
        let conversation = makeConversation(id: "resume-running")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "long think",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")

        // the app was suspended and the socket died under the pending prompt
        socket.enqueueError()

        let resumedSocket = try await factory.socket(at: 1)
        let reconnect = try await resumedSocket.waitForSentFrame(type: "CONNECT")
        XCTAssertEqual(reconnect["session_id"]?.stringValue, conversation.id)
        try resumedSocket.enqueueFrame(
            ["type": .string("CONNECTED"), "status": .string("running")]
        )
        try resumedSocket.enqueueFrame(
            ["type": .string("OUTPUT"), "result": .string("recovered reply")]
        )

        let result = try await promptTask.value
        XCTAssertEqual(result.output, "recovered reply")
        let resentInputs = try resumedSocket.sentFrames().filter { $0["type"]?.stringValue == "INPUT" }
        XCTAssertTrue(resentInputs.isEmpty, "a delivered INPUT must not be resent on resume")
        await connection.close()
    }

    func testPromptRecoversMissedReplyFromReconnectChatItems() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 3)
        let conversation = makeConversation(id: "resume-finished")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        var events: [HostedAgentEvent] = []

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "long think",
                onEvent: { events.append($0) },
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        socket.enqueueError()

        let resumedSocket = try await factory.socket(at: 1)
        _ = try await resumedSocket.waitForSentFrame(type: "CONNECT")
        // the run finished while disconnected; the reply only exists in chat_items
        try resumedSocket.enqueueFrame(
            [
                "type": .string("CONNECTED"),
                "status": .string("connected"),
                "server_newer": .bool(true),
                "session": .object(["mode": .string("safe")]),
                "chat_items": .array([
                    .object([
                        "id": .string("msg-0"),
                        "type": .string("user"),
                        "content": .string("long think")
                    ]),
                    .object([
                        "id": .string("tool-1"),
                        "type": .string("tool_call"),
                        "name": .string("shell"),
                        "status": .string("done"),
                        "result": .string("ok")
                    ]),
                    .object([
                        "id": .string("msg-1"),
                        "type": .string("agent"),
                        "content": .string("missed reply")
                    ])
                ])
            ]
        )

        let result = try await promptTask.value
        XCTAssertEqual(result.output, "missed reply")
        XCTAssertEqual(
            events,
            [.toolResult(id: "tool-1", name: "shell", output: "ok", state: .completed)]
        )
        await connection.close()
    }

    // MARK: Prompts sent before a relaunch

    func testSendPromptReportsDispatchBeforeTheInputLeaves() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "dispatch-order")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        var inputFramesAtDispatch: Int?

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "make a file",
                onEvent: nil,
                onInteraction: nil,
                onInputDispatched: {
                    inputFramesAtDispatch = (try? socket.sentFrames())?
                        .filter { $0["type"]?.stringValue == "INPUT" }.count
                }
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        try socket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("done")])

        let result = try await promptTask.value
        XCTAssertEqual(result.output, "done")
        XCTAssertEqual(inputFramesAtDispatch, 0, "the app must save the mark before INPUT is written")
        await connection.close()
    }

    func testResumeReadsAFinishedTurnWithoutSendingInput() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(
            id: "resume-finished-turn",
            serverSession: ["turn": .number(1), "session_id": .string("resume-finished-turn")]
        )

        let resumeTask = Task {
            try await connection.resumePrompt(
                conversation: conversation,
                prompt: "Make him a text file",
                onEvent: nil,
                onInteraction: nil
            )
        }
        let socket = try await factory.socket(at: 0)
        let connectFrame = try await socket.waitForSentFrame(type: "CONNECT")
        // No turn history goes up, so the host's copy always wins and chat_items come back.
        guard case .object(let session)? = connectFrame["session"] else {
            return XCTFail("CONNECT must carry a session object")
        }
        XCTAssertEqual(Set(session.keys), ["session_id", "mode"])

        try socket.enqueueFrame(
            [
                "type": .string("CONNECTED"),
                "status": .string("connected"),
                "server_newer": .bool(true),
                "session": .object(["turn": .number(2)]),
                "chat_items": .array([
                    .object(["id": .string("msg-0"), "type": .string("user"), "content": .string("earlier")]),
                    .object(["id": .string("msg-1"), "type": .string("agent"), "content": .string("earlier reply")]),
                    .object(["id": .string("msg-2"), "type": .string("user"), "content": .string("Make him a text file")]),
                    .object(["id": .string("msg-3"), "type": .string("agent"), "content": .string("Created smiley.txt")])
                ])
            ]
        )

        let result = try await resumeTask.value
        XCTAssertEqual(result.output, "Created smiley.txt")
        XCTAssertEqual(try socket.sentFrames().compactMap { $0["type"]?.stringValue }, ["CONNECT"])
        await connection.close()
    }

    func testResumeRejectsAnOlderTurnsReply() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "resume-older-turn")

        let resumeTask = Task {
            try await connection.resumePrompt(
                conversation: conversation,
                prompt: "Delete the temp folder",
                onEvent: nil,
                onInteraction: nil
            )
        }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        // The INPUT never arrived: the host's last turn is an older message.
        try socket.enqueueFrame(
            [
                "type": .string("CONNECTED"),
                "status": .string("connected"),
                "server_newer": .bool(true),
                "chat_items": .array([
                    .object(["id": .string("msg-0"), "type": .string("user"), "content": .string("earlier")]),
                    .object(["id": .string("msg-1"), "type": .string("agent"), "content": .string("earlier reply")])
                ])
            ]
        )

        await assertOutcomeUnknown(from: resumeTask)
        XCTAssertEqual(try socket.sentFrames().compactMap { $0["type"]?.stringValue }, ["CONNECT"])
        await connection.close()
    }

    func testResumeWithNoHostRecordFailsWithoutSendingInput() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "resume-no-record")

        let resumeTask = Task {
            try await connection.resumePrompt(
                conversation: conversation,
                prompt: "Make him a text file",
                onEvent: nil,
                onInteraction: nil
            )
        }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("new")])

        await assertOutcomeUnknown(from: resumeTask)
        XCTAssertEqual(try socket.sentFrames().compactMap { $0["type"]?.stringValue }, ["CONNECT"])
        await connection.close()
    }

    func testResumeFollowsATurnThatIsStillRunning() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "resume-running")
        var events: [HostedAgentEvent] = []

        let resumeTask = Task {
            try await connection.resumePrompt(
                conversation: conversation,
                prompt: "long task",
                onEvent: { events.append($0) },
                onInteraction: nil
            )
        }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("running")])
        try socket.enqueueFrame(
            ["type": .string("tool_result"), "id": .string("tool-1"), "name": .string("write"), "result": .string("ok")]
        )
        try socket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("finished")])

        let result = try await resumeTask.value
        XCTAssertEqual(result.output, "finished")
        XCTAssertEqual(events, [.toolResult(id: "tool-1", name: "write", output: "ok", state: .completed)])
        XCTAssertEqual(try socket.sentFrames().compactMap { $0["type"]?.stringValue }, ["CONNECT"])
        await connection.close()
    }

    private func assertOutcomeUnknown(
        from task: Task<HostedAgentResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected outcomeUnknown", file: file, line: line)
        } catch HostedAgentClientError.outcomeUnknown {
            return
        } catch {
            XCTFail("Expected outcomeUnknown, got \(error)", file: file, line: line)
        }
    }

    func testPromptResendsInputThatNeverReachedTheAgent() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 3)
        let conversation = makeConversation(id: "resume-resend")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        socket.failNextSend()

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "never delivered",
                onEvent: nil,
                onInteraction: nil
            )
        }

        let resumedSocket = try await factory.socket(at: 1)
        _ = try await resumedSocket.waitForSentFrame(type: "CONNECT")
        try resumedSocket.enqueueFrame(
            ["type": .string("CONNECTED"), "status": .string("new")]
        )
        let resentInput = try await resumedSocket.waitForSentFrame(type: "INPUT")
        XCTAssertEqual(resentInput["prompt"]?.stringValue, "never delivered")
        try resumedSocket.enqueueFrame(
            ["type": .string("OUTPUT"), "result": .string("made it")]
        )

        let result = try await promptTask.value
        XCTAssertEqual(result.output, "made it")
        await connection.close()
    }

    func testResentInputKeepsTheOriginalInputID() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 3)
        let conversation = makeConversation(id: "resume-duplicate")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        socket.failNextSend(afterRecording: true)

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "charge the card once",
                onEvent: nil,
                onInteraction: nil
            )
        }
        let firstInput = try await socket.waitForSentFrame(type: "INPUT")

        let resumedSocket = try await factory.socket(at: 1)
        _ = try await resumedSocket.waitForSentFrame(type: "CONNECT")
        try resumedSocket.enqueueFrame(
            ["type": .string("CONNECTED"), "status": .string("new")]
        )
        let resentInput = try await resumedSocket.waitForSentFrame(type: "INPUT")
        try resumedSocket.enqueueFrame(
            ["type": .string("OUTPUT"), "result": .string("charged once")]
        )
        _ = try await promptTask.value

        let originalID = try XCTUnwrap(firstInput["input_id"]?.stringValue)
        XCTAssertFalse(originalID.isEmpty)
        XCTAssertEqual(
            resentInput["input_id"]?.stringValue,
            originalID,
            "a resent INPUT must reuse the original input_id so the agent can drop the duplicate"
        )
        await connection.close()
    }

    func testResumeGivesUpAfterAttemptLimitAndFailsPrompt() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 1)
        let conversation = makeConversation(id: "resume-exhausted")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "doomed",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        socket.enqueueError()

        let resumedSocket = try await factory.socket(at: 1)
        _ = try await resumedSocket.waitForSentFrame(type: "CONNECT")
        resumedSocket.enqueueError()

        await assertClientError(.closed, from: promptTask)
        XCTAssertEqual(factory.count, 2)
    }

    func testResumeSendsLastMessageIDAndDropsReplayedEvents() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 3)
        let conversation = makeConversation(id: "resume-bookmark")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        var events: [HostedAgentEvent] = []

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "long job",
                onEvent: { events.append($0) },
                onInteraction: nil
            )
        }

        _ = try await socket.waitForSentFrame(type: "INPUT")
        try socket.enqueueFrame(["type": .string("tool_call"), "id": .string("t1"), "name": .string("shell")])
        try socket.enqueueFrame(["type": .string("tool_result"), "id": .string("t1"), "name": .string("ok")])

        try await waitUntil { events.count == 2 }
        socket.enqueueError()

        let resumedSocket = try await factory.socket(at: 1)
        let reconnect = try await resumedSocket.waitForSentFrame(type: "CONNECT")

        XCTAssertEqual(reconnect["session_id"]?.stringValue, conversation.id)
        XCTAssertEqual(reconnect["last_msg_id"]?.stringValue, "t1")

        try resumedSocket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("running")])

        // the host does not know that the client has rendered tool_result, thus resends it
        try resumedSocket.enqueueFrame(["type": .string("tool_result"), "id": .string("t1"), "name": .string("ok")])
        try resumedSocket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("done")])

        let result = try await promptTask.value

        XCTAssertEqual(result.output, "done")
        XCTAssertEqual(events.count, 2, "a replayed event must not reach the UI twice")
        await connection.close()
    }

    func testUnasnweredApprovalIsNotBookmarkedSoTheHostReplaysIt() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 3)
        let conversation = makeConversation(id: "resume-approval")
        _ = try await establish(connection, conversation: conversation, factory: factory)

        let socket = try await factory.socket(at: 0)
        let asked = expectation(description: "approval shown")

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "edit the file",
                onEvent: nil,
                onInteraction: { _ in
                    asked.fulfill()
                    // user has not answered when the network drops
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    return .approval(.allowOnce)
                }
            )
        }

        _ = try await socket.waitForSentFrame(type: "INPUT")
        try socket.enqueueFrame(["type": .string("approval_needed"), "id": .string("approval-9"), "tool": .string("shell")])
        await fulfillment(of: [asked], timeout: 1)
        socket.enqueueError()

        let resumedSocket = try await factory.socket(at: 1)
        let reconnect = try await resumedSocket.waitForSentFrame(type: "CONNECT")

        XCTAssertNil(reconnect["last_msg_id"], "an unanswered approval must be replayed")

        promptTask.cancel()
        await connection.close()
    }

    func testBookmarksAreKeptPerConversation() {
        let store = HostedAgentBookmarkStore(suiteName: "test.bookmarks.\(UUID().uuidString)")
        store.save(SessionBookmark(sessionID: "a", lastMessageID: "evt-a"), conversationID: "a")
        store.save(SessionBookmark(sessionID: "b", lastMessageID: "evt-b"), conversationID: "b")

        XCTAssertEqual(store.load(conversationID: "a")?.lastMessageID, "evt-a")
        XCTAssertEqual(store.load(conversationID: "b")?.lastMessageID, "evt-b")

        store.remove(conversationID: "a")

        XCTAssertNil(store.load(conversationID: "a"))
        XCTAssertEqual(store.load(conversationID: "b")?.lastMessageID, "evt-b")
    }

    func testRelaunchedConnectionResumesTheSameSessionFromTheBookmark() async throws {
        let store = HostedAgentBookmarkStore(suiteName: "test.bookmarks.\(UUID().uuidString)")
        let conversation = makeConversation(id: "relaunch")

        // app is killed mid run
        let firstFactory = MockHostedAgentSocketFactory()
        let first = makeConnection(factory: firstFactory, resumeAttemptLimit: 3, bookmarkStore: store)

        _ = try await establish(first, conversation: conversation, factory: firstFactory)

        let socket = try await firstFactory.socket(at: 0)
        let promptTask = Task {
            try await first.sendPrompt(
                conversation: conversation,
                prompt: "long job",
                onEvent: nil,
                onInteraction: nil
            )
        }

        _ = try await socket.waitForSentFrame(type: "INPUT")

        try socket.enqueueFrame(
            ["type": .string("tool_call"), "id": .string("evt-1"), "name": .string("shell")]
        )

        try await waitUntil {
            store.load(conversationID: "test-conversation")?.lastMessageID == "evt-1"
        }

        promptTask.cancel()

        _ = try? await promptTask.value
        await first.close()

        // new connection only reads saved
        let secondFactory = MockHostedAgentSocketFactory()
        let second = makeConnection(factory: secondFactory, bookmarkStore: store)
        let connectTask = Task { try await second.ensureConnected(conversation: conversation) }
        let relaunchSocket = try await secondFactory.socket(at: 0)
        let connect = try await relaunchSocket.waitForSentFrame(type: "CONNECT")

        XCTAssertEqual(connect["session_id"]?.stringValue, "relaunch")
        XCTAssertEqual(connect["last_msg_id"]?.stringValue, "evt-1")

        try relaunchSocket.enqueueFrame(
            [
                "type": .string("CONNECTED"),
                "status": .string("running"),
                "session_id": .string("relaunch")
            ]
        )

        let result = try await connectTask.value

        XCTAssertEqual(
            result.serverSession?["session_id"]?.stringValue,
            "relaunch",
            "a resume must not create a new session"
        )

        await second.close()
    }

    func testResumeFailsOverToTheRelayWhenTheDirectEndpointDies() async throws {
        let relay = ResolvedEndpoint(
            wsURL: URL(string: "wss://relay.unit.test/ws/input")!,
            kind: .relay,
            label: "Relay"
        )
        let endpoints = EndpointSequence([endpoint, relay])
        let store = HostedAgentBookmarkStore(suiteName: "test.bookmarks.\(UUID().uuidString)")
        let factory = MockHostedAgentSocketFactory()

        let connection = makeConnection(
            factory: factory,
            resolver: { _ in await endpoints.next() },
            resumeAttemptLimit: 3,
            bookmarkStore: store
        )
        let conversation = makeConversation(id: "failover")

        _ = try await establish(connection, conversation: conversation, factory: factory)
        let directSocket = try await factory.socket(at: 0)

        let promptTask = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "keep going",
                onEvent: nil,
                onInteraction: nil
            )
        }

        _ = try await directSocket.waitForSentFrame(type: "INPUT")

        try directSocket.enqueueFrame(
            ["type": .string("thinking"), "id": .string("t1"), "status": .string("done")]
        )
        try await waitUntil { store.load(conversationID: "test-conversation")?.lastMessageID == "t1" }

        // route dies
        directSocket.enqueueError()

        let relaySocket = try await factory.socket(at: 1)
        let reconnect = try await relaySocket.waitForSentFrame(type: "CONNECT")

        XCTAssertEqual(factory.url(at: 0), endpoint.wsURL)
        XCTAssertEqual(factory.url(at: 1), relay.wsURL)
        XCTAssertEqual(reconnect["session_id"]?.stringValue, "failover")
        XCTAssertEqual(reconnect["last_msg_id"]?.stringValue, "t1")

        try relaySocket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("running")])
        try relaySocket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("finished over the relay")])

        let result = try await promptTask.value

        XCTAssertEqual(result.output, "finished over the relay")
        XCTAssertTrue(
            try relaySocket.sentFrames().filter { $0["type"]?.stringValue == "INPUT" }.isEmpty,
            "a delivered INPUT must not be resent after failover"
        )

        await connection.close()
    }

    private var agentAddress: String {
        "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }

    /// Signed commands:

    private func signedPayload(of frame: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let payload)? = frame["payload"] else {
            throw HostedAgentTestError.failed
        }
        return payload
    }

    /// Host verifies signature against key in 'from', over canonical payload
    private func assertSignatureVerifies(_ frame: [String: JSONValue]) throws {
        let payload = try signedPayload(of: frame)
        let address = try XCTUnwrap(frame["from"]?.stringValue)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try XCTUnwrap(Hex.decode(String(address.dropFirst(2)))))
        let signature = try XCTUnwrap(Hex.decode(try XCTUnwrap(frame["signature"]?.stringValue)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: CanonicalJSON.data(from: payload)))
    }

    func testConnectFrameSignsToTimestampNonceAndSignedCommands() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let task = Task { try await connection.ensureConnected(conversation: makeConversation(id: "c-1")) }
        let socket = try await factory.socket(at: 0)
        let frame = try await socket.waitForSentFrame(type: "CONNECT")
        let payload = try signedPayload(of: frame)

        XCTAssertEqual(payload["to"], .string(agentAddress))
        XCTAssertEqual(payload["signed_commands"], .number(1))
        XCTAssertFalse(try XCTUnwrap(payload["nonce"]?.stringValue).isEmpty)
        XCTAssertNotNil(payload["timestamp"]?.numberValue)
        XCTAssertNil(payload["action"])
        XCTAssertNil(payload["session_sha256"])
        XCTAssertEqual(frame["session_id"], .string("c-1"))
        XCTAssertNotNil(frame["session"])
        try assertSignatureVerifies(frame)
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("new")])
        _ = try await task.value
        await connection.close()
    }

    func testInputFrameSignsEveryFieldTheHostReads() async throws {
        let connection = makeConnection(factory: MockHostedAgentSocketFactory())
        let frame = try await connection.frames.input(
            inputID: "input-1",
            prompt: "ls /tmp",
            images: ["data:image/png;base64,AA=="],
            files: [HostedAgentFilePayload(name: "note.txt", data: "data:text/plain;base64, SGk=").jsonValue]
        )
        let payload = try signedPayload(of: frame)

        XCTAssertEqual(payload["type"], .string("INPUT"))
        XCTAssertEqual(payload["to"], .string(agentAddress))
        XCTAssertEqual(payload["prompt"], .string("ls /tmp"))
        XCTAssertEqual(payload["input_id"], .string("input-1"))
        XCTAssertEqual(payload["images"], .array([.string("data:image/png;base64,AA==")]))
        XCTAssertNotNil(payload["files"])
        XCTAssertFalse(try XCTUnwrap(payload["nonce"]?.stringValue).isEmpty)
        XCTAssertEqual(frame["prompt"], .string("ls /tmp"))   // copy at the top level for pre-v2 hosts
        try assertSignatureVerifies(frame)
    }

    func testInteractionResponsesAreSignedAndNameTheirRequest() async throws {
        let connection = makeConnection(factory: MockHostedAgentSocketFactory())
        let approval = try await connection.frames.approvalResponse(
            requestID: "approval-1",
            decision: ApprovalDecision.allowOnce.decisionFields
        )
        let payload = try signedPayload(of: approval)

        XCTAssertEqual(payload["type"], .string("APPROVAL_RESPONSE"))
        XCTAssertEqual(payload["approved"], .bool(true))
        XCTAssertEqual(payload["request_id"], .string("approval-1"))
        XCTAssertEqual(payload["to"], .string(agentAddress))
        try assertSignatureVerifies(approval)

        let ulw = try await connection.signedCommand(UlwCheckpointDecision.continueWork(turns: 10).responseFrame)
        XCTAssertEqual(try signedPayload(of: ulw)["type"], .string("ULW_RESPONSE"))
        try assertSignatureVerifies(ulw)
    }

    private func makeConversation(
        id: String,
        mode: ChatMode = .safe,
        serverSession: [String: JSONValue]? = nil
    ) -> Conversation {
        Conversation(
            id: id,
            title: "Test",
            agentID: "agent-id",
            agentAddress: agentAddress,
            mode: mode,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            messages: [],
            serverSession: serverSession
        )
    }

    // CONNECT adoption tests

    func testConnectDeclaresTheProtocolVersionOnTheWire() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let task = Task { try await connection.ensureConnected(conversation: makeConversation(id: "c-1")) }
        let socket = try await factory.socket(at: 0)
        let frame = try await socket.waitForSentFrame(type: "CONNECT")

        XCTAssertEqual(frame["protocol"], .object(OIP.descriptor))
        XCTAssertEqual(frame["to"], .string(agentAddress))
        XCTAssertEqual(try signedPayload(of: frame)["signed_commands"], .number(1))
        try assertSignatureVerifies(frame)

        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("new")])
        _ = try await task.value
        await connection.close()
    }

    func testIncompatibleVersionFailsOnceAndNamesTheVersionNeeded() async throws {
        let factory = MockHostedAgentSocketFactory()
        // Resume is allowed here, so a second socket would show up in factory.count.
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 3)
        let task = Task { try await connection.ensureConnected(conversation: makeConversation(id: "c-1")) }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(incompatibleFrame(host: "0.2"))

        do {
            _ = try await task.value
            XCTFail("Expected incompatibleProtocol")
        } catch let error as HostedAgentClientError {
            let incompatibility = try XCTUnwrap(error.incompatibility, "Got \(error)")
            XCTAssertEqual(incompatibility.neededVersion, "0.2")
            XCTAssertEqual(incompatibility.direction, .appTooOld)
            XCTAssertFalse(incompatibility.isRetryable)
            XCTAssertTrue(error.localizedDescription.contains("0.2"), error.localizedDescription)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(factory.count, 1)
        XCTAssertNotNil(socket.closeCode)
        let connects = try socket.sentFrames().filter { $0["type"]?.stringValue == "CONNECT" }
        XCTAssertEqual(connects.count, 1)
        let state = await connection.state
        XCTAssertEqual(state, .disconnected)
    }

    func testIncompatibleVersionWithAPromptPendingIsNotResumed() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory, resumeAttemptLimit: 3)
        let conversation = makeConversation(id: "c-2")
        _ = try await establish(connection, conversation: conversation, factory: factory)
        let socket = try await factory.socket(at: 0)
        let prompt = Task {
            try await connection.sendPrompt(
                conversation: conversation,
                prompt: "hello",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        try socket.enqueueFrame(incompatibleFrame(host: "0.2"))

        do {
            _ = try await prompt.value
            XCTFail("Expected incompatibleProtocol")
        } catch let error as HostedAgentClientError {
            XCTAssertNotNil(error.incompatibility, "Got \(error)")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(factory.count, 1)
    }

    func testErrorWithoutACodeStaysAServerError() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let task = Task { try await connection.ensureConnected(conversation: makeConversation(id: "c-1")) }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("ERROR"), "message": .string("signature expired")])

        do {
            _ = try await task.value
            XCTFail("Expected server error")
        } catch let error as HostedAgentClientError {
            guard case .server(let message) = error else {
                return XCTFail("Expected server error, got \(error)")
            }
            XCTAssertEqual(message, "signature expired")
            XCTAssertNil(error.incompatibility)
        }
    }

    func testIndexStatusIsRejected() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let task = Task { try await connection.ensureConnected(conversation: makeConversation(id: "c-1")) }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame([
            "type": .string("CONNECTED"),
            "session_id": .string("c-1"),
            "status": .string("index")
        ])
        await assertClientError(.badFrame, from: task)
    }

    func testServerNewerSessionReplacesTheSavedOne() async throws {
        let factory = MockHostedAgentSocketFactory()
        let connection = makeConnection(factory: factory)
        let conversation = makeConversation(id: "c-3", serverSession: ["theme": .string("saved")])
        let task = Task { try await connection.ensureConnected(conversation: conversation) }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame([
            "type": .string("CONNECTED"),
            "session_id": .string("c-3"),
            "status": .string("connected"),
            "server_newer": .bool(true),
            "session": .object(["theme": .string("from-host")])
        ])

        let result = try await task.value
        XCTAssertEqual(result.serverSession?["theme"], .string("from-host"))
        XCTAssertEqual(result.serverSession?["session_id"], .string("c-3"))
        await connection.close()
    }

    private func incompatibleFrame(host version: String) -> [String: JSONValue] {
        [
            "type": .string("ERROR"),
            "code": .number(-32010),
            "message": .string("Unsupported OIP protocol"),
            "retryable": .bool(false),
            "protocol": .object([
                "name": .string("oip"),
                "version": .string(version),
                "min_version": .string(version),
                "max_version": .string(version),
                "websocket_path": .string("/ws")
            ])
        ]
    }

    private func makeConnection(
        factory: MockHostedAgentSocketFactory,
        resolver: HostedAgentEndpointResolver? = nil,
        observer: HostedAgentConnectionStateObserver = HostedAgentConnectionStateObserver(),
        connectTimeout: TimeInterval = 1,
        livenessTimeout: TimeInterval = 5,
        livenessCheckInterval: TimeInterval = 0.1,
        resumeAttemptLimit: Int = 0,
        resumeRetryDelay: TimeInterval = 0,
        bookmarkStore: HostedAgentBookmarkStore = HostedAgentBookmarkStore(suiteName: "test.bookmarks.\(UUID().uuidString)")
    ) -> HostedAgentConnection {
        let endpoint = endpoint
        return HostedAgentConnection(
            key: HostedAgentConnectionKey(agentAddress: agentAddress, conversationID: "test-conversation"),
            identityStore: IdentityStore(),
            session: .shared,
            discovery: HostedAgentDiscovery(session: .shared, relayURL: "ws://unused.test", localEndpoints: []),
            connectionStateObserver: observer,
            socketFactory: factory.factory,
            endpointResolver: resolver ?? { _ in endpoint },
            connectTimeout: connectTimeout,
            livenessTimeout: livenessTimeout,
            livenessCheckInterval: livenessCheckInterval,
            resumeAttemptLimit: resumeAttemptLimit,
            resumeRetryDelay: resumeRetryDelay,
            bookmarkStore: bookmarkStore
        )
    }

    private func establish(
        _ connection: HostedAgentConnection,
        conversation: Conversation,
        factory: MockHostedAgentSocketFactory,
        socketIndex: Int = 0
    ) async throws -> HostedAgentResult {
        let task = Task {
            try await connection.ensureConnected(conversation: conversation)
        }
        let socket = try await factory.socket(at: socketIndex)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("new")])
        return try await task.value
    }

    private func assertCancellation(from task: Task<HostedAgentResult, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            return
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func assertClientError(
        _ expected: HostedAgentClientError,
        operation: () async throws -> HostedAgentResult
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as HostedAgentClientError {
            XCTAssertTrue(sameErrorCase(error, expected), "Expected \(expected), got \(error)")
        } catch {
            XCTFail("Expected HostedAgentClientError, got \(error)")
        }
    }

    private func assertClientError(
        _ expected: HostedAgentClientError,
        from task: Task<HostedAgentResult, Error>
    ) async {
        await assertClientError(expected) { try await task.value }
    }

    private func sameErrorCase(
        _ lhs: HostedAgentClientError,
        _ rhs: HostedAgentClientError
    ) -> Bool {
        switch (lhs, rhs) {
        case (.invalidAddress, .invalidAddress),
             (.badFrame, .badFrame),
             (.closed, .closed),
             (.timeout, .timeout),
             (.busy, .busy):
            return true
        case (.invalidURL, .invalidURL), (.server, .server), (.incompatibleProtocol, .incompatibleProtocol):
            return true
        default:
            return false
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw HostedAgentTestError.timedOut
    }
}
