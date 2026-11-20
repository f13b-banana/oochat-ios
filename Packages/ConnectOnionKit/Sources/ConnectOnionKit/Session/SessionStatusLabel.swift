import Foundation

/// The chat header's words for a session, shared so both apps say the same thing.
/// The socket state wins; once connected, the host's own status (CONNECTED `status`
/// or a SESSION_STATUS reply) says whether a run is still going.

public enum SessionStatusLabel {
    /// O Chat polls this often; poll only while the last answer was `running` (README, SESSION_STATUS rule).
    public static let pollInterval: TimeInterval = 10
    public static func text(
        state: SessionState,
        hasBookmark: Bool,
        hostStatus: String?
    ) -> String {
        guard state == .connected else {
            return state.displayName(hasBookmark: hasBookmark)
        }

        switch hostStatus {
        case "running":
            return "Running"
        case "new":
            return "New session"
        default:
            return "Connected"
        }
    }

    /// Keep polling only while the host still reports a run in progress.
    public static func keepsPolling(after hostStatus: String) -> Bool {
        hostStatus == "running"
    }

    /// The state machine event a SESSION_STATUS reply causes, if any.
    public static func event(for hostStatus: String) -> SessionEvent? {
        hostStatus == "not_found" ? .notFound : nil
    }
}
