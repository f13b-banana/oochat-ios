import ConnectOnionKit
import Foundation

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

/// One SessionBookmark per conversation, mirroring macOS
/// ConnectOnionRemoteSessionStore keeping its sesssion state

struct HostedAgentBookmarkStore: Sendable {
    private let suiteName: String?

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    private func key(for conversationID: String) -> String {
        "connectonion.session-bookmark.\(conversationID)"
    }

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    func load(conversationID: String) -> SessionBookmark? {
        guard let data = defaults.data(forKey: key(for: conversationID)) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionBookmark.self, from: data)
    }

    func save(_ bookmark: SessionBookmark, conversationID: String) {
        guard let data = try? JSONEncoder().encode(bookmark) else {
            return
        }
        defaults.set(data, forKey: key(for: conversationID))
    }

    func remove(conversationID: String) {
        defaults.removeObject(forKey: key(for: conversationID))
    }
}
