//
//  OIPClientFramesTests.swift
//  ConnectOnionKit
//

import CryptoKit
import Foundation
import Testing
@testable import ConnectOnionKit

// Same key, Host, clock as OIPSignerTests.
private let fixtureKey = Data((0..<32).map { UInt8($0)})
private let host = "0x" + String(repeating: "ab", count: 32)

private func frames() -> OIPClientFrames {
    let now = Date(timeIntervalSince1970: 1_700_000_000.9)
    return OIPClientFrames(
        keyStore: InMemoryPrivateKeyStore(rawKey: fixtureKey),
        to: host,
        now: { now },
        nonce: { "nonce-1" }
    )
}

private struct Fixture: Decodable {
    let signed: Bool
    let frame: [String: JSONValue]
}

private func loadFixture(_ name: String) throws -> Fixture {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/client")
    )
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
}

/// Helper to compare CryptoKit signatures. Signatures are not compared by bytes - so asigned fixture holds no signature; it is checked with CryptoKit, removed and the rest must be equal.
private func expectFrame(_ built: [String: JSONValue], equals name: String) throws {
    let fixture = try loadFixture(name)
    var actual = built
    let signature = actual.removeValue(forKey: "signature")
    if fixture.signed {
        let hex = try #require(signature?.stringValue, "\(name) is not signed")
        guard case .object(let payload)? = actual["payload"] else {
            Issue.record("\(name): no payload")
            return
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: fixtureKey).publicKey
        #expect(key.isValidSignature(try #require(Hex.decode(hex)), for: CanonicalJSON.data(from: payload)))
    } else {
        #expect(signature == nil, "\(name) is exempt and must not be signed")
    }
    #expect(actual == fixture.frame, "\(name) differes from its fixture")
}

@Test func connectMatchesItsFixtures() throws {
    try expectFrame(
        frames().connect(direct: true, sessionID: nil, session: nil, lastMessageID: nil),
        equals: "connect-direct"
    )
    try expectFrame(
        frames().connect(
            direct: false,
            sessionID: "session-1",
            session: .object(["mode": .string("auto"), "turns_left": .number(1)]),
            lastMessageID: "msg-9"
        ),
        equals: "connect-relay-resume"
    )
}

@Test func connectCanAskForSessionSyncAndOtherwiseAsksForNothing() throws {
    try expectFrame(
        frames().connect(direct: true, sessionID: nil, session: nil, lastMessageID: nil, requestSessionSync: true),
        equals: "connect-session-sync"
    )
    let plain = try frames().connect(direct: true, sessionID: nil, session: nil, lastMessageID: nil)
    #expect(plain["payload"]?.objectValue?["extensions"] == nil)
}

@Test func inputMatchesItsFixture() throws {
    try expectFrame(
        frames().input(
            inputID: "input-1",
            prompt: "hi",
            images: ["data:image/png;base64,AA=="],
            files: [.object(["name": .string("notes.txt")])]
        ),
        equals: "input"
    )
}

@Test func askUserResponseMatchesItsFixture() throws {
    try expectFrame(frames().askUserResponse(requestID: "ask-1", answer: "A"), equals: "ask-user-response")
}

@Test func approvalResponseMatchesItsFixture() throws {
    let decision: [String: JSONValue] = [
        "approved": .bool(false),
        "mode": .string("reject_soft"),
        "feedback": .string("Use another file")
    ]
    try expectFrame(
        frames().approvalResponse(requestID: "approval-1", decision: decision),
        equals: "approval-response"
    )
}

@Test func exemptFramesMatchTheirFixturesAndCarryNoSignature() throws {
    try expectFrame(OIPClientFrames.pong(), equals: "pong")
    try expectFrame(OIPClientFrames.sessionStatus(sessionID: "session-1"), equals: "session-status")
}

