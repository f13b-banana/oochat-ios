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
    }

    let key: HostedAgentConnectionKey
    let identityStore: IdentityStore
    let connectionStateObserver: HostedAgentConnectionStateObserver
    let socketFactory: HostedAgentWebSocketFactory
    let endpointResolver: HostedAgentEndpointResolver
    let connectTimeout: TimeInterval
    let livenessTimeout: TimeInterval
    let livenessCheckInterval: TimeInterval
    let resumeAttemptLimit: Int
    let resumeRetryDelay: TimeInterval

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
    var serverSession: [String: JSONValue]?
    var connectionStatus: String?
    var lastNetworkActivityAt = Date()
    var resumeAttemptsUsed = 0
    var lastConversation: Conversation?
    var requiresRevalidation = false

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
        resumeRetryDelay: TimeInterval = 1
    ) {
        self.key = key
        self.identityStore = identityStore
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
            return HostedAgentResult(output: nil, endpointLabel: endpoint.label, serverSession: serverSession)
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
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
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
                    files: files
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

            let connectFrame = try buildConnectFrame(conversation: conversation)
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
            let inputFrame = try buildInputFrame(
                prompt: prompt,
                images: images,
                files: files,
                conversation: conversation,
                inputID: pending.inputID
            )
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
