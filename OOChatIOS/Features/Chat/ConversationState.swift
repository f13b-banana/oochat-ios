import Combine
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

    private var draftsByConversationID: [String: String] = [:]
    private let store: ConversationRepository

    init(store: ConversationRepository) {
        self.store = store

        let snapshotResult = store.loadResult()
        let snapshot = (try? snapshotResult.get()) ?? .empty
        agents = snapshot.agents
        conversations = snapshot.conversations
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
        guard let activeConversationID else {
            return
        }
        draftsByConversationID[activeConversationID] = draft
    }

    func agent(withID id: String) -> SavedAgent? {
        agents.first { $0.id == id }
    }

    func conversation(withID id: String) -> Conversation? {
        conversations.first { $0.id == id }
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
        }

        agents.removeAll { $0.id == next.id }
        agents.insert(next, at: 0)
        activeAgentID = next.id
        recordPersistence(store.upsertAgentResult(next))
        persistSelection()
        return next
    }

    func deleteConversation(_ conversation: Conversation, currentDraft: String) {
        updateActiveDraft(currentDraft)
        conversations.removeAll { $0.id == conversation.id }
        if activeConversationID == conversation.id {
            if let activeAgent {
                activeConversationID = conversations(for: activeAgent).first?.id
            } else {
                activeConversationID = nil
            }
        }
        draftsByConversationID[conversation.id] = nil
        failedDeliveryConversationIDs.remove(conversation.id)
        completedUnreadConversationIDs.remove(conversation.id)
        markActiveConversationViewed()
        recordPersistence(store.deleteConversationResult(id: conversation.id))
        persistSelection()
    }

    func deleteAgent(_ agent: SavedAgent, currentDraft: String) {
        updateActiveDraft(currentDraft)
        let deletedConversationIDs = Set(conversations(for: agent).map(\.id))
        agents.removeAll { $0.id == agent.id }
        conversations.removeAll { conversationBelongsToAgent($0, agent) }

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
            failedDeliveryConversationIDs.remove(conversationID)
            completedUnreadConversationIDs.remove(conversationID)
            recordPersistence(store.deleteConversationResult(id: conversationID))
        }
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
        guard let agent else {
            return results
        }
        return results.filter { conversationBelongsToAgent($0, agent) }
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
