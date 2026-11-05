import SwiftData
import ConnectOnionKit
import XCTest
@testable import OOChatIOS

// The stored-message schema as shipped before `messageID` existed (commit 5bdf20b^), used
// to seed an on-disk store so tests exercise the real upgrade path. Entity names match the
// production models, so the production schema opens these stores via lightweight migration.
// `StoredAgent.token` is kept here on purpose: it is what old stores actually contain, and
// opening them proves the V4 column drop migrates cleanly.
private enum LegacyStoredModels {
    @Model
    final class StoredAgent {
        @Attribute(.unique) var id: String
        var name: String
        var address: String
        var token: String = ""
        var createdAt: Date
        var updatedAt: Date

        init(id: String, name: String, address: String, token: String, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.name = name
            self.address = address
            self.token = token
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class StoredConversation {
        @Attribute(.unique) var id: String
        var title: String
        var agentID: String?
        var agentAddress: String
        var modeRaw: String
        var createdAt: Date
        var updatedAt: Date
        var serverSessionData: Data?
        @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
        var messages: [StoredMessage]

        init(
            id: String,
            title: String,
            agentID: String?,
            agentAddress: String,
            modeRaw: String,
            createdAt: Date,
            updatedAt: Date,
            serverSessionData: Data?,
            messages: [StoredMessage]
        ) {
            self.id = id
            self.title = title
            self.agentID = agentID
            self.agentAddress = agentAddress
            self.modeRaw = modeRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.serverSessionData = serverSessionData
            self.messages = messages
        }
    }

    @Model
    final class StoredMessage {
        @Attribute(.unique) var id: String
        var roleRaw: String
        var content: String
        var createdAt: Date
        var deliveryStateRaw: String = "sent"
        var toolName: String?
        var toolArgumentsData: Data?
        var toolStateRaw: String?
        var conversation: StoredConversation?

        init(id: String, roleRaw: String, content: String, createdAt: Date) {
            self.id = id
            self.roleRaw = roleRaw
            self.content = content
            self.createdAt = createdAt
        }
    }
}

@MainActor
final class SwiftDataConversationRepositoryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeRepository() throws -> SwiftDataConversationRepository {
        try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
    }

    func testLoadReturnsEmptyWhenNothingStored() throws {
        let repository = try makeRepository()

        XCTAssertEqual(repository.load(), .empty)
    }

    func testReopeningStoreRemovesLegacyInitialAssistantMessage() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        var conversation = makeConversation(
            agentID: "a1",
            address: "0xabc",
            title: "Existing chat",
            updatedAt: seconds(1000)
        )
        conversation.messages = [
            ChatMessage(
                id: "legacy-ready",
                role: .agent,
                content: "ConnectOnion native iOS session is ready.",
                createdAt: seconds(1001)
            ),
            ChatMessage(
                id: "real-reply",
                role: .agent,
                content: "How can I help?",
                createdAt: seconds(1002)
            ),
            ChatMessage(
                id: "quoted-by-user",
                role: .user,
                content: "ConnectOnion native iOS session is ready.",
                createdAt: seconds(1003)
            )
        ]
        repository.upsertConversation(conversation)

        let reopened = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let messages = try XCTUnwrap(reopened.load().conversations.first).messages

        XCTAssertEqual(messages.map(\.id), ["real-reply", "quoted-by-user"])
    }

    /// `.thinking` bubbles only get removed when a round-trip ends, which never happens if the
    /// process dies mid-send. Reopening must drop them without touching anything else.
    func testReopeningStoreRemovesStaleThinkingMessages() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        var conversation = makeConversation(
            agentID: "a1",
            address: "0xabc",
            title: "Interrupted chat",
            updatedAt: seconds(1000)
        )
        conversation.messages = [
            ChatMessage(id: "asked", role: .user, content: "hi", createdAt: seconds(1001)),
            ChatMessage(id: "stale", role: .thinking, content: "Waiting…", createdAt: seconds(1002)),
            ChatMessage(id: "tool-run", role: .tool, content: "", createdAt: seconds(1003)),
            ChatMessage(id: "replied", role: .agent, content: "hello", createdAt: seconds(1004))
        ]
        repository.upsertConversation(conversation)

        let reopened = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let messages = try XCTUnwrap(reopened.load().conversations.first).messages