// 16.3: both answers carry request_id inside the signed payload, and it cannot be overridden.
@Test func bothAnswersCarryRequestIDInTheSignedPayload() throws {
    let ask = try frames().askUserResponse(requestID: "ask-1", answer: "A")
    let approval = try frames().approvalResponse(
        requestID: "approval-1",
        decision: ["approved": .bool(true), "request_id": .string("stale")]
    )
    for (frame, id) in [(ask, "ask-1"), (approval, "approval-1")] {
        guard case .object(let payload)? = frame["payload"] else {
            Issue.record("no payload")
            return
        }
        #expect(payload["request_id"] == .string(id))
    }
}

@Test func decisionCannotOverrideSignerOwnedKeys() {
    #expect(throws: OIPSignerError.reservedField("nonce")) {
        try frames().approvalResponse(requestID: "approval-1", decision: ["nonce": .string("x")])
    }
}

@Test func execMatchesItsFixture() throws {
    try expectFrame(
        frames().exec(execID: "exec-1", tool: "read_file", args: ["path": .string("README.md")]),
        equals: "exec"
    )
}

@Test func modeChangeMatchesItsFixture() throws {
    try expectFrame(frames().modeChange(.fullAccess), equals: "mode-change")
}

@Test func interruptMatchesItsFixture() throws {
    try expectFrame(frames().interrupt(inputID: "input-1"), equals: "interrupt")
}

@Test func onboardSubmitMatchesItsFixture() throws {
    try expectFrame(frames().onboardSubmit(inviteCode: "abc/123"), equals: "onboard-submit")
}

@Test func everyFrameOutsideTheExemptSetIsASignedCommand() throws {
    let signed = [
        try frames().input(inputID: "i", prompt: "p"),
        try frames().exec(execID: "e", tool: "t"),
        try frames().modeChange(.auto),
        try frames().interrupt(inputID: nil),
        try frames().askUserResponse(requestID: "r", answer: "a"),
        try frames().approvalResponse(requestID: "r", decision: ["approved": .bool(true)]),
        try frames().command(type: "ULW_RESPONSE", fields: ["action": .string("continue")])
    ]
    for frame in signed {
        let type = try #require(frame["type"]?.stringValue)
        #expect(!OIPClientFrames.v2ExemptTypes.contains(type), "\(type) is exempt, so it needs no signature")
        #expect(frame["signature"]?.stringValue != nil, "\(type) is not signed")
    }
}

@Test func optionalFieldsAreLeftOutWhenNotGiven() throws {
    let interrupt = try frames().interrupt(inputID: nil)
    #expect(interrupt["input_id"] == nil, "With no active run there is no input_id to correlate.")
    #expect(interrupt["requested_at_ms"] == .number(1_700_000_000_900))
    let input = try frames().input(inputID: "i", prompt: "p")
    #expect(input["images"] == nil)
    #expect(input["files"] == nil)
}

@Test func providerCommandsMatchTheirFixtures() throws {
    try expectFrame(
        frames().providerInterrupt(invocationID: "codex:call-7", requestID: "interrupt-1", stateRevision: 2),
        equals: "provider-interrupt"
    )
    try expectFrame(
        frames().providerInput(
            invocationID: "codex:call-7",
            requestID: "input-1",
            stateRevision: 1,
            text: "  Add a reverse-order fixture \n"
        ),
        equals: "provider-input"
    )
    try expectFrame(
        frames().providerPermissionChange(
            invocationID: "codex:call-7",
            requestID: "permission-1",
            stateRevision: 1,
            optionID: "codex:workspace-auto",
            confirmRisk: false
        ),
        equals: "provider-permission-change"
    )
    try expectFrame(
        frames().providerStationAttach(pairingCode: "test-pairing-code", requestID: "attach-1"),
        equals: "provider-station-attach"
    )
    try expectFrame(
        frames().providerControl(sessionID: "station-session", action: .take, stateRevision: 2, requestID: "control-1"),
        equals: "provider-control"
    )
}

