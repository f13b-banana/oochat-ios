import ConnectOnionKit
import CryptoKit
import Security
import XCTest
@testable import OOChatIOS

@MainActor
final class PreviousIdentityConversationTests: XCTestCase {
    private let service = "previous-identity-tests.\(UUID().uuidString)"
    private let bookmarks = HostedAgentBookmarkStore()

    override func tearDown() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        bookmarks.remove(conversationID: "con1")
        super.tearDown()
    }

    func testALinkStampsTheOpenChatWithTheReplacedAddressDropsItsBookmarkAndDoesNotReconnectIt() async throws {
        let store = IdentityStore(service: service)
        let transport = MockAgentTransport()
        let viewModel = ViewFixtures.chatViewModel(transport: transport, identityStore: store)
        let before = try XCTUnwrap(viewModel.identity?.address)
        bookmarks.save(SessionBookmark(sessionID: "con1", lastMessageID: "event-9"), conversationID: "con1")
        let incoming = Curve25519.Signing.PrivateKey()

        try store.replacePrivateKey(with: incoming.rawRepresentation)
        await viewModel.adoptReplacedIdentity(previousAddress: before)

        XCTAssertEqual(viewModel.identity?.address, "0x" + Hex.encode(incoming.publicKey.rawRepresentation))
        let chat = try XCTUnwrap(viewModel.activeConversation)
        XCTAssertEqual(chat.identityAddress, before)
        XCTAssertTrue(viewModel.isFromPreviousIdentity(chat))
        XCTAssertNil(bookmarks.load(conversationID: "con1"))
        // Every connection signed in as the old Address closes; the old chat is never resumed.
        XCTAssertEqual(transport.connectionCalls, ["disconnectAll"])
    }
}

@MainActor
final class PreviousIdentityLockTests: XCTestCase {
    private let agent = ViewFixtures.agent()

    private func lockedChatModel(
        transport: MockAgentTransport,
        monitor: MockNetworkMonitor = MockNetworkMonitor(),
        messages: [ChatMessage] = []
    ) -> ChatViewModel {
        var chat = ViewFixtures.conversation(agent: agent, messages: messages)
        chat.identityAddress = "0x" + String(repeating: "0", count: 64)
        let repo = InMemoryConversationRepository(snapshot: ChatSnapshot(
            agents: [agent], conversations: [chat], activeAgentID: agent.id, activeConversationID: chat.id
        ))
        return ChatViewModel(store: repo, client: transport, networkMonitor: monitor)
    }

    func testAChatFromAPreviousIdentityNeverConnectsOrSendsWhatItHadQueued() async {
        let transport = MockAgentTransport()
        let monitor = MockNetworkMonitor()
        let queued = ChatMessage(role: .user, content: "still waiting", deliveryState: .queued)
        let failed = ChatMessage(role: .user, content: "went wrong", deliveryState: .failed)
        let viewModel = lockedChatModel(transport: transport, monitor: monitor, messages: [queued, failed])
        XCTAssertTrue(viewModel.isFromPreviousIdentity(viewModel.activeConversation!))

        monitor.simulate(online: true)
        await viewModel.flushQueuedMessages()
        viewModel.retryMessage(failed)
        await viewModel.flushQueuedMessages()
        viewModel.connectActiveConversationOnOpen()
        await viewModel.reconnect()

        XCTAssertEqual(transport.sentPrompts, [])
        XCTAssertEqual(transport.connectedAddresses, [])
        XCTAssertEqual(viewModel.activeConversation?.messages.map(\.deliveryState), [.queued, .failed])
    }

