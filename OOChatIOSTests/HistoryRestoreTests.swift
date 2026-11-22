import ConnectOnionKit
import XCTest
@testable import OOChatIOS

@MainActor
final class HistoryRestoreTests: XCTestCase {
    private let address = "0x" + String(repeating: "cd", count: 32)

    private final class FakeFetcher: SessionsFetching {
        var result: Result<[ConnectOnionHostedSession], Error> = .success([])
        func sessions(agentAddress: String) async throws -> [ConnectOnionHostedSession] { try result.get() }
    }

    private func session(
        _ id: String,
        _ pairs: [(String, String)] = [("user", "hi"), ("assistant", "yo")],
        updated: Double? = nil
    ) throws -> ConnectOnionHostedSession {
        let messages = pairs.map { ["role": $0.0, "content": $0.1] }
        var hosted: [String: Any] = ["messages": messages]
        hosted["updated"] = updated
        let object: [String: Any] = [
            "session_id": id, "status": "done", "prompt": "hi", "created": 100.0,
            "session": hosted
        ]
        return try JSONDecoder().decode(ConnectOnionHostedSession.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private let defaults = UserDefaults(suiteName: "HistoryRestoreTests.\(UUID())")!

    /// With a `storeURL`, a second call reopens the same on-disk store, as a relaunch does.
    private func makeViewModel(_ fetcher: FakeFetcher, storeURL: URL? = nil) throws -> (ChatViewModel, SavedAgent) {
        let store = try SwiftDataConversationRepository(inMemory: storeURL == nil, storeURL: storeURL, defaults: defaults)
        let viewModel = ChatViewModel(store: store, client: MockAgentTransport(), networkMonitor: MockNetworkMonitor())
        viewModel.historyFetcher = fetcher
        return (viewModel, viewModel.saveAgent(name: "A", address: address)!)
    }

    func testRestoredSessionBecomesConversationBySessionID() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = try .success([session("s1")])
        let (viewModel, agent) = try makeViewModel(fetcher)

        await viewModel.restoreHistory(for: agent)

        let restored = try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1"))
        XCTAssertEqual(restored.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(restored.agentAddress, address)
        XCTAssertEqual(viewModel.restoreStates[agent.id], .restored)
    }

    func testARestoredChatIsNamedLikeTheMacNamesIt() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = try .success([
            session("cmd", [("user", "/hello"), ("assistant", "hi"), ("user", "Plan my trip")]),
            session("untitled", [("user", "/hello"), ("assistant", "hi")])
        ])
        let (viewModel, agent) = try makeViewModel(fetcher)

        await viewModel.restoreHistory(for: agent)

        XCTAssertEqual(viewModel.conversationState.conversation(withID: "cmd")?.title, "Plan my trip")
        XCTAssertEqual(viewModel.conversationState.conversation(withID: "untitled")?.title, Conversation.defaultTitle)
    }

    func testAChatFromAPreviousIdentityIsNeverMergedIntoHostedHistory() async throws {
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try makeViewModel(fetcher)
        let old = viewModel.createConversation(for: agent)
        _ = viewModel.conversationState.stampForReplace(previousAddress: "0x" + String(repeating: "0", count: 64))
        fetcher.result = try .success([session(old.id)])

        await viewModel.restoreHistory(for: agent)

        XCTAssertEqual(viewModel.conversationState.conversation(withID: old.id)?.messages, [])
    }

    func testRepeatRefreshCreatesNoDuplicates() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = try .success([session("s1"), session("s2")])
        let (viewModel, agent) = try makeViewModel(fetcher)

        await viewModel.restoreHistory(for: agent)
        let before = viewModel.conversations.count
        await viewModel.restoreHistory(for: agent)

        XCTAssertEqual(viewModel.conversations.count, before)
        XCTAssertEqual(viewModel.conversations.filter { $0.id == "s1" }.count, 1)
    }

    func testExistingLocalConversationIsNotOverwritten() async throws {
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try makeViewModel(fetcher)
        var local = Conversation(agentID: agent.id, agentAddress: address)
        local.messages = [ChatMessage(role: .user, content: "local only")]
        viewModel.conversationState.upsert(local)
        fetcher.result = try .success([session(local.id)])

        await viewModel.restoreHistory(for: agent)

        XCTAssertEqual(viewModel.conversationState.conversation(withID: local.id)?.messages.first?.content, "local only")
    }

    func testAuthRejectionIsFailedNotEmpty() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = .failure(SessionsClientError.authRejected(status: 401))
        let (viewModel, agent) = try makeViewModel(fetcher)

        await viewModel.restoreHistory(for: agent)

