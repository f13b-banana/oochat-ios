import Combine
import ConnectOnionKit
import Security
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
        XCTAssertEqual(conversation.title, "New chat")
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

    func testDraftSurvivesARelaunch() {
        let repo = makeDraftRepository()

        let first = ChatViewModel(store: repo)
        first.prompt = "half-written thought"
        XCTAssertEqual(repo.savedDrafts, ["con1": "half-written thought"])

        let relaunched = ChatViewModel(store: repo)
        XCTAssertEqual(relaunched.prompt, "half-written thought")
    }

    func testClearedOrDeletedDraftIsForgotten() {
        let repo = makeDraftRepository()
        let viewModel = ChatViewModel(store: repo)

        viewModel.prompt = "draft"
        // Sending clears the prompt the same way.
        viewModel.prompt = ""
        XCTAssertEqual(repo.savedDrafts, [:])

        viewModel.prompt = "draft again"
        guard let conversation = viewModel.activeConversation else {
            return XCTFail("Expected con1 to be open")
        }
        viewModel.deleteConversation(conversation)
        XCTAssertEqual(repo.savedDrafts, [:])
    }

    /// One agent with one open chat, "con1".
    private func makeDraftRepository() -> SpyConversationRepository {
        let agent = makeAgent(id: "agent1", address: "0xaaa", updatedAt: seconds(1000))
        let conversation = makeConversation(id: "con1", agent: agent, updatedAt: seconds(1000))
        return SpyConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [conversation],
                activeAgentID: agent.id,
                activeConversationID: conversation.id
            )
        )
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

/// One agent per Address, and the Agent Name list a Device Link brings in.
@MainActor
final class AgentNameTests: XCTestCase {
    private let address = "0x" + String(repeating: "ab", count: 32)
    private let upperAddress = "0x" + String(repeating: "AB", count: 32)
    private let otherAddress = "0x" + String(repeating: "cd", count: 32)
    private let identityService = "agent-name-tests.\(UUID().uuidString)"

