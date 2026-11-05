import ConnectOnionKit
import Foundation
import XCTest
@testable import OOChatIOS

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
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("new")])
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
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("new")])
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
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("new")])
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

    func testIncompatibleProtocolNamesTheVersionAndWhoShouldUpdate() {
        let error = HostedAgentClientError.incompatibleProtocol(
            OIPHandshake.Incompatibility(neededVersion: "0.2", appVersion: "0.1")
        )
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("0.2"), message)
        XCTAssertTrue(message.contains("Update the app"), message)
        XCTAssertFalse(HostedAgentClientError.isConnectivityFailure(error))
        XCTAssertNotNil(error.incompatibility)
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
