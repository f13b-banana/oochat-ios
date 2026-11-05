import ConnectOnionKit
import Foundation

extension HostedAgentConnection {
    func handle(_ frame: [String: JSONValue], generation: Int) async {
        guard generation == socketGeneration else {
            return
        }
        lastNetworkActivityAt = Date()
        guard recordEventIfNew(frame) else {
            return
        }

        switch frame["type"]?.stringValue {
        case "PING":
            await handlePing(generation: generation)
        case "CONNECTED":
            await handleConnected(frame, generation: generation)
        case "OUTPUT":
            handleOutput(frame)
        case "EXEC_RESULT":
            handleExecResult(frame)
        case "tool_call", "tool_result", "mode_changed":
            await handleEvent(frame)
        case "approval_needed", "APPROVAL_NEEDED", "ulw_turns_reached", "plan_review", "ask_user":
            await handleInteraction(frame, generation: generation)
        case "ERROR":
            failConnection(connectError(for: frame), generation: generation)
        default:
            break
        }
    }

    static let interactionFrameTypes: Set<String> = [
        "approval_needed", "APPROVAL_NEEDED", "ulw_turns_reached", "plan_review", "ask_user"
    ]

    /// Port of macOS recordEventIfNew
    func recordEventIfNew(_ frame: [String: JSONValue]) -> Bool {
        guard let eventID = frame["id"]?.stringValue, !eventID.isEmpty else {
            return true
        }
        let type = frame["type"]?.stringValue ?? "unknown"
        guard !Self.interactionFrameTypes.contains(type) else {
            return true
        }
        let status = frame["status"]?.stringValue ?? "none"
        let sequence = frame["seq"]?.numberValue.map { String(Int($0)) } ?? "none"
        guard eventLedger.record(eventID: "\(type):\(eventID):\(status):\(sequence)") else {
            return false
        }
        advanceBookmark(to: eventID)
        return true
    }

    func advanceBookmark(to eventID: String) {
        let fallbackID = lastConversation?.id ?? key.conversationID
        var bookmark = bookmarkStore.load(conversationID: key.conversationID) ?? SessionBookmark(sessionID: fallbackID)
        bookmark.lastMessageID = eventID
        bookmarkStore.save(bookmark, conversationID: key.conversationID)
    }

