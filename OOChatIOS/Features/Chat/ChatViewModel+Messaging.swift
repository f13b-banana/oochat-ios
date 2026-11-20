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
