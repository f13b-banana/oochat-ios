import Foundation

/// Where Pairing with a Claude Station stands, and whether it can be tried. The Work Room store builds it;
/// a view only draws it.
public struct StationPairing: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unpaired
        /// A code is with the host, waiting for its answer.
        case pairing
        /// The host accepted the code. The app connects again to this session to open the Station.
        case paired(sessionID: String)
        /// Plain copy for why the last attempt did not pair.
        case failed(reason: String)
    }

    public var state = State.unpaired
    var isConnected = false
    /// A code was remembered for the automatic attach and has not been used yet.
    public internal(set) var hasRememberedCode = false

    /// The app should ask for a code: the last attempt failed, or nothing was remembered to try.
    public var needsCode: Bool {
        switch state {
        case .failed: true
        case .unpaired: !hasRememberedCode
        case .pairing, .paired: false
        }
    }

    /// Why pairing cannot be tried now, nil when it can or when the Station is already paired.
    public var unavailableReason: String? {
        switch state {
        case .paired:
            nil
        case .pairing:
            "Pairing with your terminal"
        case _ where !isConnected:
            "There is no connection to the agent right now. Pairing needs one."
        default:
            nil
        }
    }

    /// The Pair button is enabled.
    public var canPair: Bool {
        unavailableReason == nil && sessionID == nil
    }

    /// The session the host paired this device with.
    public var sessionID: String? {
        if case .paired(let sessionID) = state {
            return sessionID
        }
        return nil
    }
}

enum StationPairingRules {
    /// How long the host has to answer PROVIDER_STATION_ATTACH.
    static let acknowledgement = Duration.seconds(30)

    /// The host also closes the connection when the Station is already paired with another device.
    static let connectionDropped =
        "The connection closed before the host answered. A Station pairs with one device at a time: if another "
        + "device is paired, restart the Station in your terminal and use its new code."
    static let timedOut = "The host did not answer in time. Try again."
    static let refused = "The host refused the pairing request. Try again."
    static let noSession = "The host accepted the code but did not name the session. Try again."

    /// Plain copy for a refused code. The host's reason is an open string; an unknown one gets the generic line.
    static func rejectionText(reason: String?) -> String {
        WorkRoomRequest.rejectionText(reason, [
            "invalid_pairing_code": "That pairing code was not accepted. Check the code in your terminal and try again."
        ], fallback: "The host did not accept the pairing.")
    }
}

public extension WorkRoom {
    /// The Station's invocation id is `claude_code:station:<session id>` and its Work Room group is the same id.
    static let stationIDPrefix = "claude_code:station:"

    /// This Work Room is a Claude Station's session.
    var isClaudeStation: Bool {
        provider == .claudeCode && id.hasPrefix(Self.stationIDPrefix)
    }
}
