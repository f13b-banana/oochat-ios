import Combine
import ConnectOnionKit
import Foundation

enum ConnectionRecoveryTrigger {
    case probe
    case pathRestored
    case userRetry
    // active chat, for control center
    case open
}

@MainActor
final class ConnectionRecoveryCoordinator: ObservableObject {
    @Published private(set) var isOffline = false
    @Published private(set) var isOfflineBannerDismissed = false
    @Published private(set) var isRetryingConnectivity = false
    @Published private var statesByConversationID: [String: ConversationConnectionState] = [:]

    private(set) var recoveryTask: Task<Void, Never>?
    private(set) var probeTask: Task<Void, Never>?
    private(set) var launchFlushTask: Task<Void, Never>?
    private(set) var disconnectTask: Task<Void, Never>?
    private(set) var openTask: Task<Void, Never>?
    /// A short interval keeps tests fast without allowing an invalid sleep duration.
    var probeInterval: TimeInterval = 5 {
        didSet {
            probeInterval = max(0.1, probeInterval)
        }
    }

    var onConnected: ((String) -> Void)?
    var onRecoveryError: ((String, Error) -> Void)?
    var onReconnect: ((SavedAgent) -> Void)?
    var onNetworkAvailabilityChange: ((Bool) -> Void)?

    private var recoveryConversationID: String?
    private var recoveryGeneration = 0
    private var probeConversationID: String?
    private var hasFlushedOnLaunch = false
    private let conversationState: ConversationState
    private let deliveryCoordinator: MessageDeliveryCoordinator
    private let networkMonitor: NetworkPathMonitoring
    private var transport: HostedAgentConversationTransport

    init(
        conversationState: ConversationState,
        deliveryCoordinator: MessageDeliveryCoordinator,
        networkMonitor: NetworkPathMonitoring,
        transport: HostedAgentConversationTransport
    ) {
        self.conversationState = conversationState
        self.deliveryCoordinator = deliveryCoordinator
        self.networkMonitor = networkMonitor
        self.transport = transport

        self.networkMonitor.onUpdate = { [weak self] isOnline in
            self?.handleNetworkChange(isOnline: isOnline)
        }
        self.transport.onConnectionStateChange = { [weak self] conversationID, state in
            self?.setConnectionState(state, forConversationID: conversationID)
        }
        self.deliveryCoordinator.connectionState = { [weak self] conversationID in
            self?.connectionState(forConversationID: conversationID) ?? .disconnected
        }
        self.deliveryCoordinator.onConnectionStateChange = { [weak self] conversationID, state in
            self?.setConnectionState(state, forConversationID: conversationID)
        }
    }

    deinit {
        networkMonitor.cancel()
        probeTask?.cancel()
        recoveryTask?.cancel()
        launchFlushTask?.cancel()
        disconnectTask?.cancel()
        openTask?.cancel()
    }

    var shouldShowOfflineBanner: Bool {
        isOffline && !isOfflineBannerDismissed
    }

    func start() {
        networkMonitor.start()
    }

    /// O Chat opens the socket as soon as an agent's chat is on screen: the host sends Control Center
    func connectOnOpen(conversationID: String?) {
        openTask?.cancel()
        guard let conversationID, !isOffline, connectionState(forConversationID: conversationID) != .connected else {
            return
        }
        openTask = Task { [weak self] in
            _ = await self?.reconnect(conversationID: conversationID, trigger: .open)
        }
    }

    func connectionState(forConversationID conversationID: String) -> ConversationConnectionState {
        statesByConversationID[conversationID] ?? .disconnected
    }

    func setConnectionState(
        _ state: ConversationConnectionState,
        forConversationID conversationID: String
    ) {
        let wasConnected = statesByConversationID[conversationID] == .connected
        statesByConversationID[conversationID] = state
        if state == .connected, !wasConnected { onConnected?(conversationID) }
    }

    func removeConnectionState(forConversationID conversationID: String) {
        statesByConversationID[conversationID] = nil
        cancelRecovery(forConversationID: conversationID)
    }

    func dismissOfflineBanner() {
        isOfflineBannerDismissed = true
    }

    func retryConnectivity() {
        guard isOffline, let conversationID = conversationState.activeConversationID else {
            return
        }
        startRecovery(forConversationID: conversationID, trigger: .userRetry)
    }

    func reconnectActiveConversation() async {
        guard let conversationID = conversationState.activeConversationID else {
            return
        }
        _ = await reconnect(conversationID: conversationID, trigger: .userRetry)
    }

    private func handleNetworkChange(isOnline: Bool) {
        let wasOffline = isOffline
        isOffline = !isOnline
        onNetworkAvailabilityChange?(isOnline)
        deliveryCoordinator.setDeliveryEnabled(isOnline)

        guard isOnline else {
            recoveryTask?.cancel()
            recoveryConversationID = nil
            if !wasOffline {
                isOfflineBannerDismissed = false
            }
            for conversationID in conversationState.conversations.map(\.id) {
                statesByConversationID[conversationID] = .disconnected
            }
            noteNetworkLost()
            startRecoveryProbing(forConversationID: conversationState.activeConversationID)
            return
        }

        probeTask?.cancel()
        probeConversationID = nil
        // Flush messages from an earlier session when the app first launches online.
        if !hasFlushedOnLaunch {
            hasFlushedOnLaunch = true
            launchFlushTask = Task { [weak self] in
                await self?.deliveryCoordinator.flushQueuedMessages()
            }
        }
        guard wasOffline, let conversationID = conversationState.activeConversationID else {
            return
        }
        startRecovery(forConversationID: conversationID, trigger: .pathRestored)
    }

