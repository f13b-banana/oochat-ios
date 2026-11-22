import Foundation

/// Who spoke a transcript turn. The host calls the agent `agent` in `chat_items` and
/// `assistant` (or `model`) in hosted history; all are `.agent`. Case is ignored.
public enum TurnRole: Equatable, Sendable {
    case user
    case agent

    /// Nil for tool, system and any other role. Hosted `system` is the agent's prompt, not chat.
    public init?(hostRole: String) {
        switch hostRole.lowercased() {
        case "user": self = .user
        case "agent", "assistant", "model": self = .agent
        default: return nil
        }
    }
}

/// One user or agent turn from the host's `chat_items`, as a device joining a session sees it.
public struct CatchUpItem: Equatable, Sendable {
    public let role: TurnRole
    public let text: String

    public init(role: TurnRole, text: String) {
        self.role = role
        self.text = text
    }

    var isUser: Bool { role == .user }
}

/// What the app should add so its transcript matches the host.
public enum CatchUpStep: Equatable, Sendable {
    case user(String)
    case agent(String)
    /// The prompt of the turn still running. `isKnown` means the transcript already shows it,
    /// so the app only starts a run for it instead of appending it again.
    case runningUser(String, isKnown: Bool)
}

/// What the viewer side of a session reports about a turn another device started.
public enum MirroredTurn {
    /// The prompt carried by a `user_message` frame, or nil when the frame has no text.
    public static func prompt(fromUserMessage frame: [String: JSONValue]) -> String? {
        frame["content"]?.stringValue
    }

    /// The user and agent turns in CONNECTED's `chat_items`; tool and other items are dropped.
    public static func items(fromChatItems chatItems: [JSONValue]?) -> [CatchUpItem] {
        (chatItems ?? []).compactMap { item in
            guard let object = item.objectValue,
                  let text = object["content"]?.stringValue,
                  let role = object["type"]?.stringValue.flatMap(TurnRole.init(hostRole:)) else {
                return nil
            }
            return CatchUpItem(role: role, text: text)
        }
    }

    /// Whether two transcript texts match once surrounding whitespace and newlines are trimmed.
    public static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The turns the host has that the transcript lacks, in order: everything after the last
    /// host item already shown, or only the newest turn when none is. Texts match when equal
    /// after trimming, so a repeated identical prompt such as "ok" can match an older one.
    public static func catchUpSteps(
        host items: [CatchUpItem],
        local: [CatchUpItem],
        isRunning: Bool
    ) -> [CatchUpStep] {
        let known = items.lastIndex { item in
            local.contains { $0.role == item.role && sameText($0.text, item.text) }
        }
        let start = known.map { $0 + 1 } ?? (items.lastIndex(where: \.isUser) ?? items.count)
        var steps: [CatchUpStep] = []
        for (offset, item) in items[start...].enumerated() {
            let isRunningPrompt = isRunning && item.isUser && start + offset == items.count - 1
            if isRunningPrompt {
                steps.append(.runningUser(item.text, isKnown: false))
            } else {
                steps.append(item.isUser ? .user(item.text) : .agent(item.text))
            }
        }
        // The running prompt is already in the transcript: it still needs a run for the stream.
        if isRunning, start >= items.count, let last = items.last, last.isUser,
           local.contains(where: { $0.isUser && sameText($0.text, last.text) }) {
            steps.append(.runningUser(last.text, isKnown: true))
        }
        return steps
    }
}

/// Whether a request is active on this chat and whether another device owns it.
/// A mirrored turn locks the composer (Replying, Send off, Stop on) but is never ours to cancel.
public struct ViewerTurnState: Equatable, Sendable {
    public enum Event: Sendable {
        case userMessage            // `user_message`: another device typed a prompt
        case catchUp(isRunning: Bool)   // CONNECTED said whether a turn is running
        case finished               // output, interrupted or error ended the turn
        case viewerEnded            // the viewer connection ended
        case localSendStarted       // this device started its own turn
    }

    public private(set) var isActive = false
    public private(set) var isMirrored = false

    public init(isActive: Bool = false, isMirrored: Bool = false) {
        self.isActive = isActive
        self.isMirrored = isMirrored
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .userMessage:
            // Never override a turn this device owns.
            if !isActive || isMirrored {
                isActive = true
                isMirrored = true
            }
        case .catchUp(let isRunning):
            // Never override a turn this device owns.
            if !isActive || isMirrored {
                isActive = isRunning
                isMirrored = isRunning
            }
        case .finished:
            isActive = false
            isMirrored = false
        case .viewerEnded:
            // A local send closes the viewer and owns the flags from then on.
            if isMirrored {
                isActive = false
                isMirrored = false
            }
        case .localSendStarted:
            isActive = true
            isMirrored = false
        }
    }

    /// The input id an INTERRUPT should name: none for a mirrored turn, which has no INPUT of ours.
    public func interruptInputID(local: String?) -> String? {
        isMirrored ? nil : local
    }
}
