//
//  OIPServerFrame.swift
//  ConnectOnionKit
//
//

import Foundation

// OIP Server Frame Decoder implementation

// Structs

// Protocol field in JSON
public struct OIPDescriptor: Equatable, Sendable {
    public let name: String?
    public let version: String?
    public let minVersion: String?
    public let maxVersion: String?
    public let websocketPath: String?
    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue else {
            return nil
        }
        name = object["name"]?.stringValue
        version = object["version"]?.stringValue
        minVersion = object["min_version"]?.stringValue
        maxVersion = object["max_version"]?.stringValue
        websocketPath = object["websocket_path"]?.stringValue
    }
}

// Used for availableModes as part of OIPSessionModes
public struct OIPModeOption: Equatable, Sendable {
    public let id: OIPPermissionMode
    public let name: String?
}

// Used for sessionModes as part of OIPConnected
public struct OIPSessionModes: Equatable, Sendable {
    public let currentMode: OIPPermissionMode?
    public let turnsLeft: Int?
    public let availableModes: [OIPModeOption]
    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue else {
            return nil
        }
        currentMode = object["currentModeId"]?.stringValue.map(OIPPermissionMode.init(protocolValue:))
        turnsLeft = object["turnsLeft"]?.intValue
        availableModes = (object["availableModes"]?.arrayValue ?? []).compactMap { item in
            guard let id = item.objectValue?["id"]?.stringValue else {
                return nil
            }
            return OIPModeOption(
                id: OIPPermissionMode(protocolValue: id),
                name: item.objectValue?["name"]?.stringValue
            )
        }
    }
}

// CONNECTED (status, session_modes, server_newer)
public struct OIPConnected: Equatable, Sendable {
    public let sessionID: String?
    public let status: String
    public let hostProtocol: OIPDescriptor?
    public let sessionModes: OIPSessionModes?
    public let serverNewer: Bool
    public let session: [String: JSONValue]?
    public let chatItems: [JSONValue]?
}

// Code for Error needs handling since it can be int or string
public enum OIPServerErrorCode: Equatable, Sendable {
    case int(Int)
    case string(String)
    init?(_ value: JSONValue?) {
        if let string = value?.stringValue {
            self = .string(string)
        } else if let int = value?.intValue {
            self = .int(int)
        } else {
            return nil
        }
    }
}

// ERROR (integer or string code)
public struct OIPServerError: Equatable, Sendable {
    public let code: OIPServerErrorCode?
    public let message: String?
    public let reason: String?
    public let requestID: String?
}

// SESSION_STATUS, mode_changed (with turns_left), PING, stream events and unknown

// OUTPUT
public struct OIPOutput: Equatable, Sendable {
    public let result: String
    public let sessionID: String?
    public let durationMS: Int?
    /// The session snapshot, including the trace.
    public let session: [String: JSONValue]?
}

// Agent Skills for OIPAgentProfile
public struct OIPAgentSkill: Equatable, Sendable {
    public let name: String
    public let description: String?
    public let location: String?
}

// AGENT_PROFILE
public struct OIPAgentProfile: Equatable, Sendable {
    public let sessionID: String?
    public let name: String?
    public let address: String?
    public let model: String?
    public let tools: [String]
    public let skills: [OIPAgentSkill]
    public let balanceUSD: Double?
}

// EXEC_RESULT
public struct OIPExecResult: Equatable, Sendable {
    public let execID: String
    public let tool: String?
    public let status: String
    // On failure (tool raised, not whitelisted, unknown tool): status: "error" with an error field instead of result
    public let result: String?
    public let error: String?
    public let durationMS: Int?

    public var isSuccess: Bool {
        status == "success"
    }
}

// ONBOARD_REQUIRED
public struct OIPOnboardRequired: Equatable, Sendable {
    public let identity: String?
    public let methods: [String]
    public let paymentAmount: Double?
    public let paymentAddress: String?
}

// Frame

