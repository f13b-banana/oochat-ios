import Foundation
import ConnectOnionKit

extension ChatViewModel {
    func sendPrompt() {
        stopVoiceInput()
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let files = pendingFiles
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty else {
            return
        }
        if images.isEmpty, files.isEmpty, runExecIfCommand(text) {
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

    /// `/exec <tool> [name=value ...]` runs one tool on the host directly. Returns true when the text
    /// was an /exec command, usable or not; never sent to the agent as a prompt.
    private func runExecIfCommand(_ text: String) -> Bool {
        switch OIPExecCommand.parse(text) {
        case .notACommand:
            return false
        case .invalid(let message):
            errorMessage = message
        case .command(let command):
            guard !isOffline else {
                errorMessage = "You're offline. Reconnect to run a tool."
                return true
            }
            switch deliveryCoordinator.runExec(command) {
            case .queued:
                prompt = ""
                errorMessage = nil
            case .rejected(let message):
                errorMessage = message
            }
        }
        return true
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
