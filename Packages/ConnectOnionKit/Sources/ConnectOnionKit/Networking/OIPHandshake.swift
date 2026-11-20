import Foundation

/// What a connection should do with one frame received between our CONNECT and the host's CONNECTED.
///
/// This file only decides what a decoded frame means for the handshake
public enum OIPHandshake {
    /// What the app should do with one received frame.
    public enum Step: Equatable, Sendable {
        /// CONNECTED. The handshake is over.
        case established(OIPConnected)
        /// A frame to send back at once (PING gets PONG), then keep waiting.
        case reply([String: JSONValue])
        /// The agent wants an invite code or payment before it accepts the CONNECT.
        case onboardRequired(OIPOnboardRequired)
        /// ONBOARD_SUCCESS. The host replays the stashed CONNECT itself, so keep waiting.
        case onboardSucceeded(message: String?)
        /// The host answered -32010. (stop)
        case incompatible(Incompatibility)
        /// Any other ERROR (signature, recipient, replay, trust, storage).
        case rejected(message: String)
        /// Not part of the handshake. Keep waiting.
        case ignore
    }

    /// The frame could not be used as a handshake frame.
    public enum Failure: Error, Equatable, Sendable {
        case notAnObject
        /// A CONNECTED frame without a `status`, which `OIPServerFrame` reports as unknown.
        case malformed(frame: String)
    }

    /// Which side has to update when the host refuses our protocol version.
    /// Declared here, not inside `Incompatibility`, to stay within SwiftLint's one-level nesting limit.
    public enum Direction: Equatable, Sendable {
        /// The agent runs a newer protocol than this app. Update the app.
        case appTooOld
        /// The agent runs an older protocol. The agent's owner has to update it.
        case agentTooOld
        /// The host did not say, or the versions do not compare.
        case unknown
    }

    /// The host refused our protocol version. It is final: the version is fixed in the app.
    public struct Incompatibility: Error, Equatable, Sendable {
        /// The version the host speaks. Nil only when the host sent no descriptor.
        public let neededVersion: String?
        /// The version our CONNECT declared.
        public let appVersion: String?

        public init(neededVersion: String?, appVersion: String? = OIP.version) {
            self.neededVersion = neededVersion
            self.appVersion = appVersion
        }

        public var direction: Direction {
            guard let needed = neededVersion.flatMap(Self.components),
                  let app = appVersion.flatMap(Self.components) else {
                return .unknown
            }
            if needed.lexicographicallyPrecedes(app) {
                return .agentTooOld
            }
            return needed == app ? .unknown : .appTooOld
        }

        public var isRetryable: Bool {
            false
        }

        public var title: String {
            "Incompatible agent"
        }

        /// Names the version needed, in words the Incompatible screen can show as it is.
        public var message: String {
            guard let needed = neededVersion else {
                return "This agent does not support the protocol version this app uses"
                    + (appVersion.map { " (OIP \($0))." } ?? ".")
            }
            let app = appVersion.map { "OIP \($0)" } ?? "an unknown version"
            switch direction {
            case .appTooOld:
                return "This agent needs OIP \(needed). This app speaks \(app). Update the app to connect."
            case .agentTooOld:
                return "This agent speaks OIP \(needed). This app speaks \(app). "
                    + "Ask the agent's owner to update it."
            case .unknown:
                return "This agent needs OIP \(needed). This app speaks \(app)."
            }
        }

        private static func components(_ version: String) -> [Int]? {
            let parts = version.split(separator: ".").map { Int($0) }
            guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else {
                return nil
            }
            return parts.compactMap { $0 }
        }
    }

    /// One received text frame. Frames that are not part of the handshake are `.ignore`.
    /// `appVersion` is the version our CONNECT declared; tests pass another to cover both directions.
    public static func interpret(_ data: Data, appVersion: String? = OIP.version) throws -> Step {
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Failure.notAnObject
        }
        return try interpret(fields, appVersion: appVersion)
    }

    public static func interpret(_ fields: [String: JSONValue], appVersion: String? = OIP.version) throws -> Step {
        switch OIPServerFrame.decode(fields) {
        case .connected(let connected):
            // `index` answers a session-sync-only CONNECT, which no app sends.
            if connected.status == "index" {
                return .rejected(message: "The agent replied with a session index instead of joining the session.")
            }
            return .established(connected)
        case .error(let error):
            if error.code == .int(OIPErrorCode.incompatibleVersion) {
                // `OIPServerError` does not carry the host's `protocol`, so read its version here.
                return .incompatible(
                    Incompatibility(neededVersion: OIPDescriptor(fields["protocol"])?.version, appVersion: appVersion)
                )
            }
            // The host's CONNECT-phase errors carry `message` only; older tests and relays use `error`.
            return .rejected(
                message: error.message ?? fields["error"]?.stringValue ?? error.reason ?? "Authentication failed"
            )
        case .ping:
            return .reply(OIPClientFrames.pong())
        case .onboardRequired(let required):
            return .onboardRequired(required)
        case .event(let type, _, let body) where type == OIPFrameType.onboardSuccess:
            return .onboardSucceeded(message: body["message"]?.stringValue)
        case .unknown(let type, _) where type == OIPFrameType.connected:
            throw Failure.malformed(frame: OIPFrameType.connected)
        default:
            return .ignore
        }
    }
}

extension OIPConnected {
    /// A turn is still running on the host and its output will be replayed after CONNECTED.
    public var isRunning: Bool {
        status == "running"
    }

    /// The host gave us a different id than the one we asked to resume.
    /// The app must drop its stored transcript.
    public func replacesSession(asked: String?) -> Bool {
        guard let asked, let sessionID else {
            return false
        }
        return asked != sessionID
    }
}
