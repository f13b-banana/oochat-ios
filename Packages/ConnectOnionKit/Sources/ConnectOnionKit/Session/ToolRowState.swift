import SwiftUI

/// What a tool row shows. Both apps map their own tool records onto this, so the words,
/// glyphs, colours and group summary are the same on iOS and macOS.
public enum ToolRowState: String, CaseIterable, Sendable {
    case running
    /// The host announced the tool, then asked permission before running it.
    case awaitingApproval
    case completed
    case failed
    /// Still running when the run ended: Stop, a lost connection, or a stopped batch.
    case interrupted
    /// You chose Skip on its approval, so it never ran.
    case skipped

    public var label: String {
        switch self {
        case .running: return "Running"
        case .awaitingApproval: return "Awaiting approval"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .skipped: return "Skipped"
        }
    }

    /// The glyph for a state that isn't moving. nil for running (a spinner) and completed
    /// (the tool's own icon).
    public var systemImage: String? {
        switch self {
        case .awaitingApproval: return "hand.raised.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .interrupted: return "stop.circle"
        case .skipped: return "minus.circle"
        case .running, .completed: return nil
        }
    }

    /// Green while it runs, amber while it waits on you (as the approval card), red only when
    /// it failed. Interrupted and skipped are your choice, not an error, so they stay grey.
    public var tint: Color {
        switch self {
        case .running: return OOColor.primary
        case .awaitingApproval: return OOColor.decisionMark
        case .failed: return OOColor.failureMark
        case .completed, .interrupted, .skipped: return OOColor.inkSecondary
        }
    }

    /// Running and awaiting approval can still change; the rest are final.
    public var isSettled: Bool {
        self != .running && self != .awaitingApproval
    }

    public func accessibilityLabel(toolName: String) -> String {
        switch self {
        case .running: return "\(toolName), running"
        case .awaitingApproval: return "\(toolName), waiting for your approval"
        case .completed: return "\(toolName), completed"
        case .failed: return "\(toolName), failed"
        case .interrupted: return "\(toolName), interrupted before it finished"
        case .skipped: return "\(toolName), skipped"
        }
    }

    /// The state a group of rows shows: the most urgent one. nil for no rows.
    public static func summary(of states: [ToolRowState]) -> ToolRowState? {
        let urgency: [ToolRowState] = [.awaitingApproval, .running, .failed, .interrupted, .skipped, .completed]
        return urgency.first(where: states.contains)
    }

    /// The group header while something is still open; nil once all are settled, when each
    /// app describes what the tools did.
    public static func groupTitle(for states: [ToolRowState]) -> String? {
        switch summary(of: states) {
        case .awaitingApproval:
            return "Waiting for your approval"
        case .running:
            let count = states.count
            return count == 1 ? "Running 1 tool" : "Running \(count) tools"
        default:
            return nil
        }
    }
}
