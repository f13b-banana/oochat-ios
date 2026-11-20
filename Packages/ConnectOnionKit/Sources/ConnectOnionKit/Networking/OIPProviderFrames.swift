import Foundation

// Provider frames: what a host sends about a Provider Invocation (Claude Code or Codex).
// The decoder validates every field here, so a typed frame only ever carries ids that match
// the host's id rule and copy that is on Core's allowed lists (ProviderCopy). A frame missing
// a required field, or with an unknown Provider, kind, role or activity copy, stays `.unknown`.

/// The native coding tool a host runs.
public enum OIPProvider: String, Equatable, Sendable {
    case codex
    case claudeCode = "claude_code"

    /// The client names the Provider itself; the frame's `providerDisplayName` is ignored.
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

/// Lifecycle of one Provider Invocation. An unknown value is treated as absent.
public enum OIPProviderStatus: String, Equatable, Sendable {
    case starting
    case running
    case awaitingApproval = "awaiting_approval"
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }

    /// The status a card or Work Room shows. "Stopped", never "Cancelled", in UI copy.
    public var label: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .awaitingApproval: "Waiting for approval"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }
}

/// provider_invocation: creates or updates one Provider Invocation. Absent fields are nil and
/// leave the stored value alone; copy that is not on Core's lists is also nil.
public struct OIPProviderInvocation: Equatable, Sendable {
    public let invocationID: String
    public let parentToolCallID: String
    public let provider: OIPProvider
    public var status: OIPProviderStatus?
    /// Positive per-invocation revision; nil when missing or not a positive integer.
    public var stateRevision: Int?
    public var taskTitle: String?
    public var currentSummary: String?
    public var resultSummary: String?
    public var errorSummary: String?
    public var workroomID: String?
    public var continuationOf: String?
    /// The Permission Profile catalog, kept only when it validates against `stateRevision`.
    public var providerPermission: OIPProviderPermission?
    /// Who drives a Claude Station, with its phase and its own revision counter (not `stateRevision`).
    /// Set only by `provider_session` or a snapshot, and only when all three are valid.
    public var controlOwner: OIPControlOwner?
    public var controlPhase: OIPControlPhase?
    public var controlRevision: Int?
}

/// Which side of a Claude Station session drives it. The host calls the device `browser`.
public enum OIPControlOwner: String, Equatable, Sendable {
    case terminal
    case browser
}

/// Where a Claude Station's handover stands.
public enum OIPControlPhase: String, Equatable, Sendable {
    case localStarting = "local_starting"
    case localObserving = "local_observing"
    case handoverToRemote = "handover_to_remote"
    case remoteControlling = "remote_controlling"
    case handoverToLocal = "handover_to_local"
    case completed
    case failed
}

/// provider_session: the Control state of a Claude Station. `stateRevision` is the control revision, a
/// separate counter from the invocation's. It is found by `invocationID` alone.
public struct OIPProviderSession: Equatable, Sendable {
    public let invocationID: String
    /// The host's own value when the frame carries a valid one.
    public var parentToolCallID: String?
    public let owner: OIPControlOwner
    public let phase: OIPControlPhase
    public let stateRevision: Int
}

/// provider_activity: one semantic step, upserted by `activityID` within its invocation.
public struct OIPProviderActivity: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case command
        case fileChange = "file_change"
        case inspect
        case search
        case tool
    }

    public enum Status: String, Equatable, Sendable {
        case running, completed, failed
    }

    public let invocationID: String
    public let parentToolCallID: String
    public let provider: OIPProvider
    public let activityID: String
    /// Activities are ordered by sequence; a missing one sorts last.
    public let sequence: Int?
    public let kind: Kind
    public let status: Status
    public let title: String
    public let summary: String
    /// Base names only, at most 128 characters each, no duplicates, at most 8.
    public let files: [String]
}

/// provider_message: one turn of the Provider's own conversation. Plain text only.
public struct OIPProviderMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user, assistant
    }

    public let invocationID: String
    public let parentToolCallID: String
    public let provider: OIPProvider
    public let messageID: String
    public let role: Role
    /// Trimmed and never blank. Render as plain text, never as Markdown or HTML.
    public let text: String
}