    private func noteNetworkLost() {
        disconnectTask?.cancel()
        let transport = transport
        disconnectTask = Task {
            await transport.noteNetworkLost()
        }
    }

    private func startRecovery(
        forConversationID conversationID: String,
        trigger: ConnectionRecoveryTrigger
    ) {
        recoveryTask?.cancel()
        recoveryConversationID = conversationID
        recoveryGeneration += 1
        let generation = recoveryGeneration
        isRetryingConnectivity = trigger == .userRetry
        recoveryTask = Task { [weak self] in
            guard let self else {
                return
            }
            // Ignore a cancelled attempt that finishes after its replacement starts.
            defer {
                if self.recoveryGeneration == generation {
                    self.isRetryingConnectivity = false
                }
            }
            let connected = await self.reconnect(
                conversationID: conversationID,
                trigger: trigger
            )
            // Report success only after the conversation reconnects.
            guard !Task.isCancelled,
                  trigger != .userRetry || connected else {
                return
            }
            if connected {
                self.isOffline = false
            }
            self.deliveryCoordinator.setDeliveryEnabled(!self.isOffline)
            await self.deliveryCoordinator.flushQueuedMessages()
        }
    }

    private func startRecoveryProbing(forConversationID conversationID: String?) {
        probeTask?.cancel()
        probeConversationID = conversationID
        guard let conversationID else {
            return
        }

        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.probeInterval,
                      self?.isOffline == true else {
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled,
                      self?.isOffline == true else {
                    return
                }
                if await self?.reconnect(
                    conversationID: conversationID,
                    trigger: .probe
                ) == true {
                    guard !Task.isCancelled, let self else {
                        return
                    }
                    self.isOffline = false
                    self.deliveryCoordinator.setDeliveryEnabled(true)
                    await self.deliveryCoordinator.flushQueuedMessages()
                    return
                }
            }
        }
    }

    /// Saves the session a connect returned. Opening a chat is not activity, so `.open` keeps the
    /// conversation's place in the list.
    private func storeSession(
        _ session: [String: JSONValue]?,
        for conversation: Conversation,
        agent: SavedAgent,
        trigger: ConnectionRecoveryTrigger
    ) {
        guard let session else {
            return
        }
        var updated = conversationState.conversation(withID: conversation.id) ?? conversation
        updated.agentID = agent.id
        updated.agentAddress = agent.address
        updated.serverSession = HostedAgentSessionState.applying(
            updated.mode,
            to: session,
            conversationID: updated.id
        )
        if trigger == .open {
            conversationState.replaceWithoutActivity(updated)
        } else {
            conversationState.upsert(updated)
        }
    }

    private func reconnect(
        conversationID: String,
        trigger: ConnectionRecoveryTrigger
    ) async -> Bool {
        guard let conversation = conversationState.conversation(withID: conversationID),
              !conversationState.isFromPreviousIdentity(conversation),
              let agent = conversationState.agent(for: conversation),
              HostedAgentClient.isHostedAgentAddress(agent.address) else {
            return false
        }

        await disconnectTask?.value

        let silently = trigger == .probe
        if !silently {
            setConnectionState(.reconnecting, forConversationID: conversationID)
        }
        do {
            let result = try await transport.connect(
                agentAddress: agent.address,
                conversation: conversation
            )
            try Task.checkCancellation()
            guard conversationState.conversation(withID: conversationID) != nil else {
                return false
            }
            // Every CONNECTED carries the host's current mode list. Recording it only on the first connection or
            // after a reply left Full Access mode hidden after the reconnect.
            deliveryCoordinator.noteSessionModes(result.sessionModes, agentAddress: agent.address)
            storeSession(result.serverSession, for: conversation, agent: agent, trigger: trigger)
            setConnectionState(.connected, forConversationID: conversationID)
            // Reconnect refreshes skills
            if trigger != .open {
                onReconnect?(agent)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if let clientError = error as? HostedAgentClientError, case .busy = clientError {
                return false
            }
            if !silently {
                setConnectionState(.disconnected, forConversationID: conversationID)
                // no banner for reopening chat
                if trigger != .open, conversationState.activeConversationID == conversationID {
                    onRecoveryError?(conversationID, error)
                }
            }
            return false
        }
    }

    private func cancelRecovery(forConversationID conversationID: String) {
        if recoveryConversationID == conversationID {
            recoveryTask?.cancel()
            recoveryConversationID = nil
        }
        if probeConversationID == conversationID {
            probeTask?.cancel()
            probeConversationID = nil
        }
    }
}
