import Combine
import ConnectOnionKit
import Foundation

enum MessageEnqueueResult {
    case queued
    case rejected(String)
}

@MainActor
final class MessageDeliveryCoordinator: ObservableObject {
    private struct PreparedDelivery {
        let agent: SavedAgent
        let conversation: Conversation
        let message: ChatMessage
    }

    @Published private var processingConversationIDs: Set<String> = []
    @Published private(set) var availableModesByAgentAddress: [String: [OIPPermissionMode]] = [:]
    var onConnectionStateChange: ((String, ConversationConnectionState) -> Void)?
    var connectionState: ((String) -> ConversationConnectionState)?
    var onDeliveryError: ((String, Error) -> Void)?
    var onDeliveriesIdle: (() -> Void)?
    // conversationID, the confirmed mode, and turns_left (full access only)
    var onModeChanged: ((String, OIPPermissionMode, Int?) -> Void)?

    var hasActiveDeliveries: Bool {
        !deliveryTasksByConversationID.isEmpty
    }

    private var deliveryTasksByConversationID: [String: Task<Void, Never>] = [:]
    private var activeMessageIDsByConversationID: [String: String] = [:]
    private var pausedConversationIDs: Set<String> = []
    private var isDeliveryEnabled = true
    /// The most recent `/exec` run, kept so tests can wait for it.
    private(set) var lastExecTask: Task<Void, Never>?

    private let conversationState: ConversationState
    private let interactionCoordinator: InteractionCoordinator
    private let transport: HostedAgentConversationTransport

    init(
        conversationState: ConversationState,
        interactionCoordinator: InteractionCoordinator,
        transport: HostedAgentConversationTransport
    ) {
        self.conversationState = conversationState
        self.interactionCoordinator = interactionCoordinator
        self.transport = transport
    }

    deinit {
        deliveryTasksByConversationID.values.forEach { $0.cancel() }
    }

    func setDeliveryEnabled(_ isEnabled: Bool) {
        isDeliveryEnabled = isEnabled
    }

    func isProcessing(conversationID: String) -> Bool {
        processingConversationIDs.contains(conversationID)
    }

    func task(for conversationID: String?) -> Task<Void, Never>? {
        guard let conversationID else {
            return nil
        }
        return deliveryTasksByConversationID[conversationID]
    }

    func enqueuePrompt(
        _ text: String,
        images: [ChatImageAttachment] = [],
        files: [ChatFileAttachment] = []
    ) -> MessageEnqueueResult {
        guard var conversation = conversationState.activeConversation,
              let agent = conversationState.agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return .rejected("Connect to an agent before sending a message.")
        }

        conversation.agentID = agent.id
        conversation.agentAddress = agent.address
        if conversation.title == Conversation.defaultTitle {
            conversation.title = Self.title(
                from: text,
                imageCount: images.count,
                fileCount: files.count
            )
        }
        conversation.messages.append(
            ChatMessage(
                role: .user,
                content: text,
                deliveryState: .queued,
                images: images,
                files: files
            )
        )
        conversationState.clearCompletedUnread(conversationID: conversation.id)
        conversationState.upsert(conversation)
        pausedConversationIDs.remove(conversation.id)

