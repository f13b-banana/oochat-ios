import ConnectOnionKit
import SwiftUI

struct ChatScrollUpdate: Equatable {
    let conversationID: String
    let messageCount: Int
    let messageID: String?
    /// Length rather than the text itself: this is rebuilt on every redraw purely to detect
    /// change, and a streamed reply still grows it by one on each token — copying the whole
    /// body into an Equatable struct per token is pure allocation churn.
    let contentLength: Int
    let deliveryState: String
    let toolState: String

    func isNewMessage(comparedTo previous: ChatScrollUpdate) -> Bool {
        conversationID == previous.conversationID
            && (messageCount != previous.messageCount || messageID != previous.messageID)
    }
}

enum ChatScrollMetrics {
    static let followThreshold: CGFloat = 80
    /// Jump to latest only shows once you're this many screens up, not just past the follow point.
    static let jumpToLatestScreens: CGFloat = 1.5
    static let keyboardFollowUpDelay: DispatchTimeInterval = .milliseconds(250)
}

// Caps the message column so text stays at a readable line length on iPad, where the
// content region is far wider than any phone. Below this width it is inert, so compact
// layouts keep their existing full-bleed behavior.
enum ChatReadableWidth {
    static let maximum: CGFloat = 720
}

enum ChatTimelineEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case toolCallGroup([ChatMessage])
    case workRoom(WorkRoom)

    var id: String {
        switch self {
        case .message(let message):
            return message.id
        case .toolCallGroup(let messages):
            return messages.first?.id ?? "toolCallGroup"
        case .workRoom(let workRoom):
            return "workRoom.\(workRoom.id)"
        }
    }
}

enum ChatTimelineBuilder {
    /// A Provider Invocation replaces its outer tool_call: the Work Room Card takes the root's place
    /// and the tool_call rows of the group are hidden.
    @MainActor
    static func entries(from messages: [ChatMessage], workRooms: WorkRoomStore? = nil) -> [ChatTimelineEntry] {
        var entries: [ChatTimelineEntry] = []
        var pendingToolCalls: [ChatMessage] = []

        func appendPendingToolCalls() {
            guard !pendingToolCalls.isEmpty else {
                return
            }

            if pendingToolCalls.count == 1, let message = pendingToolCalls.first {
                entries.append(.message(message))
            } else {
                entries.append(.toolCallGroup(pendingToolCalls))
            }
            pendingToolCalls.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if message.role == .tool, let workRooms, workRooms.isProviderToolCall(message.id) {
                if let workRoom = workRooms.workRoom(forToolCallID: message.id) {
                    appendPendingToolCalls()
                    entries.append(.workRoom(workRoom))
                }
            } else if message.role == .tool {
                pendingToolCalls.append(message)
            } else {
                appendPendingToolCalls()
                entries.append(.message(message))
            }
        }

        appendPendingToolCalls()
        return entries
    }
}