    override func tearDown() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: identityService] as CFDictionary)
        super.tearDown()
    }

    private func agent(_ id: String, _ address: String, _ name: String, created: TimeInterval) -> SavedAgent {
        SavedAgent(id: id, address: address, name: name, createdAt: Date(timeIntervalSince1970: created),
                   updatedAt: Date(timeIntervalSince1970: created))
    }

    private func chat(_ id: String, _ agent: SavedAgent) -> Conversation {
        Conversation(id: id, title: id, agentID: agent.id, agentAddress: agent.address, mode: .safe,
                     createdAt: agent.createdAt, updatedAt: agent.createdAt, messages: [], serverSession: nil)
    }

    private func model(_ agents: [SavedAgent], _ chats: [Conversation] = [], active: String? = nil,
                       repo: ConversationRepository? = nil, transport: MockAgentTransport = MockAgentTransport()) -> ChatViewModel {
        let store = repo ?? InMemoryConversationRepository(snapshot: ChatSnapshot(
            agents: agents, conversations: chats, activeAgentID: active, activeConversationID: nil
        ))
        return ChatViewModel(store: store, identityStore: IdentityStore(service: identityService), client: transport,
                             networkMonitor: MockNetworkMonitor())
    }

    // By hand, QR and deep link all save through saveAgent with no id.
    func testAddingAnAddressThatExistsInAnyCaseUpdatesThatAgent() throws {
        let mine = agent("mine", address, "Mine", created: 100)
        let viewModel = model([mine], [chat("c1", mine)])

        let saved = try XCTUnwrap(viewModel.saveAgent(name: "Reported", address: upperAddress))

        XCTAssertEqual(viewModel.agents.map(\.id), ["mine"])
        XCTAssertEqual(saved.id, "mine")
        XCTAssertEqual(saved.name, "Mine", "a reported or prefilled name only fills the default on add")
        XCTAssertEqual(viewModel.conversations(for: saved).map(\.id), ["c1"])
    }

    func testConnectingByAnAddressThatExistsInAnyCaseUsesThatAgent() async {
        let mine = agent("mine", address, "Mine", created: 100)
        let viewModel = model([mine], [chat("c1", mine)])
        viewModel.agentAddressDraft = upperAddress

        let connected = await viewModel.connectToAgent()

        XCTAssertEqual(connected?.id, "mine")
        XCTAssertEqual(viewModel.agents.map(\.id), ["mine"])
    }

    func testDuplicatesLoadedFromTheStoreMergeIntoTheEarliestCreatedWithAllTheirChats() throws {
        let older = agent("older", address, "Older", created: 100)
        let newer = agent("newer", upperAddress, "Newer", created: 200)
        let other = agent("other", otherAddress, "Other", created: 300)
        // The real store: deleting an agent there also deletes the chats still on it.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identityService))
        defer { defaults.removePersistentDomain(forName: identityService) }
        let repo = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        [newer, other, older].forEach(repo.upsertAgent)
        var deleted = chat("t1", newer)
        deleted.tombstoneUpdated = Date(timeIntervalSince1970: 500)
        [chat("c1", older), chat("c2", newer), chat("c3", newer), chat("c4", other), deleted].forEach(repo.upsertConversation)
        repo.saveActive(agentID: newer.id, conversationID: "c2")

        let viewModel = model([], repo: repo)

        XCTAssertEqual(Set(viewModel.agents.map(\.id)), ["older", "other"])
        XCTAssertEqual(viewModel.agent(withID: "older")?.name, "Older")
        XCTAssertEqual(Set(viewModel.conversations(for: older).map(\.id)), ["c1", "c2", "c3"])
        XCTAssertEqual(viewModel.activeAgentID, "older")
        // Saved, so the next launch loads one agent too.
        let reloaded = repo.load()
        XCTAssertEqual(Set(reloaded.agents.map(\.id)), ["older", "other"])
        XCTAssertEqual(Set(reloaded.conversations.filter { $0.agentID == "older" }.map(\.id)), ["c1", "c2", "c3", "t1"])
        XCTAssertNotNil(reloaded.conversations.first { $0.id == "t1" }?.tombstoneUpdated, "a Tombstone moves, it is not deleted")
    }

    func testHistoryRestoreRunsOncePerAddressAfterDuplicatesMerge() async {
        let older = agent("older", address, "Older", created: 100)
        let newer = agent("newer", address, "Newer", created: 200)
        let viewModel = model([newer, older, agent("other", otherAddress, "Other", created: 300)])
        let fetcher = CountingFetcher()
        viewModel.historyFetcher = fetcher

        await viewModel.refreshHistory()

        XCTAssertEqual(fetcher.asked.sorted(), [address, otherAddress])
    }

    func testALinkRenamesTheMatchingAgentAddsTheMissingOneAndLeavesTheRest() async throws {
        let onlyHere = "0x" + String(repeating: "ef", count: 32)
        let viewModel = model([agent("mine", address, "Mine", created: 100), agent("here", onlyHere, "Only here", created: 200)])
        let fetcher = CountingFetcher()
        viewModel.historyFetcher = fetcher

        try await link(into: viewModel, giving: [(upperAddress, "Theirs"), (otherAddress, "New")])

        XCTAssertEqual(viewModel.agent(withID: "mine")?.name, "Theirs")
        XCTAssertEqual(viewModel.agent(withID: "here")?.name, "Only here")
        let added = try XCTUnwrap(viewModel.agents.first { $0.address == otherAddress })
        XCTAssertEqual(added.name, "New")
        XCTAssertEqual(viewModel.agents.count, 3)
        // History Restore runs for the added agent with no setup.
        await eventually { fetcher.asked.contains(otherAddress) }
    }

    func testAgentsThatCannotBeSavedStillLeaveTheNewIdentityAndTheLinkDone() async throws {
        let viewModel = model([], repo: FailingAgentRepository())

        let giver = try await link(into: viewModel, giving: [(otherAddress, "New")])

        XCTAssertEqual(try IdentityStore(service: identityService).loadOrCreateIdentity().address, giver)
        await eventually { viewModel.identity?.address == giver }
    }

    // Deleting an agent deletes the chats still on it, so an extra whose chats could not move stays.
    func testADuplicateWhoseChatsCannotMoveIsKept() {
        let older = agent("older", address, "Older", created: 100)
        let newer = agent("newer", address, "Newer", created: 200)
        let repo = UnmovableChatsRepository(snapshot: ChatSnapshot(
            agents: [older, newer], conversations: [chat("c2", newer)], activeAgentID: nil, activeConversationID: nil
        ))

        _ = model([], repo: repo)

        XCTAssertEqual(repo.deletedAgentIDs, [])
    }

    func testEditingAnAgentToAnAddressAnotherAgentHasIsRefused() {
        let viewModel = model([agent("mine", address, "Mine", created: 100), agent("other", otherAddress, "Other", created: 200)])

        let saved = viewModel.saveAgent(id: "other", name: "Other", address: upperAddress)

        XCTAssertNil(saved)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.agent(withID: "other")?.address, otherAddress)
    }

    func testTheGiversOwnAgentsAreUntouchedByALink() async throws {
        let mine = agent("mine", address, "Mine", created: 100)
        let viewModel = model([mine])
        let receiver = try DeviceLinkReceiver()
        let flow = DeviceLinkFlow(
            role: .giving, keyStore: viewModel.deviceLinkKeyStore, agentNames: { viewModel.linkAgentNames },
            ownerCheck: { true },
            give: { giver, approve in
                let verified = try giver.verify(try receiver.start())
                guard await approve() else { throw DeviceLinkError.cancelled }
                let identity = try receiver.accept(try giver.seal(for: verified))
                XCTAssertEqual(identity.agentNames.map(\.name), ["Mine"])
            }
        )

        flow.submit(try receiver.offer.qrPayload)
        await eventually { flow.step == .confirmingSend }
        flow.confirm()
        await eventually { if case .done = flow.step { true } else { false } }

        XCTAssertEqual(viewModel.agents, [mine])
    }

    func testTheGiverSendsEachAgentByItsLowerCasedAddressWithItsName() {
        let viewModel = model([
            agent("mine", upperAddress, "Mine", created: 100),
            agent("other", otherAddress, "Other", created: 200)
        ])

        XCTAssertEqual(Set(viewModel.linkAgentNames.map(\.address)), [address, otherAddress])
        XCTAssertEqual(Set(viewModel.linkAgentNames.map(\.name)), ["Mine", "Other"])
    }

    /// Links `viewModel`'s device as the Receiving Device, the way the link sheet wires it, from an in-memory
    /// giver holding `giving`. Returns the giver's Address once the link is done.
    @discardableResult
    private func link(into viewModel: ChatViewModel, giving: [(String, String)]) async throws -> String {
        let giverStore = InMemoryPrivateKeyStore()
        let names = giving.compactMap { DeviceLinkAgentName(address: $0.0, name: $0.1) }
        let flow = DeviceLinkFlow(
            role: .receiving,
            keyStore: viewModel.deviceLinkKeyStore,
            onReplaced: { previous in Task { await viewModel.adoptReplacedIdentity(previousAddress: previous) } },
            onAgentNames: { try viewModel.applyLinkedAgentNames($0) },
            receive: { receiver, accept in
                let giver = try DeviceLinkGiver(scanning: receiver.offer, keyStore: giverStore, agentNames: names)
                let identity = try receiver.accept(try giver.seal(for: try giver.verify(try receiver.start())))
                guard await accept(identity) else { throw DeviceLinkError.cancelled }
                return identity
            }
        )
        let giverAddress = try OIPSigner(keyStore: giverStore).address()
        flow.start()
        await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        flow.confirm()
        await eventually { flow.step == .done(address: giverAddress) }
        return giverAddress
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }
}

