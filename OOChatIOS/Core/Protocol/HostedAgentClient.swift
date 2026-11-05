import Foundation
import ConnectOnionKit

final class HostedAgentClient: HostedAgentTransport {
    private let connectionPool: HostedAgentConnectionPool
    private let discovery: HostedAgentDiscovery
    private let connectionStateObserver: HostedAgentConnectionStateObserver

    var onConnectionStateChange: (@MainActor (String, ConversationConnectionState) -> Void)? {
        get { connectionStateObserver.handler }
        set { connectionStateObserver.handler = newValue }
    }

    init(
        identityStore: IdentityStore,
        session: URLSession = .shared,
        poolSize: Int = 3,
        connectionIdleLifetime: TimeInterval = 5 * 60
    ) {
        let relayURL = "wss://oo.openonion.ai"
        let localEndpoints = ["http://localhost:8000", "http://127.0.0.1:8000"]
        let discovery = HostedAgentDiscovery(
            session: session,
            relayURL: relayURL,
            localEndpoints: localEndpoints
        )
        let connectionStateObserver = HostedAgentConnectionStateObserver()
        self.discovery = discovery
        self.connectionStateObserver = connectionStateObserver
        connectionPool = HostedAgentConnectionPool(
            identityStore: identityStore,
            session: session,
            maximumSize: poolSize,
            idleLifetime: connectionIdleLifetime,
            discovery: discovery,
            connectionStateObserver: connectionStateObserver
        )
    }

    deinit {
        let connectionPool = connectionPool
        Task {
            await connectionPool.closeAll()
        }
    }

    static func isHostedAgentAddress(_ address: String) -> Bool {
        address.range(of: #"^0x[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil
    }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        return try await connectionPool.connect(agentAddress: agentAddress, conversation: conversation)
    }

    func checkAgentAvailability(agentAddress: String) async -> AgentAvailability {
        guard Self.isHostedAgentAddress(agentAddress) else {
            return .unknown
        }
        return await discovery.checkAvailability(agentAddress: agentAddress)
    }

    func fetchAgentName(agentAddress: String) async throws -> String? {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        let result = try await discovery.discover(agentAddress: agentAddress)
        guard result.metadataAvailable else {
            throw HostedAgentClientError.server("Agent metadata is unavailable.")
        }
        return result.name
    }

    func fetchSkills(agentAddress: String) async throws -> [AgentSkill] {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        let result = try await discovery.discover(agentAddress: agentAddress)
        guard result.metadataAvailable else {
            throw HostedAgentClientError.server("Agent skill metadata is unavailable.")
        }
        return result.skills
    }

    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: HostedAgentPrompt,
        handlers: HostedAgentPromptHandlers
    ) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        return try await connectionPool.sendPrompt(
            agentAddress: agentAddress,
            conversation: conversation,
            prompt: prompt.text,
            images: prompt.images,
            files: prompt.files,
            onEvent: handlers.onEvent,
            onInteraction: handlers.onInteraction,
            onInputDispatched: handlers.onInputDispatched
        )
    }

    func resumePrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: HostedAgentPrompt,
        handlers: HostedAgentPromptHandlers
    ) async throws -> HostedAgentResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        return try await connectionPool.resumePrompt(
            agentAddress: agentAddress,
            conversation: conversation,
            prompt: prompt.text,
            onEvent: handlers.onEvent,
            onInteraction: handlers.onInteraction
        )
    }

    func execTool(
        agentAddress: String,
        conversation: Conversation,
        execID: String,
        tool: String,
        args: [String: JSONValue]
    ) async throws -> OIPExecResult {
        guard Self.isHostedAgentAddress(agentAddress) else {
            throw HostedAgentClientError.invalidAddress
        }
        return try await connectionPool.exec(
            agentAddress: agentAddress,
            conversation: conversation,
            execID: execID,
            tool: tool,
            args: args
        )
    }

    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async {
        await connectionPool.waitForPendingInteractionResponses(
            agentAddress: agentAddress,
            conversationID: conversationID
        )
    }

    func noteNetworkLost() async {
        await connectionPool.noteNetworkLost()
    }

    func applicationDidBecomeActive() {
        let connectionPool = connectionPool
        Task {
            await connectionPool.noteApplicationBecameActive()
        }
    }
}
