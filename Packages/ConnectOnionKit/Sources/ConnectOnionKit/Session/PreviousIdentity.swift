import Foundation

/// Previous-Identity Conversations: local chats made under an Address this device no longer holds.
/// They stay readable but are never resumed or merged; the app shows `label` and offers
/// `startNewChat` in place of its composer.
public enum PreviousIdentity {
    public static let label = "From a previous identity"
    public static let startNewChat = "Start a new chat with this agent"

    /// Stamped with an Address other than `current`. Unstamped means made under the current Address.
    /// Compared case-insensitively. A stamp with an unknown current Address (nil) counts as previous.
    public static func isPrevious(stamp: String?, current: String?) -> Bool {
        guard let stamp else { return false }
        return !AgentAddress.same(stamp, current)
    }

    /// On replace: an unstamped conversation takes the Address being replaced; a stamped one keeps its own.
    public static func stamp(_ existing: String?, replacing previous: String) -> String {
        existing ?? previous
    }
}
