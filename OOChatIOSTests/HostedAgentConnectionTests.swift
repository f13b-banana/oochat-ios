import CryptoKit
import Foundation
import ConnectOnionKit
import XCTest
@testable import OOChatIOS

private enum HostedAgentTestError: Error {
    case failed
    case cancelled
    case timedOut
}

private final class MockHostedAgentWebSocket: HostedAgentWebSocketTask, @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message

    private let lock = NSLock()
    private var queuedReceives: [Result<Message, Error>] = []
    private var receiveContinuation: CheckedContinuation<Message, Error>?
    private var storedSentMessages: [Message] = []
    private var storedNextSendError: Error?
    private var storedRecordsFailedSend = false
    private var storedIsResumed = false
    private var storedCloseCode: URLSessionWebSocketTask.CloseCode?

    var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsResumed
    }

    var closeCode: URLSessionWebSocketTask.CloseCode? {
        lock.lock()
        defer { lock.unlock() }
        return storedCloseCode
    }

    func resume() {
        lock.lock()
        storedIsResumed = true
        lock.unlock()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let continuation: CheckedContinuation<Message, Error>?
        lock.lock()
        storedCloseCode = closeCode
        continuation = receiveContinuation
        receiveContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: HostedAgentTestError.cancelled)
    }

    func send(_ message: Message) async throws {
        if let error = recordSend(message) {
            throw error
        }
    }

    private func recordSend(_ message: Message) -> Error? {
        lock.lock()
        if let error = storedNextSendError {
            storedNextSendError = nil
            if storedRecordsFailedSend {
                storedRecordsFailedSend = false
                storedSentMessages.append(message)
            }
            lock.unlock()
            return error
        }
        storedSentMessages.append(message)
        lock.unlock()
        return nil
    }

    func receive() async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result = queuedReceives.first {
                queuedReceives.removeFirst()
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            if storedCloseCode != nil {
                lock.unlock()
                continuation.resume(throwing: HostedAgentTestError.cancelled)
                return
            }
            receiveContinuation = continuation
            lock.unlock()
        }
    }

    func failNextSend(with error: Error = HostedAgentTestError.failed, afterRecording: Bool = false) {
        lock.lock()
        storedNextSendError = error
        storedRecordsFailedSend = afterRecording
        lock.unlock()
    }

    func enqueueFrame(_ frame: [String: JSONValue], asData: Bool = false) throws {
        let data = try JSONEncoder().encode(frame)
        let message: Message
        if asData {
            message = .data(data)
        } else {
            message = .string(try XCTUnwrap(String(data: data, encoding: .utf8)))
        }
        enqueue(.success(message))
    }

    func enqueueText(_ text: String) {
        enqueue(.success(.string(text)))
    }

    func enqueueError(_ error: Error = HostedAgentTestError.failed) {
        enqueue(.failure(error))
    }

    func sentFrames() throws -> [[String: JSONValue]] {
        let messages: [Message]
        lock.lock()
        messages = storedSentMessages
        lock.unlock()

        return try messages.map { message in
            let data: Data
            switch message {
            case .string(let text):
                data = try XCTUnwrap(text.data(using: .utf8))
            case .data(let value):
                data = value
            @unknown default:
                throw HostedAgentTestError.failed
            }
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        }
    }

    func waitForSentFrame(
        type: String,
        occurrence: Int = 1,
        timeout: TimeInterval = 1
    ) async throws -> [String: JSONValue] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matching = try sentFrames().filter { $0["type"]?.stringValue == type }
            if matching.count >= occurrence {
                return matching[occurrence - 1]
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw HostedAgentTestError.timedOut
    }

    private func enqueue(_ result: Result<Message, Error>) {
        let continuation: CheckedContinuation<Message, Error>?
        lock.lock()
        continuation = receiveContinuation
        receiveContinuation = nil
        if continuation == nil {
            queuedReceives.append(result)
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class MockHostedAgentSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let configureSocket: @Sendable (MockHostedAgentWebSocket) -> Void
    private var storedSockets: [MockHostedAgentWebSocket] = []
    private var storedURLs: [URL] = []

    init(configureSocket: @escaping @Sendable (MockHostedAgentWebSocket) -> Void = { _ in }) {
        self.configureSocket = configureSocket
    }

    var factory: HostedAgentWebSocketFactory {
        { [weak self] url in
            guard let self else {
                return MockHostedAgentWebSocket()
            }
            let socket = MockHostedAgentWebSocket()
            self.configureSocket(socket)
            self.lock.lock()
            self.storedURLs.append(url)
            self.storedSockets.append(socket)
            self.lock.unlock()
            return socket
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSockets.count
    }

    func url(at index: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedURLs.indices.contains(index) ? storedURLs[index] : nil
    }

    func socket(at index: Int, timeout: TimeInterval = 1) async throws -> MockHostedAgentWebSocket {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let socket = storedSocket(at: index)
            if let socket {
                return socket
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw HostedAgentTestError.timedOut
    }

    private func storedSocket(at index: Int) -> MockHostedAgentWebSocket? {
        lock.lock()
        defer { lock.unlock() }
        return storedSockets.indices.contains(index) ? storedSockets[index] : nil
    }
}

private final class MutableHostedAgentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date = Date(timeIntervalSince1970: 1_000)) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor EndpointSequence {
    private var queue: [ResolvedEndpoint]

    init(_ endpoints: [ResolvedEndpoint]) {
        queue = endpoints
    }

    func next() -> ResolvedEndpoint {
        queue.count > 1 ? queue.removeFirst() : queue[0]
    }
}

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

        try socket.enqueueFrame(["type": .string("CONNECTED")])
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
        let connection = makeConnection(factory: MockHostedAgentSocketFactory())
        let frame = try await connection.buildConnectFrame(conversation: makeConversation(id: "c-1"))
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
        try socket.enqueueFrame(["type": .string("CONNECTED")])
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
        case (.invalidURL, .invalidURL), (.server, .server):
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

@MainActor
final class HostedAgentConnectionPoolTests: XCTestCase {
    private let endpoint = ResolvedEndpoint(
        wsURL: URL(string: "wss://relay.unit.test/ws/input")!,
        kind: .relay,
        label: "Relay"
    )

    func testObserverCoalescesStaleUpdatesAndUsesLatestHandler() async {
        let observer = HostedAgentConnectionStateObserver()
        let notified = expectation(description: "latest state delivered")
        var states: [(String, ConversationConnectionState)] = []
        observer.handler = { conversationID, state in
            states.append((conversationID, state))
            notified.fulfill()
        }

        observer.notify(conversationID: "conversation", state: .reconnecting)
        observer.notify(conversationID: "conversation", state: .connected)
        observer.notify(conversationID: "conversation", state: .disconnected)
        await fulfillment(of: [notified], timeout: 1)

        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.0, "conversation")
        XCTAssertEqual(states.first?.1, .disconnected)

        observer.handler = nil
        XCTAssertNil(observer.handler)
        observer.notify(conversationID: "ignored", state: .connected)
        await Task.yield()
        XCTAssertEqual(states.count, 1)
    }

    func testPoolConnectReusesConnectionWaitsAndClosesAll() async throws {
        let factory = MockHostedAgentSocketFactory()
        let pool = makePool(factory: factory, maximumSize: 2)
        let conversation = makeConversation(id: "pool-reuse")

        let first = Task {
            try await pool.connect(agentAddress: agentAddress, conversation: conversation)
        }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("CONNECTED")])
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.endpointLabel, endpoint.label)

        let reused = try await pool.connect(agentAddress: agentAddress, conversation: conversation)
        XCTAssertEqual(reused.endpointLabel, endpoint.label)
        XCTAssertEqual(factory.count, 1)

        await pool.waitForPendingInteractionResponses(
            agentAddress: agentAddress,
            conversationID: conversation.id
        )
        await pool.waitForPendingInteractionResponses(
            agentAddress: agentAddress,
            conversationID: "missing"
        )
        await pool.closeAll()
        XCTAssertEqual(socket.closeCode, .goingAway)
        await pool.closeAll()
    }

    // A connected socket answers `connect` from cache, which is the right call for a reused
    // conversation and the wrong one after the network disappeared: the recovery layer would
    // read that cached success as proof it is back. Closing has to leave nothing to answer from.
    func testConnectAfterCloseAllHandshakesAgainInsteadOfAnsweringFromCache() async throws {
        let factory = MockHostedAgentSocketFactory()
        let pool = makePool(factory: factory, maximumSize: 2)
        let conversation = makeConversation(id: "pool-close-then-connect")
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 0)
        let reused = try await pool.connect(agentAddress: agentAddress, conversation: conversation)
        XCTAssertEqual(reused.endpointLabel, endpoint.label)
        XCTAssertEqual(factory.count, 1, "a live conversation reuses its socket")

        await pool.closeAll()
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 1)

        XCTAssertEqual(factory.count, 2)
        await pool.closeAll()
    }

    func testCloseAllFailsAPendingPromptRightAwayInsteadOfLeavingItWaiting() async throws {
        let factory = MockHostedAgentSocketFactory()
        let pool = makePool(factory: factory, maximumSize: 2)
        let conversation = makeConversation(id: "pool-close-pending")
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 0)
        let socket = try await factory.socket(at: 0)
        let prompt = Task {
            try await pool.sendPrompt(
                agentAddress: agentAddress,
                conversation: conversation,
                prompt: "in flight",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")

        await pool.closeAll()

        do {
            _ = try await prompt.value
            XCTFail("Expected the pending prompt to fail with the socket")
        } catch let error as HostedAgentClientError {
            guard case .closed = error else {
                return XCTFail("Expected closed, got \(error)")
            }
        }
    }

    func testNetworkLossClosesTheIdleSocketAndForcesTheNextConnectToHandshake() async throws {
        let factory = MockHostedAgentSocketFactory()
        let pool = makePool(factory: factory, maximumSize: 2)
        let conversation = makeConversation(id: "pool-network-loss-idle")
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 0)
        let socket = try await factory.socket(at: 0)

        await pool.noteNetworkLost()

        XCTAssertEqual(socket.closeCode, .goingAway, "nothing is riding an idle socket")
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 1)
        XCTAssertEqual(factory.count, 2)
        await pool.closeAll()
    }

    // The reason a busy connection is marked rather than closed: the prompt on it may still
    // survive a blip through the resume path, which closing would take away.
    func testNetworkLossLeavesAnInFlightPromptOnItsSocket() async throws {
        let factory = MockHostedAgentSocketFactory()
        let pool = makePool(factory: factory, maximumSize: 2)
        let conversation = makeConversation(id: "pool-network-loss-busy")
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 0)
        let socket = try await factory.socket(at: 0)
        let prompt = Task {
            try await pool.sendPrompt(
                agentAddress: agentAddress,
                conversation: conversation,
                prompt: "in flight",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")

        await pool.noteNetworkLost()

        XCTAssertNil(socket.closeCode, "the socket carrying a prompt is left to the resume path")
        try socket.enqueueFrame(["type": .string("OUTPUT"), "content": .string("late reply")])
        let result = try await prompt.value
        XCTAssertEqual(result.output, "late reply")
        await pool.closeAll()
    }

    func testNetworkLossStopsABusyConnectionAnsweringConnectFromCache() async throws {
        let factory = MockHostedAgentSocketFactory()
        let pool = makePool(factory: factory, maximumSize: 2)
        let conversation = makeConversation(id: "pool-network-loss-probe")
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 0)
        let socket = try await factory.socket(at: 0)
        let prompt = Task {
            try await pool.sendPrompt(
                agentAddress: agentAddress,
                conversation: conversation,
                prompt: "in flight",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        await pool.noteNetworkLost()

        // what a recovery probe does, and it must not come back a success
        do {
            _ = try await pool.connect(agentAddress: agentAddress, conversation: conversation)
            XCTFail("Expected the probe to be refused")
        } catch let error as HostedAgentClientError {
            guard case .busy = error else {
                return XCTFail("Expected busy, got \(error)")
            }
        }
        XCTAssertEqual(factory.count, 1, "the in-flight prompt keeps its socket")

        // once the prompt is done the connection still owes a real handshake
        try socket.enqueueFrame(["type": .string("OUTPUT"), "content": .string("reply")])
        _ = try await prompt.value
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 1)
        XCTAssertEqual(factory.count, 2)
        await pool.closeAll()
    }

    func testPoolSendPromptSuccessAndFailureReleaseLeases() async throws {
        let factory = MockHostedAgentSocketFactory()
        let pool = makePool(factory: factory, maximumSize: 2)
        let conversation = makeConversation(id: "pool-prompt")
        try await connect(pool, conversation: conversation, factory: factory, socketIndex: 0)
        let socket = try await factory.socket(at: 0)

        let prompt = Task {
            try await pool.sendPrompt(
                agentAddress: agentAddress,
                conversation: conversation,
                prompt: "hello",
                onEvent: nil,
                onInteraction: nil
            )
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")
        try socket.enqueueFrame(["type": .string("OUTPUT"), "content": .string("reply")])
        let promptResult = try await prompt.value
        XCTAssertEqual(promptResult.output, "reply")

        socket.failNextSend()
        do {
            _ = try await pool.sendPrompt(
                agentAddress: agentAddress,
                conversation: conversation,
                prompt: "fails",
                onEvent: nil,
                onInteraction: nil
            )
            XCTFail("Expected closed error")
        } catch let error as HostedAgentClientError {
            guard case .closed = error else {
                return XCTFail("Expected closed, got \(error)")
            }
        }
        await pool.closeAll()
    }

    func testPoolPropagatesConnectFailureAndCanRecoverWithNewKey() async throws {
        let factory = MockHostedAgentSocketFactory()
        let pool = makePool(
            factory: factory,
            maximumSize: 1,
            resolver: { address in
                if address.hasSuffix("bad") {
                    throw HostedAgentClientError.invalidURL(address)
                }
                return self.endpoint
            }
        )

        do {
            _ = try await pool.connect(
                agentAddress: "agent-bad",
                conversation: makeConversation(id: "failed-connect")
            )
            XCTFail("Expected invalid URL")
        } catch let error as HostedAgentClientError {
            guard case .invalidURL = error else {
                return XCTFail("Expected invalidURL, got \(error)")
            }
        }

        let conversation = makeConversation(id: "recovered-connect")
        let recovered = Task {
            try await pool.connect(agentAddress: agentAddress, conversation: conversation)
        }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("CONNECTED")])
        let recoveredResult = try await recovered.value
        XCTAssertEqual(recoveredResult.endpointLabel, endpoint.label)
        await pool.closeAll()
    }

    func testPoolEvictsExpiredAndLeastRecentlyUsedIdleConnections() async throws {
        let lruFactory = MockHostedAgentSocketFactory()
        let lruClock = MutableHostedAgentClock()
        let lruPool = makePool(
            factory: lruFactory,
            maximumSize: 1,
            idleLifetime: 100,
            clock: lruClock
        )
        let firstConversation = makeConversation(id: "lru-first")
        try await connect(lruPool, conversation: firstConversation, factory: lruFactory, socketIndex: 0)
        let firstSocket = try await lruFactory.socket(at: 0)
        lruClock.advance(by: 1)

        let secondConversation = makeConversation(id: "lru-second")
        try await connect(lruPool, conversation: secondConversation, factory: lruFactory, socketIndex: 1)
        XCTAssertEqual(firstSocket.closeCode, .goingAway)
        await lruPool.closeAll()

        let expiryFactory = MockHostedAgentSocketFactory()
        let expiryClock = MutableHostedAgentClock()
        let expiryPool = makePool(
            factory: expiryFactory,
            maximumSize: 3,
            idleLifetime: 1,
            clock: expiryClock
        )
        let expiringConversation = makeConversation(id: "expires")
        try await connect(
            expiryPool,
            conversation: expiringConversation,
            factory: expiryFactory,
            socketIndex: 0
        )
        let expiringSocket = try await expiryFactory.socket(at: 0)
        expiryClock.advance(by: 2)
        try await connect(
            expiryPool,
            conversation: makeConversation(id: "after-expiry"),
            factory: expiryFactory,
            socketIndex: 1
        )
        XCTAssertEqual(expiringSocket.closeCode, .goingAway)
        await expiryPool.closeAll()
    }

    private var agentAddress: String {
        "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }

    private func makeConversation(id: String) -> Conversation {
        Conversation(
            id: id,
            title: "Pool Test",
            agentID: "agent-id",
            agentAddress: agentAddress,
            mode: .safe,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            messages: [],
            serverSession: nil
        )
    }

    private func makePool(
        factory: MockHostedAgentSocketFactory,
        maximumSize: Int,
        idleLifetime: TimeInterval = 60,
        resolver: HostedAgentEndpointResolver? = nil,
        clock: MutableHostedAgentClock = MutableHostedAgentClock()
    ) -> HostedAgentConnectionPool {
        let endpoint = endpoint
        return HostedAgentConnectionPool(
            identityStore: IdentityStore(),
            session: .shared,
            maximumSize: maximumSize,
            idleLifetime: idleLifetime,
            discovery: HostedAgentDiscovery(session: .shared, relayURL: "ws://unused.test", localEndpoints: []),
            connectionStateObserver: HostedAgentConnectionStateObserver(),
            socketFactory: factory.factory,
            endpointResolver: resolver ?? { _ in endpoint },
            connectTimeout: 1,
            livenessTimeout: 5,
            livenessCheckInterval: 0.1,
            resumeAttemptLimit: 0,
            resumeRetryDelay: 0,
            now: { clock.now() }
        )
    }

    private func connect(
        _ pool: HostedAgentConnectionPool,
        conversation: Conversation,
        factory: MockHostedAgentSocketFactory,
        socketIndex: Int
    ) async throws {
        let task = Task {
            try await pool.connect(agentAddress: agentAddress, conversation: conversation)
        }
        let socket = try await factory.socket(at: socketIndex)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("CONNECTED")])
        _ = try await task.value
    }
}

