import SwiftUI

/// What a chat row says in place of its time when something is happening. Ordered by urgency:
/// waiting on you (an approval, or a question or code to answer), then a message that didn't
/// send, then the agent just working.
public enum SidebarChatStatus: Int, CaseIterable, Comparable, Sendable {
    case approval
    /// The agent asked something only you can answer: a question, an invite code, a plan to
    /// review or a checkpoint. Not an approval, so it doesn't say Approve.
    case reply
    case notSent
    case working

    public static func < (lhs: SidebarChatStatus, rhs: SidebarChatStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The one a row shows when several apply.
    public static func mostUrgent(_ statuses: [SidebarChatStatus]) -> SidebarChatStatus? {
        statuses.min()
    }

    /// Waiting on you or failed; working only needs patience.
    public var needsYou: Bool {
        self != .working
    }

    public var label: String {
        switch self {
        case .approval: return "Approve"
        case .reply: return "Reply"
        case .notSent: return "Not sent"
        case .working: return "Working"
        }
    }

    /// For VoiceOver, after the chat's title.
    public var spokenLabel: String {
        switch self {
        case .approval: return "needs your approval"
        case .reply: return "waiting for your reply"
        case .notSent: return "message not sent"
        case .working: return "agent working"
        }
    }

    /// nil for working, which shows a spinner.
    public var systemImage: String? {
        switch self {
        case .approval: return "hand.raised.fill"
        case .reply: return "bubble.left.fill"
        case .notSent: return "exclamationmark.triangle.fill"
        case .working: return nil
        }
    }

    /// Amber when it waits on you, as the approval card; red only for a message that didn't
    /// send; grey for working.
    public var tint: Color {
        switch self {
        case .approval, .reply: return OOColor.decisionMark
        case .notSent: return OOColor.failureText
        case .working: return OOColor.inkSecondary
        }
    }
}
