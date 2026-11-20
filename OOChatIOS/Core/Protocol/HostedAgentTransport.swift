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

// The callbacks for one prompt, grouped so sendPrompt and resumePrompt keep a short parameter list.
struct HostedAgentPromptHandlers {
    var onEvent: (@MainActor (HostedAgentEvent) -> Void)?
    var onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    // Called just before the INPUT frame is written, every time it is written.
    // resumePrompt never sends INPUT, so it never calls this.
    var onInputDispatched: (@MainActor () -> Void)?
}

protocol HostedAgentConversationTransport: AnyObject {
    var onConnectionStateChange: (@MainActor (String, ConversationConnectionState) -> Void)? { get set }
    var onAgentProfile: (@MainActor (String, OIPAgentProfile) -> Void)? { get set }
    var onSessionUpdate: (@MainActor (String, HostedAgentSessionUpdate) -> Void)? { get set }
    var onProviderUpdate: (@MainActor (String, HostedAgentProviderUpdate) -> Void)? { get set }
    var ownsApproval: (@MainActor (String, [String: JSONValue]) -> Bool)? { get set }

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult
    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: HostedAgentPrompt,
        handlers: HostedAgentPromptHandlers
    ) async throws -> HostedAgentResult
    // Settles a prompt that an earlier run of the app may already have sent. Never sends INPUT.
    func resumePrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: HostedAgentPrompt,
        handlers: HostedAgentPromptHandlers
    ) async throws -> HostedAgentResult
    func requestModeChange(
        agentAddress: String,
        conversation: Conversation,
        mode: OIPPermissionMode,
        onEvent: @escaping @MainActor (HostedAgentEvent) -> Void
    ) async throws
    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async
    // Drops this chat's socket so the next send reconnects with the app's copy of the session,
    // which the host only reads on CONNECT.
    func restartSession(agentAddress: String, conversationID: String) async
    // Answers an ONBOARD_REQUIRED on the conversation's open socket with ONBOARD_SUBMIT.
    func submitOnboarding(agentAddress: String, conversationID: String, code: String) async throws
    func noteNetworkLost() async
    func applicationDidBecomeActive()
}

extension HostedAgentConversationTransport {
    func applicationDidBecomeActive() {}

    func restartSession(agentAddress: String, conversationID: String) async {}

    var onSessionUpdate: (@MainActor (String, HostedAgentSessionUpdate) -> Void)? {
        get { nil }
        set { _ = newValue }
    }

    var onProviderUpdate: (@MainActor (String, HostedAgentProviderUpdate) -> Void)? {
        get { nil }
        set { _ = newValue }
    }

    var ownsApproval: (@MainActor (String, [String: JSONValue]) -> Bool)? {
        get { nil }
        set { _ = newValue }
    }

    func submitOnboarding(agentAddress: String, conversationID: String, code: String) async throws {
        throw HostedAgentClientError.closed
    }

    // Default for test doubles that don't support mode control.
    func requestModeChange(
        agentAddress: String,
        conversation: Conversation,
        mode: OIPPermissionMode,
        onEvent: @escaping @MainActor (HostedAgentEvent) -> Void
    ) async throws {
        throw HostedAgentClientError.server("This transport does not support mode changes.")
    }
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
