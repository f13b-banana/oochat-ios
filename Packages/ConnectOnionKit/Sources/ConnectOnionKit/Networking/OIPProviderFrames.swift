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

extension OIPServerFrame {
    static func decodeProviderFrame(_ type: String, _ frame: [String: JSONValue]) -> OIPServerFrame? {
        switch type {
        case OIPFrameType.providerInvocation:
            return OIPProviderInvocation(frame).map(OIPServerFrame.providerInvocation)
        case OIPFrameType.providerActivity:
            return OIPProviderActivity(frame).map(OIPServerFrame.providerActivity)
        case OIPFrameType.providerMessage:
            return OIPProviderMessage(frame).map(OIPServerFrame.providerMessage)
        default:
            return nil
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

/// A non-empty id of at most 512 characters, the bound Core puts on correlation ids.
private func boundedID(_ value: JSONValue?) -> String? {
    guard let id = value?.stringValue, !id.isEmpty, id.count <= 512 else {
        return nil
    }
    return id
}

/// The host's id rule for Work Room, continuation and message ids: `^[A-Za-z0-9._:-]{1,512}$`.
private func safeID(_ value: JSONValue?) -> String? {
    guard let id = value?.stringValue,
          id.range(of: "^[A-Za-z0-9._:-]{1,512}$", options: .regularExpression) != nil else {
        return nil
    }
    return id
}
