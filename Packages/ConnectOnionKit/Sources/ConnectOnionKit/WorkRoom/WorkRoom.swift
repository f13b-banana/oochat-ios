import Foundation

/// What one Work Room shows. Built only from validated frames, so every string here is either
/// allowed Provider copy or the Provider's own conversation text; views never inspect raw frames.
public struct WorkRoom: Identifiable, Equatable, Sendable {
    /// The Work Room group key: the invocations' `workroomId`, or the root's own id.
    public let id: String
    /// The id of the outer `tool_call` the root invocation replaces. The card sits there in the
    /// timeline. It is for placement only and is never shown.
    public let toolCallID: String
    public let provider: OIPProvider
    /// Allowed task title, or nil when the host sent none on the allowed list.
    public let title: String?
    /// The current invocation's status: the latest continuation's, or the root's.
    public let status: OIPProviderStatus
    /// The one allowed summary for that status, or nil.
    public let summary: String?
    /// Allowed activity steps across the group, each invocation's ordered by sequence.
    public let activities: [OIPProviderActivity]
    /// The Provider's own conversation across the group in arrival order, one per message id.
    /// Plain text only.
    public let messages: [OIPProviderMessage]
    /// The verified Provider approval waiting on this Work Room's current invocation, or nil.
    public var approval: WorkRoomApproval?
    /// The Scoped Stop for this Work Room's current invocation.
    public var stop = WorkRoomStop()
    /// The direct composer for this Work Room's current invocation.
    public var composer = WorkRoomComposer()
    /// The Permission Profile selector, nil when the host supplied no valid catalog for this Work Room.
    public var permission: WorkRoomPermission?
    /// Who has Control of a Claude Station, nil until the host has said.
    public var control: WorkRoomControl?
    /// A real Provider screenshot that is evidence for this Work Room's current invocation at its current
    /// revision, or nil. Never made from text, a URL, SVG or a path.
    public var preview: OIPProviderArtifact.Screenshot?
}

public extension WorkRoom {
    /// The allowed title, or a fallback made from the Provider's name.
    var displayTitle: String {
        title ?? "\(provider.displayName) Work Room"
    }

    /// The current turn: the last user message and everything after it. A user message starts a
    /// turn, so without one the whole conversation is the current turn.
    var currentTurn: [OIPProviderMessage] {
        Array(messages[currentTurnStart...])
    }

    /// Earlier turns, which the Work Room folds away.
    var earlierMessages: [OIPProviderMessage] {
        Array(messages[..<currentTurnStart])
    }

    /// The step the Provider is running now. None once the invocation has finished, so a stale
    /// running step never looks live.
    var currentActivity: OIPProviderActivity? {
        status.isTerminal ? nil : activities.last { $0.status == .running }
    }

    /// The latest finished step, completed or failed, shown only while a different step runs.
    var lastCompleted: OIPProviderActivity? {
        currentActivity == nil ? nil : activities.last { $0.status != .running }
    }

    /// Every other step, which the Work Room folds away.
    var earlierActivities: [OIPProviderActivity] {
        let shown = [currentActivity, lastCompleted]
        return activities.filter { !shown.contains($0) }
    }

    private var currentTurnStart: Int {
        messages.lastIndex { $0.role == .user } ?? 0
    }
}

extension OIPProviderInvocation {
    /// Fields the update carries overwrite; absent ones keep their value. A terminal update
    /// replaces the running summary with its own, so a finished card never says it is working.
    func merging(_ update: Self) -> Self {
        var merged = self
        merged.status = update.status ?? status
        merged.stateRevision = update.stateRevision ?? stateRevision
        merged.taskTitle = update.taskTitle ?? taskTitle
        merged.currentSummary = update.status?.isTerminal == true
            ? update.currentSummary
            : update.currentSummary ?? currentSummary
        merged.resultSummary = update.resultSummary ?? resultSummary
        merged.errorSummary = update.errorSummary ?? errorSummary
        merged.workroomID = update.workroomID ?? workroomID
        merged.continuationOf = update.continuationOf ?? continuationOf
        merged.providerPermission = update.providerPermission ?? providerPermission
        return merged
    }

    /// The one summary a card shows: the error for a failure, the result for another ending,
    /// otherwise what the Provider is doing now.
    func summary(for status: OIPProviderStatus) -> String? {
        guard status.isTerminal else {
            return currentSummary
        }
        let error = status == .failed ? errorSummary : nil
        return error ?? resultSummary ?? currentSummary
    }
}

extension Array {
    /// Replaces the element with the same id in place, or appends.
    mutating func upsert(_ element: Element, id: KeyPath<Element, String>) {
        if let index = firstIndex(where: { $0[keyPath: id] == element[keyPath: id] }) {
            self[index] = element
        } else {
            append(element)
        }
    }
}

public extension OIPProviderMessage {
    /// A piece of message text: prose, or the inside of a ``` fence. Both stay plain text.
    enum Block: Equatable, Sendable {
        case text(String)
        case code(String)
    }

    /// The text split at ``` fence lines, so a view can let code scroll sideways in its own
    /// bounds while prose wraps. The fence lines are dropped; an unclosed fence runs to the end.
    var blocks: [Block] {
        var blocks: [Block] = []
        var lines: [Substring] = []
        var isCode = false
        func close() {
            let body = lines.joined(separator: "\n")
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(isCode ? .code(body) : .text(body.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            lines = []
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                close()
                isCode.toggle()
            } else {
                lines.append(line)
            }
        }
        close()
        return blocks
    }
}

extension OIPProviderActivity {
    /// A missing sequence sorts last.
    var order: Int {
        sequence ?? .max
    }
}
