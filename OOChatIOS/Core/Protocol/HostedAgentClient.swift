import CryptoKit
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

    static func connectSignaturePayload(
        agentAddress: String,
        conversationID: String,
        session: [String: JSONValue],
        timestamp: Double
    ) -> [String: JSONValue] {
        [
            "action": .string("session.connect"),
            "to": .string(agentAddress),
            "timestamp": .number(timestamp),
            "session_id": .string(conversationID),
            "session_sha256": .string(canonicalSHA256(.object(session))),
        ]
    }

    static func inputSignaturePayload(
        agentAddress: String,
        conversationID: String,
        inputID: String,
        prompt: String,
        mode: ChatMode,
        timestamp: Double,
        images: [String] = [],
        files: [HostedAgentFilePayload] = []
    ) -> [String: JSONValue] {
        [
            "action": .string("session.input"),
            "to": .string(agentAddress),
            "timestamp": .number(timestamp),
            "session_id": .string(conversationID),
            "input_id": .string(inputID),
            "prompt": .string(prompt),
            "mode": .string(mode.rawValue),
            "attachments_sha256": .string(
                canonicalSHA256(
                    .object([
                        "images": .array(images.map(JSONValue.string)),
                        "files": .array(files.map(\.jsonValue)),
                    ])
                )
            ),
        ]
    }

    private static func canonicalSHA256(_ value: JSONValue) -> String {
        let digest = SHA256.hash(data: Data(CanonicalJSON.string(from: value).utf8))
        return Hex.encode(Data(digest))
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
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
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
            onEvent: onEvent,
            onInteraction: onInteraction
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

    static func approvalResponseFrame(
        decision: ApprovalDecision,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        let recipient = endpoint.kind == .relay ? agentAddress : nil
        return decision.responseFrame(to: recipient)
    }

    static func ulwResponseFrame(
        decision: UlwCheckpointDecision,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        routedInteractiveFrame(
            decision.responseFrame,
            agentAddress: agentAddress,
            endpoint: endpoint
        )
    }

    static func planReviewResponseFrame(
        decision: PlanReviewDecision,
        request: PlanReviewRequest,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        routedInteractiveFrame(
            decision.responseFrame(for: request),
            agentAddress: agentAddress,
            endpoint: endpoint
        )
    }

    static func askUserResponseFrame(
        answer: String,
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        routedInteractiveFrame(
            [
                "type": .string("ASK_USER_RESPONSE"),
                "answer": .string(answer),
            ],
            agentAddress: agentAddress,
            endpoint: endpoint
        )
    }

    private static func routedInteractiveFrame(
        _ frame: [String: JSONValue],
        agentAddress: String,
        endpoint: ResolvedEndpoint
    ) -> [String: JSONValue] {
        guard endpoint.kind == .relay else {
            return frame
        }
        var routed = frame
        routed["to"] = .string(agentAddress)
        return routed
    }

}
