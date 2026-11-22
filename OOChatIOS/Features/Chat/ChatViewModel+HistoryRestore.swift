import Foundation

extension ChatViewModel {
    /// Launch, return to foreground, pull-to-refresh and a link that replaced the key. No timer.
    func refreshHistory() async {
        for agent in agents {
            await restoreHistory(for: agent)
        }
    }

    func restoreHistory(for agent: SavedAgent) async {
        let fetchedAs = identity?.address
        // Per Address too, so a link's restore runs even while one as the old Address is in flight.
        let key = "\(agent.id) \(fetchedAs ?? "")"
        guard let fetcher = historyFetcher, restoresInFlight.insert(key).inserted else { return }
        defer { restoresInFlight.remove(key) }
        do {
            let sessions = try await fetcher.sessions(agentAddress: agent.address)
            // Fetched as an Address a link has since replaced: those sessions belong to the old identity.
            guard identity?.address == fetchedAs else { return }
            // A chat from a previous identity is never merged with hosted history.
            conversationState.restore(
                HistoryRestore.merge(
                    sessions,
                    agent: agent,
                    into: conversationState.conversations + conversationState.tombstones
                )
                    .filter { !conversationState.isFromPreviousIdentity($0) }
            )
            restoreStates[agent.id] = .restored
        } catch {
            // A cancelled refresh (view gone, pull released) says nothing about the agent.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            restoreStates[agent.id] = HistoryRestore.state(for: error)
        }
    }

    /// Pending agents retry the next time one of their chats connects.
    func retryPendingHistory(afterConnecting conversationID: String) {
        guard let conversation = conversationState.conversation(withID: conversationID),
              let agent = conversationState.agent(for: conversation),
              restoreStates[agent.id] == .pending else { return }
        Task { await restoreHistory(for: agent) }
    }
}