    func testStartingANewChatFromAnOldOneOpensACurrentChatWithTheSameAgentThatConnects() async {
        let transport = MockAgentTransport()
        let viewModel = lockedChatModel(transport: transport)
        let old = viewModel.activeConversation!

        viewModel.startNewChat(withAgentOf: old)
        await viewModel.reconnect()

        let new = viewModel.activeConversation!
        XCTAssertNotEqual(new.id, old.id)
        XCTAssertEqual(new.agentID, agent.id)
        XCTAssertFalse(viewModel.isFromPreviousIdentity(new))
        XCTAssertTrue(viewModel.isFromPreviousIdentity(viewModel.conversation(withID: old.id)!))
        XCTAssertEqual(transport.connectedAddresses, [agent.address])
    }

    // Paths that don't go through the composer: a Control Center button, /exec and the mode picker.
    func testAChatFromAPreviousIdentityTakesNoSkillToolOrModeChange() async {
        let transport = MockAgentTransport()
        let viewModel = lockedChatModel(transport: transport)

        viewModel.runControlCenterSkill("/summarise")
        viewModel.prompt = "/exec read_file path=a.txt"
        viewModel.sendPrompt()
        viewModel.setMode(.plan)
        await Task.yield()

        XCTAssertEqual(viewModel.activeConversation?.messages, [])
        XCTAssertEqual(transport.requestedModes, [])
        XCTAssertNil(viewModel.activePendingMode)
    }
}

@MainActor
final class PreviousIdentityRestoreRaceTests: XCTestCase {
    private final class SlowFetcher: SessionsFetching {
        var duringFetch: () async -> Void = {}
        var sessions: [ConnectOnionHostedSession] = []
        func sessions(agentAddress: String) async throws -> [ConnectOnionHostedSession] {
            await duringFetch()
            return sessions
        }
    }

    // A restore that was fetched as the old Address and lands after a link must not add unstamped chats.
    func testARestoreThatFinishesAfterALinkAddsNothing() async throws {
        let fetcher = SlowFetcher()
        let viewModel = ChatViewModel(
            store: InMemoryConversationRepository(snapshot: .empty),
            client: MockAgentTransport(),
            networkMonitor: MockNetworkMonitor()
        )
        viewModel.historyFetcher = fetcher
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "A", address: "0x" + String(repeating: "cd", count: 32)))
        let object: [String: Any] = [
            "session_id": "old-session", "status": "done", "prompt": "hi", "created": 100.0,
            "session": ["messages": [["role": "user", "content": "hi"]]]
        ]
        fetcher.sessions = [try JSONDecoder().decode(
            ConnectOnionHostedSession.self, from: JSONSerialization.data(withJSONObject: object)
        )]
        fetcher.duringFetch = { @MainActor in
            viewModel.identity = StoredIdentity(address: "0xnew", publicKeyHex: "new", createdAt: Date())
        }

        await viewModel.restoreHistory(for: agent)

        XCTAssertNil(viewModel.conversation(withID: "old-session"))
    }

    // The link's own restore must run even while one fetched as the old Address is still in flight.
    func testALinkDuringARestoreStillRestoresAsTheNewAddress() async throws {
        let fetcher = SlowFetcher()
        let viewModel = ChatViewModel(
            store: InMemoryConversationRepository(snapshot: .empty),
            client: MockAgentTransport(),
            networkMonitor: MockNetworkMonitor()
        )
        viewModel.historyFetcher = fetcher
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "A", address: "0x" + String(repeating: "cd", count: 32)))
        let object: [String: Any] = [
            "session_id": "shared", "status": "done", "prompt": "hi", "created": 100.0,
            "session": ["messages": [["role": "user", "content": "hi"]]]
        ]
        fetcher.sessions = [try JSONDecoder().decode(
            ConnectOnionHostedSession.self, from: JSONSerialization.data(withJSONObject: object)
        )]
        fetcher.duringFetch = { @MainActor in
            fetcher.duringFetch = {}
            viewModel.identity = StoredIdentity(address: "0xnew", publicKeyHex: "new", createdAt: Date())
            await viewModel.restoreHistory(for: agent)
        }

        await viewModel.restoreHistory(for: agent)

        XCTAssertNotNil(viewModel.conversation(withID: "shared"))
    }
}
