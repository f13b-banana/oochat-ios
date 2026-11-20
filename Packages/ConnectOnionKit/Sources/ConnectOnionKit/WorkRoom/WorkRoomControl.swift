import Foundation

/// Who has Control of a Claude Station and whether it can be handed over. The Work Room store builds it;
/// a view only draws it.
public struct WorkRoomControl: Equatable, Sendable {
    public let owner: OIPControlOwner
    public let phase: OIPControlPhase
    /// The change waiting for the host's answer. Control does not move until it is confirmed.
    public var pending: OIPProviderControlAction?
    /// Plain copy for the last change that did not happen; nil otherwise.
    public var failure: String?
    var isConnected = false
    var isPaired = false

    init(owner: OIPControlOwner, phase: OIPControlPhase) {
        self.owner = owner
        self.phase = phase
    }

    /// "Terminal" or "This device".
    public var ownerLabel: String {
        owner == .terminal ? "Terminal" : "This device"
    }

    /// Where a handover stands, nil when nothing is changing.
    public var phaseLabel: String? {
        switch phase {
        case .localStarting: "Terminal is starting"
        case .handoverToRemote: "Handing control to this device"
        case .handoverToLocal: "Returning control to the terminal"
        case .completed: "Session ended"
        case .failed: "Session failed"
        case .localObserving, .remoteControlling: nil
        }
    }

    /// Why the buttons are disabled, nil when a change can be asked for.
    public var unavailableReason: String? {
        if pending != nil {
            "Waiting for the host to confirm"
        } else if !isConnected {
            "Control can be changed while the agent is connected."
        } else if !isPaired {
            "Pair with the terminal before changing control."
        } else {
            nil
        }
    }

    /// "Take control here" is enabled.
    public var canTake: Bool {
        unavailableReason == nil && owner == .terminal && phase == .localObserving
    }

    /// "Return to terminal" is enabled.
    public var canRelease: Bool {
        unavailableReason == nil && owner == .browser && phase == .remoteControlling
    }
}

enum WorkRoomControlRules {
    /// How long the host has to answer PROVIDER_CONTROL; a take can wait up to 10 s on the terminal.
    static let acknowledgement = Duration.seconds(30)

    static let connectionDropped = "The connection dropped before the host answered. Check who has control before trying again."
    static let timedOut = "The host did not answer in time. Check who has control before trying again."
    static let refused = "The host refused the request. Try again."
    static let unverified = "The host accepted the request but did not confirm the change. Check who has control."

    /// Why the composer is off while the terminal drives the session. Core refuses the message with
    /// `terminal_owns_session` in the same case.
    static let terminalHasControl = "The terminal has control of this session. Take control here to send messages."
    static let changingHands = "Control is changing hands. Messages are paused until it settles."
    static let sessionEnded = "This session has ended."
    static let controlUnknown = "Waiting for the terminal to say who has control."

    /// Why the composer is off for a Station, nil when this device has Control.
    static func composerReason(isStation: Bool, control: WorkRoomControl?) -> String? {
        guard isStation else {
            return nil
        }
        guard let control else {
            return controlUnknown
        }
        switch control.phase {
        case .remoteControlling: return control.owner == .browser ? nil : terminalHasControl
        case .handoverToRemote, .handoverToLocal: return changingHands
        case .localStarting, .localObserving: return terminalHasControl
        case .completed, .failed: return sessionEnded
        }
    }

    /// Plain copy for a refused change. The host's reason is an open string; an unknown one gets the generic line.
    static func rejectionText(reason: String?) -> String {
        WorkRoomRequest.rejectionText(reason, [
            "stale_or_unowned": "Control changed first, or this device does not own the session. Check who has control and try again.",
            "not_ready": "The terminal is not ready to hand over control yet. Try again in a moment.",
            "handover_timeout": "The terminal did not hand over control in time. Check the terminal and try again.",
            "provider_busy": "Claude Code is busy. Wait for it to finish, then try again."
        ], fallback: "The host did not change who has control.")
    }
}
