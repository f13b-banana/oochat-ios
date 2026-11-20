import ConnectOnionKit

extension ChatViewModel {
    func upsertAgent(_ agent: SavedAgent) -> SavedAgent {
        let next = conversationState.upsertAgent(agent)
        agentAddressDraft = next.address
        return next
    }

    func ensureDefaultConversation(for agent: SavedAgent, seed: Conversation) {
        var normalizedSeed = seed
        if let existing = conversations(for: agent).first,
           let session = seed.serverSession {
            normalizedSeed.serverSession = HostedAgentSessionState.applying(
                existing.mode,
                to: session,
                conversationID: existing.id
            )
        }
        conversationState.ensureDefaultConversation(
            for: agent,
            seed: normalizedSeed,
            currentDraft: prompt
        )
        prompt = conversationState.activeDraft
        restorePendingAttachmentDrafts()
    }

#if DEBUG
    /// Stores conversation state supplied by tests through the normal persistence path.
    func upsertForTesting(_ conversation: Conversation) {
        upsert(conversation)
    }
#endif

    func upsert(
        _ conversation: Conversation,
        persistence: ConversationPersistence = .full
    ) {
        conversationState.upsert(conversation, persistence: persistence)
    }

    func agent(for conversation: Conversation) -> SavedAgent? {
        conversationState.agent(for: conversation)
    }

    private func conversationBelongsToAgent(_ conversation: Conversation, _ agent: SavedAgent) -> Bool {
        conversationState.conversationBelongsToAgent(conversation, agent)
    }

    func apply(_ update: HostedAgentSessionUpdate, forConversationID conversationID: String) {
        switch update {
        case .dashboard(let dashboard):
            dashboards[conversationID] = dashboard
        }
    }

    var activeDashboard: OIPDashboard? {
        activeConversationID.flatMap { dashboards[$0] }
    }
}
