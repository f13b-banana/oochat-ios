import Foundation

/// Cuts a host session back to just before your latest message, so the agent answers that
/// message again without remembering its first answer. Both apps use it for Retry and Edit.
public enum SessionRewind {
    /// The framing Core puts on a message sent while the agent was working (runtime_input.py).
    static let runtimeInputPrefix = "[The user sent this while you were working on the previous request."

    /// `prompt` is the message being redone; when given, the cut is at the message and trace
    /// entry carrying exactly that text. nil when the session holds no such message of yours.
    public static func droppingLatestTurn(
        from session: [String: JSONValue],
        prompt: String? = nil,
        now: Date = Date()
    ) -> [String: JSONValue]? {
        let wanted = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let messages = session["messages"]?.arrayValue,
              let turnStart = messages.lastIndex(where: { isTurnStart($0, prompt: wanted) }) else {
            return nil
        }
        var rewound = session
        rewound["messages"] = .array(Array(messages[..<turnStart]))
        if let trace = session["trace"]?.arrayValue, trace.contains(where: isUserInput) {
            // The trace must be cut at the same turn, or the host would replay a half-dropped one.
            guard let inputIndex = trace.lastIndex(where: { isTurnInput($0, prompt: wanted) }) else {
                return nil
            }
            rewound["trace"] = .array(Array(trace[..<inputIndex]))
        }
        // `turn` stays as it is. The host keeps whichever copy is ahead on (turn, iteration,
        // updated), compared in that order (session/merge.py). Same turn and one more
        // iteration makes ours win, while a newer turn from another device still beats it.
        rewound["iteration"] = .number(Double((session["iteration"]?.intValue ?? 0) + 1))
        rewound["updated"] = .number(now.timeIntervalSince1970)
        return rewound
    }

    /// A message you typed: role user, not one Core added mid-turn (a system reminder is
    /// `internal`, a message sent while the agent worked carries the runtime framing).
    private static func isTurnStart(_ message: JSONValue, prompt: String?) -> Bool {
        guard let object = message.objectValue,
              object["role"]?.stringValue == "user",
              object["internal"]?.boolValue != true,
              let text = text(of: object["content"]),
              !text.hasPrefix(runtimeInputPrefix) else {
            return false
        }
        return prompt.map { text.trimmingCharacters(in: .whitespacesAndNewlines) == $0 } ?? true
    }

    private static func isUserInput(_ entry: JSONValue) -> Bool {
        entry.objectValue?["type"]?.stringValue == "user_input"
    }

    /// The trace entry that opened the turn: user_input, not a mid-run runtime input.
    private static func isTurnInput(_ entry: JSONValue, prompt: String?) -> Bool {
        guard isUserInput(entry), let object = entry.objectValue, object["runtime_input"]?.boolValue != true else {
            return false
        }
        guard let prompt else {
            return true
        }
        return object["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == prompt
    }

    /// Plain text, or the text part of a message sent with images.
    private static func text(of content: JSONValue?) -> String? {
        if let string = content?.stringValue {
            return string
        }
        return content?.arrayValue?
            .compactMap { $0.objectValue }
            .first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue
    }
}
