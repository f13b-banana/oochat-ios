import Foundation

/// Where a Scoped Stop stands for a Work Room's current invocation, as the Work Room renders it.
/// A rejected request is not a phase: the controls come back and `rejection` says why.
public struct WorkRoomStop: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Sent, no acknowledgement yet.
        case requesting
        /// The host acknowledged the exact revision. Approval and Stop controls stay hidden until a
        /// terminal event or a newer revision arrives.
        case acknowledged
        /// No acknowledgement, no terminal event in time, or the connection dropped. Fails closed like
        /// `acknowledged`.
        case unconfirmed
    }

    public var phase: Phase = .idle
    /// Plain copy for the last Stop the host refused; nil otherwise.
    public var rejection: String?
    /// The invocation is unfinished and has a positive revision to stop against.
    var isActive = false
    /// The store has a transport to send the request through.
    var isConnected = false

    /// The Stop button is shown and enabled.
    public var offersStop: Bool {
        isActive && isConnected && phase == .idle
    }

    /// Why Stop is shown disabled while the agent is not connected, nil otherwise.
    public var unavailableReason: String? {
        isActive && !isConnected && phase == .idle ? "Stop is available while the agent is connected." : nil
    }

    /// The Stop button is shown but disabled.
    public var isRequesting: Bool {
        phase == .requesting
    }

    /// Said in place of the Stop and approval controls while the barrier holds, nil otherwise.
    public var barrierText: String? {
        switch phase {
        case .acknowledged: "Stop requested"
        case .unconfirmed: "Status needs confirmation"
        case .idle, .requesting: nil
        }
    }

    /// Plain copy for a refused Stop. The host's reason is an open string; an unknown one gets the
    /// generic line.
    static func rejectionText(reason: String?) -> String {
        WorkRoomRequest.rejectionText(reason, [
            "not_active": "This run is no longer active.",
            "state_changed": "The run changed before it could be stopped. Check its status and try again."
        ], fallback: "The host did not accept the request. Try again.")
    }
}

/// How long the host has to acknowledge a Stop, then to report the run ended.
enum WorkRoomStopTiming {
    static let acknowledgement = Duration.seconds(10)
    static let terminalEvent = Duration.seconds(15)
}

extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Runs an action after a delay on the main actor. The store takes it so tests drive time by hand.
public typealias WorkRoomScheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

public extension WorkRoomStore {
    /// The real clock: waits, then runs the action.
    static func sleepThenRun(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            action()
        }
    }
}
