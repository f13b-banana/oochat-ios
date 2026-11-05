import Foundation
import ConnectOnionKit

enum ConversationConnectionState: String, Codable {
    case disconnected
    case connected
    case reconnecting
}

enum ChatRole: String, Codable {
    case user
    case agent
    case thinking
    case tool
    case error
}

enum ChatMode: String, CaseIterable, Codable, Identifiable, Equatable {
    case safe
    case plan
    case accept = "accept_edits"
    case ulw

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .safe:
            return "Safe"
        case .plan:
            return "Plan"
        case .accept:
            return "Accept Edits"
        case .ulw:
            return "Ultra Work"
        }
    }
}

enum MessageDeliveryState: String, Codable, Equatable {
    case sent
    case queued
    /// The INPUT may have reached the host but no reply was recorded. The app never sends
    /// it again on its own; it reconnects and asks the host what happened to it.
    case transmitted
    case failed
    case cancelled
}

enum ToolCallState: String, Codable, Equatable {
    case running
    case completed
    case failed
}

struct ChatImageAttachment: Identifiable, Codable, Equatable {
    static let maximumCount = 10
    static let maximumByteCount = 10 * 1024 * 1024

    let id: String
    let data: Data
    let mimeType: String

    init(
        id: String = UUID().uuidString,
        data: Data,
        mimeType: String
    ) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct ChatFileAttachment: Identifiable, Codable, Equatable {
    static let maximumCount = 10
    static let maximumByteCount = 10 * 1024 * 1024

    let id: String
    let name: String
    let data: Data
    let mimeType: String

    init(
        id: String = UUID().uuidString,
        name: String,
        data: Data,
        mimeType: String
    ) {
        self.id = id
        self.name = name
        self.data = data
        self.mimeType = mimeType
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    var role: ChatRole
    var content: String
    var createdAt: Date
    var deliveryState: MessageDeliveryState
    var images: [ChatImageAttachment]
    var files: [ChatFileAttachment]
    var toolName: String?
    var toolArguments: [String: JSONValue]?
    var toolState: ToolCallState?

    init(
        id: String = UUID().uuidString,
        role: ChatRole,
        content: String,
        createdAt: Date = Date(),
        deliveryState: MessageDeliveryState = .sent,
        images: [ChatImageAttachment] = [],
        files: [ChatFileAttachment] = [],
        toolName: String? = nil,
        toolArguments: [String: JSONValue]? = nil,
        toolState: ToolCallState? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.images = images
        self.files = files
        self.toolName = toolName
        self.toolArguments = toolArguments
        self.toolState = toolState
    }
}

extension ChatMessage {
    /// Tool cards made by `/exec` carry this id prefix, so they can be told apart from the agent's
    /// own tool calls without a new stored field.
    static let directExecIDPrefix = "exec-"

    var isDirectExec: Bool {
        role == .tool && id.hasPrefix(Self.directExecIDPrefix)
    }
}

struct Conversation: Identifiable, Equatable {
    let id: String
    var title: String
    var agentID: String?
    var agentAddress: String
    var mode: ChatMode
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var serverSession: [String: JSONValue]?

    /// Placeholder title; `MessageDeliveryCoordinator` compares against it to decide whether
    /// the first prompt should name the conversation.
    static let defaultTitle = "New mobile session"

    init(agentID: String? = nil, agentAddress: String = "") {
        let now = Date()
        self.id = UUID().uuidString
        self.title = Self.defaultTitle
        self.agentID = agentID
        self.agentAddress = agentAddress
        self.mode = .safe
        self.createdAt = now
        self.updatedAt = now
        self.messages = []
    }

    init(
        id: String,
        title: String,
        agentID: String?,
        agentAddress: String,
        mode: ChatMode,
        createdAt: Date,
        updatedAt: Date,
        messages: [ChatMessage],
        serverSession: [String: JSONValue]?
    ) {
        self.id = id
        self.title = title
        self.agentID = agentID
        self.agentAddress = agentAddress
        self.mode = mode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.serverSession = serverSession
    }

}

struct ChatSnapshot: Equatable {
    var agents: [SavedAgent]
    var conversations: [Conversation]
    var activeAgentID: String?
    var activeConversationID: String?

    static let empty = ChatSnapshot(
        agents: [],
        conversations: [],
        activeAgentID: nil,
        activeConversationID: nil
    )
}
