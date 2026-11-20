import Combine
import XCTest
@testable import OOChatIOS

@MainActor
final class AgentsFeatureTests: XCTestCase {
    // Make sure ViewModel can read agents from repo.
    func testLoadAgentsActiveSelectionFromRepo() {
        let first = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let second = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(2000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [second, first],
                conversations: [],
                activeAgentID: first.id,
                activeConversationID: nil
            )
        )

        let view = ChatViewModel(store: repo)

        XCTAssertEqual(view.agents.map(\.id), [second.id, first.id])
        XCTAssertEqual(view.activeAgentID, first.id)
        XCTAssertEqual(view.agentAddressDraft, first.address)
    }

    // Mock user choose second agent and test switch conversation.
    func testSelectAgentActivatesItsMostRecentCon() {
        let first = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let second = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(2000))
        let firstCon = makeConversation(
            id: "con1",
            agent: first,
            updatedAt: seconds(1000)
        )
        let oldSecondCon = makeConversation(
            id: "con2",
            agent: second,
            updatedAt: seconds(2000)
        )
        let newSecondCon = makeConversation(
            id: "con3",
            agent: second,
            updatedAt: seconds(3000)
        )
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [first, second],
                conversations: [
                    firstCon,
                    oldSecondCon,
                    newSecondCon
                ],
                activeAgentID: first.id,
                activeConversationID: firstCon.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.selectAgent(second)

        XCTAssertEqual(view.activeAgentID, second.id)
        XCTAssertEqual(view.activeConversationID, newSecondCon.id)
        XCTAssertEqual(view.agentAddressDraft, second.address)
        XCTAssertEqual(
            repo.savedActiveCalls.last,
            SavedActive(agentID: second.id, conversationID: newSecondCon.id)
        )
    }

    // Make sure conversation list order is right.
    func testConForAgentFiltersAndSortsNewestFirst() {
        let first = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let second = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(2000))
        let old = makeConversation(id: "old", agent: first, updatedAt: seconds(1000))
        let new = makeConversation(id: "new", agent: first, updatedAt: seconds(3000))
        let hhh = makeConversation(id: "hhh", agent: second, updatedAt: seconds(4000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [first, second],
                conversations: [old, hhh, new],
                activeAgentID: first.id,
                activeConversationID: old.id
            )
        )
        let view = ChatViewModel(store: repo)

        let conversations = view.conversations(for: first)

        XCTAssertEqual(conversations.map(\.id), [new.id, old.id])
    }

    // Make sure click new chat will open a new chat view.
    func testCreateConMakesAgentAndConActive() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [],
                activeAgentID: agent.id,
                activeConversationID: nil
            )
        )
        let view = ChatViewModel(store: repo)

        let conversation = view.createConversation(for: agent)

        XCTAssertEqual(conversation.agentID, agent.id)
        XCTAssertEqual(conversation.agentAddress, agent.address)
        XCTAssertEqual(conversation.title, "New mobile session")
        XCTAssertFalse(conversation.id.isEmpty)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertTrue(view.prompt.isEmpty)
        XCTAssertEqual(view.activeAgentID, agent.id)
        XCTAssertEqual(view.activeConversationID, conversation.id)
        XCTAssertEqual(repo.upsertedConversations.last?.id, conversation.id)
        XCTAssertEqual(
            repo.savedActiveCalls.last,
            SavedActive(agentID: agent.id, conversationID: conversation.id)
        )
    }

    func testNewConversationHasBlankComposerAndPreservesPreviousDraft() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let existing = makeConversation(id: "existing", agent: agent, updatedAt: seconds(2000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [existing],
                activeAgentID: agent.id,
                activeConversationID: existing.id
            )
        )
        let view = ChatViewModel(store: repo)
        view.prompt = "unfinished draft"

        let created = view.createConversation(for: agent)

        XCTAssertEqual(view.activeConversationID, created.id)
        XCTAssertTrue(view.prompt.isEmpty)
        XCTAssertTrue(created.messages.isEmpty)

        view.selectConversation(existing)

        XCTAssertEqual(view.prompt, "unfinished draft")
    }

    func testPhotoDraftStaysWithConversationWhereSelectionStarted() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let first = makeConversation(id: "first", agent: agent, updatedAt: seconds(2000))
        let second = makeConversation(id: "second", agent: agent, updatedAt: seconds(1000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [first, second],
                activeAgentID: agent.id,
                activeConversationID: first.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.selectConversation(second)
        XCTAssertTrue(
            view.addPendingImage(
                data: Data([0x01]),
                mimeType: "image/png",
                to: first.id
            )
        )
        XCTAssertTrue(view.pendingImages.isEmpty)

        view.selectConversation(first)
        XCTAssertEqual(view.pendingImages.map(\.data), [Data([0x01])])
    }

    func testFileDraftStaysWithConversationWhereSelectionStarted() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let first = makeConversation(id: "first", agent: agent, updatedAt: seconds(2000))
        let second = makeConversation(id: "second", agent: agent, updatedAt: seconds(1000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [first, second],
                activeAgentID: agent.id,
                activeConversationID: first.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.selectConversation(second)
        XCTAssertTrue(
            view.addPendingFile(
                name: "notes.txt",
                data: Data("hello".utf8),
                mimeType: "text/plain",
                to: first.id
            )
        )
        XCTAssertTrue(view.pendingFiles.isEmpty)

        view.selectConversation(first)
        XCTAssertEqual(view.pendingFiles.map(\.name), ["notes.txt"])
    }

    // Mock delete current conversation delete, the chat also deletes.
    func testDeleteActiveAgentRemovesConAndSelectRemainAgent() {
        let deletedAgent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(2000))
        let remainingAgent = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(1000))
        let deletedConversation = makeConversation(
            id: "conversation1",
            agent: deletedAgent,
            updatedAt: seconds(2000)
        )
        let remainingConversation = makeConversation(
            id: "conversation2",
            agent: remainingAgent,
            updatedAt: seconds(1000)
        )
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [deletedAgent, remainingAgent],
                conversations: [deletedConversation, remainingConversation],
                activeAgentID: deletedAgent.id,
                activeConversationID: deletedConversation.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.deleteAgent(deletedAgent)

        XCTAssertEqual(view.agents.map(\.id), [remainingAgent.id])
        XCTAssertEqual(view.conversations.map(\.id), [remainingConversation.id])
        XCTAssertEqual(view.activeAgentID, remainingAgent.id)
        XCTAssertEqual(view.activeConversationID, remainingConversation.id)
        XCTAssertEqual(view.agentAddressDraft, remainingAgent.address)
        XCTAssertEqual(repo.deletedAgentIDs, [deletedAgent.id])
        XCTAssertEqual(repo.deletedConversationIDs, [deletedConversation.id])
    }

    // Test invalid agent address is failed to connect.
    func testInvalidAgentAddressFailedConnect() async {
        let repo = SpyConversationRepository(snapshot: .empty)
        let view = ChatViewModel(store: repo)
        view.agentAddressDraft = "not-an-agent-address"

        let result = await view.connectToAgent()

        XCTAssertNil(result)
        XCTAssertFalse(view.isConnecting)
        XCTAssertNotNil(view.errorMessage)
        XCTAssertTrue(repo.upsertedAgents.isEmpty)
    }

    // Rename updates the title in place and persists that single row.
    func testRenameConversationUpdatesTitleAndPersists() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let conversation = makeConversation(id: "con1", agent: agent, updatedAt: seconds(1000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [conversation],
                activeAgentID: agent.id,
                activeConversationID: conversation.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.renameConversation(conversation, to: "  Renamed  ")

        XCTAssertEqual(view.conversations.first?.title, "Renamed")
        XCTAssertEqual(repo.upsertedConversations.last?.id, conversation.id)
        XCTAssertEqual(repo.upsertedConversations.last?.title, "Renamed")
    }

    // Rename does not reorder the list, change updatedAt, or switch the active conversation.
    func testRenameConversationIsMetadataOnlyEdit() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(3000))
        let older = makeConversation(id: "older", agent: agent, updatedAt: seconds(1000))
        let newer = makeConversation(id: "newer", agent: agent, updatedAt: seconds(2000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [newer, older],
                activeAgentID: agent.id,
                activeConversationID: newer.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.renameConversation(older, to: "Fresh title")

        XCTAssertEqual(view.conversations.map(\.id), [newer.id, older.id])
        XCTAssertEqual(view.conversations.last?.updatedAt, seconds(1000))
        XCTAssertEqual(view.activeConversationID, newer.id)
    }

    // Empty/whitespace titles and no-op renames neither mutate nor persist.
    func testRenameConversationIgnoresBlankAndNoopTitles() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let conversation = makeConversation(id: "con1", agent: agent, updatedAt: seconds(1000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [conversation],
                activeAgentID: agent.id,
                activeConversationID: conversation.id
            )
        )
        let view = ChatViewModel(store: repo)

        view.renameConversation(conversation, to: "   \n")
        view.renameConversation(conversation, to: "con1") // same as makeConversation title

        XCTAssertEqual(view.conversations.first?.title, "con1")
        XCTAssertTrue(repo.upsertedConversations.isEmpty)
    }

    func testConversationStateChangesPublishThroughFacade() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let conversation = makeConversation(id: "con1", agent: agent, updatedAt: seconds(1000))
        let repo = SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [conversation],
                activeAgentID: agent.id,
                activeConversationID: conversation.id
            )
        )
        let view = ChatViewModel(store: repo)
        var changeCount = 0
        let cancellable = view.objectWillChange.sink {
            changeCount += 1
        }

        view.renameConversation(conversation, to: "Published title")

        XCTAssertGreaterThan(changeCount, 0)
        XCTAssertEqual(view.activeConversation?.title, "Published title")
        withExtendedLifetime(cancellable) {}
    }

    // Search forwards the query to the store and returns its results unfiltered.
    func testSearchConversationsForwardsToStore() {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let hit = makeConversation(id: "hit", agent: agent, updatedAt: seconds(1000))
        let repo = SpyConversationRepository(snapshot: .empty)
        repo.searchResults = [hit]
        let view = ChatViewModel(store: repo)

        let results = view.searchConversations("milk")

        XCTAssertEqual(results.map(\.id), [hit.id])
        XCTAssertEqual(repo.searchQueries, ["milk"])
    }

    // Scoping a search to an agent keeps only that agent's matches.
    func testSearchConversationsScopedToAgentFiltersOthers() {
        let mine = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let other = makeAgent(id: "agent2", address: "0xbbb", updatedAt: seconds(1000))
        let mineHit = makeConversation(id: "mine", agent: mine, updatedAt: seconds(2000))
        let otherHit = makeConversation(id: "other", agent: other, updatedAt: seconds(1000))
        let repo = SpyConversationRepository(snapshot: .empty)
        repo.searchResults = [mineHit, otherHit]
        let view = ChatViewModel(store: repo)

        let results = view.searchConversations("note", for: mine)

        XCTAssertEqual(results.map(\.id), [mineHit.id])
    }

    private func makeAgent(id: String, address: String, updatedAt: Date) -> SavedAgent {
        SavedAgent(
            id: id,
            address: address,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    private func makeConversation(
        id: String,
        agent: SavedAgent,
        updatedAt: Date
    ) -> Conversation {
        Conversation(
            id: id,
            title: id,
            agentID: agent.id,
            agentAddress: agent.address,
            mode: .safe,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            messages: [],
            serverSession: nil
        )
    }

    private func seconds(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}

private struct SavedActive: Equatable {
    let agentID: String?
    let conversationID: String?
}

@MainActor
private final class SpyConversationRepository: ConversationRepository {
    let snapshot: ChatSnapshot
    private(set) var upsertedConversations: [Conversation] = []
    private(set) var deletedConversationIDs: [String] = []
    private(set) var upsertedAgents: [SavedAgent] = []
    private(set) var deletedAgentIDs: [String] = []
    private(set) var savedActiveCalls: [SavedActive] = []
    private(set) var searchQueries: [String] = []
    var searchResults: [Conversation] = []

    init(snapshot: ChatSnapshot) {
        self.snapshot = snapshot
    }

    func load() -> ChatSnapshot {
        snapshot
    }

    func upsertConversation(_ conversation: Conversation) {
        upsertedConversations.append(conversation)
    }

    func deleteConversation(id: String) {
        deletedConversationIDs.append(id)
    }

    func upsertAgent(_ agent: SavedAgent) {
        upsertedAgents.append(agent)
    }

    func deleteAgent(id: String) {
        deletedAgentIDs.append(id)
    }

    func saveActive(agentID: String?, conversationID: String?) {
        savedActiveCalls.append(
            SavedActive(agentID: agentID, conversationID: conversationID)
        )
    }

    func search(_ query: String) -> [Conversation] {
        searchQueries.append(query)
        return searchResults
    }
}