/// approval_needed with Provider context. A Provider approval is an ordinary `approval_needed` frame, there is no
/// provider_approval frame; it is answered with APPROVAL_RESPONSE. `presentation` is nil when the nested
/// `providerApproval` failed a check: the approval then stays generic and offers no Allow anywhere.
public struct OIPProviderApproval: Equatable, Sendable {
    /// The approval's `id`, echoed as `request_id` in the answer. Nil when the host stamped none.
    public let id: String?
    public let invocationID: String
    public let parentToolCallID: String
    public let provider: OIPProvider
    public let activityID: String?
    public let presentation: Presentation?

    public enum Scope: String, Equatable, Sendable {
        case workroom
        case elevated
        case unknown
    }

    /// Everything about the approval a client may show: all of it is allowed copy or base file names.
    public struct Presentation: Equatable, Sendable {
        public let scope: Scope
        public let action: String
        public let scopeText: String
        public let reason: String
        /// Forced false unless the scope is `workroom`.
        public let allowOnce: Bool
        /// Forced false unless the scope is `workroom`. No client offers it.
        public let allowSession: Bool
        /// Base names only, at most 128 characters each, no duplicates, at most 8.
        public let files: [String]
    }
}

/// The host's answer to PROVIDER_INTERRUPT, PROVIDER_INPUT or PROVIDER_PERMISSION_CHANGE. `reason` is the host's
/// string, kept open: an unknown reason still decodes and is a rejection like any other. A client accepts a
/// positive ack only when `requestID`, `invocationID` and `stateRevision` match what it sent.
public struct OIPProviderAck: Equatable, Sendable {
    /// Empty when the host could not read the request's id.
    public let requestID: String
    public let invocationID: String?
    public let accepted: Bool
    /// Positive revision; nil when missing or not a positive integer.
    public let stateRevision: Int?
    public let reason: String?
    /// Only on an accepted PROVIDER_PERMISSION_ACK, kept raw: the Work Room store validates it against the new revision.
    public let providerPermission: JSONValue?
}

/// The host's answer to PROVIDER_STATION_ATTACH, matched by `requestID`.
public struct OIPProviderStationAttachAck: Equatable, Sendable {
    public let requestID: String
    public let accepted: Bool
    public let sessionID: String?
    public let reason: String?
}

/// The host's answer to PROVIDER_CONTROL, matched by `requestID`. `stateRevision` is the new control revision.
public struct OIPProviderControlAck: Equatable, Sendable {
    public let requestID: String
    /// `take` or `release`; the host sends an empty string when it could not read the request, and the
    /// documented accepted frame omits it.
    public let action: String?
    public let accepted: Bool
    public let stateRevision: Int?
    public let reason: String?
}

extension OIPServerFrame {
    static func decodeProviderFrame(_ type: String, _ frame: [String: JSONValue]) -> OIPServerFrame? {
        switch type {
        case OIPFrameType.providerInvocation:
            return OIPProviderInvocation(frame).map(OIPServerFrame.providerInvocation)
        case OIPFrameType.providerActivity:
            return OIPProviderActivity(frame).map(OIPServerFrame.providerActivity)
        case OIPFrameType.providerMessage:
            return OIPProviderMessage(frame).map(OIPServerFrame.providerMessage)
        case OIPFrameType.providerSession:
            return OIPProviderSession(frame).map(OIPServerFrame.providerSession)
        case OIPFrameType.providerInterruptAck:
            return OIPProviderAck(frame).map(OIPServerFrame.providerInterruptAck)
        case OIPFrameType.providerInputAck:
            return OIPProviderAck(frame).map(OIPServerFrame.providerInputAck)
        case OIPFrameType.providerPermissionAck:
            return OIPProviderAck(frame).map(OIPServerFrame.providerPermissionAck)
        case OIPFrameType.providerStationAttachAck:
            return OIPProviderStationAttachAck(frame).map(OIPServerFrame.providerStationAttachAck)
        case OIPFrameType.providerControlAck:
            return OIPProviderControlAck(frame).map(OIPServerFrame.providerControlAck)
        default:
            return type == OIPFrameType.providerArtifact
                ? OIPProviderArtifact(frame).map(OIPServerFrame.providerArtifact) : nil
        }
    }
}

