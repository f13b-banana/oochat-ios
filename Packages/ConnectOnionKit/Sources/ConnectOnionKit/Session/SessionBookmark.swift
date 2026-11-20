import Foundation

/// Holds the protocol identifiers required to resume a session.
/// Persisted locally by each app after every recorded event.
public struct SessionBookmark: Codable, Equatable, Sendable {
    public let sessionID: String
    public var lastMessageID: String?

    public init(sessionID: String, lastMessageID: String? = nil) {
        self.sessionID = sessionID
        self.lastMessageID = lastMessageID
    }
}
