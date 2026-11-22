import Combine
import ConnectOnionKit
import Foundation

enum ConversationPersistence {
    case full
    case message(id: String)
    case metadata
}

@MainActor
final class ConversationState: ObservableObject {
    @Published private(set) var agents: [SavedAgent]
    @Published private(set) var conversations: [Conversation]
    @Published private(set) var activeAgentID: String?
    @Published private(set) var activeConversationID: String?
    @Published private(set) var persistenceError: ConversationRepositoryError?
    /// Maintained incrementally on every mutation. The sidebar and the toolbar badge read it
    /// on each redraw, and rescanning every conversation's messages there costs a full
    /// O(conversations × messages) sweep per streamed token.
    @Published private(set) var failedDeliveryConversationIDs: Set<String> = []
    /// Session-scoped completion receipts. They are cleared when the conversation is viewed
    /// and intentionally are not restored after an app relaunch.
    @Published private(set) var completedUnreadConversationIDs: Set<String> = []
    /// The Address this device signs as. Chats stamped with another one are Previous-Identity
    /// Conversations: readable, never connected, resumed or merged.
    @Published var currentAddress: String?

    /// Deleted chats kept as empty rows so History Restore skips their sessions. Never part of
    /// `conversations`, so the chat list and everything else that reads it never see them.
    private(set) var tombstones: [Conversation] = []

    private var draftsByConversationID: [String: String] = [:]
    /// One Work Room store per conversation, fed from the live frame pipeline. Session-scoped like drafts.
    private var workRoomStoresByConversationID: [String: WorkRoomStore] = [:]
    private let store: ConversationRepository

    init(store: ConversationRepository) {
        self.store = store

        let snapshotResult = store.loadResult()
        let snapshot = (try? snapshotResult.get()) ?? .empty
        agents = snapshot.agents
        conversations = snapshot.conversations.filter { !$0.isTombstone }
        tombstones = snapshot.conversations.filter(\.isTombstone)
        activeConversationID = snapshot.activeConversationID
        failedDeliveryConversationIDs = Set(
            snapshot.conversations
                .filter { $0.messages.contains { $0.deliveryState == .failed } }
                .map(\.id)
        )

        let activeConversationAgentID = snapshot.activeConversationID.flatMap { activeConversationID in
            snapshot.conversations.first { $0.id == activeConversationID }?.agentID
        }
        activeAgentID = snapshot.activeAgentID
            ?? activeConversationAgentID
            ?? snapshot.agents.first?.id

        if case .failure(let error) = snapshotResult {
            persistenceError = error
        }

        let conversationIDs = Set(snapshot.conversations.map(\.id))
        draftsByConversationID = store.loadDrafts().filter { conversationIDs.contains($0.key) }
        mergeDuplicateAgents()
    }

    /// One Address saved as two agents merges into the earliest-created, which keeps its Agent Name and takes
    /// the others' conversations without counting as activity. Chats move before the extras go, because
    /// deleting an agent deletes the chats still on it.
    private func mergeDuplicateAgents() {
        let earliestFirst = agents.sorted { $0.createdAt < $1.createdAt }
        for (keep, extras) in DeviceLinkAgentName.duplicates(in: earliestFirst, address: \.address) {
            var unmoved: Set<String> = []
            // Tombstones move too, or deleting the extra would take them and bring their chats back.
            moveRows(&conversations, from: extras, to: keep, unmoved: &unmoved)
            moveRows(&tombstones, from: extras, to: keep, unmoved: &unmoved)
            // Kept in the store while any of its chats are still saved on it; the next launch tries again.
            for extra in extras {
                agents.removeAll { $0.id == extra.id }
                if activeAgentID == extra.id {
                    activeAgentID = keep.id
                    persistSelection()
                }
                if !unmoved.contains(extra.id) {
                    recordPersistence(store.deleteAgentResult(id: extra.id))
                }
            }
        }
    }

    private func moveRows(
        _ rows: inout [Conversation],
        from extras: [SavedAgent],
        to keep: SavedAgent,
        unmoved: inout Set<String>
    ) {
        for index in rows.indices {
            guard let extra = extras.first(where: { conversationBelongsToAgent(rows[index], $0) }) else { continue }
            rows[index].agentID = keep.id
            rows[index].agentAddress = keep.address
            let result = store.updateConversationMetadataResult(rows[index])
            if case .failure = result { unmoved.insert(extra.id) }
            recordPersistence(result)
        }
    }

