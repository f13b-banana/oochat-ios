import Foundation
import ConnectOnionKit

struct ToolApprovalBatchItem: Equatable {
    let tool: String
    let arguments: JSONValue

    init(tool: String, arguments: [String: JSONValue] = [:]) {
        self.tool = tool
        self.arguments = .object(arguments)
    }

    init(tool: String, rawArguments: JSONValue) {
        self.tool = tool
        self.arguments = rawArguments
    }
}

struct ToolApprovalRequest: Identifiable, Equatable {
    let id: String
    let tool: String
    let arguments: [String: JSONValue]
    let description: String?
    let batchRemaining: [ToolApprovalBatchItem]

    init(
        id: String = UUID().uuidString,
        tool: String,
        arguments: [String: JSONValue],
        description: String? = nil,
        batchRemaining: [ToolApprovalBatchItem] = []
    ) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
        self.description = description
        self.batchRemaining = batchRemaining
    }
}

enum ApprovalDecision: Equatable {
    case allowOnce
    case allowSession
    case rejectSoft(feedback: String?)
    case rejectHard(feedback: String?)
    case rejectExplain(feedback: String?)
}

struct PendingApproval: Identifiable, Equatable {
    let conversationID: String
    let request: ToolApprovalRequest

    var id: String {
        request.id
    }
}

struct UlwCheckpointRequest: Identifiable, Equatable {
    let id: String
    let turnsUsed: Int
    let maxTurns: Int

    init(id: String = UUID().uuidString, turnsUsed: Int, maxTurns: Int) {
        self.id = id
        self.turnsUsed = turnsUsed
        self.maxTurns = maxTurns
    }
}

enum UlwCheckpointDecision: Equatable {
    case continueWork(turns: Int)
    case switchMode(ChatMode)
}

struct PendingUlwCheckpoint: Identifiable, Equatable {
    let conversationID: String
    let request: UlwCheckpointRequest

    var id: String { request.id }
}

struct PlanReviewRequest: Identifiable, Equatable {
    let id: String
    let planContent: String

    init(id: String = UUID().uuidString, planContent: String) {
        self.id = id
        self.planContent = planContent
    }
}

enum PlanReviewDecision: Equatable {
    case approve
    case requestChanges(feedback: String?)
}

struct PendingPlanReview: Identifiable, Equatable {
    let conversationID: String
    let request: PlanReviewRequest

    var id: String { request.id }
}

struct AskUserField: Identifiable, Equatable {
    let name: String
    let label: String
    let type: String
    let placeholder: String?

    var id: String { name }

    init(name: String, label: String, type: String = "text", placeholder: String? = nil) {
        self.name = name
        self.label = label
        self.type = type
        self.placeholder = placeholder
    }

    var isSecure: Bool {
        type.lowercased() == "password"
    }
}

struct AskUserRequest: Identifiable, Equatable {
    let id: String
    let question: String
    let options: [String]
    let multiSelect: Bool
    let fields: [AskUserField]

    init(
        id: String = UUID().uuidString,
        question: String,
        options: [String] = [],
        multiSelect: Bool = false,
        fields: [AskUserField] = []
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.fields = fields
    }
}

enum AskUserDecision: Equatable {
    case answer(String)
    case cancel
}

/// An agent interaction that pauses a turn until the user responds.
enum HostedAgentInteraction: Identifiable, Equatable {
    case approval(ToolApprovalRequest)
    case ulwCheckpoint(UlwCheckpointRequest)
    case planReview(PlanReviewRequest)
    case askUser(AskUserRequest)

    var id: String {
        switch self {
        case .approval(let request):
            return request.id
        case .ulwCheckpoint(let request):
            return request.id
        case .planReview(let request):
            return request.id
        case .askUser(let request):
            return request.id
        }
    }
}

/// A response paired with the interaction kind it answers.
enum HostedAgentInteractionDecision: Equatable {
    case approval(ApprovalDecision)
    case ulwCheckpoint(UlwCheckpointDecision)
    case planReview(PlanReviewDecision)
    case askUser(AskUserDecision)
    /// The agent replaced this request, so no response should be sent.
    case superseded
}

struct PendingAskUser: Identifiable, Equatable {
    let conversationID: String
    let request: AskUserRequest

    var id: String { request.id }
}
