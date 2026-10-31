import ConnectOnionKit
import Foundation

enum HostedAgentClientError: LocalizedError {
    case invalidAddress
    case invalidURL(String)
    case badFrame
    case server(String)
    case closed
    case timeout
    case busy
    /// A message sent before the app closed has no recorded result on the host.
    case outcomeUnknown

    case incompatibleProtocol(OIPHandshake.Incompatibility)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "That doesn't look like an agent address. It should start with 0x followed by 64 characters."
        case .invalidURL(let url):
            return "Couldn't reach the agent at \(url). Check that the address is correct and the agent is online."
        case .badFrame:
            return "The agent sent a reply the app couldn't understand. Try again."
        case .server(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "The agent reported a problem but didn't say what went wrong. Try again."
                : "The agent reported a problem: \(detail)"
        case .closed:
            return "The connection closed before the agent replied. Try again."
        case .timeout:
            return "The agent didn't reply in time. Try again."
        case .busy:
            return "The agent is still working on your previous message in this conversation. Wait for it to finish, then try again."
        case.incompatibleProtocol(let incompatibility):
            return incompatibility.message
        case .outcomeUnknown:
            return "The app closed before the agent replied, and the agent has no reply to this message. "
                + "It may or may not have run, so check before you retry."
        }
    }

    // Set only for -32010. The view model shows the Incompatible screen when it is non-nil.
    var incompatibility: OIPHandshake.Incompatibility? {
        if case .incompatibleProtocol(let value) = self {
            return value
        }
        return nil
    }

    static func isConnectivityFailure(_ error: Error) -> Bool {
        guard let clientError = error as? HostedAgentClientError else {
            return false
        }
        switch clientError {
        case .closed, .timeout, .invalidURL:
            return true
        case .invalidAddress, .badFrame, .server, .busy, .incompatibleProtocol, .outcomeUnknown:
            return false
        }
    }
}
