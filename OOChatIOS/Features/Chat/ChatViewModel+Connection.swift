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

        let agent = conversationState.agent(withAddress: address) ?? SavedAgent(address: address)
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
        retryableErrorMessage = nil
        await recoveryCoordinator.reconnectActiveConversation()
    }

    /// A Device Link replaced this device's key. The chats made under `previousAddress` become
    /// Previous-Identity Conversations and lose their resume bookmarks, since the host won't resume
    /// them for the new Address. Every agent connection signed in as the old Address, so all of them
    /// close; the open chat reconnects only if it is a current one.
    func adoptReplacedIdentity(previousAddress: String) async {
        var loadError: Error?
        do {
            identity = try identityStore.loadOrCreateIdentity()
        } catch {
            // No current Address: every stamped chat stays locked rather than signing as an unknown one.
            identity = nil
            loadError = error
        }
        let bookmarks = HostedAgentBookmarkStore()
        for conversation in conversationState.stampForReplace(previousAddress: previousAddress) {
            bookmarks.remove(conversationID: conversation.id)
            // A card or Control Center pane left open from before the link would act as the new Address.
            cancelPendingInteractions(forConversationID: conversation.id)
            forgetDashboard(forConversationID: conversation.id)
        }
        await client.disconnectAll()
        await reconnect()
        // The new Address owns its own Hosted History, so the chat list fills now, not at the next refresh.
        await refreshHistory()
        // After the reconnect, which clears the banner, so a failed reload stays visible.
        if let loadError {
            errorMessage = loadError.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
        retryableErrorMessage = nil
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
        let sentence = HostedAgentClientError.chatFailure(for: error).sentence(agentName: agentName)
        retryableErrorMessage = sentence
        errorMessage = sentence
    }

    /// The error banner offers Retry only for a failed reconnect.
    var canRetryError: Bool {
        errorMessage != nil && errorMessage == retryableErrorMessage
    }

    /// The plain reason a message wasn't sent, and the raw text for "Copy error details".
    func failure(forMessageID messageID: String) -> (reason: String, details: String?)? {
        guard let failure = failureByMessageID[messageID] else {
            return nil
        }
        return (failure.sentence(agentName: activeAgent?.name ?? "the agent"), failure.details)
    }
}