    var activeAgent: SavedAgent? {
        if let activeAgentID, let agent = agent(withID: activeAgentID) {
            return agent
        }
        if let activeConversation, let agent = agent(for: activeConversation) {
            return agent
        }
        return agents.first
    }

    var activeConversation: Conversation? {
        guard let activeConversationID else {
            return nil
        }
        return conversation(withID: activeConversationID)
    }

    var activeDraft: String {
        guard let activeConversationID else {
            return ""
        }
        return draftsByConversationID[activeConversationID] ?? ""
    }

    func updateActiveDraft(_ draft: String) {
        guard let activeConversationID,
              draftsByConversationID[activeConversationID, default: ""] != draft else {
            return
        }
        draftsByConversationID[activeConversationID] = draft.isEmpty ? nil : draft
        store.saveDrafts(draftsByConversationID)
    }

    func applyProviderUpdate(_ update: HostedAgentProviderUpdate, forConversationID conversationID: String) {
        let store = workRoomStore(for: conversationID)
        switch update {
        case .frame(let frame):
            store.receive(frame)
        case .snapshot(let connected):
            store.receiveSnapshot(connected)
        case .connectionDropped:
            store.connectionDidDrop()
        case .transport(let transport):
            store.transport = transport
        }
    }

    func ownsApproval(_ body: [String: JSONValue], forConversationID conversationID: String) -> Bool {
        workRoomStore(for: conversationID).ownsApproval(body)
    }

    /// A Station's paired session reconnects under its own conversation but keeps the store that holds the pairing.
    /// The old conversation gets a fresh store, so its socket closing cannot reach the moved one.
    func moveWorkRoomStore(from oldID: String, to newID: String) {
        let moved = workRoomStore(for: oldID)
        moved.moveBarrier(toScope: barrierScope(forConversationID: newID))
        workRoomStoresByConversationID[newID] = moved
        workRoomStoresByConversationID[oldID] = makeWorkRoomStore(for: oldID)
    }

    /// Created on first use, so a view that reads it before the first provider frame observes the same store.
    /// The store a chat already has, without making one: for views, which mustn't create state.
    func existingWorkRoomStore(for conversationID: String) -> WorkRoomStore? {
        workRoomStoresByConversationID[conversationID]
    }

    func workRoomStore(for conversationID: String) -> WorkRoomStore {
        if let existing = workRoomStoresByConversationID[conversationID] {
            return existing
        }
        let created = makeWorkRoomStore(for: conversationID)
        workRoomStoresByConversationID[conversationID] = created
        return created
    }

    /// The Stop Barrier is saved per agent address and conversation id, which survive a relaunch. A conversation
    /// that is not saved yet has no durable id, so its barrier stays in memory only.
    func barrierScope(forConversationID conversationID: String) -> String? {
        conversation(withID: conversationID).map { "\($0.agentAddress):\($0.id)" }
    }

    private func makeWorkRoomStore(for conversationID: String) -> WorkRoomStore {
        WorkRoomStore(barrierScope: barrierScope(forConversationID: conversationID))
    }

    func agent(withID id: String) -> SavedAgent? {
        agents.first { $0.id == id }
    }

    /// One agent per Address: matched by the lower-cased 0x Address.
    func agent(withAddress address: String) -> SavedAgent? {
        guard let key = AgentAddress.normalized(address) else { return nil }
        return agents.first { AgentAddress.normalized($0.address) == key }
    }

    func conversation(withID id: String) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func isFromPreviousIdentity(_ conversation: Conversation) -> Bool {
        PreviousIdentity.isPrevious(stamp: conversation.identityAddress, current: currentAddress)
    }

    /// After a Device Link replaced the key: stamps every unstamped chat with the Address it was made
    /// under, without counting as activity. Returns the chats that are now from a previous identity.
    /// Tombstones are stamped too, so History Restore never brings back one from a previous identity.
    func stampForReplace(previousAddress: String) -> [Conversation] {
        stamp(&conversations, previousAddress: previousAddress)
        stamp(&tombstones, previousAddress: previousAddress)
        return conversations.filter(isFromPreviousIdentity)
    }

    private func stamp(_ rows: inout [Conversation], previousAddress: String) {
        for index in rows.indices {
            let stamp = PreviousIdentity.stamp(rows[index].identityAddress, replacing: previousAddress)
            guard stamp != rows[index].identityAddress else { continue }
            rows[index].identityAddress = stamp
            recordPersistence(store.updateConversationMetadataResult(rows[index]))
        }
    }