/// Records agent deletes; moving a chat to another agent fails.
@MainActor
private final class UnmovableChatsRepository: ConversationRepository {
    private let inner: InMemoryConversationRepository
    private(set) var deletedAgentIDs: [String] = []
    init(snapshot: ChatSnapshot) { inner = InMemoryConversationRepository(snapshot: snapshot) }
    func load() -> ChatSnapshot { inner.load() }
    func upsertConversation(_ conversation: Conversation) { inner.upsertConversation(conversation) }
    func deleteConversation(id: String) { inner.deleteConversation(id: id) }
    func upsertAgent(_ agent: SavedAgent) { inner.upsertAgent(agent) }
    func deleteAgent(id: String) { deletedAgentIDs.append(id) }
    func saveActive(agentID: String?, conversationID: String?) {}
    func search(_ query: String) -> [Conversation] { [] }
    func updateConversationMetadataResult(_ conversation: Conversation) -> Result<Void, ConversationRepositoryError> {
        .failure(ConversationRepositoryError(operation: .saveConversation, underlyingError: CocoaError(.fileWriteNoPermission)))
    }
}

/// Saves everything but agents.
@MainActor
private final class FailingAgentRepository: ConversationRepository {
    private let inner = InMemoryConversationRepository()
    func load() -> ChatSnapshot { inner.load() }
    func upsertConversation(_ conversation: Conversation) { inner.upsertConversation(conversation) }
    func deleteConversation(id: String) { inner.deleteConversation(id: id) }
    func upsertAgent(_ agent: SavedAgent) {}
    func deleteAgent(id: String) { inner.deleteAgent(id: id) }
    func saveActive(agentID: String?, conversationID: String?) {}
    func search(_ query: String) -> [Conversation] { [] }
    func upsertAgentResult(_ agent: SavedAgent) -> Result<Void, ConversationRepositoryError> {
        .failure(ConversationRepositoryError(operation: .saveAgent, underlyingError: CocoaError(.fileWriteNoPermission)))
    }
}

private final class CountingFetcher: SessionsFetching {
    private(set) var asked: [String] = []
    func sessions(agentAddress: String) async throws -> [ConnectOnionHostedSession] {
        asked.append(agentAddress)
        return []
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
    private(set) var savedDrafts: [String: String] = [:]
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

    func loadDrafts() -> [String: String] {
        savedDrafts
    }

    func saveDrafts(_ drafts: [String: String]) {
        savedDrafts = drafts
    }
}
