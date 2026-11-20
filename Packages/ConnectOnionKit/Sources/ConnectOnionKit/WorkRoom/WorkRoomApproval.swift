import Foundation

/// What the developer can decide about a Provider approval. Neither choice grants more than this one
/// request: there is no session-wide Allow.
public enum WorkRoomDecision: Equatable, Sendable {
    case allowOnce
    case reject
}

/// The pending Provider approval of a Work Room, as the Decision Strip and the Work Room decision render it.
/// Only a verified approval gets here: its copy is allowed copy and its file names are base names.
public struct WorkRoomApproval: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case pending
        /// The answer was sent from this client, from the card or the Work Room. Never goes back to pending.
        case settled(WorkRoomDecision)
        /// The host reported the request already answered (`STALE_ANSWER`). Never resent.
        case answeredElsewhere
    }

    /// The approval's `id`, nil when the host stamped none.
    public let id: String?
    public let action: String
    public let scope: String
    public let reason: String
    public let classification: OIPProviderApproval.Scope
    /// Base names only, at most 8.
    public let files: [String]
    public let phase: Phase
    let allowOnce: Bool
    let isAwaitingApproval: Bool

    /// The decision can be made: unanswered, and the invocation is waiting for it.
    public var isActive: Bool {
        phase == .pending && isAwaitingApproval
    }

    /// Allow once is offered only for a verified Work Room scope the host allows once.
    public var offersAllow: Bool {
        isActive && classification == .workroom && allowOnce
    }

    /// Reject is always offered for a verified Provider approval.
    public var offersReject: Bool {
        isActive
    }

    /// The risk line, taken from the scope classification alone: the host sends no risk of its own.
    public var risk: String {
        switch classification {
        case .workroom: "Contained to this Work Room"
        case .elevated: "Reaches outside this Work Room"
        case .unknown: "Cannot be verified"
        }
    }

    /// Said in place of the buttons once the decision is no longer open, nil while it is.
    public var resolution: String? {
        switch phase {
        case .pending: nil
        case .settled(.allowOnce): "Allowed once"
        case .settled(.reject): "Rejected"
        case .answeredElsewhere: "Already answered elsewhere"
        }
    }
}

/// The one way the store hands a signed client frame to the app. The app sets it when its socket is
/// ready and clears it when the socket is gone: `frames` builds and signs the frame, `send` writes it
/// through the app's existing send path and calls `failed` on the main actor if the write fails, so the
/// request it carried ends at once instead of looking sent.
public struct WorkRoomTransport {
    public let frames: OIPClientFrames
    public let send: @MainActor (_ frame: [String: JSONValue], _ failed: @escaping @MainActor () -> Void) -> Void

    public init(
        frames: OIPClientFrames,
        sendReportingFailure send: @escaping @MainActor ([String: JSONValue], @escaping @MainActor () -> Void) -> Void
    ) {
        self.frames = frames
        self.send = send
    }

    /// A send path that never reports a failed write.
    @MainActor
    public init(frames: OIPClientFrames, send: @escaping @MainActor ([String: JSONValue]) -> Void) {
        self.init(frames: frames, sendReportingFailure: { frame, _ in send(frame) })
    }
}