final class HostedAgentClientErrorMessageTests: XCTestCase {
    func testInvalidURLPointsAtTheAddressAndSuggestsAFix() {
        let message = HostedAgentClientError.invalidURL("0xabc").errorDescription ?? ""
        XCTAssertTrue(message.contains("0xabc"), message)
        XCTAssertTrue(message.contains("online"), message)
    }

    func testServerErrorIsAttributedToTheAgent() {
        let message = HostedAgentClientError.server("rate limit exceeded").errorDescription ?? ""
        XCTAssertEqual(message, "The agent reported a problem: rate limit exceeded")
    }

    func testBlankServerErrorFallsBackToAFullSentence() {
        let message = HostedAgentClientError.server("   ").errorDescription ?? ""
        XCTAssertEqual(
            message,
            "The agent reported a problem but didn't say what went wrong. Try again."
        )
    }

    func testBusyErrorTellsTheUserWhatToDoNext() {
        let message = HostedAgentClientError.busy.errorDescription ?? ""
        XCTAssertTrue(message.contains("Wait for it to finish"), message)
    }

    func testEveryOtherCaseProducesNonEmptyText() {
        let cases: [HostedAgentClientError] = [.invalidAddress, .badFrame, .closed, .timeout]
        for error in cases {
            XCTAssertFalse(
                (error.errorDescription ?? "").isEmpty,
                "Expected non-empty message for \(error)"
            )
        }
    }
}
