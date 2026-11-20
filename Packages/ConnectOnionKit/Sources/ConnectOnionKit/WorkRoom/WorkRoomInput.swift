import Foundation

/// What the Work Room composer shows for one Work Room: the retained draft, whether it can send,
/// and why not. Direct Provider Input only, never an outer agent turn.
public struct WorkRoomComposer: Equatable, Sendable {
    /// Kept until the host confirms the Provider accepted it.
    public var draft = ""
    /// Plain copy for the last message that was not accepted; nil otherwise.
    public var rejection: String?
    /// A message is waiting for the host's answer.
    public var isSending = false
    /// The current invocation has a positive revision to send against.
    var isSupported = false
    /// A Stop request or barrier exists for the current invocation.
    var isStopping = false
    var isConnected = false
    /// Another Work Room's message is waiting for the host's answer; only one is sent at a time.
    var isWaitingElsewhere = false
    /// A Provider approval is waiting for the user's decision.
    var isDeciding = false
    /// Why this device cannot send into a Claude Station: the terminal has Control, or it is changing hands.
    var controlReason: String?

    /// Why the composer is shown disabled, nil when it can be used.
    public var unavailableReason: String? {
        if !isSupported {
            return "This host does not support messages to this run yet."
        } else if isSending {
            return "Sending your message"
        } else if let controlReason {
            return controlReason
        } else if isWaitingElsewhere {
            return "Another Work Room is waiting for the host's answer."
        } else if isStopping {
            return "Stopping this run. Messages are paused until it ends."
        } else if !isConnected {
            return "Messages are available while the agent is connected."
        } else if isDeciding {
            return "Answer the approval first, then send a message."
        }
        return nil
    }

    /// The draft is longer than the host accepts.
    public var isOverLimit: Bool {
        trimmedDraft.unicodeScalars.count > WorkRoomInputRules.characterLimit
    }

    /// The Send button is enabled.
    public var canSend: Bool {
        unavailableReason == nil && !trimmedDraft.isEmpty && !isOverLimit
    }

    /// The mic is enabled: the same situations as Send, except that an empty draft is fine.
    public var canDictate: Bool {
        unavailableReason == nil
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WorkRoomInputRules {
    static let characterLimit = 12_000

    /// How long the host has to answer, since a Claude start can be slow.
    static let acknowledgement = Duration.seconds(60)

    static let connectionDropped = "The connection dropped before the host answered. Check the conversation before sending again."
    static let timedOut = "The host did not answer in time. Check the conversation before sending again."
    static let unconfirmed = "The host accepted the message but did not confirm the run's state. Check the conversation first."

    /// Plain copy for a refused message. The host's reason is an open string; an unknown one gets the
    /// generic line.
    static func rejectionText(reason: String?) -> String {
        WorkRoomRequest.rejectionText(reason, [
            "not_active": "The run could not take the message right now.",
            "unsupported_provider": "This host cannot take messages for this run.",
            "state_changed": "The run changed before the message arrived. Check its status and send again.",
            "provider_start_failed": "The run could not be started again. Try again.",
            "terminal_owns_session": WorkRoomControlRules.terminalHasControl
        ], fallback: "The host did not accept the message.")
    }
}
