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
