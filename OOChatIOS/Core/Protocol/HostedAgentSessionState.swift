import ConnectOnionKit

enum HostedAgentSessionState {
    static func applying(
        _ mode: ChatMode,
        to session: [String: JSONValue]?,
        conversationID: String
    ) -> [String: JSONValue] {
        var next = session ?? [:]
        next["session_id"] = .string(conversationID)
        next["mode"] = .string(mode.rawValue)
        next.removeValue(forKey: "ulw_turns")
        next.removeValue(forKey: "ulw_turns_used")
        next.removeValue(forKey: "ulw_prompt")
        next.removeValue(forKey: "skip_tool_approval")
        return next
    }

    static func mode(from session: [String: JSONValue], fallback: ChatMode) -> ChatMode {
        guard let rawMode = session["mode"]?.stringValue,
              let mode = ChatMode(rawValue: rawMode) else {
            return fallback
        }
        return mode
    }
}
