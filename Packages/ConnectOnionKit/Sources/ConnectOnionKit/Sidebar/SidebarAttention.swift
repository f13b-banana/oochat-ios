import Foundation

/// The line at the top of the sidebar when a chat needs you, so folding an agent never hides it.
/// Kept to one short line; the chats themselves are a tap away.
public enum SidebarAttention {
    /// `statuses`: one per chat. Working chats don't need you and aren't counted.
    public static func summary(_ statuses: [SidebarChatStatus]) -> String? {
        let needingYou = statuses.filter(\.needsYou)
        switch needingYou.count {
        case 0:
            return nil
        case 1:
            switch needingYou[0] {
            case .approval: return "1 chat needs approval"
            case .reply: return "1 chat needs a reply"
            case .notSent, .working: return "1 message not sent"
            }
        default:
            return "\(needingYou.count) chats need attention"
        }
    }
}