        XCTAssertEqual(messages.map(\.id), ["asked", "tool-run", "replied"])
    }

    /// A legacy message with no conversation is already unreachable; keeping it would mint an
    /// empty-scope composite key that can collide with another orphan.
    func testReopeningStoreDropsOrphanedLegacyMessages() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        try withLegacyContext(at: storeURL) { context in
            context.insert(LegacyStoredModels.StoredConversation(
                id: "c1", title: "kept", agentID: "a1", agentAddress: "0xaaa", modeRaw: "safe",
                createdAt: seconds(1000), updatedAt: seconds(2000), serverSessionData: nil,
                messages: [
                    LegacyStoredModels.StoredMessage(
                        id: "m1", roleRaw: "user", content: "attached", createdAt: seconds(1001)
                    )
                ]
            ))
            // No conversation assigned: an orphan left behind by an older delete path.
            context.insert(LegacyStoredModels.StoredMessage(
                id: "orphan", roleRaw: "user", content: "unreachable", createdAt: seconds(1002)
            ))
        }

        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let conversations = repository.load().conversations

        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations.first?.messages.map(\.id), ["m1"])
    }

    /// After a force quit, everything comes back unchanged
    func testRelaunchRestoresTranscriptAndServerSessionFromDisk() throws {
        let storeURL = try makeScratchStoreURL()

        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        var conversation = makeConversation(
            agentID: "a1",
            address: "0xabc",
            title: "Relaunch",
            updatedAt: seconds(1000)
        )

        conversation.serverSession = ["session_id": .string(conversation.id)]
        conversation.messages = [
            ChatMessage(id: "u1", role: .user, content: "run the build", createdAt: seconds(1001)),
            ChatMessage(id: "r1", role: .agent, content: "Build passed.", createdAt: seconds(1002))
        ]
        repository.upsertConversation(conversation)

        let relaunched = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let restored = try XCTUnwrap(
            relaunched.load().conversations.first { $0.id == conversation.id }
        )

        XCTAssertEqual(restored.messages.map(\.id), ["u1", "r1"])
        XCTAssertEqual(restored.messages.map(\.content), ["run the build", "Build passed."])
        XCTAssertEqual(restored.serverSession?["session_id"], .string(conversation.id))
    }

    func testUpsertsThenLoadRestoresAgentsConversationsAndActiveIDs() throws {
        let repository = try makeRepository()
        let agent = SavedAgent(address: "0xabc", createdAt: seconds(1000), updatedAt: seconds(1000))
        let conversation = makeConversation(agentID: agent.id, address: agent.address, title: "Hello", updatedAt: seconds(1000))

        repository.upsertAgent(agent)
        repository.upsertConversation(conversation)
        repository.saveActive(agentID: agent.id, conversationID: conversation.id)
        let loaded = repository.load()

        XCTAssertEqual(loaded.agents.map(\.id), [agent.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(loaded.conversations.first?.title, "Hello")
        XCTAssertEqual(loaded.conversations.first?.messages.map(\.content), conversation.messages.map(\.content))
        XCTAssertEqual(loaded.activeAgentID, agent.id)
        XCTAssertEqual(loaded.activeConversationID, conversation.id)
    }

    func testUpsertPreservesConversationModeAndServerSession() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xabc", title: "t", updatedAt: seconds(1000))
        conversation.mode = .ulw
        conversation.serverSession = [
            "session_id": .string("s1"),
            "plugin_state": .object([
                "ulw": .object([
                    "turns": .number(100),
                    "turns_used": .number(7)
                ])
            ])
        ]
        repository.upsertConversation(conversation)

        let loaded = repository.load().conversations.first

        XCTAssertEqual(loaded?.mode, .ulw)
        XCTAssertEqual(loaded?.serverSession?["session_id"]?.stringValue, "s1")
        XCTAssertEqual(
            loaded?.serverSession?["plugin_state"],
            conversation.serverSession?["plugin_state"]
        )
    }

    func testUpsertConversationInsertsThenUpdatesOneRow() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "before", updatedAt: seconds(1000))
        repository.upsertConversation(conversation)

        conversation.title = "after"
        repository.upsertConversation(conversation)
        let loaded = repository.load()

        XCTAssertEqual(loaded.conversations.count, 1)
        XCTAssertEqual(loaded.conversations.first?.title, "after")
    }

    func testDeleteConversationRemovesOnlyThatConversation() throws {
        let repository = try makeRepository()
        let keep = makeConversation(agentID: "a1", address: "0xaaa", title: "keep", updatedAt: seconds(2000))
        let drop = makeConversation(agentID: "a1", address: "0xaaa", title: "drop", updatedAt: seconds(1000))
        repository.upsertConversation(keep)
        repository.upsertConversation(drop)

        repository.deleteConversation(id: drop.id)
        let loaded = repository.load()

        XCTAssertEqual(loaded.conversations.map(\.id), [keep.id])
    }

    func testDeleteAgentAlsoRemovesItsConversations() throws {
        let repository = try makeRepository()
        let agent = SavedAgent(address: "0xaaa")
        repository.upsertAgent(agent)
        let conversation = makeConversation(agentID: agent.id, address: agent.address, title: "c", updatedAt: seconds(1000))
        repository.upsertConversation(conversation)

        repository.deleteAgent(id: agent.id)
        let loaded = repository.load()

        XCTAssertTrue(loaded.agents.isEmpty)
        XCTAssertTrue(loaded.conversations.isEmpty)
    }

    func testDeleteAgentKeepsSiblingAgentSharingSameAddress() throws {
        let repository = try makeRepository()
        // Two saved agents can share the same remote address.
        let firstAgent = SavedAgent(id: "a1", address: "0xaaa")
        let secondAgent = SavedAgent(id: "a2", address: "0xaaa")
        repository.upsertAgent(firstAgent)
        repository.upsertAgent(secondAgent)
        let convA = makeConversation(
            agentID: firstAgent.id,
            address: "0xaaa",
            title: "belongs to a",
            updatedAt: seconds(1000)
        )
        let convB = makeConversation(
            agentID: secondAgent.id,
            address: "0xaaa",
            title: "belongs to b",
            updatedAt: seconds(2000)
        )
        repository.upsertConversation(convA)
        repository.upsertConversation(convB)

        repository.deleteAgent(id: firstAgent.id)
        let loaded = repository.load()

        XCTAssertEqual(loaded.agents.map(\.id), [secondAgent.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [convB.id])
    }

    func testAgentRoundTrips() throws {
        let repository = try makeRepository()
        let agent = SavedAgent(id: "a1", address: "0xaaa", name: "Primary")
        repository.upsertAgent(agent)

        let loaded = repository.load().agents.first
        XCTAssertEqual(loaded?.id, "a1")
        XCTAssertEqual(loaded?.address, "0xaaa")
        XCTAssertEqual(loaded?.name, "Primary")
    }

    func testAppendingMessageKeepsExistingMessagesAndAddsOne() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        let first = ChatMessage(role: .user, content: "one")
        conversation.messages = [first]
        repository.upsertConversation(conversation)

        let second = ChatMessage(role: .agent, content: "two")
        conversation.messages = [first, second]
        repository.upsertConversation(conversation)
        let loaded = repository.load().conversations.first

        XCTAssertEqual(loaded?.messages.map(\.id), [first.id, second.id])
        XCTAssertEqual(loaded?.messages.map(\.content), ["one", "two"])
    }

    func testRemovingMessageDeletesOnlyThatMessage() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        let keep = ChatMessage(role: .user, content: "keep")
        let thinking = ChatMessage(role: .thinking, content: "...")
        conversation.messages = [keep, thinking]
        repository.upsertConversation(conversation)

        conversation.messages = [keep]
        repository.upsertConversation(conversation)
        let loaded = repository.load().conversations.first

        XCTAssertEqual(loaded?.messages.map(\.id), [keep.id])
    }

    func testGranularMessageUpsertPreservesSiblingMessages() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(
            agentID: "a1",
            address: "0xabc",
            title: "Streaming",
            updatedAt: seconds(1000)
        )
        conversation.messages = [
            ChatMessage(id: "tool-1", role: .tool, content: "", toolName: "read", toolState: .running),
            ChatMessage(id: "user-1", role: .user, content: "Keep me")
        ]
        repository.upsertConversation(conversation)

        var completedTool = conversation.messages[0]
        completedTool.content = "Done"
        completedTool.toolState = .completed
        conversation.messages = [completedTool]
        try repository.upsertMessageResult(completedTool, in: conversation).get()

        let loaded = try XCTUnwrap(repository.load().conversations.first)
        XCTAssertEqual(Set(loaded.messages.map(\.id)), ["tool-1", "user-1"])
        XCTAssertEqual(loaded.messages.first { $0.id == "tool-1" }?.content, "Done")
        XCTAssertEqual(loaded.messages.first { $0.id == "tool-1" }?.toolState, .completed)
    }

    func testMetadataUpdatePreservesStoredMessages() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(
            agentID: "a1",
            address: "0xabc",
            title: "Before",
            updatedAt: seconds(1000)
        )
        conversation.messages = [ChatMessage(id: "m1", role: .user, content: "Keep me")]
        repository.upsertConversation(conversation)

        conversation.title = "After"
        conversation.mode = .ulw
        conversation.messages = []
        try repository.updateConversationMetadataResult(conversation).get()

        let loaded = try XCTUnwrap(repository.load().conversations.first)
        XCTAssertEqual(loaded.title, "After")
        XCTAssertEqual(loaded.mode, .ulw)
        XCTAssertEqual(loaded.messages.map(\.id), ["m1"])
    }

    func testSaveActivePersistsPointers() throws {
        let repository = try makeRepository()

        repository.saveActive(agentID: "a1", conversationID: "c1")

        let loaded = repository.load()
        XCTAssertEqual(loaded.activeAgentID, "a1")
        XCTAssertEqual(loaded.activeConversationID, "c1")
    }

    func testSearchMatchesTitleAndMessageContent() throws {
        let repository = try makeRepository()
        var byTitle = makeConversation(agentID: "a1", address: "0xaaa", title: "Groceries", updatedAt: seconds(3000))
        byTitle.messages = [ChatMessage(role: .user, content: "unrelated")]
        var byContent = makeConversation(agentID: "a1", address: "0xaaa", title: "Random", updatedAt: seconds(2000))
        byContent.messages = [ChatMessage(role: .user, content: "buy milk and eggs")]
        let noMatch = makeConversation(agentID: "a1", address: "0xaaa", title: "Nope", updatedAt: seconds(1000))
        [byTitle, byContent, noMatch].forEach(repository.upsertConversation)

        let titleHits = Set(repository.search("grocer").map(\.id))
        let contentHits = Set(repository.search("milk").map(\.id))

        XCTAssertEqual(titleHits, [byTitle.id])
        XCTAssertEqual(contentHits, [byContent.id])
    }

    func testSearchWithEmptyOrWhitespaceQueryReturnsAllConversations() throws {
        let repository = try makeRepository()
        let first = makeConversation(agentID: "a1", address: "0xaaa", title: "one", updatedAt: seconds(2000))
        let second = makeConversation(agentID: "a1", address: "0xaaa", title: "two", updatedAt: seconds(1000))
        [first, second].forEach(repository.upsertConversation)

        XCTAssertEqual(Set(repository.search("").map(\.id)), [first.id, second.id])
        XCTAssertEqual(Set(repository.search("   \n").map(\.id)), [first.id, second.id])
    }

    func testSearchResultsAreSortedByUpdatedAtDescendingAndDeduplicated() throws {
        let repository = try makeRepository()
        // Matches by BOTH title and message content — must appear exactly once.
        var both = makeConversation(agentID: "a1", address: "0xaaa", title: "apple pie", updatedAt: seconds(1000))
        both.messages = [ChatMessage(role: .user, content: "apple crumble recipe")]
        var newer = makeConversation(agentID: "a1", address: "0xaaa", title: "shopping", updatedAt: seconds(3000))
        newer.messages = [ChatMessage(role: .user, content: "buy apples")]
        let middle = makeConversation(agentID: "a1", address: "0xaaa", title: "apple support call", updatedAt: seconds(2000))
        [both, newer, middle].forEach(repository.upsertConversation)

        let hits = repository.search("apple")

        XCTAssertEqual(hits.map(\.id), [newer.id, middle.id, both.id])
    }

    func testSearchIsCaseAndDiacriticInsensitive() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "Café notes", updatedAt: seconds(1000))
        conversation.messages = [ChatMessage(role: .user, content: "agenda for the storage design review")]
        repository.upsertConversation(conversation)

        XCTAssertEqual(repository.search("cafe").map(\.id), [conversation.id])
        XCTAssertEqual(repository.search("CAFÉ").map(\.id), [conversation.id])
        XCTAssertEqual(repository.search("Storage Design").map(\.id), [conversation.id])
    }

    func testSaveActiveNilClearsStoredPointers() throws {
        let repository = try makeRepository()
        repository.saveActive(agentID: "a1", conversationID: "c1")

        repository.saveActive(agentID: nil, conversationID: nil)
        let loaded = repository.load()

        XCTAssertNil(loaded.activeAgentID)
        XCTAssertNil(loaded.activeConversationID)
    }

    func testDiskStoreSurvivesRepositoryRelaunch() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let agent = SavedAgent(address: "0xabc")
        var conversation = makeConversation(agentID: agent.id, address: agent.address, title: "persisted", updatedAt: seconds(1000))
        conversation.messages = [ChatMessage(role: .user, content: "survives relaunch")]

        // First "launch": write, then release the repository (and its container).
        do {
            let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
            repository.upsertAgent(agent)
            repository.upsertConversation(conversation)
            repository.saveActive(agentID: agent.id, conversationID: conversation.id)
        }

        // Second "launch": a fresh repository on the same file must read everything back.
        let relaunched = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let loaded = relaunched.load()

        XCTAssertEqual(loaded.agents.map(\.id), [agent.id])
        XCTAssertEqual(loaded.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(loaded.conversations.first?.messages.map(\.content), conversation.messages.map(\.content))
        XCTAssertEqual(loaded.activeAgentID, agent.id)
        XCTAssertEqual(loaded.activeConversationID, conversation.id)
        XCTAssertEqual(relaunched.search("relaunch").map(\.id), [conversation.id])
    }

    func testMultipleAgentsRoundTrip() throws {
        let repository = try makeRepository()
        let firstAgent = SavedAgent(
            id: "a1",
            address: "0xaaa",
            createdAt: seconds(1000),
            updatedAt: seconds(1000)
        )
        let secondAgent = SavedAgent(
            id: "a2",
            address: "0xbbb",
            createdAt: seconds(2000),
            updatedAt: seconds(2000)
        )
        repository.upsertAgent(firstAgent)
        repository.upsertAgent(secondAgent)

        XCTAssertEqual(Set(repository.load().agents.map(\.id)), ["a1", "a2"])
    }

    func testUpsertAgentUpdatesExistingInPlace() throws {
        let repository = try makeRepository()
        var agent = SavedAgent(id: "a1", address: "0xaaa", name: "First", createdAt: seconds(1000), updatedAt: seconds(1000))
        repository.upsertAgent(agent)
        agent.name = "Renamed"
        repository.upsertAgent(agent)

        let loaded = repository.load().agents
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Renamed")
    }

    func testDeletingNonexistentIDsIsANoOp() throws {
        let repository = try makeRepository()
        repository.deleteConversation(id: "missing")
        repository.deleteAgent(id: "missing")

        XCTAssertEqual(repository.load(), .empty)
    }

    func testMessagesAreReturnedInCreatedAtOrder() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        let later = ChatMessage(role: .user, content: "later", createdAt: seconds(2000))
        let earlier = ChatMessage(role: .agent, content: "earlier", createdAt: seconds(1000))
        conversation.messages = [later, earlier]
        repository.upsertConversation(conversation)

        let loaded = repository.load().conversations.first
        XCTAssertEqual(loaded?.messages.map(\.content), ["earlier", "later"])
    }

    func testNilServerSessionRoundTripsAsNil() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        conversation.serverSession = nil
        repository.upsertConversation(conversation)

        XCTAssertNil(repository.load().conversations.first?.serverSession)
    }

    func testEmptyMessagesRoundTrip() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        conversation.messages = []
        repository.upsertConversation(conversation)

        XCTAssertEqual(repository.load().conversations.first?.messages.count, 0)
    }

    func testAllModesRoundTrip() throws {
        let repository = try makeRepository()
        for mode in ChatMode.allCases {
            var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: mode.rawValue, updatedAt: seconds(1000))
            conversation.mode = mode
            repository.upsertConversation(conversation)
            let loaded = repository.load().conversations.first { $0.id == conversation.id }
            XCTAssertEqual(loaded?.mode, mode)
        }
    }

    func testAllRolesRoundTrip() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        conversation.messages = [
            ChatMessage(role: .user, content: "u", createdAt: seconds(1000)),
            ChatMessage(role: .agent, content: "a", createdAt: seconds(1001)),
            ChatMessage(role: .thinking, content: "t", createdAt: seconds(1002)),
            ChatMessage(role: .error, content: "e", createdAt: seconds(1003))
        ]
        repository.upsertConversation(conversation)

        XCTAssertEqual(repository.load().conversations.first?.messages.map(\.role), [.user, .agent, .thinking, .error])
    }

    func testToolCallMessageRoundTripsWithInputOutputAndState() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(agentID: "a1", address: "0xaaa", title: "c", updatedAt: seconds(1000))
        let tool = ChatMessage(
            id: "tool-1",
            role: .tool,
            content: "README contents",
            createdAt: seconds(1001),
            toolName: "read_file",
            toolArguments: ["path": .string("README.md")],
            toolState: .completed
        )
        conversation.messages = [tool]
        repository.upsertConversation(conversation)

        let loaded = repository.load().conversations.first?.messages.first

        XCTAssertEqual(loaded, tool)
    }

    func testImageAttachmentsRoundTripWithMessage() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(
            agentID: "a1",
            address: "0xaaa",
            title: "photo",
            updatedAt: seconds(1000)
        )
        let image = ChatImageAttachment(
            id: "image-1",
            data: Data([0x00, 0x01, 0x02, 0xff]),
            mimeType: "image/png"
        )
        conversation.messages = [
            ChatMessage(id: "m1", role: .user, content: "Look", images: [image])
        ]

        repository.upsertConversation(conversation)
        let loaded = repository.load().conversations.first?.messages.first

        XCTAssertEqual(loaded?.images, [image])
        XCTAssertEqual(loaded?.images.first?.dataURL, "data:image/png;base64,AAEC/w==")
    }

    func testFileAttachmentsRoundTripWithMessage() throws {
        let repository = try makeRepository()
        var conversation = makeConversation(
            agentID: "a1",
            address: "0xaaa",
            title: "file",
            updatedAt: seconds(1000)
        )
        let file = ChatFileAttachment(
            id: "file-1",
            name: "notes.txt",
            data: Data("hello".utf8),
            mimeType: "text/plain"
        )
        conversation.messages = [
            ChatMessage(id: "m1", role: .user, content: "Read this", files: [file])
        ]

        repository.upsertConversation(conversation)
        let loaded = repository.load().conversations.first?.messages.first

        XCTAssertEqual(loaded?.files, [file])
        XCTAssertEqual(loaded?.files.first?.dataURL, "data:text/plain;base64,aGVsbG8=")
    }

    func testV1StoreMigratesToV3WithEmptyAttachments() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        do {
            let schema = Schema(versionedSchema: StoredModelsSchemaV1.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(container)
            let seededV1 = StoredModelsSchemaV1.StoredConversation(
                id: "v1-conversation",
                title: "Before photos",
                agentID: nil,
                agentAddress: "0xaaa",
                modeRaw: "safe",
                createdAt: seconds(1000),
                updatedAt: seconds(1001),
                serverSessionData: nil,
                messages: [
                    StoredModelsSchemaV1.StoredMessage(
                        messageID: "v1-message",
                        conversationID: "v1-conversation",
                        roleRaw: "user",
                        content: "hello",
                        createdAt: seconds(1001)
                    )
                ]
            )
            context.insert(seededV1)
            for message in seededV1.messages {
                context.insert(message)
                message.conversation = seededV1
            }
            try context.save()
        }

        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let message = repository.load().conversations.first?.messages.first

        XCTAssertEqual(message?.id, "v1-message")
        XCTAssertEqual(message?.content, "hello")
        XCTAssertEqual(message?.images, [])
        XCTAssertEqual(message?.files, [])
    }

    func testV2StoreMigratesToV3PreservingImagesWithEmptyFiles() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let image = ChatImageAttachment(
            id: "image-1",
            data: Data([0x00, 0x01]),
            mimeType: "image/png"
        )

        do {
            let schema = Schema(versionedSchema: StoredModelsSchemaV2.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(container)
            let seededV2 = StoredModelsSchemaV2.StoredConversation(
                id: "v2-conversation",
                title: "Before files",
                agentID: nil,
                agentAddress: "0xaaa",
                modeRaw: "safe",
                createdAt: seconds(1000),
                updatedAt: seconds(1001),
                serverSessionData: nil,
                messages: [
                    StoredModelsSchemaV2.StoredMessage(
                        messageID: "v2-message",
                        conversationID: "v2-conversation",
                        roleRaw: "user",
                        content: "look",
                        createdAt: seconds(1001),
                        imageAttachmentsData: try JSONEncoder().encode([image])
                    )
                ]
            )
            context.insert(seededV2)
            for message in seededV2.messages {
                context.insert(message)
                message.conversation = seededV2
            }
            try context.save()
        }

        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let message = repository.load().conversations.first?.messages.first

        XCTAssertEqual(message?.id, "v2-message")
        XCTAssertEqual(message?.images, [image])
        XCTAssertEqual(message?.files, [])
    }

    func testMessagesWithSameIDInDifferentConversationsBothSurvive() throws {
        let repository = try makeRepository()
        // Server-chosen tool IDs are not globally unique across conversations.
        var first = makeConversation(agentID: "a1", address: "0xaaa", title: "first", updatedAt: seconds(1000))
        first.messages = [ChatMessage(id: "t1", role: .tool, content: "in first", createdAt: seconds(1001))]
        var second = makeConversation(agentID: "a1", address: "0xaaa", title: "second", updatedAt: seconds(2000))
        second.messages = [ChatMessage(id: "t1", role: .tool, content: "in second", createdAt: seconds(2001))]

        repository.upsertConversation(first)
        repository.upsertConversation(second)
        let loaded = repository.load().conversations

        let firstLoaded = loaded.first { $0.id == first.id }
        let secondLoaded = loaded.first { $0.id == second.id }
        XCTAssertEqual(firstLoaded?.messages.map(\.content), ["in first"])
        XCTAssertEqual(secondLoaded?.messages.map(\.content), ["in second"])
    }

    func testCompositeIDStaysUniqueForDelimiterEmptyAndMultibyteIDs() {
        // Pairs chosen to collide under naive "conversation#message" concatenation.
        let pairs: [(conversation: String, message: String)] = [
            ("a#b", "c"),
            ("a", "b#c"),
            ("a#", "b#c"),
            ("a#b#", "c"),
            ("", ""),
            ("", "x"),
            ("x", ""),
            ("12", "x"),
            ("1", "2#x"),
            ("Café", "résumé"),
            ("Caf", "é#résumé")
        ]

        let ids = pairs.map { StoredMessage.compositeID(conversationID: $0.conversation, messageID: $0.message) }

        XCTAssertEqual(Set(ids).count, pairs.count, "distinct (conversation, message) pairs must never share a key")
    }

    func testCompositeIDFormatIsStable() {
        // The key is persisted; changing the encoding would orphan every existing row.
        XCTAssertEqual(StoredMessage.compositeID(conversationID: "c1", messageID: "m1"), "2#c1#m1")
        // The prefix is the UTF-8 byte count, not the character count.
        XCTAssertEqual(StoredMessage.compositeID(conversationID: "Café", messageID: "x"), "5#Café#x")
        XCTAssertEqual(StoredMessage.compositeID(conversationID: "", messageID: ""), "0##")
    }

    func testLegacyStoreOpensAfterUpgradeKeepingMessagesAndServerIDs() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        try seedLegacyStore(at: storeURL)

        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let loaded = repository.load()

        XCTAssertEqual(loaded.agents.map(\.id), ["a1"])
        XCTAssertEqual(Set(loaded.conversations.map(\.id)), ["c1", "c2"])
        let first = loaded.conversations.first { $0.id == "c1" }
        let second = loaded.conversations.first { $0.id == "c2" }
        XCTAssertEqual(first?.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(first?.messages.map(\.content), ["hello", "world"])
        XCTAssertEqual(first?.messages.map(\.role), [.user, .agent])
        XCTAssertEqual(second?.messages.map(\.id), ["m3"])
        XCTAssertEqual(second?.messages.first?.role, .tool)

        // The lifted store must reopen (now matching the versioned plan) with the repair intact.
        let reopened = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        XCTAssertEqual(reopened.load().conversations.first { $0.id == "c1" }?.messages.map(\.id), ["m1", "m2"])
    }

    func testUpgradedLegacyStoreAcceptsSameMessageIDAcrossConversations() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        try seedLegacyStore(at: storeURL)
        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)

        // "m3" already exists in legacy conversation c2; reusing it elsewhere must not clash.
        var third = makeConversation(agentID: "a1", address: "0xaaa", title: "third", updatedAt: seconds(4000))
        third.messages = [ChatMessage(id: "m3", role: .tool, content: "duplicate id", createdAt: seconds(4001))]
        repository.upsertConversation(third)
        let loaded = repository.load().conversations

        XCTAssertEqual(loaded.first { $0.id == "c2" }?.messages.map(\.content), ["tool ran"])
        XCTAssertEqual(loaded.first { $0.id == third.id }?.messages.map(\.content), ["duplicate id"])
    }

    func testLegacyStoreUpgradePreservesDelimiterUnicodeToolAndSessionData() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let sessionData = try JSONEncoder().encode(["session_id": JSONValue.string("s1")])
        let argumentsData = try JSONEncoder().encode(["query": JSONValue.string("café")])
        try withLegacyContext(at: storeURL) { context in
            let user = LegacyStoredModels.StoredMessage(id: "m#1", roleRaw: "user", content: "queued send", createdAt: seconds(1001))
            user.deliveryStateRaw = "queued"
            let agent = LegacyStoredModels.StoredMessage(id: "Café", roleRaw: "agent", content: "unicode id", createdAt: seconds(1002))
            let tool = LegacyStoredModels.StoredMessage(id: "t1", roleRaw: "tool", content: "ran", createdAt: seconds(1003))
            tool.toolName = "search"
            tool.toolArgumentsData = argumentsData
            tool.toolStateRaw = "completed"
            context.insert(LegacyStoredModels.StoredConversation(
                id: "c1", title: "legacy", agentID: nil, agentAddress: "0xaaa", modeRaw: "safe",
                createdAt: seconds(1000), updatedAt: seconds(2000), serverSessionData: sessionData,
                messages: [user, agent, tool]
            ))
        }

        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let conversation = repository.load().conversations.first { $0.id == "c1" }

        XCTAssertEqual(conversation?.messages.map(\.id), ["m#1", "Café", "t1"])
        XCTAssertNil(conversation?.agentID)
        XCTAssertEqual(conversation?.serverSession?["session_id"]?.stringValue, "s1")
        XCTAssertEqual(conversation?.messages.first?.deliveryState, .queued)
        let toolMessage = conversation?.messages.last
        XCTAssertEqual(toolMessage?.toolName, "search")
        XCTAssertEqual(toolMessage?.toolArguments, ["query": .string("café")])
        XCTAssertEqual(toolMessage?.toolState, .completed)

        // A repaired delimiter-bearing ID must still be reusable in another conversation.
        var other = makeConversation(agentID: "a1", address: "0xaaa", title: "other", updatedAt: seconds(3000))
        other.messages = [ChatMessage(id: "m#1", role: .user, content: "same raw id", createdAt: seconds(3001))]
        repository.upsertConversation(other)
        let reloaded = repository.load().conversations
        XCTAssertEqual(reloaded.first { $0.id == "c1" }?.messages.first?.content, "queued send")
        XCTAssertEqual(reloaded.first { $0.id == other.id }?.messages.map(\.content), ["same raw id"])
    }

    func testLegacyOrphanMessageDoesNotBlockUpgrade() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        try withLegacyContext(at: storeURL) { context in
            context.insert(LegacyStoredModels.StoredConversation(
                id: "c1", title: "kept", agentID: "a1", agentAddress: "0xaaa", modeRaw: "safe",
                createdAt: seconds(1000), updatedAt: seconds(1000), serverSessionData: nil,
                messages: [LegacyStoredModels.StoredMessage(id: "m1", roleRaw: "user", content: "hello", createdAt: seconds(1001))]
            ))
            // A row that lost its conversation must not stall the repair pass.
            context.insert(LegacyStoredModels.StoredMessage(id: "orphan", roleRaw: "agent", content: "dangling", createdAt: seconds(1002)))
        }

        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)

        XCTAssertEqual(repository.load().conversations.first { $0.id == "c1" }?.messages.map(\.id), ["m1"])
        // The repair must be durable: a reopen sees the same healthy state.
        let reopened = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        XCTAssertEqual(reopened.load().conversations.first { $0.id == "c1" }?.messages.map(\.id), ["m1"])
    }

    func testUpgradedStoreMixesRepairedAndFreshMessagesCorrectly() throws {
        let storeURL = try makeScratchStoreURL()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        try seedLegacyStore(at: storeURL)
        let repository = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)

        var conversation = try XCTUnwrap(repository.load().conversations.first { $0.id == "c1" })
        conversation.messages.append(ChatMessage(id: "fresh", role: .agent, content: "post-upgrade", createdAt: seconds(5000)))
        repository.upsertConversation(conversation)

        let reopened = try SwiftDataConversationRepository(storeURL: storeURL, defaults: defaults)
        let loaded = reopened.load().conversations.first { $0.id == "c1" }
        XCTAssertEqual(loaded?.messages.map(\.id), ["m1", "m2", "fresh"])
        XCTAssertEqual(loaded?.messages.last?.content, "post-upgrade")
    }

    /// The last-resort repository the factory falls back to when no SwiftData container can be
    /// built. It keeps the session usable, so it has to honour the same read-back contract.
    func testEphemeralRepositoryRoundTripsWithinASession() {
        let repository = EphemeralConversationRepository()
        var conversation = makeConversation(
            agentID: "a1",
            address: "0xabc",
            title: "Ephemeral",
            updatedAt: seconds(1000)
        )
        conversation.messages = [
            ChatMessage(id: "m1", role: .user, content: "café", createdAt: seconds(1001))
        ]
        repository.upsertAgent(SavedAgent(id: "a1", address: "0xabc"))
        repository.upsertConversation(conversation)
        repository.saveActive(agentID: "a1", conversationID: conversation.id)

        let snapshot = repository.load()
        XCTAssertEqual(snapshot.agents.map(\.id), ["a1"])
        XCTAssertEqual(snapshot.conversations.map(\.id), [conversation.id])
        XCTAssertEqual(snapshot.activeAgentID, "a1")
        XCTAssertEqual(repository.search("café").map(\.id), [conversation.id])
        XCTAssertEqual(repository.search("nothing-matches"), [])

        repository.deleteAgent(id: "a1")
        XCTAssertEqual(repository.load().agents, [])
        XCTAssertEqual(repository.load().conversations, [])
    }

    private func makeScratchStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("store.sqlite")
    }

    private func withLegacyContext(at storeURL: URL, _ populate: (ModelContext) throws -> Void) throws {
        let schema = Schema([
            LegacyStoredModels.StoredAgent.self,
            LegacyStoredModels.StoredConversation.self,
            LegacyStoredModels.StoredMessage.self
        ])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: storeURL))
        let context = ModelContext(container)
        try populate(context)
        // Wire every message's inverse before saving. Assigning a conversation's
        // `messages` array is enough on iOS 18 and later; on iOS 17 the
        // back-reference stays nil, so the seeded store contains orphans and the
        // repair step deletes them before the migration under test ever runs.
        for conversation in try context.fetch(FetchDescriptor<LegacyStoredModels.StoredConversation>()) {
            for message in conversation.messages where message.conversation == nil {
                message.conversation = conversation
            }
        }
        try context.save()
    }

    private func seedLegacyStore(at storeURL: URL) throws {
        try withLegacyContext(at: storeURL) { context in
            context.insert(LegacyStoredModels.StoredAgent(
                id: "a1", name: "Agent", address: "0xaaa", token: "",
                createdAt: seconds(1000), updatedAt: seconds(1000)
            ))
            context.insert(LegacyStoredModels.StoredConversation(
                id: "c1", title: "first", agentID: "a1", agentAddress: "0xaaa", modeRaw: "safe",
                createdAt: seconds(1000), updatedAt: seconds(2000), serverSessionData: nil,
                messages: [
                    LegacyStoredModels.StoredMessage(id: "m1", roleRaw: "user", content: "hello", createdAt: seconds(1001)),
                    LegacyStoredModels.StoredMessage(id: "m2", roleRaw: "agent", content: "world", createdAt: seconds(1002))
                ]
            ))
            context.insert(LegacyStoredModels.StoredConversation(
                id: "c2", title: "second", agentID: "a1", agentAddress: "0xaaa", modeRaw: "plan",
                createdAt: seconds(3000), updatedAt: seconds(3000), serverSessionData: nil,
                messages: [
                    LegacyStoredModels.StoredMessage(id: "m3", roleRaw: "tool", content: "tool ran", createdAt: seconds(3001))
                ]
            ))
        }
    }

    private func seconds(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private func makeConversation(agentID: String?, address: String, title: String, updatedAt: Date) -> Conversation {
        var conversation = Conversation(agentID: agentID, agentAddress: address)
        conversation.title = title
        conversation.createdAt = updatedAt
        conversation.updatedAt = updatedAt
        return conversation
    }
}