@Test func providerCommandsRefuseInvalidInput() {
    let frames = frames()
    for revision in [0, -1] {
        #expect(throws: OIPClientFrameError.invalidField("stateRevision")) {
            try frames.providerInterrupt(invocationID: "a", requestID: "r", stateRevision: revision)
        }
        #expect(throws: OIPClientFrameError.invalidField("stateRevision")) {
            try frames.providerControl(sessionID: "s", action: .release, stateRevision: revision, requestID: "r")
        }
    }
    #expect(throws: OIPClientFrameError.invalidField("invocationId")) {
        try frames.providerInterrupt(invocationID: "", requestID: "r", stateRevision: 1)
    }
    #expect(throws: OIPClientFrameError.invalidField("requestId")) {
        try frames.providerInterrupt(invocationID: "a", requestID: String(repeating: "r", count: 129), stateRevision: 1)
    }
    #expect(throws: OIPClientFrameError.invalidField("text")) {
        try frames.providerInput(invocationID: "a", requestID: "r", stateRevision: 1, text: " \n ")
    }
    #expect(throws: OIPClientFrameError.invalidField("text")) {
        try frames.providerInput(invocationID: "a", requestID: "r", stateRevision: 1, text: String(repeating: "x", count: 12_001))
    }
    #expect(throws: OIPClientFrameError.invalidField("optionId")) {
        try frames.providerPermissionChange(
            invocationID: "a", requestID: "r", stateRevision: 1, optionID: "", confirmRisk: true
        )
    }
    #expect(throws: OIPClientFrameError.invalidField("pairingCode")) {
        try frames.providerStationAttach(pairingCode: "", requestID: "r")
    }
    #expect(throws: OIPClientFrameError.invalidField("pairingCode")) {
        try frames.providerStationAttach(pairingCode: String(repeating: "p", count: 129), requestID: "r")
    }
}

@Test func providerInputAtTheLimitIsAccepted() throws {
    let frame = try frames().providerInput(
        invocationID: "a", requestID: "r", stateRevision: 1, text: String(repeating: "x", count: 12_000)
    )
    #expect(frame["type"] == .string("PROVIDER_INPUT"))
}

@Test func providerCommandsAreNotV2Exempt() {
    for type in [
        OIPFrameType.providerInterrupt, OIPFrameType.providerInput, OIPFrameType.providerPermissionChange,
        OIPFrameType.providerStationAttach, OIPFrameType.providerControl
    ] {
        #expect(!OIPClientFrames.v2ExemptTypes.contains(type))
    }
}

// ConnectOnion 1.8.10 reads only the signed payload. It accepts `request_id` or `requestId`; only the spec's `request_id` is sent.
@Test func stationAttachAndControlKeepEveryFieldInsideTheSignedPayload() throws {
    for frame in [
        try frames().providerStationAttach(pairingCode: "code", requestID: "r-1"),
        try frames().providerControl(sessionID: "s", action: .take, stateRevision: 2, requestID: "r-1")
    ] {
        let payload = try #require(frame["payload"]?.objectValue)
        #expect(payload["request_id"] == .string("r-1"))
        #expect(payload["requestId"] == nil)
    }
}

@Test func everyProviderFrameCarriesAllItsFieldsInsideThePayload() throws {
    let all = [
        try frames().providerInterrupt(invocationID: "i", requestID: "r", stateRevision: 1),
        try frames().providerInput(invocationID: "i", requestID: "r", stateRevision: 1, text: "hi"),
        try frames().providerPermissionChange(
            invocationID: "i", requestID: "r", stateRevision: 1, optionID: "claude:plan", confirmRisk: false
        ),
        try frames().providerStationAttach(pairingCode: "code", requestID: "r"),
        try frames().providerControl(sessionID: "s", action: .release, stateRevision: 1, requestID: "r")
    ]
    for frame in all {
        let payload = try #require(frame["payload"]?.objectValue)
        for key in ["from", "signature", "payload"] {
            #expect(payload[key] == nil)
        }
        for (key, value) in frame where !["payload", "from", "signature"].contains(key) {
            #expect(payload[key] == value, "\(key) must be signed")
        }
        #expect(payload["nonce"] != nil && payload["to"] != nil && payload["timestamp"] != nil)
    }
}
