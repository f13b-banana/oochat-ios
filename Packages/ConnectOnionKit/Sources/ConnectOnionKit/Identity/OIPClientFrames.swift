//
//  OIPClientFrames.swift
//  ConnectOnionKit
//

import Foundation

/// A provider builder refused its input; `invalidField` names the wire field.
public enum OIPClientFrameError: Error, Equatable {
    case invalidField(String)
}

/// What a client asks of a Station session's control.
public enum OIPProviderControlAction: String, Equatable, Sendable {
    case take
    case release
}

/// Builds every frame the client sends to one agent, signed throug OIPSigner unless exempt.
/// Pure: no sockets no app types, the app passes plain values in and sends what comes out.

public struct OIPClientFrames: Sendable {

    /// with signedCommands: 1 the host demands a v2 signed command for every frame except these (host ws_router/ses_
    /// Connect and ONBOARD_SUBMIT are still signed with v1 envelope; PONG and SESSION_STATUS cary no signature at all.
    public static let v2ExemptTypes: Set<String> = [
        OIPFrameType.connect,
        OIPFrameType.pong,
        OIPFrameType.sessionStatus,
        OIPFrameType.onboardSubmit
    ]

    private let signer: OIPSigner
    private let recipient: String
    private let now: @Sendable() -> Date

    /// One Clock for the signer and requested_at,ax so both never disagree
    public init(
    keyStore: any PrivateKeyStoring,
    to recipient: String,
    now: @escaping @Sendable () -> Date = { Date() },
    nonce: @escaping @Sendable() -> String = { UUID().uuidString.lowercased() }
    ) {
        self.signer = OIPSigner(keyStore: keyStore, now: now, nonce: nonce)
        self.recipient = recipient
        self.now = now
    }

    // Signed with the v1 Envelope

    /// CONNECT. Only to, timestamp, nonce and signed_commands are signed'; the protocl descriptor and the resume fileds travel unsigned beside theim
    public func connect(
        direct: Bool,
        sessionID: String?,
        session: JSONValue?,
        lastMessageID: String?,
        requestSessionSync: Bool = false
    ) throws -> [String: JSONValue] {
        var frame = try signer.envelope(
            type: OIPFrameType.connect,
            payload: signer.connectPayload(to: recipient, requestSessionSync: requestSessionSync)
        )
        frame["protocol"] = .object(OIP.descriptor)
        if !direct {
            frame["to"] = .string(recipient)
        }
        if let sessionID {
            frame["session_id"] = .string(sessionID)
        }
        if let session {
            frame["session"] = session
        }
        if let lastMessageID {
            frame["last_msg_id"] = .string(lastMessageID)
        }
        return frame
    }

    public func onboardSubmit(inviteCode: String) throws -> [String: JSONValue] {
        try signer.envelope(
            type: OIPFrameType.onboardSubmit,
            payload: [
                "timestamp": .number(now().timeIntervalSince1970.rounded(.down)),
                "invite_code": .string(inviteCode)
            ]
        )
    }

    // Signed v2 Commands:

    /// The host reads prompt, imgs, and files; everythign it acts on must be signed.
    public func input(
        inputID: String,
        prompt: String,
        images: [String] = [],
        files: [JSONValue] = []
    ) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "input_id": .string(inputID),
            "prompt": .string(prompt)
        ]

        if !images.isEmpty {
            fields["images"] = .array(images.map(JSONValue.string))
        }
        if !files.isEmpty {
            fields["files"] = .array(files)
        }
        return try command(type: OIPFrameType.input, fields: fields)
    }

    /// Runs one named tool without the LLM. The host answers with the EXEC_RESULT carrying the same exec_id
    public func exec(execID: String, tool: String, args: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        try command(
            type: OIPFrameType.exec,
            fields: ["exec_id": .string(execID), "tool": .string(tool), "args": .object(args)])
    }

    /// The Host accepts only read-only, auto and full-access, and sets the full-access turn budget itself so no turns is set
    public func modeChange(_ mode: OIPPermissionMode) throws -> [String: JSONValue] {
        try command(type: OIPFrameType.modeChange, fields: ["mode": .string(mode.rawValue)])
    }

    /// Naming hte run being interrupted lets the host echo it back, so a stale ack fo ran abandoned run can be told apart from current one.
    public func interrupt(inputID: String?) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "requested_at_ms": .number((now().timeIntervalSince1970 * 1_000).rounded())
        ]
        if let inputID {
            fields["input_id"] = .string(inputID)
        }
        return try command(type: OIPFrameType.interrupt, fields: fields)
    }

    /// 'requestID" i sthe id of the ask_user event being answered: the host drop a mismatched answera as STALE ANSEWR
    public func askUserResponse(requestID: String, answer: String) throws -> [String: JSONValue] {
        try command(
            type: OIPFrameType.askUserResponse,
            fields: ["request_id": .string(requestID), "answer": .string(answer)]
        )
    }

    /// `decision` is the approval's fields (approved, scope, mode, feedback)
    ///  `requestID` is the `id` of the approval_needed event; always wins over the decision. Nil only when the
    ///  host stamped no id: then no `request_id` is sent, as the web client does.
    public func approvalResponse(
        requestID: String?,
        decision: [String: JSONValue]
    ) throws -> [String: JSONValue] {
        var fields = decision
        fields["request_id"] = requestID.map(JSONValue.string)
        return try command(type: OIPFrameType.approvalResponse, fields: fields)
    }

    // Provider commands. A builder throws `OIPClientFrameError` rather than sign a frame the host would reject.

    /// Stops one Provider Invocation. `stateRevision` is the revision the client last saw for it.
    public func providerInterrupt(
        invocationID: String,
        requestID: String,
        stateRevision: Int
    ) throws -> [String: JSONValue] {
        try command(
            type: OIPFrameType.providerInterrupt,
            fields: try Self.invocationFields(invocationID, requestID, stateRevision)
        )
    }

    /// Sends text to a Provider Invocation. The text is trimmed and must be 1 to 12,000 characters.
    public func providerInput(
        invocationID: String,
        requestID: String,
        stateRevision: Int,
        text: String
    ) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= Self.providerInputLimit else {
            throw OIPClientFrameError.invalidField("text")
        }
        var fields = try Self.invocationFields(invocationID, requestID, stateRevision)
        fields["text"] = .string(trimmed)
        return try command(type: OIPFrameType.providerInput, fields: fields)
    }

    /// `confirmRisk` must be true for an elevated option; the host checks that, the client only passes it on.
    public func providerPermissionChange(
        invocationID: String,
        requestID: String,
        stateRevision: Int,
        optionID: String,
        confirmRisk: Bool
    ) throws -> [String: JSONValue] {
        var fields = try Self.invocationFields(invocationID, requestID, stateRevision)
        fields["optionId"] = .string(try Self.boundedID(optionID, "optionId"))
        fields["confirmRisk"] = .bool(confirmRisk)
        return try command(type: OIPFrameType.providerPermissionChange, fields: fields)
    }

    public func providerStationAttach(pairingCode: String, requestID: String) throws -> [String: JSONValue] {
        guard !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pairingCode.unicodeScalars.count <= Self.pairingCodeLimit else {
            throw OIPClientFrameError.invalidField("pairingCode")
        }
        return try command(
            type: OIPFrameType.providerStationAttach,
            fields: [
                "pairingCode": .string(pairingCode),
                "request_id": .string(try Self.boundedID(requestID, "request_id", 128))
            ]
        )
    }

    /// `stateRevision` is the Station control revision from `provider_session`, not an invocation revision.
    public func providerControl(
        sessionID: String,
        action: OIPProviderControlAction,
        stateRevision: Int,
        requestID: String
    ) throws -> [String: JSONValue] {
        guard stateRevision > 0 else {
            throw OIPClientFrameError.invalidField("stateRevision")
        }
        return try command(
            type: OIPFrameType.providerControl,
            fields: [
                "sessionId": .string(try Self.boundedID(sessionID, "sessionId")),
                "action": .string(action.rawValue),
                "stateRevision": .number(Double(stateRevision)),
                "request_id": .string(try Self.boundedID(requestID, "request_id", 128))
            ]
        )
    }

    private static let providerInputLimit = 12_000
    private static let pairingCodeLimit = 128

    private static func invocationFields(
        _ invocationID: String,
        _ requestID: String,
        _ stateRevision: Int
    ) throws -> [String: JSONValue] {
        guard stateRevision > 0 else {
            throw OIPClientFrameError.invalidField("stateRevision")
        }
        return [
            "invocationId": .string(try boundedID(invocationID, "invocationId")),
            "requestId": .string(try boundedID(requestID, "requestId", 128)),
            "stateRevision": .number(Double(stateRevision))
        ]
    }

    /// A non-empty id of at most `limit` characters; the host's bounds are 512 for ids and 128 for request ids.
    private static func boundedID(_ value: String, _ field: String, _ limit: Int = 512) throws -> String {
        guard !value.isEmpty, value.count <= limit else {
            throw OIPClientFrameError.invalidField(field)
        }
        return value
    }

    public func command(type: String, fields: [String: JSONValue]) throws -> [String: JSONValue] {
        try signer.command(type: type, fields: fields, to: recipient)
    }

    public static func pong() -> [String: JSONValue] {
        ["type": .string(OIPFrameType.pong)]
    }

    public static func sessionStatus(sessionID: String) -> [String: JSONValue] {
        [
            "type": .string(OIPFrameType.sessionStatus),
            "session": .object(["session_id": .string(sessionID)])
        ]
    }
}
