//
//  OIPClientFrames.swift
//  ConnectOnionKit
//

import Foundation

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
        lastMessageID: String?
    ) throws -> [String: JSONValue] {
        var frame = try signer.envelope(
            type: OIPFrameType.connect,
            payload: signer.connectPayload(to: recipient)
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
    ///  `requestID` is the `id` of the approval_needed event; always wins over the decision
    public func approvalResponse(
        requestID: String,
        decision: [String: JSONValue]
    ) throws -> [String: JSONValue] {
        var fields = decision
        fields["request_id"] = .string(requestID)
        return try command(type: OIPFrameType.approvalResponse, fields: fields)
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