/// The three fields every provider frame needs to find its invocation.
private struct ProviderCorrelation {
    let invocationID: String
    let parentToolCallID: String
    let provider: OIPProvider

    init?(_ frame: [String: JSONValue]) {
        guard let invocationID = boundedID(frame["invocationId"]),
              let parentToolCallID = boundedID(frame["parentToolCallId"]),
              let provider = frame["provider"]?.stringValue.flatMap(OIPProvider.init(rawValue:)) else {
            return nil
        }
        self.invocationID = invocationID
        self.parentToolCallID = parentToolCallID
        self.provider = provider
    }
}

extension OIPProviderInvocation {
    init?(_ frame: [String: JSONValue]) {
        guard let correlation = ProviderCorrelation(frame) else {
            return nil
        }
        invocationID = correlation.invocationID
        parentToolCallID = correlation.parentToolCallID
        provider = correlation.provider
        status = frame["status"]?.stringValue.flatMap(OIPProviderStatus.init(rawValue:))
        stateRevision = frame["stateRevision"]?.intValue.flatMap { $0 > 0 ? $0 : nil }
        taskTitle = ProviderCopy.taskTitle(frame["taskTitle"]?.stringValue)
        currentSummary = ProviderCopy.summary(frame["currentSummary"]?.stringValue)
        resultSummary = ProviderCopy.summary(frame["resultSummary"]?.stringValue)
        errorSummary = ProviderCopy.summary(frame["errorSummary"]?.stringValue)
        workroomID = safeID(frame["workroomId"])
        continuationOf = safeID(frame["continuationOf"])
        providerPermission = OIPProviderPermission(
            frame["providerPermission"], provider: correlation.provider, stateRevision: stateRevision
        )
    }
}

extension OIPProviderSession {
    init?(_ frame: [String: JSONValue]) {
        guard let invocationID = boundedID(frame["invocationId"]),
              let owner = frame["owner"]?.stringValue.flatMap(OIPControlOwner.init(rawValue:)),
              let phase = frame["phase"]?.stringValue.flatMap(OIPControlPhase.init(rawValue:)),
              let revision = positiveRevision(frame["stateRevision"]) else {
            return nil
        }
        self.invocationID = invocationID
        parentToolCallID = boundedID(frame["parentToolCallId"])
        self.owner = owner
        self.phase = phase
        stateRevision = revision
    }
}

extension OIPProviderActivity {
    static let fileLimit = 8
    static let fileNameLimit = 128

    init?(_ frame: [String: JSONValue]) {
        guard let correlation = ProviderCorrelation(frame),
              let activityID = boundedID(frame["activityId"]),
              let kind = frame["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let status = frame["status"]?.stringValue.flatMap(Status.init(rawValue:)),
              let copy = ProviderCopy.activity(
                title: frame["title"]?.stringValue,
                summary: frame["summary"]?.stringValue
              ) else {
            return nil
        }
        invocationID = correlation.invocationID
        parentToolCallID = correlation.parentToolCallID
        provider = correlation.provider
        self.activityID = activityID
        sequence = frame["sequence"]?.intValue.flatMap { $0 >= 1 ? $0 : nil }
        self.kind = kind
        self.status = status
        title = copy.title
        summary = copy.summary
        files = Self.fileNames(frame["files"])
    }

    /// Base names only, so a card or Work Room never shows a local path.
    static func fileNames(_ value: JSONValue?) -> [String] {
        var names: [String] = []
        for item in value?.arrayValue ?? [] {
            let name = item.stringValue?
                .split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last
                .map(String.init) ?? ""
            guard !name.isEmpty, name != ".", name != "..", name.count <= fileNameLimit,
                  !names.contains(name) else {
                continue
            }
            names.append(name)
            if names.count == fileLimit {
                break
            }
        }
        return names
    }
}

extension OIPProviderApproval {
    /// Nil unless the frame carries Provider context (provider, invocationId and parentToolCallId).
    init?(_ frame: [String: JSONValue]) {
        guard let correlation = ProviderCorrelation(frame) else {
            return nil
        }
        id = frame["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        invocationID = correlation.invocationID
        parentToolCallID = correlation.parentToolCallID
        provider = correlation.provider
        activityID = boundedID(frame["activityId"])
        presentation = Presentation(frame["providerApproval"])
    }
}

extension OIPProviderApproval.Presentation {
    init?(_ value: JSONValue?) {
        guard let fields = value?.objectValue,
              let scope = fields["scopeClassification"]?.stringValue.flatMap(OIPProviderApproval.Scope.init(rawValue:)),
              let scopeText = ProviderCopy.approvalScopes[scope.rawValue],
              fields["scope"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == scopeText,
              let action = ProviderCopy.approvalAction(fields["action"]?.stringValue),
              let reason = ProviderCopy.approvalReason(fields["reason"]?.stringValue),
              let allowOnce = fields["allowOnce"]?.boolValue,
              let allowSession = fields["allowSession"]?.boolValue else {
            return nil
        }
        self.scope = scope
        self.scopeText = scopeText
        self.action = action
        self.reason = reason
        self.allowOnce = scope == .workroom && allowOnce
        self.allowSession = scope == .workroom && allowSession
        files = OIPProviderActivity.fileNames(fields["files"])
    }
}

extension OIPProviderMessage {
    /// Core's limit, counted the way Core counts (Unicode scalars), before trimming.
    static let textLimit = 16_000

