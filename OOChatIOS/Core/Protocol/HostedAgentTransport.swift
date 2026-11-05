import ConnectOnionKit

struct HostedAgentFilePayload: Codable, Equatable {
    let name: String
    let data: String

    var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "data": .string(data)
        ])
    }
}

struct HostedAgentPrompt {
    let text: String
    let images: [String]
    let files: [HostedAgentFilePayload]
}

protocol HostedAgentConversationTransport: AnyObject {
    var onConnectionStateChange: (@MainActor (String, ConversationConnectionState) -> Void)? { get set }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult
    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: HostedAgentPrompt,
        onEvent: (@MainActor (HostedAgentEvent) -> Void)?,
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    ) async throws -> HostedAgentResult
    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async
    func noteNetworkLost() async
    func applicationDidBecomeActive()
}

extension HostedAgentConversationTransport {
    func applicationDidBecomeActive() {}
}

protocol AgentAvailabilityChecking: AnyObject {
    func checkAgentAvailability(agentAddress: String) async -> AgentAvailability
}

protocol AgentMetadataProviding: AnyObject {
    func fetchAgentName(agentAddress: String) async throws -> String?
    func fetchSkills(agentAddress: String) async throws -> [AgentSkill]
}

protocol HostedAgentTransport:
    HostedAgentConversationTransport,
    AgentAvailabilityChecking,
    AgentMetadataProviding {}
