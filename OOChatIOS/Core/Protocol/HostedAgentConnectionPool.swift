import ConnectOnionKit
import Foundation

// sends only the newest queued state update for each conversation
final class HostedAgentConnectionStateObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: (@MainActor (String, ConversationConnectionState) -> Void)?
    private var sequenceByConversationID: [String: Int] = [:]

    var handler: (@MainActor (String, ConversationConnectionState) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    func notify(conversationID: String, state: ConversationConnectionState) {
        lock.lock()
        let sequence = (sequenceByConversationID[conversationID] ?? 0) + 1
        sequenceByConversationID[conversationID] = sequence
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let handler = self?.currentHandler(
                conversationID: conversationID,
                sequence: sequence
            ) else {
                return
            }
            handler(conversationID, state)
        }
    }

    private func currentHandler(
        conversationID: String,
        sequence: Int
    ) -> (@MainActor (String, ConversationConnectionState) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard sequenceByConversationID[conversationID] == sequence else {
            return nil
        }
        return storedHandler
    }
}

// identifies one agent socket within one conversation session
struct HostedAgentConnectionKey: Hashable {
    let agentAddress: String
    let conversationID: String
}

// owns a bounded group of reusable conversation sockets
// active leases keep a connection from being evicted
actor HostedAgentConnectionPool {
    private struct Entry {
        let connection: HostedAgentConnection
        var activeLeases: Int
        var lastUsedAt: Date
    }

    private struct Lease {
        let key: HostedAgentConnectionKey
        let connection: HostedAgentConnection
    }

    private let identityStore: IdentityStore
    private let session: URLSession
    private let maximumSize: Int
    private let idleLifetime: TimeInterval
    private let discovery: HostedAgentDiscovery
    private let connectionStateObserver: HostedAgentConnectionStateObserver
    private let socketFactory: HostedAgentWebSocketFactory?
    private let endpointResolver: HostedAgentEndpointResolver?
    private let connectTimeout: TimeInterval
    private let livenessTimeout: TimeInterval
    private let livenessCheckInterval: TimeInterval
    private let resumeAttemptLimit: Int
    private let resumeRetryDelay: TimeInterval
    private let now: @Sendable () -> Date

    private var connections: [HostedAgentConnectionKey: Entry] = [:]
    private var cleanupTask: Task<Void, Never>?

    init(
        identityStore: IdentityStore,
        session: URLSession,
        maximumSize: Int,
        idleLifetime: TimeInterval,
        discovery: HostedAgentDiscovery,
        connectionStateObserver: HostedAgentConnectionStateObserver,
        socketFactory: HostedAgentWebSocketFactory? = nil,
        endpointResolver: HostedAgentEndpointResolver? = nil,
        connectTimeout: TimeInterval = 45,
        livenessTimeout: TimeInterval = 75,
        livenessCheckInterval: TimeInterval = 10,
        resumeAttemptLimit: Int = 3,
        resumeRetryDelay: TimeInterval = 1,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.identityStore = identityStore
        self.session = session
        self.maximumSize = max(1, maximumSize)
        self.idleLifetime = max(1, idleLifetime)
        self.discovery = discovery
        self.connectionStateObserver = connectionStateObserver
        self.socketFactory = socketFactory
        self.endpointResolver = endpointResolver
        self.connectTimeout = connectTimeout
        self.livenessTimeout = livenessTimeout
        self.livenessCheckInterval = livenessCheckInterval
        self.resumeAttemptLimit = resumeAttemptLimit
        self.resumeRetryDelay = resumeRetryDelay
        self.now = now
    }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult {
        let lease = await acquire(agentAddress: agentAddress, conversationID: conversation.id)
        do {
            let result = try await lease.connection.ensureConnected(conversation: conversation)
            release(lease)
            await trimToSize()
            return result
        } catch {
            release(lease)
            await trimToSize()
            throw error
        }
    }

    func requestModeChange(
        agentAddress: String,
        conversation: Conversation,
        mode: OIPPermissionMode,
        onEvent: @escaping @MainActor (HostedAgentEvent) -> Void
    ) async throws {
        let lease = await acquire(agentAddress: agentAddress, conversationID: conversation.id)
        do {
            try await lease.connection.requestModeChange(
                conversation: conversation,
                mode: mode,
                onEvent: onEvent
            )
            release(lease)
            await trimToSize()
        } catch {
            release(lease)
            await trimToSize()
            throw error
        }
    }

    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        images: [String] = [],
        files: [HostedAgentFilePayload] = [],
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?,
        onInputDispatched: (@MainActor () -> Void)? = nil
    ) async throws -> HostedAgentResult {
        let lease = await acquire(agentAddress: agentAddress, conversationID: conversation.id)
        do {
            let result = try await lease.connection.sendPrompt(
                conversation: conversation,
                prompt: prompt,
                images: images,
                files: files,
                onEvent: onEvent,
                onInteraction: onInteraction,
                onInputDispatched: onInputDispatched
            )
            release(lease)
            await trimToSize()
            return result
        } catch {
            release(lease)
            await trimToSize()
            throw error
        }
    }

    func resumePrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: String,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    ) async throws -> HostedAgentResult {
        let lease = await acquire(agentAddress: agentAddress, conversationID: conversation.id)
        do {
            let result = try await lease.connection.resumePrompt(
                conversation: conversation,
                prompt: prompt,
                onEvent: onEvent,
                onInteraction: onInteraction
            )
            release(lease)
            await trimToSize()
            return result
        } catch {
            release(lease)
            await trimToSize()
            throw error
        }
    }

    func exec(
        agentAddress: String,
        conversation: Conversation,
        execID: String,
        tool: String,
        args: [String: JSONValue]
    ) async throws -> OIPExecResult {
        let lease = await acquire(agentAddress: agentAddress, conversationID: conversation.id)
        do {
            let result = try await lease.connection.exec(
                conversation: conversation,
                execID: execID,
                tool: tool,
                args: args
            )
            release(lease)
            await trimToSize()
            return result
        } catch {
            release(lease)
            await trimToSize()
            throw error
        }
    }

    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async {
        let key = HostedAgentConnectionKey(agentAddress: agentAddress, conversationID: conversationID)
        guard let connection = connections[key]?.connection else {
            return
        }
        await connection.waitForPendingInteractionResponses()
    }

    func noteApplicationBecameActive() async {
        for entry in connections.values {
            await entry.connection.noteApplicationBecameActive()
        }
    }

    func noteNetworkLost() async {
        let idleKeys = connections.compactMap { key, entry in
            entry.activeLeases == 0 ? key : nil
        }
        let idleConnections = idleKeys.compactMap { key in
            connections.removeValue(forKey: key)?.connection
        }
        let leasedConnections = connections.values.map(\.connection)
        for connection in idleConnections {
            await connection.close()
        }
        for connection in leasedConnections {
            await connection.noteNetworkLost()
        }
    }

    func closeAll() async {
        cleanupTask?.cancel()
        cleanupTask = nil
        let activeConnections = connections.values.map(\.connection)
        connections.removeAll()
        for connection in activeConnections {
            await connection.close()
        }
    }

    private func acquire(agentAddress: String, conversationID: String) async -> Lease {
        // remove expired entries before checking the pool limit
        startCleanupTaskIfNeeded()
        await evictExpiredConnections()

        let key = HostedAgentConnectionKey(agentAddress: agentAddress, conversationID: conversationID)
        if var entry = connections[key] {
            // reuse keeps session state and the socket handshake intact
            entry.activeLeases += 1
            entry.lastUsedAt = now()
            connections[key] = entry
            return Lease(key: key, connection: entry.connection)
        }

        // active entries can let the pool grow until their leases are released
        while connections.count >= maximumSize, await evictLeastRecentlyUsedIdleConnection() {}

        let connection = HostedAgentConnection(
            key: key,
            identityStore: identityStore,
            session: session,
            discovery: discovery,
            connectionStateObserver: connectionStateObserver,
            socketFactory: socketFactory,
            endpointResolver: endpointResolver,
            connectTimeout: connectTimeout,
            livenessTimeout: livenessTimeout,
            livenessCheckInterval: livenessCheckInterval,
            resumeAttemptLimit: resumeAttemptLimit,
            resumeRetryDelay: resumeRetryDelay
        )
        connections[key] = Entry(connection: connection, activeLeases: 1, lastUsedAt: now())
        return Lease(key: key, connection: connection)
    }

    private func release(_ lease: Lease) {
        guard var entry = connections[lease.key], entry.connection === lease.connection else {
            return
        }
        entry.activeLeases = max(0, entry.activeLeases - 1)
        entry.lastUsedAt = now()
        connections[lease.key] = entry
    }

    private func startCleanupTaskIfNeeded() {
        guard cleanupTask == nil else {
            return
        }
        // run cleanup often enough for short idle lifetimes without polling too fast
        let interval = min(30, max(1, idleLifetime / 2))
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                await self?.evictExpiredConnections()
            }
        }
    }

    private func evictExpiredConnections() async {
        // update the dictionary before awaiting connection shutdown
        let cutoff = now().addingTimeInterval(-idleLifetime)
        let expiredKeys = connections.compactMap { key, entry in
            entry.activeLeases == 0 && entry.lastUsedAt < cutoff ? key : nil
        }
        let expiredConnections = expiredKeys.compactMap { key in
            connections.removeValue(forKey: key)?.connection
        }
        for connection in expiredConnections {
            await connection.close()
        }
    }

    @discardableResult
    private func evictLeastRecentlyUsedIdleConnection() async -> Bool {
        var candidate: (key: HostedAgentConnectionKey, entry: Entry)?
        for (key, entry) in connections {
            // leased connections stay pinned until their operation completes
            guard entry.activeLeases == 0 else {
                continue
            }
            if candidate == nil || entry.lastUsedAt < candidate!.entry.lastUsedAt {
                candidate = (key, entry)
            }
        }
        guard let candidate,
              let removed = connections.removeValue(forKey: candidate.key),
              removed.connection === candidate.entry.connection else {
            return false
        }
        await removed.connection.close()
        return true
    }

    private func trimToSize() async {
        // stop when every remaining connection still has an active lease
        while connections.count > maximumSize {
            guard await evictLeastRecentlyUsedIdleConnection() else {
                return
            }
        }
    }
}
