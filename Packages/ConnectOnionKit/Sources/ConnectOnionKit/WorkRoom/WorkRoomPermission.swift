import Foundation

/// The Permission Profile selector of a Work Room: the Provider's own options as the host supplied them,
/// which one is active, and whether a change is waiting for the host. Only a validated catalog gets here.
public struct WorkRoomPermission: Equatable, Sendable {
    /// One profile as the selector lists it. Disabled options carry the host's reason.
    public struct Option: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let description: String
        /// Needs a separate risk confirmation before it can be chosen.
        public let isElevated: Bool
        /// False when the host says the Outer Mode ceiling is below this option.
        public let isSelectable: Bool
        public let disabledReason: String?
    }

    /// The last change the host did not accept, with plain copy for the reason.
    public struct Failure: Equatable, Sendable {
        public let optionID: String
        public let text: String
    }

    public let options: [Option]
    public let activeID: String
    /// The option waiting for the host's answer; the label still shows the active profile meanwhile.
    public var pendingID: String?
    public var failure: Failure?
    /// The current invocation has a revision to send, so a change can be requested.
    var isCurrent = false
    var isConnected = false
    /// Another Work Room's change is waiting for the host's answer; only one is sent at a time.
    var isWaitingElsewhere = false

    init(catalog: OIPProviderPermission, isCurrent: Bool) {
        options = catalog.options.map {
            Option(
                id: $0.id, label: $0.label, description: $0.description, isElevated: $0.risk == .elevated,
                isSelectable: $0.isSelectable, disabledReason: $0.disabledReason
            )
        }
        activeID = catalog.activeOptionID
        self.isCurrent = isCurrent
    }

    /// The label of the profile in force, as the host named it.
    public var activeLabel: String {
        options.first { $0.id == activeID }?.label ?? ""
    }

    /// The label of the profile being requested, nil unless a change is pending.
    public var pendingLabel: String? {
        pendingID.flatMap { id in options.first { $0.id == id }?.label }
    }

    public var isPending: Bool {
        pendingID != nil
    }

    /// Why the whole selector is disabled, nil when a change can be made.
    public var unavailableReason: String? {
        if isPending {
            return "Waiting for the host to confirm the change"
        } else if !isCurrent {
            return "Profile changes are available once the run reports its state."
        } else if !isConnected {
            return "Profile changes are available while the agent is connected."
        } else if isWaitingElsewhere {
            return "Another Work Room is waiting for the host's answer."
        }
        return nil
    }

    /// The option can be chosen now: the host allows it, it is not already active, and no change is blocked.
    public func offers(_ option: Option) -> Bool {
        unavailableReason == nil && option.isSelectable && option.id != activeID
    }

    /// Plain copy for a refused change. The host's reason is an open string; an unknown one gets the
    /// generic line.
    static func rejectionText(reason: String?) -> String {
        WorkRoomRequest.rejectionText(reason, [
            "ceiling_denied": "This agent's Outer Mode does not allow that profile.",
            "confirmation_required": "The host needs the risk of that profile confirmed. Choose it again and confirm.",
            "operator_required": "You are not permitted to change this run's profile.",
            "unsupported_option": "The host does not offer that profile for this run.",
            "stale_revision": "The run changed while you were choosing. Try again.",
            "not_owner": "Only the person who started this run can change its profile.",
            "not_found": "The host could not find this run.",
            "unavailable": "Profile changes are not available right now. Try again later."
        ], fallback: "The host did not accept the change.")
    }

    static let unverified = "The host's answer could not be verified, so the profile was not changed. Try again."
    static let timedOut = "The host did not answer in time, so the profile was not changed. Try again."
    static let connectionDropped = "The connection dropped before the host answered, so the profile was not changed. Try again."
}

/// How long the host has to acknowledge a profile change.
enum WorkRoomPermissionTiming {
    static let acknowledgement = Duration.seconds(10)
}