        if isDeliveryEnabled {
            startNextQueuedMessage(in: conversation.id)
        }
        return .queued
    }

    @discardableResult
    func retryMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .user,
              message.deliveryState == .failed || message.deliveryState == .cancelled,
              var conversation = conversationState.conversations.first(where: { candidate in
                  candidate.messages.contains { $0.id == message.id }
              }),
              let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else {
            return false
        }

        conversation.messages[index].deliveryState = .queued
        conversationState.clearCompletedUnread(conversationID: conversation.id)
        conversationState.upsert(conversation)
        pausedConversationIDs.remove(conversation.id)
        if isDeliveryEnabled {
            startNextQueuedMessage(in: conversation.id)
        }
        return true
    }

    func flushQueuedMessages() async {
        guard isDeliveryEnabled else {
            return
        }

        for conversation in conversationState.conversations {
            startNextQueuedMessage(in: conversation.id)
        }

        while isDeliveryEnabled {
            let tasks = Array(deliveryTasksByConversationID.values)
            guard !tasks.isEmpty else {
                break
            }
            for task in tasks {
                await task.value
            }
        }
    }

    func stopActiveResponse() {
        guard let conversationID = conversationState.activeConversationID,
              let task = deliveryTasksByConversationID[conversationID],
              let conversation = conversationState.conversation(withID: conversationID),
              let agent = conversationState.agent(for: conversation) else {
            return
        }

        pausedConversationIDs.insert(conversationID)
        guard interactionCoordinator.cancelInteractions(for: conversationID) else {
            task.cancel()
            return
        }

        let transport = transport
        Task {
            await transport.waitForPendingInteractionResponses(
                agentAddress: agent.address,
                conversationID: conversationID
            )
            task.cancel()
        }
    }

    func cancelDeliveryAndInteractions(for conversationID: String) {
        interactionCoordinator.cancelInteractions(for: conversationID)
        deliveryTasksByConversationID[conversationID]?.cancel()
        pausedConversationIDs.remove(conversationID)
    }

    /// `/exec`: run one tool on the host without the LLM. It appears as a tool card that goes
    /// Running, then Completed or Failed. It is not a delivery: no queued user message,
    /// no "waiting" row, no call to `onDeliveryError` or `onConnectionStateChange`.
    /// Tool that fails leaves the session exactly as it was.
    func runExec(_ command: OIPExecCommand) -> MessageEnqueueResult {
        guard var conversation = conversationState.activeConversation,
              let agent = conversationState.agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return .rejected("Connect to an agent before running a tool.")
        }
        let execID = UUID().uuidString
        let cardID = ChatMessage.directExecIDPrefix + execID
        conversation.messages.append(
            ChatMessage(
                id: cardID,
                role: .tool,
                content: "",
                toolName: command.tool,
                toolArguments: command.args,
                toolState: .running
            )
        )
        conversationState.upsert(conversation, persistence: .message(id: cardID))

        let snapshot = conversation
        let transport = transport
        lastExecTask = Task { [weak self, transport] in
            let event: HostedAgentEvent
            do {
                let reply = try await transport.execTool(
                    agentAddress: agent.address,
                    conversation: snapshot,
                    execID: execID,
                    tool: command.tool,
                    args: command.args
                )
                event = .toolResult(
                    id: cardID,
                    name: command.tool,
                    output: reply.displayText,
                    state: reply.isSuccess ? .completed : .failed
                )
            } catch {
                event = .toolResult(
                    id: cardID,
                    name: command.tool,
                    output: error.localizedDescription,
                    state: .failed
                )
            }
            self?.apply(event, toConversationID: snapshot.id)
        }
        return .queued
    }

    @discardableResult
    private func startNextQueuedMessage(in conversationID: String) -> Bool {
        guard isDeliveryEnabled,
              !pausedConversationIDs.contains(conversationID),
              deliveryTasksByConversationID[conversationID] == nil,
              let conversation = conversationState.conversation(withID: conversationID),
              // A .transmitted message comes first: it was sent before the app last closed and
              // must be settled (never resent) before anything queued after it goes out.
              let message = conversation.messages.first(where: {
                  $0.role == .user && ($0.deliveryState == .transmitted || $0.deliveryState == .queued)
              }) else {
            return false
        }

        activeMessageIDsByConversationID[conversationID] = message.id
        processingConversationIDs.insert(conversationID)
        if connectionState?(conversationID) != .connected {
            onConnectionStateChange?(conversationID, .reconnecting)
        }

        guard let deliveryTask = makeDeliveryTask(
            messageID: message.id,
            conversationID: conversationID
        ) else {
            activeMessageIDsByConversationID[conversationID] = nil
            processingConversationIDs.remove(conversationID)
            return false
        }
        deliveryTasksByConversationID[conversationID] = deliveryTask
        return true
    }

    private func makeDeliveryTask(
        messageID: String,
        conversationID: String
    ) -> Task<Void, Never>? {
        guard let delivery = prepareDelivery(
            messageID: messageID,
            conversationID: conversationID
        ) else {
            return nil
        }

        let transport = transport
        let handlers = promptHandlers(messageID: messageID, conversationID: conversationID)
        return Task { [weak self, transport] in
            defer {
                self?.deliveryDidFinish(
                    messageID: messageID,
                    conversationID: conversationID
                )
            }
            do {
                let result = try await Self.deliver(delivery, over: transport, handlers: handlers)
                try Task.checkCancellation()
                self?.completeDelivery(
                    result,
                    messageID: messageID,
                    conversationID: conversationID
                )
            } catch is CancellationError {
                self?.cancelDelivery(messageID: messageID, conversationID: conversationID)
            } catch {
                self?.failDelivery(
                    error,
                    messageID: messageID,
                    conversationID: conversationID
                )
            }
        }
    }

    // An earlier run of the app may already have sent a .transmitted message, so ask the host
    // what happened to it instead of sending it again.
    private static func deliver(
        _ delivery: PreparedDelivery,
        over transport: HostedAgentConversationTransport,
        handlers: HostedAgentPromptHandlers
    ) async throws -> HostedAgentResult {
        let prompt = transportPrompt(for: delivery.message)
        if delivery.message.deliveryState == .transmitted {
            return try await transport.resumePrompt(
                agentAddress: delivery.agent.address,
                conversation: delivery.conversation,
                prompt: prompt,
                handlers: handlers
            )
        }
        return try await transport.sendPrompt(
            agentAddress: delivery.agent.address,
            conversation: delivery.conversation,
            prompt: prompt,
            handlers: handlers
        )
    }

    private func promptHandlers(messageID: String, conversationID: String) -> HostedAgentPromptHandlers {
        let interactionCoordinator = interactionCoordinator
        let conversationState = conversationState
        return HostedAgentPromptHandlers(
            onEvent: { [weak self] event in
                self?.apply(event, toConversationID: conversationID)
            },
            onInteraction: { interaction in
                await Self.handleInteraction(
                    interaction,
                    conversationID: conversationID,
                    coordinator: interactionCoordinator,
                    conversationState: conversationState
                )
            },
            onInputDispatched: { [weak self] in
                self?.markTransmitted(messageID: messageID, conversationID: conversationID)
            }
        )
    }

    private func prepareDelivery(
        messageID: String,
        conversationID: String
    ) -> PreparedDelivery? {
        guard var conversation = conversationState.conversation(withID: conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.role == .user,
              let agent = conversationState.agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return nil
        }
        conversation.messages.append(ChatMessage(role: .thinking, content: "Waiting for hosted agent…"))
        conversationState.upsert(conversation)
        return PreparedDelivery(agent: agent, conversation: conversation, message: message)
    }

    private static func transportPrompt(for message: ChatMessage) -> HostedAgentPrompt {
        HostedAgentPrompt(
            text: message.content,
            images: message.images.map(\.dataURL),
            files: message.files.map {
                HostedAgentFilePayload(name: $0.name, data: $0.dataURL)
            }
        )
    }

    private static func handleInteraction(
        _ interaction: HostedAgentInteraction,
        conversationID: String,
        coordinator: InteractionCoordinator,
        conversationState: ConversationState
    ) async -> HostedAgentInteractionDecision {
        await coordinator.handle(interaction, conversationID: conversationID) {
            conversationState.conversation(withID: conversationID) != nil
        }
    }

    private func deliveryDidFinish(messageID: String, conversationID: String) {
        guard activeMessageIDsByConversationID[conversationID] == messageID else {
            return
        }
        deliveryTasksByConversationID[conversationID] = nil
        activeMessageIDsByConversationID[conversationID] = nil
        processingConversationIDs.remove(conversationID)
        if isDeliveryEnabled, !pausedConversationIDs.contains(conversationID) {
            startNextQueuedMessage(in: conversationID)
        }
        if deliveryTasksByConversationID.isEmpty {
            onDeliveriesIdle?()
        }
    }

    // Saved before the INPUT bytes leave. If the app dies before the reply, the relaunch sees
    // .transmitted and settles the message with resumePrompt instead of sending it twice.
    private func markTransmitted(messageID: String, conversationID: String) {
        guard activeMessageIDsByConversationID[conversationID] == messageID,
              var updated = conversationState.conversation(withID: conversationID),
              let index = updated.messages.firstIndex(where: { $0.id == messageID }),
              updated.messages[index].deliveryState == .queued else {
            return
        }
        updated.messages[index].deliveryState = .transmitted
        conversationState.upsert(updated, persistence: .message(id: messageID))
    }

    private func completeDelivery(
        _ result: HostedAgentResult,
        messageID: String,
        conversationID: String
    ) {
        guard var updated = conversationState.conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .sent
        }
        noteSessionModes(result.sessionModes, agentAddress: updated.agentAddress)
        if let session = result.serverSession {
            updated.mode = HostedAgentSessionState.mode(from: session, fallback: updated.mode)
            updated.serverSession = HostedAgentSessionState.applying(
                updated.mode,
                to: session,
                conversationID: updated.id
            )
        }
        // An empty output would otherwise render as a blank bubble.
        if let output = result.output, !output.isEmpty {
            updated.messages.append(ChatMessage(role: .agent, content: output))
        }
        onConnectionStateChange?(conversationID, .connected)
        conversationState.upsert(updated)
        conversationState.markCompletedUnread(conversationID: conversationID)
    }

    private func failDelivery(
        _ error: Error,
        messageID: String,
        conversationID: String
    ) {
        guard var updated = conversationState.conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .failed
        }
        conversationState.clearCompletedUnread(conversationID: conversationID)
        onDeliveryError?(conversationID, error)
        onConnectionStateChange?(conversationID, .disconnected)
        conversationState.upsert(updated)
    }

    private func cancelDelivery(messageID: String, conversationID: String) {
        guard var updated = conversationState.conversation(withID: conversationID) else {
            return
        }
        updated.messages.removeAll { $0.role == .thinking }
        if let index = updated.messages.firstIndex(where: { $0.id == messageID }) {
            updated.messages[index].deliveryState = .cancelled
        }
        conversationState.clearCompletedUnread(conversationID: conversationID)
        onConnectionStateChange?(conversationID, .disconnected)
        conversationState.upsert(updated)
    }

    func noteSessionModes(_ sessionModes: OIPSessionModes?, agentAddress: String) {
        guard let sessionModes else {
            return
        }

        availableModesByAgentAddress[agentAddress] = sessionModes.availableModes.map(\.id)
    }

    func apply(_ event: HostedAgentEvent, toConversationID conversationID: String) {
        guard var conversation = conversationState.conversation(withID: conversationID) else {
            return
        }

        let persistence: ConversationPersistence
        switch event {
        case .toolCall(let id, let name, let arguments):
            guard !conversation.messages.contains(where: { $0.id == id }) else {
                return
            }
            conversation.messages.append(
                ChatMessage(
                    id: id,
                    role: .tool,
                    content: "",
                    toolName: name,
                    toolArguments: arguments,
                    toolState: .running
                )
            )
            persistence = .message(id: id)
        case .toolResult(let id, let name, let output, let state):
            if let index = conversation.messages.firstIndex(where: { $0.id == id && $0.role == .tool }) {
                conversation.messages[index].toolName = name ?? conversation.messages[index].toolName
                conversation.messages[index].content = output
                conversation.messages[index].toolState = state
            } else {
                conversation.messages.append(
                    ChatMessage(
                        id: id,
                        role: .tool,
                        content: output,
                        toolName: name ?? "tool",
                        toolState: state
                    )
                )
            }
            persistence = .message(id: id)
        case .modeChanged(let protocolMode, let turnsLeft):
            conversation.mode = ChatMode(permissionMode: protocolMode)
            conversation.serverSession = HostedAgentSessionState.applying(
                conversation.mode,
                to: conversation.serverSession,
                conversationID: conversationID
            )
            onModeChanged?(conversationID, protocolMode, turnsLeft)
            persistence = .metadata
        case .modeChangeFailed, .modeChangeTimedOut:
            return
        }

        conversationState.upsert(conversation, persistence: persistence)
    }

    private static func title(from text: String, imageCount: Int, fileCount: Int) -> String {
        guard !text.isEmpty else {
            if imageCount > 0, fileCount > 0 {
                return "Attachments"
            }
            if imageCount > 0 {
                return imageCount == 1 ? "Photo" : "\(imageCount) Photos"
            }
            return fileCount == 1 ? "File" : "\(fileCount) Files"
        }
        if text.count > 38 {
            return String(text.prefix(35)) + "..."
        }
        return text
    }
}
