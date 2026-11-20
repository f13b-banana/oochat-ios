import Foundation

/// Why a message didn't go through, in the same plain words on iOS and macOS.
/// Each app maps its own error type to one of these. The raw text stays available as `details`.
public enum ChatFailure: Equatable, Sendable {
    case agentOffline
    case agentNotFound
    /// The connection closed before the reply.
    case connectionClosed
    case timedOut
    /// The agent is still working on the last message.
    case busy
    /// The connection dropped mid-reply and the message was not resent.
    case notRecovered
    /// The app closed before the reply.
    case outcomeUnknown
    /// Something the agent itself reported.
    case server(String)
    /// Anything the app doesn't recognise.
    case other(String)

    /// The sentence shown after "Not sent:" or in a system row.
    public func sentence(agentName: String) -> String {
        switch self {
        case .agentOffline:
            return "\(agentName) is offline."
        case .agentNotFound:
            return "\(agentName) couldn't be found. Check its address."
        case .connectionClosed:
            return "The connection to \(agentName) closed before it replied."
        case .timedOut:
            return "\(agentName) didn't reply in time."
        case .busy:
            return "\(agentName) is still working on your last message."
        case .notRecovered:
            return "The connection dropped before the reply arrived. Your message wasn't resent."
        case .outcomeUnknown:
            return "The app closed before \(agentName) replied. It may have run, so check before you retry."
        case .server(let raw):
            return Self.agentSaid(raw, agentName: agentName)
        case .other(let raw):
            return Self.plain(raw, agentName: agentName)
        }
    }

    /// The original text, for "Copy error details" (iOS) and the hover text (Mac).
    public var details: String? {
        switch self {
        case .server(let raw), .other(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    /// Known host messages are rewritten; anything else passes through with addresses shortened.
    static func agentSaid(_ raw: String, agentName: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "\(agentName) reported a problem but didn't say what."
        }
        // The host's "Agent not connected: 0x…; reconnect with a fresh CONNECT".
        if text.hasPrefix("Agent not connected") {
            return "Lost the connection to \(agentName). Retry to reconnect."
        }
        return shortenAddresses(in: text)
    }

    static func plain(_ raw: String, agentName: String) -> String {
        let text = shortenAddresses(in: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return text.isEmpty ? "Something went wrong talking to \(agentName)." : text
    }

    /// "0x" followed by 64 hex characters becomes "0x9657…a9a7".
    public static func shortenAddresses(in text: String) -> String {
        guard let pattern = fullAddress else {
            return text
        }
        let source = text as NSString
        var result = text
        // Replace from the end so earlier ranges stay valid.
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let address = source.substring(with: match.range)
            let short = "\(address.prefix(6))…\(address.suffix(4))"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: short)
            }
        }
        return result
    }

    private static let fullAddress = try? NSRegularExpression(pattern: "0x[0-9a-fA-F]{64}")
}
