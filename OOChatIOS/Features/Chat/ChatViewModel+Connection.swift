import Foundation

extension ChatViewModel {
    func connectToAgent() async -> SavedAgent? {
        let address = agentAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostedAgentClient.isHostedAgentAddress(address) else {
            let message = "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
            errorMessage = message
            return nil
        }
        guard !isOffline else {
            let message = "You appear to be offline. Check your connection and try again."
            errorMessage = message
            return nil
        }
        guard !isConnecting else {
            return nil
        }

        isConnecting = true
        errorMessage = nil

        let agent: SavedAgent
        if let activeAgent, activeAgent.address == address {
            agent = activeAgent
        } else {
            agent = agents.first { $0.address == address } ?? SavedAgent(address: address)
        }
        var conversation = conversations(for: agent).first ?? Conversation(agentID: agent.id, agentAddress: address)
        recoveryCoordinator.setConnectionState(.reconnecting, forConversationID: conversation.id)

        do {
            let result = try await client.connect(agentAddress: address, conversation: conversation)
            deliveryCoordinator.noteSessionModes(result.sessionModes, agentAddress: address)
            if let session = result.serverSession {
                conversation.mode = HostedAgentSessionState.mode(from: session, fallback: conversation.mode)
                conversation.serverSession = HostedAgentSessionState.applying(
                    conversation.mode,
                    to: session,
                    conversationID: conversation.id
                )
            }
            let savedAgent = upsertAgent(agent)
            ensureDefaultConversation(for: savedAgent, seed: conversation)
            recoveryCoordinator.setConnectionState(.connected, forConversationID: conversation.id)
            isConnecting = false
            return savedAgent
        } catch {
            handleConnectionFailure(error, conversation: conversation)
            return nil
        }
    }

    private func handleConnectionFailure(_ error: Error, conversation: Conversation) {
        let message = error.localizedDescription
        // Remove state for a conversation that may never have been persisted.
        if conversationState.conversation(withID: conversation.id) == nil {
            recoveryCoordinator.removeConnectionState(forConversationID: conversation.id)
        } else {
            recoveryCoordinator.setConnectionState(.disconnected, forConversationID: conversation.id)
        }
        if !presentIncompatibility(error) {
            errorMessage = message
        }
        isConnecting = false
    }

    func dismissOfflineBanner() {
        recoveryCoordinator.dismissOfflineBanner()
    }

    /// Tries a real reconnect when the network monitor has not reported recovery yet.
    func retryConnectivity() {
        recoveryCoordinator.retryConnectivity()
    }

    /// Opens the active chat's socket so the agent's Control Center arrives (connect on open).
    func connectActiveConversationOnOpen() {
        recoveryCoordinator.connectOnOpen(conversationID: activeConversationID)
    }

    func reconnect() async {
        errorMessage = nil
        await recoveryCoordinator.reconnectActiveConversation()
    }

    func dismissError() {
        errorMessage = nil
    }

    /// -32010 gets its own screen instead of the red banner. Returns false for every other error.
    @discardableResult
    func presentIncompatibility(_ error: Error) -> Bool {
        guard let value = (error as? HostedAgentClientError)?.incompatibility else {
            return false
        }
        // Final: HostedAgentConnection.canResume(after:) refuses this error, so no reconnect follows.
        incompatibility = value
        errorMessage = nil
        return true
    }

    func dismissIncompatibility() {
        incompatibility = nil
    }

    /// A message didn't go through: the reason goes on that message, not in a banner.
    func presentDeliveryError(_ error: Error, messageID: String, forConversationID conversationID: String) {
        if activeConversationID == conversationID, presentIncompatibility(error) {
            return
        }
        failureByMessageID[messageID] = HostedAgentClientError.chatFailure(for: error)
    }

    /// A reconnect failed. A lost connection shows in the chat header ("Can't connect · Retry",
    /// ChatConnectionStatus), so only other problems get the banner, in plain words.
    func presentConnectionError(_ error: Error, forConversationID conversationID: String) {
        guard activeConversationID == conversationID else {
            return
        }
        if presentIncompatibility(error) {
            return
        }
        guard !HostedAgentClientError.isConnectivityFailure(error) else {
            return
        }
        let agentName = activeAgent?.name ?? "the agent"
        errorMessage = HostedAgentClientError.chatFailure(for: error).sentence(agentName: agentName)
    }

    /// The plain reason a message wasn't sent, and the raw text for "Copy error details".
    func failure(forMessageID messageID: String) -> (reason: String, details: String?)? {
        guard let failure = failureByMessageID[messageID] else {
            return nil
        }
        return (failure.sentence(agentName: activeAgent?.name ?? "the agent"), failure.details)
    }
}
