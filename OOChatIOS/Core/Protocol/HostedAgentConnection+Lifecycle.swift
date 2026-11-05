import ConnectOnionKit
import Foundation

extension HostedAgentConnection {
    func handle(_ frame: [String: JSONValue], generation: Int) async {
        guard generation == socketGeneration else {
            return
        }
        lastNetworkActivityAt = Date()

        switch frame["type"]?.stringValue {
        case "PING":
            await handlePing(generation: generation)
        case "CONNECTED":
            await handleConnected(frame, generation: generation)
        case "OUTPUT":
            handleOutput(frame)
        case "tool_call", "tool_result", "mode_changed":
            await handleEvent(frame)
        case "approval_needed", "APPROVAL_NEEDED", "ulw_turns_reached", "plan_review", "ask_user":
            await handleInteraction(frame, generation: generation)
        case "ERROR":
            failConnection(
                HostedAgentClientError.server(messageText(frame)),
                generation: generation
            )
        default:
            break
        }
    }

    private func handlePing(generation: Int) async {
        guard let socket else {
            return
        }
        do {
            try await send(["type": .string("PONG")], over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func handleConnected(_ frame: [String: JSONValue], generation: Int) async {
        updateServerSession(from: frame)
        connectionStatus = frame["status"]?.stringValue
        setState(.connected)
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        let result = HostedAgentResult(
            output: nil,
            endpointLabel: endpoint?.label ?? key.agentAddress,
            serverSession: serverSession
        )
        let waiters = Array(connectWaiters.values)
        connectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
        await resumePendingPrompt(from: frame, generation: generation)
    }

    private func handleOutput(_ frame: [String: JSONValue]) {
        updateServerSession(from: frame)
        connectionStatus = "connected"
        resumeAttemptsUsed = 0
        guard let pending = pendingPrompt else {
            return
        }
        pendingPrompt = nil
        cancelInteractionTasks()
        pending.continuation.resume(
            returning: HostedAgentResult(
                output: messageText(frame),
                endpointLabel: endpoint?.label ?? key.agentAddress,
                serverSession: serverSession
            )
        )
    }

    private func handleEvent(_ frame: [String: JSONValue]) async {
        guard let pending = pendingPrompt, let event = HostedAgentEvent.from(frame) else {
            return
        }
        await pending.onEvent?(event)
    }

    private func handleInteraction(_ frame: [String: JSONValue], generation: Int) async {
        guard let pending = pendingPrompt else {
            return
        }
        guard let interaction = HostedAgentInteraction.from(frame) else {
            // decline known interaction types when their payload cannot be parsed
            if let placeholder = HostedAgentInteraction.declinePlaceholder(for: frame) {
                await sendDeclineResponse(for: placeholder, generation: generation)
            } else {
                failConnection(HostedAgentClientError.badFrame, generation: generation)
            }
            return
        }
        startInteractionTask(interaction, promptID: pending.id, generation: generation)
    }

    // A CONNECTED frame while a prompt is pending is a mid-prompt reconnect. The server's
    // `status` says where the run stands: "running" means events and the OUTPUT will stream
    // on this socket; anything else means the run finished while we were away (the reply is
    // the trailing agent entry in `chat_items`) or the INPUT never started it (resend it).
    private func resumePendingPrompt(from frame: [String: JSONValue], generation: Int) async {
        guard let pending = pendingPrompt else {
            return
        }
        guard frame["status"]?.stringValue != "running" else {
            return
        }

        if !pending.inputDelivered {
            guard var conversation = lastConversation else {
                failConnection(HostedAgentClientError.closed, generation: generation)
                return
            }
            if let serverSession {
                conversation.serverSession = serverSession
            }
            await transmitPrompt(
                pending.prompt,
                images: pending.images,
                files: pending.files,
                conversation: conversation,
                promptID: pending.id
            )
            return
        }

        let missedItems = Self.itemsAfterLastUserMessage(in: frame)
        for item in missedItems {
            guard let event = Self.replayedToolResult(item) else {
                continue
            }
            await pending.onEvent?(event)
        }
        guard pendingPrompt?.id == pending.id else {
            return
        }
        pendingPrompt = nil
        cancelInteractionTasks()
        let reply = missedItems.last { $0["type"]?.stringValue == "agent" }?["content"]?.stringValue
        if let reply, !reply.isEmpty {
            pending.continuation.resume(
                returning: HostedAgentResult(
                    output: reply,
                    endpointLabel: endpoint?.label ?? key.agentAddress,
                    serverSession: serverSession
                )
            )
        } else {
            // the server no longer has the run or its reply, so let the user retry
            pending.continuation.resume(throwing: HostedAgentClientError.closed)
        }
    }

    private static func itemsAfterLastUserMessage(in frame: [String: JSONValue]) -> [[String: JSONValue]] {
        guard case .array(let values)? = frame["chat_items"] else {
            return []
        }
        var turn: [[String: JSONValue]] = []
        for value in values {
            guard case .object(let item) = value else {
                continue
            }
            if item["type"]?.stringValue == "user" {
                turn.removeAll()
            } else {
                turn.append(item)
            }
        }
        return turn
    }

    private static func replayedToolResult(_ item: [String: JSONValue]) -> HostedAgentEvent? {
        guard item["type"]?.stringValue == "tool_call",
              let id = item["id"]?.stringValue,
              !id.isEmpty else {
            return nil
        }
        return .toolResult(
            id: id,
            name: item["name"]?.stringValue,
            output: HostedAgentEvent.messageText(item),
            state: item["status"]?.stringValue == "error" ? .failed : .completed
        )
    }

    private func startInteractionTask(
        _ interaction: HostedAgentInteraction,
        promptID: UUID,
        generation: Int
    ) {
        let taskID = UUID()
        interactionTasks[taskID] = Task { [weak self] in
            await self?.processInteraction(
                interaction,
                promptID: promptID,
                generation: generation,
                taskID: taskID
            )
        }
    }

    private func processInteraction(
        _ interaction: HostedAgentInteraction,
        promptID: UUID,
        generation: Int,
        taskID: UUID
    ) async {
        defer {
            interactionTasks.removeValue(forKey: taskID)
        }
        guard generation == socketGeneration,
              let pending = pendingPrompt,
              pending.id == promptID else {
            return
        }
        let decision = await pending.onInteraction?(interaction) ?? interaction.unavailableDecision
        guard generation == socketGeneration,
              pendingPrompt?.id == promptID,
              let socket,
              let endpoint else {
            return
        }
        do {
            guard let frame = try interactionResponseFrame(
                for: interaction,
                decision: decision,
                endpoint: endpoint
            ) else {
                return
            }
            try await send(signedCommand(frame), over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func sendDeclineResponse(
        for interaction: HostedAgentInteraction,
        generation: Int
    ) async {
        guard generation == socketGeneration, let socket, let endpoint else {
            return
        }
        do {
            guard let frame = try interactionResponseFrame(
                for: interaction,
                decision: interaction.unavailableDecision,
                endpoint: endpoint
            ) else {
                // ask user cancellation has no response frame, so end the pending turn
                failConnection(HostedAgentClientError.badFrame, generation: generation)
                return
            }
            try await send(signedCommand(frame), over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func interactionResponseFrame(
        for interaction: HostedAgentInteraction,
        decision: HostedAgentInteractionDecision,
        endpoint: ResolvedEndpoint
    ) throws -> [String: JSONValue]? {
        switch (interaction, decision) {
        // superseded requests release the local gate without writing to the socket
        case (_, .superseded):
            return nil
        case (.approval, .approval(let approval)):
            return HostedAgentClient.approvalResponseFrame(
                decision: approval,
                agentAddress: key.agentAddress,
                endpoint: endpoint
            )
        case (.ulwCheckpoint, .ulwCheckpoint(let checkpoint)):
            return HostedAgentClient.ulwResponseFrame(
                decision: checkpoint,
                agentAddress: key.agentAddress,
                endpoint: endpoint
            )
        case (.planReview(let request), .planReview(let review)):
            return HostedAgentClient.planReviewResponseFrame(
                decision: review,
                request: request,
                agentAddress: key.agentAddress,
                endpoint: endpoint
            )
        case (.askUser, .askUser(.cancel)):
            return nil
        case (.askUser, .askUser(.answer(let answer))):
            return HostedAgentClient.askUserResponseFrame(
                answer: answer,
                agentAddress: key.agentAddress,
                endpoint: endpoint
            )
        default:
            throw HostedAgentClientError.badFrame
        }
    }

    private func cancelInteractionTasks() {
        let tasks = Array(interactionTasks.values)
        interactionTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func updateServerSession(from frame: [String: JSONValue]) {
        if case .object(let session)? = frame["session"] {
            serverSession = session
        }
        if let sessionID = frame["session_id"]?.stringValue {
            var updated = serverSession ?? [:]
            updated["session_id"] = .string(sessionID)
            serverSession = updated
        }
    }

    func failConnection(_ error: Error, generation: Int) {
        guard generation == socketGeneration else {
            return
        }
        if canResume(after: error) {
            beginResumeAttempt()
            return
        }
        disconnect(with: normalizedConnectionError(error), closeCode: .goingAway)
    }

    // A dropped socket does not end the round-trip: the server keeps the run alive and
    // re-attaches it when the same session reconnects, so a pending prompt is worth
    // resuming for connection-loss errors. Server rejections and cancellations are final.
    private func canResume(after error: Error) -> Bool {
        guard pendingPrompt != nil,
              connectWaiters.isEmpty,
              lastConversation != nil,
              resumeAttemptsUsed < resumeAttemptLimit else {
            return false
        }
        switch error {
        case is CancellationError:
            return false
        case let clientError as HostedAgentClientError:
            switch clientError {
            case .closed, .timeout:
                return true
            default:
                return false
            }
        default:
            return true
        }
    }

    private func beginResumeAttempt() {
        resumeAttemptsUsed += 1
        socketGeneration += 1
        let generation = socketGeneration
        setState(.connecting)
        connectionStatus = nil

        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        // gates from the dead socket unblock here; the server replays any interaction
        // request that is still waiting once the new socket attaches
        cancelInteractionTasks()

        let socket = socket
        self.socket = nil
        endpoint = nil
        socket?.cancel(with: .goingAway, reason: nil)

        let delay = resumeRetryDelay * pow(2, Double(resumeAttemptsUsed - 1))
        resumeTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.resumeConnection(generation: generation)
        }
    }

    private func resumeConnection(generation: Int) async {
        guard generation == socketGeneration,
              state == .connecting,
              pendingPrompt != nil,
              var conversation = lastConversation else {
            return
        }
        if let serverSession {
            conversation.serverSession = serverSession
        }
        await openConnection(conversation: conversation, generation: generation)
    }

    func disconnect(with error: Error, closeCode: URLSessionWebSocketTask.CloseCode) {
        // clear shared state before any waiter can resume and call back into this actor
        socketGeneration += 1
        setState(.disconnected)
        connectionStatus = nil

        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        resumeAttemptsUsed = 0
        cancelInteractionTasks()

        let socket = socket
        self.socket = nil
        endpoint = nil
        socket?.cancel(with: closeCode, reason: nil)

        let waiters = Array(connectWaiters.values)
        connectWaiters.removeAll()
        let pending = pendingPrompt
        pendingPrompt = nil

        for waiter in waiters {
            waiter.resume(throwing: error)
        }
        pending?.continuation.resume(throwing: error)
    }

    func setState(_ newState: State) {
        guard state != newState else {
            return
        }
        state = newState
        if newState == .connected {
            requiresRevalidation = false
        }
        let publicState: ConversationConnectionState
        switch newState {
        case .disconnected:
            publicState = .disconnected
        case .connecting:
            publicState = .reconnecting
        case .connected:
            publicState = .connected
        }
        connectionStateObserver.notify(conversationID: key.conversationID, state: publicState)
    }

    private func normalizedConnectionError(_ error: Error) -> Error {
        if error is CancellationError || error is HostedAgentClientError {
            return error
        }
        return HostedAgentClientError.closed
    }

    func resolveEndpoint(agentAddress: String) async throws -> ResolvedEndpoint {
        try await endpointResolver(agentAddress)
    }

    func buildConnectFrame(conversation: Conversation) throws -> [String: JSONValue] {
        var frame = try signer.envelope(
            type: "CONNECT",
            payload: signer.connectPayload(to: key.agentAddress)
        )
        frame["to"] = .string(key.agentAddress)
        frame["session_id"] = .string(conversation.id)
        frame["session"] = .object(sessionPayload(for: conversation))
        frame["protocol"] = .object(OIP.descriptor)
        return frame
    }

    func sessionPayload(for conversation: Conversation) -> [String: JSONValue] {
        HostedAgentSessionState.applying(
            conversation.mode,
            to: conversation.serverSession,
            conversationID: conversation.id
        )
    }

    func buildInputFrame(
        prompt: String,
        images: [String],
        files: [HostedAgentFilePayload],
        conversation: Conversation,
        inputID: String
    ) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "session_id": .string(conversation.id),
            "input_id": .string(inputID),
            "prompt": .string(prompt),
            "mode": .string(conversation.mode.rawValue)
        ]
        if !images.isEmpty {
            fields["images"] = .array(images.map(JSONValue.string))
        }
        if !files.isEmpty {
            fields["files"] = .array(files.map(\.jsonValue))
        }
        return try signer.command(type: "INPUT", fields: fields, to: key.agentAddress)
    }

    /// With 'signed_commands' on, the host runs onlyt eh signed payload, so every app frame
    /// after CONNECT must be wrapped. PONG and SESSIONSTATUS are exempt and never come through here.
    func signedCommand(_ frame: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .string(let type)? = frame["type"] else {
            throw HostedAgentClientError.badFrame
        }

        var fields = frame
        for reserved in ["type", "to", "timestamp", "nonce"] {
            fields[reserved] = nil
        }

        return try signer.command(type: type, fields: fields, to: key.agentAddress)
    }

    func send(_ frame: [String: JSONValue], over socket: any HostedAgentWebSocketTask) async throws {
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HostedAgentClientError.badFrame
        }
        try await socket.send(.string(text))
        // an awaited send may finish after this socket has already been replaced
        guard self.socket === socket else {
            throw HostedAgentClientError.closed
        }
        lastNetworkActivityAt = Date()
    }

    static func readFrame(
        from socket: any HostedAgentWebSocketTask
    ) async throws -> [String: JSONValue] {
        let message = try await socket.receive()
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw HostedAgentClientError.badFrame
            }
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        case .data(let data):
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        @unknown default:
            throw HostedAgentClientError.badFrame
        }
    }

    private func messageText(_ frame: [String: JSONValue]) -> String {
        HostedAgentEvent.messageText(frame)
    }
}