public enum OIPServerFrame: Equatable, Sendable {
    case connected(OIPConnected)
    case error(OIPServerError)
    case output(OIPOutput)
    case agentProfile(OIPAgentProfile)
    case sessionStatus(sessionID: String?, status: String)
    // Unknown mode arrives as .unknown(raw), access raw string through mode.rawValue
    case modeChanged(mode: OIPPermissionMode, turnsLeft: Int?)
    case execResult(OIPExecResult)
    case onboardRequired(OIPOnboardRequired)
    case ping
    // 'body' is the whole frame containing 'type' and 'id' for stream and interaction frames
    case event(type: String, id: String?, body: [String: JSONValue])
    // Anything unrecognised or missing required fields
    case unknown(type: String?, body: [String: JSONValue])
    // Stream Event Types
    static let streamEventTypes: Set<String> = [
        OIPFrameType.plan,
        OIPFrameType.thinking,
        OIPFrameType.toolCall,
        OIPFrameType.toolResult,
        OIPFrameType.askUser,
        OIPFrameType.approvalNeeded,
        OIPFrameType.compact,
        OIPFrameType.userMessage,
        OIPFrameType.userInput,
        OIPFrameType.runtimeInputAck,
        OIPFrameType.onboardSuccess
    ]
    // Decode
    public static func decode(_ frame: [String: JSONValue]) -> OIPServerFrame {
        guard let type = frame["type"]?.stringValue else {
            return .unknown(type: nil, body: frame)
        }
        let decoded: OIPServerFrame?
        switch type {
        case OIPFrameType.connected:
            decoded = decodeConnected(frame)
        case OIPFrameType.error:
            decoded = decodeError(frame)
        case OIPFrameType.output:
            decoded = decodeOutput(frame)
        case OIPFrameType.agentProfile:
            decoded = decodeAgentProfile(frame)
        case OIPFrameType.sessionStatus:
            decoded = decodeSessionStatus(frame)
        case OIPFrameType.modeChanged:
            decoded = decodeModeChanged(frame)
        case OIPFrameType.execResult:
            decoded = decodeExecResult(frame)
        case OIPFrameType.onboardRequired:
            decoded = decodeOnboardRequired(frame)
        case OIPFrameType.ping:
            decoded = .ping
        default:
            decoded = streamEventTypes.contains(type)
            ? .event(type: type, id: frame["id"]?.stringValue, body: frame)
            : nil
        }
        return decoded ?? .unknown(type: type, body: frame)
    }
    // Frame Decoders
    private static func decodeConnected(_ frame: [String: JSONValue]) -> OIPServerFrame? {
        guard let status = frame["status"]?.stringValue else {
            return nil
        }
        return .connected(
            OIPConnected(
                sessionID: frame["session_id"]?.stringValue,
                status: status,
                hostProtocol: OIPDescriptor(frame["protocol"]),
                sessionModes: OIPSessionModes(frame["session_modes"]),
                serverNewer: frame["server_newer"]?.boolValue ?? false,
                session: frame["session"]?.objectValue,
                chatItems: frame["chat_items"]?.arrayValue
            )
        )
    }
    private static func decodeError(_ frame: [String: JSONValue]) -> OIPServerFrame? {
        let code = OIPServerErrorCode(frame["code"])
        let incompatible = code == .int(OIPErrorCode.incompatibleVersion)
        return .error(
            OIPServerError(
                code: code,
                message: frame["message"]?.stringValue,
                reason: frame["reason"]?.stringValue,
                requestID: frame["request_id"]?.stringValue
            )
        )
    }
    private static func decodeOutput(_ frame: [String: JSONValue]) -> OIPServerFrame? {
        guard let result = frame["result"]?.stringValue else {
            return nil
        }
        let session = frame["session"]?.objectValue
        return .output(
            OIPOutput(
                result: result,
                sessionID: frame["session_id"]?.stringValue ?? session?["session_id"]?.stringValue,
                durationMS: frame["duration_ms"]?.intValue,
                session: session
            )
        )
    }
    private static func decodeAgentProfile(_ frame: [String: JSONValue]) -> OIPServerFrame? {
        .agentProfile(
            OIPAgentProfile(
                sessionID: frame["session_id"]?.stringValue,
                name: frame["name"]?.stringValue,
                address: frame["address"]?.stringValue,
                model: frame["model"]?.stringValue,
                tools: names(frame["tools"]),
                skills: skills(frame["skills"]),
                balanceUSD: frame["balance_usd"]?.numberValue
            )
        )
    }
    private static func decodeSessionStatus(_ frame: [String: JSONValue]) -> OIPServerFrame? {
        // The client's own SESSION_STATUS request has no `status`, so it falls through to .unknown.
        guard let status = frame["status"]?.stringValue else {
            return nil
        }
        return .sessionStatus(sessionID: frame["session_id"]?.stringValue, status: status)
    }

    private static func decodeModeChanged(_ frame: [String: JSONValue]) -> OIPServerFrame? {
        guard let raw = frame["mode"]?.stringValue else {
            return nil
        }
        return .modeChanged(
            mode: OIPPermissionMode(protocolValue: raw),
            turnsLeft: frame["turns_left"]?.intValue
        )
    }

    private static func decodeExecResult(_ frame: [String: JSONValue]) -> OIPServerFrame? {
        guard let execID = frame["exec_id"]?.stringValue,
              let status = frame["status"]?.stringValue else {
            return nil
        }
        return .execResult(
            OIPExecResult(
                execID: execID,
                tool: frame["tool"]?.stringValue,
                status: status,
                result: frame["result"]?.stringValue,
                error: frame["error"]?.stringValue,
                durationMS: frame["duration_ms"]?.intValue
            )
        )
    }

    private static func decodeOnboardRequired(_ frame: [String: JSONValue]) -> OIPServerFrame? {
        .onboardRequired(
            OIPOnboardRequired(
                identity: frame["identity"]?.stringValue,
                methods: strings(frame["methods"]),
                paymentAmount: frame["payment_amount"]?.numberValue,
                paymentAddress: frame["payment_address"]?.stringValue
            )
        )
    }
    // Helpers
    private static func strings(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap(\.stringValue)
    }
    /// The spec sends `["a", "b"]`; also accepts `[{"name": "a"}]`.
    private static func names(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { item in
            item.stringValue ?? item.objectValue?["name"]?.stringValue
        }
    }
    /// The spec sends `[{"name", "description", "location"}]`; also accepts bare names.
    private static func skills(_ value: JSONValue?) -> [OIPAgentSkill] {
        (value?.arrayValue ?? []).compactMap { item in
            if let name = item.stringValue {
                return OIPAgentSkill(name: name, description: nil, location: nil)
            }
            guard let object = item.objectValue,
                  let name = object["name"]?.stringValue else {
                return nil
            }
            return OIPAgentSkill(
                name: name,
                description: object["description"]?.stringValue,
                location: object["location"]?.stringValue
            )
        }
    }
}