        XCTAssertEqual(viewModel.restoreStates[agent.id], .failed)
    }

    func testUnreachableIsPendingThenRetriesOnConnect() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = .failure(HistoryRestoreError.unreachable)
        let (viewModel, agent) = try makeViewModel(fetcher)
        let chat = viewModel.conversationState.createConversation(for: agent, currentDraft: "")
        await viewModel.restoreHistory(for: agent)
        XCTAssertEqual(viewModel.restoreStates[agent.id], .pending)

        fetcher.result = try .success([session("s9")])
        viewModel.recoveryCoordinator.setConnectionState(.connected, forConversationID: chat.id)
        for _ in 0..<200 where viewModel.restoreStates[agent.id] != .restored {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(viewModel.restoreStates[agent.id], .restored)
        XCTAssertNotNil(viewModel.conversationState.conversation(withID: "s9"))
    }

    // MARK: Tombstones

    private func scratchStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tombstone-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("store.sqlite")
    }

    /// What the conversation store holds, read the way a relaunch reads it.
    private func storedRows(at storeURL: URL) throws -> [Conversation] {
        try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults).load().conversations
    }

    /// Restores `s1` (host `updated` 500) and deletes it.
    private func restoreAndDelete(_ fetcher: FakeFetcher, storeURL: URL) async throws -> (ChatViewModel, SavedAgent) {
        fetcher.result = try .success([session("s1", updated: 500)])
        let (viewModel, agent) = try makeViewModel(fetcher, storeURL: storeURL)
        await viewModel.restoreHistory(for: agent)
        viewModel.deleteConversation(try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1")))
        return (viewModel, agent)
    }

    func testADeletedChatIsNotRecreatedByALaterRefreshAndItsTombstoneHoldsNoContent() async throws {
        let storeURL = try scratchStoreURL()
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try await restoreAndDelete(fetcher, storeURL: storeURL)

        await viewModel.restoreHistory(for: agent)

        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"))
        XCTAssertFalse(viewModel.conversations.contains { $0.id == "s1" })
        XCTAssertEqual(viewModel.conversationState.searchConversations("hi").map(\.id), [])
        let tombstone = try XCTUnwrap(try storedRows(at: storeURL).first { $0.id == "s1" })
        XCTAssertEqual(tombstone.messages, [])
        XCTAssertEqual(tombstone.title, Conversation.defaultTitle)
        XCTAssertNil(tombstone.serverSession)
        XCTAssertEqual(tombstone.tombstoneUpdated, Date(timeIntervalSince1970: 500))
    }

    func testATombstoneRecordsTheLaterOfTheHostUpdatedAndTheLastMessage() async throws {
        let storeURL = try scratchStoreURL()
        let fetcher = FakeFetcher()
        fetcher.result = try .success([session("s1", updated: 500)])
        let (viewModel, agent) = try makeViewModel(fetcher, storeURL: storeURL)
        await viewModel.restoreHistory(for: agent)
        // A reply arrives after the host stamps its turn; opening the chat (its updatedAt) is not recorded.
        var chat = try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1"))
        chat.messages.append(ChatMessage(role: .agent, content: "later", createdAt: Date(timeIntervalSince1970: 900)))
        viewModel.conversationState.upsert(chat)

        let (relaunched, _) = try makeViewModel(fetcher, storeURL: storeURL)
        relaunched.deleteConversation(try XCTUnwrap(relaunched.conversationState.conversation(withID: "s1")))
        fetcher.result = try .success([session("s1", updated: 899)])
        await relaunched.restoreHistory(for: agent)

        let tombstone = try XCTUnwrap(try storedRows(at: storeURL).first { $0.id == "s1" })
        XCTAssertEqual(tombstone.tombstoneUpdated, Date(timeIntervalSince1970: 900))
        XCTAssertNil(relaunched.conversationState.conversation(withID: "s1"))
    }

    func testARefreshRecordsTheLatestHostUpdatedWithoutTouchingMessages() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = try .success([session("s1", updated: 500)])
        let (viewModel, agent) = try makeViewModel(fetcher)
        await viewModel.restoreHistory(for: agent)
        var chat = try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1"))
        chat.messages.append(ChatMessage(role: .user, content: "sent during the fetch", createdAt: Date(timeIntervalSince1970: 600)))
        viewModel.conversationState.upsert(chat)
        // The host has moved on; its snapshot predates the message above.
        fetcher.result = try .success([session("s1", updated: 900)])

        await viewModel.restoreHistory(for: agent)

        let refreshed = try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1"))
        XCTAssertEqual(refreshed.messages.last?.content, "sent during the fetch")
        viewModel.deleteConversation(refreshed)
        await viewModel.restoreHistory(for: agent)
        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"))
    }

    func testATombstoneIsRestoredInFullWhenTheHostReportsANewerUpdated() async throws {
        let storeURL = try scratchStoreURL()
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try await restoreAndDelete(fetcher, storeURL: storeURL)
        fetcher.result = try .success([session("s1", [("user", "hi"), ("assistant", "yo"), ("user", "again")], updated: 501)])

        await viewModel.restoreHistory(for: agent)

        let restored = try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1"))
        XCTAssertEqual(restored.messages.map(\.content), ["hi", "yo", "again"])
        XCTAssertEqual(restored.updatedAt, Date(timeIntervalSince1970: 501))
        let row = try XCTUnwrap(try storedRows(at: storeURL).first { $0.id == "s1" })
        XCTAssertNil(row.tombstoneUpdated)
        XCTAssertEqual(row.messages.count, 3)
    }

    func testAMillisecondUpdatedIsComparedWithTheTombstoneInSeconds() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = try .success([session("s1", updated: 1_700_000_010)])
        let (viewModel, agent) = try makeViewModel(fetcher)
        await viewModel.restoreHistory(for: agent)
        viewModel.deleteConversation(try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1")))

        fetcher.result = try .success([session("s1", updated: 1_700_000_005_000)])
        await viewModel.restoreHistory(for: agent)
        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"), "an older host time stays deleted")

        fetcher.result = try .success([session("s1", updated: 1_700_000_020_000)])
        await viewModel.restoreHistory(for: agent)
        let restored = try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1"))
        XCTAssertEqual(restored.updatedAt, Date(timeIntervalSince1970: 1_700_000_020))
    }

    func testAHostSessionWithoutUpdatedNeverRevivesATombstone() async throws {
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try await restoreAndDelete(fetcher, storeURL: try scratchStoreURL())
        fetcher.result = try .success([session("s1")])

        await viewModel.restoreHistory(for: agent)

        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"))
    }

    // MARK: Sessions with no visible messages

    /// The host's system prompt is not chat, so this session has nothing to show.
    private func emptySession(_ id: String, updated: Double) throws -> ConnectOnionHostedSession {
        try session(id, [("system", "You are helpful.")], updated: updated)
    }

    func testAHostSessionWithNoVisibleMessagesCreatesNoChat() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = try .success([emptySession("s1", updated: 500)])
        let (viewModel, agent) = try makeViewModel(fetcher)

        await viewModel.restoreHistory(for: agent)

        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"))
        XCTAssertEqual(viewModel.restoreStates[agent.id], .restored)
    }

    func testAnEmptyHostSessionKeepsATombstoneDeletedButRaisesWhatItRecorded() async throws {
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try await restoreAndDelete(fetcher, storeURL: try scratchStoreURL())
        fetcher.result = try .success([emptySession("s1", updated: 900)])

        await viewModel.restoreHistory(for: agent)
        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"), "nothing to show, so nothing revives")

        // Newer than the deletion (500) but older than the empty session (900).
        fetcher.result = try .success([session("s1", updated: 700)])
        await viewModel.restoreHistory(for: agent)
        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"))
    }

    func testAnEmptyHostSessionLeavesALiveChatsMessagesAndRecordsItsUpdated() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = try .success([session("s1", updated: 500)])
        let (viewModel, agent) = try makeViewModel(fetcher)
        await viewModel.restoreHistory(for: agent)
        fetcher.result = try .success([emptySession("s1", updated: 900)])

        await viewModel.restoreHistory(for: agent)

        let chat = try XCTUnwrap(viewModel.conversationState.conversation(withID: "s1"))
        XCTAssertEqual(chat.messages.map(\.content), ["hi", "yo"])
        viewModel.deleteConversation(chat)
        fetcher.result = try .success([session("s1", updated: 700)])
        await viewModel.restoreHistory(for: agent)
        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"), "the Tombstone recorded 900")
    }

    func testADeletedChatStaysDeletedAfterTheStoreIsReloaded() async throws {
        let storeURL = try scratchStoreURL()
        let fetcher = FakeFetcher()
        _ = try await restoreAndDelete(fetcher, storeURL: storeURL)

        let (relaunched, agent) = try makeViewModel(fetcher, storeURL: storeURL)
        XCTAssertFalse(relaunched.conversations.contains { $0.id == "s1" })
        await relaunched.restoreHistory(for: agent)

        XCTAssertNil(relaunched.conversationState.conversation(withID: "s1"))
    }

    func testADeletedChatStaysDeletedAfterAnIdentityReplace() async throws {
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try await restoreAndDelete(fetcher, storeURL: try scratchStoreURL())
        _ = viewModel.conversationState.stampForReplace(previousAddress: "0x" + String(repeating: "0", count: 64))
        fetcher.result = try .success([session("s1", updated: 900)])

        await viewModel.restoreHistory(for: agent)

        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"))
    }

    func testRemovingAnAgentRemovesItsTombstones() async throws {
        let storeURL = try scratchStoreURL()
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try await restoreAndDelete(fetcher, storeURL: storeURL)

        viewModel.deleteAgent(agent)

        XCTAssertFalse(try storedRows(at: storeURL).contains { $0.id == "s1" })
    }

    func testARestoreForAnAgentRemovedDuringTheFetchSavesNothing() async throws {
        let storeURL = try scratchStoreURL()
        let (viewModel, agent) = try makeViewModel(FakeFetcher(), storeURL: storeURL)
        let fetched = HistoryRestore.merge([try session("s1")], agent: agent, into: [])

        viewModel.deleteAgent(agent)
        viewModel.conversationState.restore(fetched)

        XCTAssertNil(viewModel.conversationState.conversation(withID: "s1"))
        XCTAssertFalse(try storedRows(at: storeURL).contains { $0.id == "s1" })
    }

    func testAStaleHostUpdatedNeverLowersTheRecordedOne() async throws {
        let fetcher = FakeFetcher()
        fetcher.result = try .success([session("s1", updated: 900)])
        let (viewModel, agent) = try makeViewModel(fetcher)
        await viewModel.restoreHistory(for: agent)

        fetcher.result = try .success([session("s1", updated: 500)])
        await viewModel.restoreHistory(for: agent)

        XCTAssertEqual(viewModel.conversationState.conversation(withID: "s1")?.hostUpdated, Date(timeIntervalSince1970: 900))
    }

    func testDeletingAChatFromAPreviousIdentityLeavesNoTombstone() async throws {
        let storeURL = try scratchStoreURL()
        let (viewModel, agent) = try makeViewModel(FakeFetcher(), storeURL: storeURL)
        let old = viewModel.createConversation(for: agent)
        _ = viewModel.conversationState.stampForReplace(previousAddress: "0x" + String(repeating: "0", count: 64))

        viewModel.deleteConversation(try XCTUnwrap(viewModel.conversationState.conversation(withID: old.id)))

        XCTAssertFalse(try storedRows(at: storeURL).contains { $0.id == old.id })
    }

    func testALocalChatRecordsItsLastMessageTime() async throws {
        let storeURL = try scratchStoreURL()
        let (viewModel, agent) = try makeViewModel(FakeFetcher(), storeURL: storeURL)
        var local = viewModel.createConversation(for: agent)
        local.messages = [ChatMessage(role: .user, content: "only here", createdAt: Date(timeIntervalSince1970: 4_000_000_000))]
        viewModel.conversationState.upsert(local)

        viewModel.deleteConversation(try XCTUnwrap(viewModel.conversationState.conversation(withID: local.id)))

        let tombstone = try XCTUnwrap(try storedRows(at: storeURL).first { $0.id == local.id })
        XCTAssertEqual(tombstone.tombstoneUpdated, Date(timeIntervalSince1970: 4_000_000_000))
    }

    // With no messages and no host time, the chat's creation time is what it records.
    func testAnEmptyChatRecordsItsCreationTime() async throws {
        let fetcher = FakeFetcher()
        let (viewModel, agent) = try makeViewModel(fetcher)
        let empty = viewModel.createConversation(for: agent)
        let created = empty.createdAt.timeIntervalSince1970
        viewModel.deleteConversation(try XCTUnwrap(viewModel.conversationState.conversation(withID: empty.id)))

        fetcher.result = try .success([session(empty.id, updated: created - 10)])
        await viewModel.restoreHistory(for: agent)
        XCTAssertNil(viewModel.conversationState.conversation(withID: empty.id), "an older host time stays deleted")

        fetcher.result = try .success([session(empty.id, updated: created + 10)])
        await viewModel.restoreHistory(for: agent)
        XCTAssertEqual(viewModel.conversationState.conversation(withID: empty.id)?.messages.map(\.content), ["hi", "yo"])
    }

    func testATombstoneFollowsItsAgentThroughAnAddressEditAndGoesWhenTheAgentIsRemoved() throws {
        let storeURL = try scratchStoreURL()
        let (_, agent) = try makeViewModel(FakeFetcher(), storeURL: storeURL)
        // An old row owned by Address alone, as stores from before agent ids hold.
        let legacy = Conversation(
            id: "legacy", title: Conversation.defaultTitle, agentID: nil, agentAddress: agent.address, mode: .safe,
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100), messages: [],
            serverSession: nil, tombstoneUpdated: Date(timeIntervalSince1970: 100)
        )
        try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults).upsertConversation(legacy)
        let (relaunched, _) = try makeViewModel(FakeFetcher(), storeURL: storeURL)

        let edited = relaunched.conversationState.saveAgent(id: agent.id, name: "A", address: "0x" + String(repeating: "ef", count: 32))
        relaunched.deleteAgent(edited)

        XCTAssertFalse(try storedRows(at: storeURL).contains { $0.id == "legacy" })
    }
}