    func conversations(for agent: SavedAgent) -> [Conversation] {
        conversations
            .filter { conversationBelongsToAgent($0, agent) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func selectAgent(_ agent: SavedAgent, currentDraft: String) {
        updateActiveDraft(currentDraft)
        activeAgentID = agent.id

        if let activeConversation, !conversationBelongsToAgent(activeConversation, agent) {
            activeConversationID = conversations(for: agent).first?.id
        } else if activeConversation == nil {
            activeConversationID = conversations(for: agent).first?.id
        }
        markActiveConversationViewed()
        persistSelection()
    }

    func selectConversation(_ conversation: Conversation, currentDraft: String) {
        updateActiveDraft(currentDraft)
        activeConversationID = conversation.id
        if let agent = agent(for: conversation) {
            activeAgentID = agent.id
        }
        markActiveConversationViewed()
        persistSelection()
    }

    func createConversation(for agent: SavedAgent, currentDraft: String) -> Conversation {
        updateActiveDraft(currentDraft)
        let conversation = Conversation(agentID: agent.id, agentAddress: agent.address)
        conversations.insert(conversation, at: 0)
        activeAgentID = agent.id
        activeConversationID = conversation.id
        markActiveConversationViewed()
        recordPersistence(store.upsertConversationResult(conversation))
        persistSelection()
        return conversation
    }

    func saveAgent(
        id: String?,
        name: String,
        address: String
    ) -> SavedAgent {
        // Adding an Address this device already has updates that agent. A reported or prefilled name
        // only fills the default on add, so the Agent Name stays.
        if id == nil, let existing = agent(withAddress: address) {
            return saveAgent(id: existing.id, name: existing.name, address: existing.address)
        }
        let existing = id.flatMap(agent(withID:))
        let now = Date()
        let shouldResetSessions = existing.map { $0.address != address } ?? false
        var next = SavedAgent(
            id: existing?.id ?? UUID().uuidString,
            address: address,
            name: name.isEmpty ? nil : name,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        next.updatedAt = now

        if let existing {
            for index in conversations.indices where conversationBelongsToAgent(conversations[index], existing) {
                conversations[index].agentID = next.id
                conversations[index].agentAddress = next.address
                if shouldResetSessions {
                    conversations[index].serverSession = nil
                }
                conversations[index].updatedAt = now
                recordPersistence(store.upsertConversationResult(conversations[index]))
            }
            // Tombstones follow too, so removing the agent still finds them.
            var unmoved: Set<String> = []
            moveRows(&tombstones, from: [existing], to: next, unmoved: &unmoved)
        }

        agents.removeAll { $0.id == next.id }
        agents.insert(next, at: 0)
        activeAgentID = next.id
        recordPersistence(store.upsertAgentResult(next))
        persistSelection()
        return next
    }

    /// The chat becomes a Tombstone: an empty row recording the later of the host's last-known `updated` and
    /// its last message time. A reply arrives after the host stamps its turn, so a chat used and deleted before
    /// the next restore stays deleted. Never the time of deletion. A chat from a previous identity is never
    /// merged with hosted history, so it needs no Tombstone.
    func deleteConversation(_ conversation: Conversation, currentDraft: String) {
        updateActiveDraft(currentDraft)
        let current = self.conversation(withID: conversation.id) ?? conversation
        let deleted: Result<Void, ConversationRepositoryError>
        if isFromPreviousIdentity(current) {
            deleted = store.deleteConversationResult(id: current.id)
        } else {
            var tombstone = current
            tombstone.tombstoneUpdated = (current.messages.map(\.createdAt) + [current.hostUpdated].compactMap { $0 }).max()
                ?? current.createdAt
            tombstone.messages = []
            tombstone.title = Conversation.defaultTitle
            tombstone.serverSession = nil
            tombstones.append(tombstone)
            deleted = store.upsertConversationResult(tombstone)
        }
        conversations.removeAll { $0.id == conversation.id }
        if activeConversationID == conversation.id {
            if let activeAgent {
                activeConversationID = conversations(for: activeAgent).first?.id
            } else {
                activeConversationID = nil
            }
        }
        draftsByConversationID[conversation.id] = nil
        store.saveDrafts(draftsByConversationID)
        workRoomStoresByConversationID[conversation.id] = nil
        failedDeliveryConversationIDs.remove(conversation.id)
        completedUnreadConversationIDs.remove(conversation.id)
        markActiveConversationViewed()
        recordPersistence(deleted)
        persistSelection()
    }

    func deleteAgent(_ agent: SavedAgent, currentDraft: String) {
        updateActiveDraft(currentDraft)
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
        agents.removeAll { $0.id == agent.id }
        conversations.removeAll { conversationBelongsToAgent($0, agent) }
        for tombstone in tombstones where conversationBelongsToAgent(tombstone, agent) {
            recordPersistence(store.deleteConversationResult(id: tombstone.id))
        }
        tombstones.removeAll { conversationBelongsToAgent($0, agent) }

        if activeAgentID == agent.id {
            activeAgentID = agents.first?.id
        }
        if let activeConversationID, deletedConversationIDs.contains(activeConversationID) {
            if let activeAgent {
                self.activeConversationID = conversations(for: activeAgent).first?.id
            } else {
                self.activeConversationID = nil
            }
        }

        for conversationID in deletedConversationIDs {
            draftsByConversationID[conversationID] = nil
            workRoomStoresByConversationID[conversationID] = nil
            failedDeliveryConversationIDs.remove(conversationID)
            completedUnreadConversationIDs.remove(conversationID)
            recordPersistence(store.deleteConversationResult(id: conversationID))
        }
        store.saveDrafts(draftsByConversationID)
        markActiveConversationViewed()
        recordPersistence(store.deleteAgentResult(id: agent.id))
        persistSelection()
    }

    func renameConversation(_ conversation: Conversation, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == conversation.id }),
              conversations[index].title != trimmed else {
            return
        }
        conversations[index].title = trimmed
        recordPersistence(store.upsertConversationResult(conversations[index]))
    }

    func searchConversations(_ query: String, for agent: SavedAgent? = nil) -> [Conversation] {
        let results: [Conversation]
        switch store.searchResult(query) {
        case .success(let conversations):
            results = conversations
        case .failure(let error):
            persistenceError = error
            results = []
        }
        let live = results.filter { !$0.isTombstone }
        guard let agent else {
            return live
        }
        return live.filter { conversationBelongsToAgent($0, agent) }
    }

    /// Receiving Device, after a Device Link: the giver's Agent Name list renames the agent with each Address
    /// and adds the ones missing; every other agent and the selection stay as they are. Throws the first
    /// save that failed, after applying the rest in memory.
    func applyAgentNames(_ list: [DeviceLinkAgentName]) throws {
        let plan = DeviceLinkAgentName.apply(list, to: agents, address: \.address)
        var changed: [SavedAgent] = []
        for (index, name) in plan.renames {
            agents[index].name = name
            changed.append(agents[index])
        }
        let added = plan.additions.map { SavedAgent(address: $0.address, name: $0.name) }
        agents.append(contentsOf: added)
        var firstFailure: ConversationRepositoryError?
        for agent in changed + added {
            if case .failure(let error) = store.upsertAgentResult(agent) {
                persistenceError = error
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    func upsertAgent(_ agent: SavedAgent) -> SavedAgent {
        var next = agent
        next.name = next.name.isEmpty ? SavedAgent.defaultName(for: next.address) : next.name
        next.updatedAt = Date()
        agents.removeAll { $0.id == next.id }
        agents.insert(next, at: 0)
        activeAgentID = next.id
        recordPersistence(store.upsertAgentResult(next))
        persistSelection()
        return next
    }

    func ensureDefaultConversation(
        for agent: SavedAgent,
        seed: Conversation,
        currentDraft: String
    ) {
        updateActiveDraft(currentDraft)
        if var existing = conversations(for: agent).first {
            if let session = seed.serverSession {
                existing.serverSession = session
            }
            existing.agentID = agent.id
            existing.agentAddress = agent.address
            activeConversationID = existing.id
            markActiveConversationViewed()
            upsert(existing)
            return
        }

        var conversation = seed
        conversation.agentID = agent.id
        conversation.agentAddress = agent.address
        conversations.insert(conversation, at: 0)
        refreshFailedDeliveryFlag(for: conversation)
        activeConversationID = conversation.id
        markActiveConversationViewed()
        recordPersistence(store.upsertConversationResult(conversation))
        persistSelection()
    }

    /// Stores a conversation (e.g. a fresh server session) without counting as activity:
    /// no updatedAt bump, no reordering, no agent touch.
    func replaceWithoutActivity(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        var next = conversation
        next.updatedAt = conversations[index].updatedAt
        conversations[index] = next
        recordPersistence(store.upsertConversationResult(next))
    }

    /// Adds restored conversations (or fills empty local ones) keeping the host's dates:
    /// no updatedAt bump and no agent touch, so a refresh never reshuffles the list. A Tombstone
    /// restored this way is a normal conversation again. A chat that already has messages only takes
    /// the host's `updated`: its messages are never replaced, so one sent while the fetch ran survives.
    /// A Tombstone passed back as one stays hidden and only records its new `updated`.
    func restore(_ restored: [Conversation]) {
        for conversation in restored {
            if conversation.isTombstone {
                // A Tombstone whose row has gone (agent removed mid-fetch) is dropped, never listed.
                if let index = tombstones.firstIndex(where: { $0.id == conversation.id }) {
                    tombstones[index] = conversation
                    recordPersistence(store.upsertConversationResult(conversation))
                }
                continue
            }
            // Its agent was removed while the fetch ran: saving it would leave an orphan row.
            if let agentID = conversation.agentID, agent(withID: agentID) == nil { continue }
            tombstones.removeAll { $0.id == conversation.id }
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                guard conversations[index].messages.isEmpty else {
                    conversations[index].hostUpdated = conversation.hostUpdated
                    recordPersistence(store.updateConversationMetadataResult(conversations[index]))
                    continue
                }
                conversations[index] = conversation
            } else {
                conversations.append(conversation)
            }
            refreshFailedDeliveryFlag(for: conversation)
            recordPersistence(store.upsertConversationResult(conversation))
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    func upsert(
        _ conversation: Conversation,
        persistence: ConversationPersistence = .full
    ) {
        var next = conversation
        next.updatedAt = Date()
        if let agent = agent(for: next) {
            next.agentID = agent.id
            next.agentAddress = agent.address
            touchAgent(id: agent.id)
            if let touched = self.agent(withID: agent.id) {
                recordPersistence(store.upsertAgentResult(touched))
            }
        }
        conversations.removeAll { $0.id == next.id }
        conversations.insert(next, at: 0)
        refreshFailedDeliveryFlag(for: next)

        switch persistence {
        case .full:
            recordPersistence(store.upsertConversationResult(next))
        case .message(let id):
            guard let message = next.messages.first(where: { $0.id == id }) else {
                recordPersistence(store.upsertConversationResult(next))
                persistSelection()
                return
            }
            recordPersistence(store.upsertMessageResult(message, in: next))
        case .metadata:
            recordPersistence(store.updateConversationMetadataResult(next))
        }
        persistSelection()
    }

    func agent(for conversation: Conversation) -> SavedAgent? {
        if let agentID = conversation.agentID, let agent = agent(withID: agentID) {
            return agent
        }
        if conversation.agentID != nil {
            return nil
        }
        return agents.first { $0.address == conversation.agentAddress }
    }

    func conversationBelongsToAgent(_ conversation: Conversation, _ agent: SavedAgent) -> Bool {
        if let agentID = conversation.agentID {
            return agentID == agent.id
        }
        return conversation.agentAddress == agent.address
    }

    func markCompletedUnread(conversationID: String) {
        guard conversationID != activeConversationID,
              conversation(withID: conversationID) != nil else {
            return
        }
        completedUnreadConversationIDs.insert(conversationID)
    }

    func clearCompletedUnread(conversationID: String) {
        completedUnreadConversationIDs.remove(conversationID)
    }

    private func refreshFailedDeliveryFlag(for conversation: Conversation) {
        if conversation.messages.contains(where: { $0.deliveryState == .failed }) {
            failedDeliveryConversationIDs.insert(conversation.id)
        } else {
            failedDeliveryConversationIDs.remove(conversation.id)
        }
    }

    private func touchAgent(id: String) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else {
            return
        }
        var agent = agents.remove(at: index)
        agent.updatedAt = Date()
        agents.insert(agent, at: 0)
    }

    private func markActiveConversationViewed() {
        guard let activeConversationID else {
            return
        }
        completedUnreadConversationIDs.remove(activeConversationID)
    }

    private func persistSelection() {
        store.saveActive(agentID: activeAgentID, conversationID: activeConversationID)
    }

    private func recordPersistence(_ result: Result<Void, ConversationRepositoryError>) {
        if case .failure(let error) = result {
            persistenceError = error
        }
    }
}