final class ConversationRepositoryErrorMessageTests: XCTestCase {
    private struct SampleError: LocalizedError {
        var errorDescription: String? { "the disk is full" }
    }

    func testEveryOperationExplainsFailureConsequenceAndUnderlyingReason() {
        let expectedConsequences: [ConversationRepositoryError.Operation: String] = [
            .load: "Your past conversations may not appear.",
            .saveConversation: "Your latest messages may be missing when you reopen the app.",
            .deleteConversation: "It may reappear when you reopen the app.",
            .saveAgent: "This agent may be missing when you reopen the app.",
            .deleteAgent: "It may reappear when you reopen the app.",
            .search: "Some results may be missing."
        ]

        for (operation, consequence) in expectedConsequences {
            let error = ConversationRepositoryError(operation: operation, underlyingError: SampleError())
            let message = error.errorDescription ?? ""

            XCTAssertTrue(
                message.contains("Couldn’t \(operation.rawValue)."),
                "Message should name the failed action for \(operation): \(message)"
            )
            XCTAssertTrue(
                message.contains(consequence),
                "Message should explain the consequence for \(operation): \(message)"
            )
            XCTAssertTrue(
                message.contains("the disk is full"),
                "Message should still carry the underlying reason for \(operation): \(message)"
            )
        }
    }
}
