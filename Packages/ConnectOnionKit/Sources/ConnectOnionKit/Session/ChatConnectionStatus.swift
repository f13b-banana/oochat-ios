import Foundation

/// The one status a chat shows, with the same words on iOS and macOS.
/// Built from this chat's own connection, never from a background reachability check.
public enum ChatConnectionStatus: Equatable, Sendable {
    case live
    /// The agent is running a turn.
    case working
    case connecting
    /// Idle: nothing is trying to connect.
    case notConnected
    case unreachable(Reason)

    public enum Reason: Equatable, Sendable {
        /// Still not connected after `unreachableAfter`.
        case noAnswer
        case noNetwork
        case sessionEnded
        case incompatible
    }

    /// How long "Connecting…" shows before it becomes "Can't connect".
    public static let unreachableAfter: TimeInterval = 10

    /// `connectingFor`: seconds this chat has been connecting, measured by the app (0 when not connecting).
    public init(state: SessionState, hostStatus: String?, connectingFor: TimeInterval) {
        switch state {
        case .connected:
            self = hostStatus == "running" ? .working : .live
        case .connecting:
            self = connectingFor >= Self.unreachableAfter ? .unreachable(.noAnswer) : .connecting
        case .idle:
            self = .notConnected
        case .failed(.offline):
            self = .unreachable(.noNetwork)
        case .failed(.ended):
            self = .unreachable(.sessionEnded)
        case .failed(.incompatible):
            self = .unreachable(.incompatible)
        }
    }

    /// Short words for the header or the composer chip.
    public var label: String {
        switch self {
        case .live: return "Live"
        case .working: return "Working…"
        case .connecting: return "Connecting…"
        case .notConnected: return "Not connected"
        case .unreachable(.noAnswer): return "Can't connect"
        case .unreachable(.noNetwork): return "No network"
        case .unreachable(.sessionEnded): return "Session ended"
        case .unreachable(.incompatible): return "Agent needs an update"
        }
    }

    /// One sentence saying why, for VoiceOver and the Mac tooltip.
    public func detail(agentName: String) -> String {
        switch self {
        case .live:
            return "Connected to \(agentName)."
        case .working:
            return "\(agentName) is working on your message."
        case .connecting:
            return "Connecting to \(agentName)."
        case .notConnected:
            return "Not connected to \(agentName)."
        case .unreachable(.noAnswer):
            return "\(agentName) isn't answering. It may be offline, or it hasn't accepted this device yet."
        case .unreachable(.noNetwork):
            return "This device is offline."
        case .unreachable(.sessionEnded):
            return "\(agentName) ended this session. Start a new chat to continue."
        case .unreachable(.incompatible):
            return "\(agentName) runs a version this app can't talk to."
        }
    }

    /// Whether tapping or clicking the status should reconnect. Retrying can't fix an ended
    /// session or an incompatible agent, so those don't offer it.
    public var canRetry: Bool {
        switch self {
        case .notConnected, .unreachable(.noAnswer), .unreachable(.noNetwork):
            return true
        default:
            return false
        }
    }

    /// Green dot only while connected.
    public var isLive: Bool {
        self == .live || self == .working
    }

    /// The status dot's colour: green when live, red when it failed, grey while waiting or idle.
    public var tone: OOStatusDot.Tone {
        if isLive {
            return .live
        }
        if case .unreachable = self {
            return .failure
        }
        return .neutral
    }
}
