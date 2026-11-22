import Foundation

extension ChatViewModel {
    func sendPrompt() {
        // A Station has no outer chat: the host refuses INPUT, so nothing is sent.
        guard !(activeAgent.map(isStation) ?? false) else {
            return
        }
        stopVoiceInput()
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let files = pendingFiles
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty else {
            return
        }
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        switch deliveryCoordinator.enqueuePrompt(text, images: images, files: files) {
        case .queued:
            prompt = ""
            pendingImages = []
            pendingFiles = []
            errorMessage = nil
            // Runs can take minutes, so this is when notifications start to matter.
            chatNotifier?.requestPermissionIfNeeded()
        case .rejected(let message):
            errorMessage = message
        }
    }

    /// A Control Center button's `/skill args` line, already checked by the kit pane, goes out as a
    /// normal, visible user message
    func runControlCenterSkill(_ message: String) {
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        switch deliveryCoordinator.enqueuePrompt(message, images: [], files: []) {
        case .queued:
            errorMessage = nil
        case .rejected(let reason):
            errorMessage = reason
        }
    }

    func retryMessage(_ message: ChatMessage) {
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        if deliveryCoordinator.retryMessage(message) {
            errorMessage = nil
            failureByMessageID[message.id] = nil
        }
    }

    /// Only your latest sent message can be edited, and never while the agent is working.
    func canEdit(_ message: ChatMessage) -> Bool {
        guard message.role == .user, let latest = latestSentPromptIndex() else {
            return false
        }
        return activeConversation?.messages[latest].id == message.id
    }

    /// Only the agent's latest reply, to your latest message, can be retried.
    func canRetry(_ message: ChatMessage) -> Bool {
        guard message.role == .agent,
              let latest = latestSentPromptIndex(),
              let messages = activeConversation?.messages,
              let replyIndex = messages.lastIndex(where: { $0.role == .agent }),
              replyIndex > latest else {
            return false
        }
        return messages[replyIndex].id == message.id
    }

    private func latestSentPromptIndex() -> Int? {
        // A chat from a previous identity never sends again, so nothing in it is redone.
        guard !isProcessing,
              activeConversation.map(isFromPreviousIdentity) != true,
              let messages = activeConversation?.messages,
              let index = messages.lastIndex(where: { $0.role == .user }),
              messages[index].deliveryState == .sent else {
            return nil
        }
        return index
    }

    /// Has the agent answer your latest message again; its old answer is replaced in place.
    func retryLatestReply() {
        redoLatestTurn(editedText: nil)
    }

    /// Changes your latest message in place and has the agent answer it again.
    func editLatestMessage(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        redoLatestTurn(editedText: trimmed)
    }

    private func redoLatestTurn(editedText: String?) {
        guard let conversationID = activeConversationID, !isProcessing else {
            return
        }
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        if deliveryCoordinator.redoLatestTurn(in: conversationID, editedText: editedText) {
            errorMessage = nil
        } else {
            errorMessage = "Couldn't redo that. Send it again as a new message instead."
        }
    }

    func flushQueuedMessages() async {
        deliveryCoordinator.setDeliveryEnabled(!isOffline)
        await deliveryCoordinator.flushQueuedMessages()
    }

    func stopActiveResponse() {
        deliveryCoordinator.stopActiveResponse()
    }
}