    private func handlePing(generation: Int) async {
        guard let socket else {
            return
        }
        do {
            try await send(OIPClientFrames.pong(), over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func handleConnected(_ frame: [String: JSONValue], generation: Int) async {
        // The kit reads CONNECTED and refuses a session index. A frame it cannot use ends the attempt.
        guard case .established(let connected)? = try? OIPHandshake.interpret(frame) else {
            failConnection(HostedAgentClientError.badFrame, generation: generation)
            return
        }
        updateServerSession(from: frame)
        connectionStatus = connected.status
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
        await resumePendingPrompt(from: frame, isRunning: connected.isRunning, generation: generation)
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

    /// Hands an EXEC_RESULT to the caller waiting under its exec_id. 
    /// Never fails the connection: `status: error` is taken as a tool response.
    private func handleExecResult(_ frame: [String: JSONValue]) {
        guard case .execResult(let result) = OIPServerFrame.decode(frame),
              let continuation = pendingExecs.removeValue(forKey: result.execID) else {
            return
        }
        continuation.resume(returning: result)
    }

    func failPendingExecs(_ error: Error) {
        let execs = pendingExecs
        pendingExecs.removeAll()
        for continuation in execs.values {
            continuation.resume(throwing: error)
        }
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
    private func resumePendingPrompt(from frame: [String: JSONValue], isRunning: Bool, generation: Int) async {
        guard let pending = pendingPrompt else {
            return
        }
        guard !isRunning else {
            return
        }
        if pending.inputDelivered {
            await settleFromChatItems(pending, frame: frame)
        } else {
            await resendUndeliveredPrompt(pending, generation: generation)
        }
    }

    // The INPUT never started the run, so send it again on this socket.
    private func resendUndeliveredPrompt(_ pending: PendingPrompt, generation: Int) async {
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
    }

    // The run finished while we were away: replay its tool results, then answer with its reply.
    private func settleFromChatItems(_ pending: PendingPrompt, frame: [String: JSONValue]) async {
        let missedItems: [[String: JSONValue]]
        if pending.requiresMatchingUserTurn {
            // After a relaunch the host's last turn may be an older one (our INPUT never
            // arrived), so its reply must not be taken as the answer to this prompt.
            missedItems = Self.itemsAfterUserMessage(matching: pending.prompt, in: frame) ?? []
        } else {
            missedItems = Self.itemsAfterLastUserMessage(in: frame)
        }
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
            pending.continuation.resume(
                throwing: pending.requiresMatchingUserTurn
                    ? HostedAgentClientError.outcomeUnknown
                    : HostedAgentClientError.closed
            )
        }
    }

    // The items of the last turn, but only when that turn's user message is `prompt`.
    // nil when there are no chat_items or the last turn belongs to another message.
    private static func itemsAfterUserMessage(
        matching prompt: String,
        in frame: [String: JSONValue]
    ) -> [[String: JSONValue]]? {
        guard case .array(let values)? = frame["chat_items"] else {
            return nil
        }
        var lastUserContent: String?
        var turn: [[String: JSONValue]] = []
        for value in values {
            guard case .object(let item) = value else {
                continue
            }
            if item["type"]?.stringValue == "user" {
                lastUserContent = item["content"]?.stringValue
                turn.removeAll()
            } else {
                turn.append(item)
            }
        }
        let expected = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastUserContent,
              lastUserContent.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            return nil
        }
        return turn
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
            try await send(frame, over: socket)
            advanceBookmark(to: interaction.id)
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
            try await send(frame, over: socket)
            advanceBookmark(to: interaction.id)
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
        case (.approval(let request), .approval(let approval)):
            return try frames.approvalResponse(requestID: request.id, decision: approval.decisionFields)
        case (.ulwCheckpoint, .ulwCheckpoint(let checkpoint)):
            return try signedCommand(checkpoint.responseFrame)
        case (.planReview(let request), .planReview(let review)):
            return try signedCommand(review.responseFrame(for: request))
        case (.askUser, .askUser(.cancel)):
            return nil
        case (.askUser(let request), .askUser(.answer(let answer))):
            return try frames.askUserResponse(requestID: request.id, answer: answer)
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
              case .connecting = reduce(
                .connecting(attempt: resumeAttemptsUsed), .socketClosed, maxAttempts: reconnectPolicy.maxAttempts
              ) else {
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
        // an EXEC sent on the dead socket will never be answered, and is never resent
        failPendingExecs(HostedAgentClientError.closed)

        let socket = socket
        self.socket = nil
        endpoint = nil
        socket?.cancel(with: .goingAway, reason: nil)

        let delay = reconnectPolicy.delay(for: resumeAttemptsUsed)
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
        failPendingExecs(error)
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

    func sessionPayload(for conversation: Conversation) -> [String: JSONValue] {
        HostedAgentSessionState.applying(
            conversation.mode,
            to: conversation.serverSession,
            conversationID: conversation.id
        )
    }

    /// ULW and plan review answers have no named builder in pkg, so they go through generic signed command.
    /// WIth signed_commands flag set, the host eruns only teh signed payload
    func signedCommand(_ frame: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .string(let type)? = frame["type"] else {
            throw HostedAgentClientError.badFrame
        }

        var fields = frame
        fields["type"] = nil
        return try frames.command(type: type, fields: fields)
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

    // -32010 means the host speaks another OIP version. canResume(after:) already treats every
    // client error except .closed and .timeout as final, so this ends the attempt with no retry.
    // Every other ERROR keeps its old meaning: the host's own text.
    private func connectError(for frame: [String: JSONValue]) -> HostedAgentClientError {
        if case .incompatible(let incompatibility)? = try? OIPHandshake.interpret(frame) {
            return .incompatibleProtocol(incompatibility)
        }
        return .server(messageText(frame))
    }
}