    init?(_ frame: [String: JSONValue]) {
        guard let correlation = ProviderCorrelation(frame),
              let messageID = safeID(frame["messageId"]),
              let role = frame["role"]?.stringValue.flatMap(Role.init(rawValue:)),
              let raw = frame["text"]?.stringValue,
              raw.unicodeScalars.count <= Self.textLimit else {
            return nil
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        invocationID = correlation.invocationID
        parentToolCallID = correlation.parentToolCallID
        provider = correlation.provider
        self.messageID = messageID
        self.role = role
        self.text = text
    }
}

extension OIPProviderAck {
    init?(_ frame: [String: JSONValue]) {
        guard let requestID = frame["requestId"]?.stringValue, let accepted = frame["accepted"]?.boolValue else {
            return nil
        }
        self.requestID = requestID
        invocationID = frame["invocationId"]?.stringValue
        self.accepted = accepted
        stateRevision = positiveRevision(frame["stateRevision"])
        reason = frame["reason"]?.stringValue
        providerPermission = frame["providerPermission"]
    }
}

extension OIPProviderStationAttachAck {
    init?(_ frame: [String: JSONValue]) {
        guard let requestID = (frame["request_id"] ?? frame["requestId"])?.stringValue,
              let accepted = frame["accepted"]?.boolValue else {
            return nil
        }
        self.requestID = requestID
        self.accepted = accepted
        sessionID = frame["sessionId"]?.stringValue
        reason = frame["reason"]?.stringValue
    }
}

extension OIPProviderControlAck {
    init?(_ frame: [String: JSONValue]) {
        guard let requestID = (frame["request_id"] ?? frame["requestId"])?.stringValue,
              let accepted = frame["accepted"]?.boolValue else {
            return nil
        }
        self.requestID = requestID
        action = frame["action"]?.stringValue
        self.accepted = accepted
        stateRevision = positiveRevision(frame["stateRevision"])
        reason = frame["reason"]?.stringValue
    }
}

private func positiveRevision(_ value: JSONValue?) -> Int? {
    value?.intValue.flatMap { $0 > 0 ? $0 : nil }
}

/// A non-empty id of at most 512 characters, the bound Core puts on correlation ids.
private func boundedID(_ value: JSONValue?) -> String? {
    guard let id = value?.stringValue, !id.isEmpty, id.count <= 512 else {
        return nil
    }
    return id
}

/// The host's id rule for Work Room, continuation and message ids: `^[A-Za-z0-9._:-]{1,512}$`.
func safeID(_ value: JSONValue?) -> String? {
    guard let id = value?.stringValue,
          id.range(of: "^[A-Za-z0-9._:-]{1,512}$", options: .regularExpression) != nil else {
        return nil
    }
    return id
}
