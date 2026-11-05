import Foundation
import ConnectOnionKit

// Owns one socket and one active prompt for a conversation.
actor HostedAgentConnection {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
    }

    struct PendingPrompt {
        let id: UUID
        // Reuse the same ID when resending this prompt.
        let inputID: String
        let continuation: CheckedContinuation<HostedAgentResult, Error>
        let onEvent: (@MainActor (HostedAgentEvent) -> Void)?
        let onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
        let prompt: String
        let images: [String]
        let files: [HostedAgentFilePayload]
        // A reconnect may resend input only when the original frame was not delivered.
        var inputDelivered = false
        // Set for a prompt sent by an earlier run of the app: a finished turn counts only
        // if the host's last user message is this prompt.
        var requiresMatchingUserTurn = false
        // Called just before each INPUT write, so the app can save that it may have been sent.
        var onInputDispatched: (@MainActor () -> Void)?
    }

    let key: HostedAgentConnectionKey
    let identityStore: IdentityStore
    let frames: OIPClientFrames
    let connectionStateObserver: HostedAgentConnectionStateObserver
    let socketFactory: HostedAgentWebSocketFactory
    let endpointResolver: HostedAgentEndpointResolver
    let connectTimeout: TimeInterval
    let livenessTimeout: TimeInterval
    let livenessCheckInterval: TimeInterval
    let resumeAttemptLimit: Int
    let resumeRetryDelay: TimeInterval
    let modeChangeTimeout: TimeInterval
    let bookmarkStore: HostedAgentBookmarkStore
    let reconnectPolicy: ReconnectPolicy
    let execTimeout: TimeInterval
    var eventLedger = EventLedger()
    var state: State = .disconnected
    var socket: (any HostedAgentWebSocketTask)?
    var endpoint: ResolvedEndpoint?
    var receiveTask: Task<Void, Never>?
    var connectTimeoutTask: Task<Void, Never>?
    var livenessTask: Task<Void, Never>?
    var resumeTask: Task<Void, Never>?
    var interactionTasks: [UUID: Task<Void, Never>] = [:]
    // Ignore frames and failures from sockets that have already been replaced.
    var socketGeneration = 0
    var connectWaiters: [UUID: CheckedContinuation<HostedAgentResult, Error>] = [:]
    var pendingPrompt: PendingPrompt?

    // The mode_change request waiting for its mode_changed, if any.
    var pendingModeChangeHandler: (@MainActor (HostedAgentEvent) -> Void)?
    var modeChangeTimeoutTask: Task<Void, Never>?

    var serverSession: [String: JSONValue]?
    var sessionModes: OIPSessionModes?
    var connectionStatus: String?
    var lastNetworkActivityAt = Date()
    var resumeAttemptsUsed = 0
    var lastConversation: Conversation?
    var requiresRevalidation = false
    var pendingExecs: [String: CheckedContinuation<OIPExecResult, Error>] = [:]

    init(
        key: HostedAgentConnectionKey,
        identityStore: IdentityStore,
        session: URLSession,
        discovery: HostedAgentDiscovery,
        connectionStateObserver: HostedAgentConnectionStateObserver,
        socketFactory: HostedAgentWebSocketFactory? = nil,
        endpointResolver: HostedAgentEndpointResolver? = nil,
        connectTimeout: TimeInterval = 45,
        livenessTimeout: TimeInterval = 75,
        livenessCheckInterval: TimeInterval = 10,
        resumeAttemptLimit: Int = 3,
        resumeRetryDelay: TimeInterval = 1,
        modeChangeTimeout: TimeInterval = 15,
        bookmarkStore: HostedAgentBookmarkStore = HostedAgentBookmarkStore(),
        execTimeout: TimeInterval = 30
    ) {
        self.key = key
        self.identityStore = identityStore
        self.frames = OIPClientFrames(keyStore: identityStore, to: key.agentAddress)
        self.connectionStateObserver = connectionStateObserver
        self.socketFactory = socketFactory ?? { session.webSocketTask(with: $0) }
        self.endpointResolver = endpointResolver ?? { agentAddress in
            try await discovery.discover(agentAddress: agentAddress).endpoint
        }
        self.connectTimeout = connectTimeout
        self.livenessTimeout = livenessTimeout
        self.livenessCheckInterval = livenessCheckInterval
        self.resumeAttemptLimit = resumeAttemptLimit
        self.resumeRetryDelay = resumeRetryDelay
        self.modeChangeTimeout = modeChangeTimeout
        self.bookmarkStore = bookmarkStore
        self.reconnectPolicy = ReconnectPolicy(maxAttempts: resumeAttemptLimit + 1, baseDelay: resumeRetryDelay)
        self.execTimeout = execTimeout
    }

    // Share one connection attempt across callers for this conversation.
    func ensureConnected(conversation: Conversation) async throws -> HostedAgentResult {
        lastConversation = conversation
        if requiresRevalidation, state == .connected {
            guard pendingPrompt == nil else {
                throw HostedAgentClientError.busy
            }
            disconnect(with: HostedAgentClientError.closed, closeCode: .goingAway)
        }
        if state == .connected, socket != nil, let endpoint {
            return HostedAgentResult(
                output: nil,
                endpointLabel: endpoint.label,
                serverSession: serverSession,
                sessionModes: sessionModes
            )
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                connectWaiters[waiterID] = continuation
                guard state != .connecting else {
                    return
                }
                setState(.connecting)
                serverSession = sessionPayload(for: conversation)
                socketGeneration += 1
                let generation = socketGeneration
                Task { [weak self] in
                    await self?.openConnection(conversation: conversation, generation: generation)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelConnectWaiter(waiterID)
            }
        }
    }

    // Allow only one prompt at a time on this conversation socket.
    func sendPrompt(
        conversation: Conversation,
        prompt: String,
        images: [String] = [],
        files: [HostedAgentFilePayload] = [],
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?,
        onInputDispatched: (@MainActor () -> Void)? = nil
    ) async throws -> HostedAgentResult {
        try Task.checkCancellation()
        _ = try await ensureConnected(conversation: conversation)
        try Task.checkCancellation()
        guard pendingPrompt == nil else {
            throw HostedAgentClientError.busy
        }
        resumeAttemptsUsed = 0

        let promptID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingPrompt = PendingPrompt(
                    id: promptID,
                    inputID: UUID().uuidString,
                    continuation: continuation,
                    onEvent: onEvent,
                    onInteraction: onInteraction,
                    prompt: prompt,
                    images: images,
                    files: files,
                    onInputDispatched: onInputDispatched
                )
                guard !Task.isCancelled else {
                    disconnect(with: CancellationError(), closeCode: .goingAway)
                    return
                }
                Task { [weak self] in
                    await self?.transmitPrompt(
                        prompt,
                        images: images,
                        files: files,
                        conversation: conversation,
                        promptID: promptID
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPrompt(promptID)
            }
        }
    }

    /// Sends a signed mode-change command. The confirmation is delivered asynchronously
    /// by the socket receive loop through `pendingModeChangeHandler`.
    func requestModeChange(
        conversation: Conversation,
        mode: OIPPermissionMode,
        onEvent: @escaping @MainActor (HostedAgentEvent) -> Void
    ) async throws {
        try Task.checkCancellation()
        _ = try await ensureConnected(conversation: conversation)
        try Task.checkCancellation()

        guard pendingModeChangeHandler == nil else {
            throw HostedAgentClientError.busy
        }
        guard let socket, state == .connected else {
            throw HostedAgentClientError.closed
        }

        // Install the callback before sending so a fast server confirmation cannot be missed.
        pendingModeChangeHandler = onEvent
        do {
            try await send(frames.modeChange(mode), over: socket)
            // A mode change should be acknowledged promptly. Avoid leaving the UI pending
            // forever if the host never sends mode_changed.
            if pendingModeChangeHandler != nil {
                modeChangeTimeoutTask?.cancel()
                let timeout = modeChangeTimeout
                modeChangeTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    } catch {
                        return
                    }
                    await self?.expireModeChangeRequest()
                }
            }
        } catch {
            pendingModeChangeHandler = nil
            modeChangeTimeoutTask?.cancel()
            modeChangeTimeoutTask = nil
            throw error
        }
    }

    func expireModeChangeRequest() async {
        guard let handler = pendingModeChangeHandler else { return }
        pendingModeChangeHandler = nil
        modeChangeTimeoutTask?.cancel()
        modeChangeTimeoutTask = nil
        await handler(.modeChangeTimedOut)
    }

    // Settles a prompt that an earlier run of the app may already have sent, without
    // sending INPUT again. The CONNECTED frame decides: "running" streams the rest of the
    // turn here, a finished turn is read from chat_items (only if its user message is this
    // prompt), and anything else fails with .outcomeUnknown so the user decides on a retry.
    func resumePrompt(
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    ) async throws -> HostedAgentResult {
        try Task.checkCancellation()
        guard pendingPrompt == nil else {
            throw HostedAgentClientError.busy
        }
        // Only a fresh CONNECTED says what happened to the earlier INPUT.
        if state == .connected {
            disconnect(with: HostedAgentClientError.closed, closeCode: .goingAway)
        }
        resumeAttemptsUsed = 0
        // Send no turn history: the host then always counts its own copy as newer and
        // returns chat_items, even if another reconnect already updated our copy.
        let probe: Conversation = {
            var copy = conversation
            copy.serverSession = nil
            return copy
        }()

        let promptID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingPrompt = PendingPrompt(
                    id: promptID,
                    inputID: UUID().uuidString,
                    continuation: continuation,
                    onEvent: onEvent,
                    onInteraction: onInteraction,
                    prompt: prompt,
                    images: [],
                    files: [],
                    inputDelivered: true,
                    requiresMatchingUserTurn: true
                )
                guard !Task.isCancelled else {
                    disconnect(with: CancellationError(), closeCode: .goingAway)
                    return
                }
                Task { [weak self] in
                    // CONNECTED settles the prompt in resumePendingPrompt; a failed connect
                    // settles it through disconnect(with:), so the result is not needed here.
                    _ = try? await self?.ensureConnected(conversation: probe)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPrompt(promptID)
            }
        }
    }

    /// Runs tool on the host without the LLM (EXEC); each reply is matched to its request by `exec_id`. 
    /// A tool that fails still returns as a result. Throws only when the round trip itself fails.
    func exec(
        conversation: Conversation,
        execID: String,
        tool: String,
        args: [String: JSONValue]
    ) async throws -> OIPExecResult {
        try Task.checkCancellation()
        _ = try await ensureConnected(conversation: conversation)
        try Task.checkCancellation()
        guard pendingExecs[execID] == nil else {
            throw HostedAgentClientError.busy
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingExecs[execID] = continuation
                Task { [weak self] in
                    await self?.transmitExec(execID: execID, tool: tool, args: args)
                }
                Task { [weak self, execTimeout] in
                    try? await Task.sleep(nanoseconds: UInt64(execTimeout * 1_000_000_000))
                    await self?.failExec(execID, with: HostedAgentClientError.timeout)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failExec(execID, with: CancellationError())
            }
        }
    }

    private func transmitExec(execID: String, tool: String, args: [String: JSONValue]) async {
        let generation = socketGeneration
        guard pendingExecs[execID] != nil else {
            return
        }
        guard let socket else {
            failExec(execID, with: HostedAgentClientError.closed)
            return
        }
        do {
            try await send(try frames.exec(execID: execID, tool: tool, args: args), over: socket)
        } catch {
            failExec(execID, with: error)
            failConnection(error, generation: generation)
        }
    }

    private func failExec(_ execID: String, with error: Error) {
        pendingExecs.removeValue(forKey: execID)?.resume(throwing: error)
    }

    func close() {
        disconnect(with: HostedAgentClientError.closed, closeCode: .goingAway)
    }

    func noteNetworkLost() {
        requiresRevalidation = true
    }

    // Ignore time spent suspended when checking socket liveness.
    func noteApplicationBecameActive() {
        lastNetworkActivityAt = Date()
    }

    func waitForPendingInteractionResponses() async {
        let tasks = Array(interactionTasks.values)
        for task in tasks {
            await task.value
        }
    }

    func openConnection(conversation: Conversation, generation: Int) async {
        scheduleConnectTimeout(generation: generation)
        do {
            let endpoint = try await resolveEndpoint(agentAddress: key.agentAddress)
            guard state == .connecting, generation == socketGeneration else {
                return
            }

            self.endpoint = endpoint
            let socket = socketFactory(endpoint.wsURL)
            self.socket = socket
            lastNetworkActivityAt = Date()
            socket.resume()
            startReceiveLoop(socket: socket, generation: generation)
            startLivenessMonitor(generation: generation)

            // direct: false keeps the top-level `to` iOS has always sent: a relay needs it and the host
            // ignores it on a direct socket. The builder also adds the protocol descriptor.
            let connectFrame = try frames.connect(
                direct: false,
                sessionID: conversation.id,
                session: .object(sessionPayload(for: conversation)),
                lastMessageID: bookmarkStore.load(conversationID: key.conversationID)?.lastMessageID
            )
            try await send(connectFrame, over: socket)
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func startReceiveLoop(
        socket: any HostedAgentWebSocketTask,
        generation: Int
    ) {
        // Keep one reader responsible for the current socket.
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await Self.readFrame(from: socket)
                    guard let self else {
                        return
                    }
                    await self.handle(frame, generation: generation)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self else {
                        return
                    }
                    await self.failConnection(error, generation: generation)
                    return
                }
            }
        }
    }

    private func scheduleConnectTimeout(generation: Int) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64((self?.connectTimeout ?? 45) * 1_000_000_000))
            } catch {
                return
            }
            await self?.failConnection(HostedAgentClientError.timeout, generation: generation)
        }
    }

    private func startLivenessMonitor(generation: Int) {
        livenessTask?.cancel()
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64((self?.livenessCheckInterval ?? 10) * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                if await self.hasTimedOut(generation: generation) {
                    await self.failConnection(HostedAgentClientError.timeout, generation: generation)
                    return
                }
            }
        }
    }

    private func hasTimedOut(generation: Int) -> Bool {
        // A user decision restarts activity tracking after a long interaction pause.
        guard interactionTasks.isEmpty else {
            return false
        }
        return generation == socketGeneration
            && Date().timeIntervalSince(lastNetworkActivityAt) > livenessTimeout
    }

    func transmitPrompt(
        _ prompt: String,
        images: [String],
        files: [HostedAgentFilePayload],
        conversation: Conversation,
        promptID: UUID
    ) async {
        let generation = socketGeneration
        guard let pending = pendingPrompt, pending.id == promptID else {
            return
        }
        // Fail the pending continuation if the socket closes before this task sends.
        guard let socket else {
            failConnection(HostedAgentClientError.closed, generation: generation)
            return
        }
        do {
            let inputFrame = try frames.input(
                inputID: pending.inputID,
                prompt: prompt,
                images: images,
                files: files.map(\.jsonValue)
            )
            // Save "may have reached the host" before the bytes leave. If the app is killed
            // after this, the relaunch asks the host instead of sending the INPUT again.
            if let onInputDispatched = pending.onInputDispatched {
                await onInputDispatched()
                // The await let other work run. Send only on the socket and prompt we
                // started with; a resume attempt sends again after its CONNECTED.
                guard pendingPrompt?.id == promptID, self.socket === socket else {
                    return
                }
            }
            try await send(inputFrame, over: socket)
            if pendingPrompt?.id == promptID {
                pendingPrompt?.inputDelivered = true
            }
        } catch {
            failConnection(error, generation: generation)
        }
    }

    private func cancelConnectWaiter(_ waiterID: UUID) {
        guard let waiter = connectWaiters.removeValue(forKey: waiterID) else {
            return
        }
        waiter.resume(throwing: CancellationError())
        if connectWaiters.isEmpty, state == .connecting {
            disconnect(with: CancellationError(), closeCode: .goingAway)
        }
    }

    private func cancelPrompt(_ promptID: UUID) {
        guard pendingPrompt?.id == promptID else {
            return
        }
        disconnect(with: CancellationError(), closeCode: .goingAway)
    }
}
