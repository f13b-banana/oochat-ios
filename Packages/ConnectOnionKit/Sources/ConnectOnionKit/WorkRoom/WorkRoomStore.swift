import Foundation
import Observation

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

/// One per agent session, and the only place Provider frames are interpreted: feed it every
/// decoded server frame and read the Work Rooms it keeps. Frames that break a rule are dropped.
@MainActor
@Observable
public final class WorkRoomStore {
    /// In arrival order, which is transcript order.
    private var invocations: [OIPProviderInvocation] = []
    private var activities: [String: [OIPProviderActivity]] = [:]
    /// In arrival order across every invocation, so a group's conversation reads as it happened.
    private var messages: [OIPProviderMessage] = []

    public init() {}

    /// One Work Room per group, in the order each group first appeared.
    public var workRooms: [WorkRoom] {
        var order: [String] = []
        var groups: [String: [OIPProviderInvocation]] = [:]
        for invocation in invocations {
            let key = invocation.workroomID ?? invocation.invocationID
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(invocation)
        }
        return order.compactMap { key in groups[key].flatMap { workRoom(id: key, members: $0) } }
    }

    /// The Work Room with this group key, for the app to show while it stays open.
    public func workRoom(id: String) -> WorkRoom? {
        workRooms.first { $0.id == id }
    }

    /// The Work Room whose card replaces the outer `tool_call` with this id. Only a group's root
    /// has a card, so a continuation's tool call gives nil.
    public func workRoom(forToolCallID toolCallID: String) -> WorkRoom? {
        workRooms.first { $0.toolCallID == toolCallID }
    }

    /// True when a Provider Invocation replaces this outer `tool_call`, so the timeline should
    /// not draw it as an ordinary tool call. This includes continuations, which have no card.
    public func isProviderToolCall(_ toolCallID: String) -> Bool {
        invocations.contains { $0.parentToolCallID == toolCallID }
    }

    /// Feed every decoded server frame; frames that are not Provider frames are ignored.
    public func receive(_ frame: OIPServerFrame) {
        switch frame {
        case .providerInvocation(let invocation):
            apply(invocation)
        case .providerActivity(let activity):
            // A child event for an invocation not seen yet is dropped, not buffered.
            guard isKnown(activity.invocationID, activity.parentToolCallID, activity.provider) else {
                return
            }
            activities[activity.invocationID, default: []].upsert(activity, id: \.activityID)
        case .providerMessage(let message):
            guard isKnown(message.invocationID, message.parentToolCallID, message.provider) else {
                return
            }
            if let index = messages.firstIndex(where: {
                $0.invocationID == message.invocationID && $0.messageID == message.messageID
            }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
        default:
            break
        }
    }

    /// The state revision gate: once an invocation has a revision, a frame without a newer one
    /// is dropped, and an equal one is a no-op. An unversioned invocation accepts any frame.
    private func apply(_ incoming: OIPProviderInvocation) {
        guard let index = invocations.firstIndex(where: { $0.invocationID == incoming.invocationID }) else {
            invocations.append(incoming)
            return
        }
        let stored = invocations[index]
        guard stored.parentToolCallID == incoming.parentToolCallID, stored.provider == incoming.provider else {
            return
        }
        if let storedRevision = stored.stateRevision {
            guard let revision = incoming.stateRevision, revision > storedRevision else {
                return
            }
        }
        invocations[index] = stored.merging(incoming)
    }

    private func isKnown(_ invocationID: String, _ parentToolCallID: String, _ provider: OIPProvider) -> Bool {
        invocations.contains {
            $0.invocationID == invocationID && $0.parentToolCallID == parentToolCallID && $0.provider == provider
        }
    }

    /// Root: the first member that continues nothing (or the first member). Current: the last
    /// continuation, or the root. The card shows the root's place and the current's state.
    private func workRoom(id: String, members: [OIPProviderInvocation]) -> WorkRoom? {
        guard let root = members.first(where: { $0.continuationOf == nil }) ?? members.first else {
            return nil
        }
        let current = members.last { $0.invocationID != root.invocationID } ?? root
        let status = current.status ?? .running
        let memberIDs = Set(members.map(\.invocationID))
        var seenMessages = Set<String>()
        return WorkRoom(
            id: id,
            toolCallID: root.parentToolCallID,
            provider: root.provider,
            title: current.taskTitle ?? root.taskTitle,
            status: status,
            summary: current.summary(for: status),
            activities: members.flatMap { (activities[$0.invocationID] ?? []).sorted { $0.order < $1.order } },
            messages: messages.filter {
                memberIDs.contains($0.invocationID) && seenMessages.insert($0.messageID).inserted
            }
        )
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

private extension Array {
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

private extension OIPProviderActivity {
    /// A missing sequence sorts last.
    var order: Int {
        sequence ?? .max
    }
}
