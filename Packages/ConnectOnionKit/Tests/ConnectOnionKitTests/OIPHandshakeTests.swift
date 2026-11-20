//
//  OIPHandshakeTests.swift
//  ConnectOnionKit
//

import Foundation
import Testing
@testable import ConnectOnionKit

private func fixture(_ name: String, folder: String = "handshake") throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/\(folder)")
    )
    return try Data(contentsOf: url)
}

private func step(_ name: String, appVersion: String? = OIP.version) throws -> OIPHandshake.Step {
    try OIPHandshake.interpret(fixture(name), appVersion: appVersion)
}

private func text(_ json: String, appVersion: String? = OIP.version) throws -> OIPHandshake.Step {
    try OIPHandshake.interpret(Data(json.utf8), appVersion: appVersion)
}

private func established(_ name: String) throws -> OIPConnected {
    guard case .established(let value) = try step(name) else {
        Issue.record("\(name) was not .established")
        throw OIPHandshake.Failure.malformed(frame: name)
    }
    return value
}

private func incompatibility(_ name: String, appVersion: String? = OIP.version) throws -> OIPHandshake.Incompatibility {
    guard case .incompatible(let value) = try step(name, appVersion: appVersion) else {
        Issue.record("\(name) was not .incompatible")
        throw OIPHandshake.Failure.malformed(frame: name)
    }
    return value
}

// The fixtures in Fixtures/handshake were captured from the real host (connectonion 1.8.9) by
// verify_connect.py; the one marked no_descriptor is written by hand. Fixtures/frames is the shared
// set that OIPServerFramesTests also reads.

// MARK: One reader

// OIPHandshake reads no fields of its own: what it hands back is exactly what OIPServerFrame decoded.
@Test func theHandshakeReturnsWhatTheDecoderDecoded() throws {
    for name in ["CONNECTED.new", "CONNECTED.running", "CONNECTED.resumed_server_newer"] {
        let data = try fixture(name)
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data),
              case .connected(let decoded) = OIPServerFrame.decode(fields) else {
            Issue.record("\(name) did not decode as CONNECTED")
            continue
        }
        #expect(try OIPHandshake.interpret(data) == .established(decoded))
    }
    let required = try fixture("ONBOARD_REQUIRED", folder: "frames")
    guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: required),
          case .onboardRequired(let decoded) = OIPServerFrame.decode(fields) else {
        Issue.record("ONBOARD_REQUIRED did not decode")
        return
    }
    #expect(try OIPHandshake.interpret(required) == .onboardRequired(decoded))
}

// MARK: CONNECTED statuses

@Test func connectedNewIsEstablishedWithTheHostDescriptor() throws {
    let value = try established("CONNECTED.new")
    #expect(value.status == "new")
    #expect(value.isRunning == false)
    #expect(value.serverNewer == false)
    #expect(value.session == nil)
    #expect(value.chatItems == nil)
    #expect(value.hostProtocol?.name == "oip")
    #expect(value.hostProtocol?.version == "0.1")
    #expect(value.hostProtocol?.maxVersion == "0.1")
}

@Test func connectedRunningIsMarkedRunning() throws {
    let value = try established("CONNECTED.running")
    #expect(value.status == "running")
    #expect(value.isRunning)
    #expect(value.sessionID == "11111111-2222-3333-4444-555555555555")
}

@Test func connectedServerNewerCarriesTheSessionAndChatItems() throws {
    let value = try established("CONNECTED.resumed_server_newer")
    #expect(value.serverNewer)
    #expect(value.session != nil)
    #expect(value.chatItems?.count == 2)
    #expect(value.replacesSession(asked: "11111111-2222-3333-4444-555555555555") == false)
    #expect(value.replacesSession(asked: "another-session"))
    #expect(value.replacesSession(asked: nil) == false)
}

@Test func connectedToleratesAMissingDescriptorAndAnUnknownStatus() throws {
    guard case .established(let value) = try text(#"{"type":"CONNECTED","status":"ready","session_id":"s-1"}"#) else {
        Issue.record("expected .established")
        return
    }
    #expect(value.status == "ready")
    #expect(value.isRunning == false)
    #expect(value.hostProtocol == nil)
    #expect(value.sessionModes == nil)
}

@Test func connectedWithoutASessionIDIsEstablishedAndNeverReplacesTheSession() throws {
    guard case .established(let value) = try text(#"{"type":"CONNECTED","status":"new"}"#) else {
        Issue.record("expected .established")
        return
    }
    #expect(value.sessionID == nil)
    #expect(value.replacesSession(asked: "s-1") == false)
}

@Test func connectedKeepsSessionModesFromTheSharedFixture() throws {
    guard case .established(let value) = try OIPHandshake.interpret(fixture("CONNECTED", folder: "frames")) else {
        Issue.record("expected .established")
        return
    }
    #expect(value.sessionModes != nil)
    #expect(value.serverNewer)
}

@Test func connectedWithoutAStatusIsMalformed() {
    #expect(throws: OIPHandshake.Failure.malformed(frame: "CONNECTED")) {
        try text(#"{"type":"CONNECTED","session_id":"s-1"}"#)
    }
}

@Test func connectedIndexIsRejectedBecauseNoAppAsksForIt() throws {
    let result = try text(#"{"type":"CONNECTED","status":"index","protocol":{"name":"oip","version":"0.1"}}"#)
    guard case .rejected(let message) = result else {
        Issue.record("expected .rejected")
        return
    }
    #expect(message.contains("session index"))
}

// The fixture was captured by sending the real host a CONNECT that declared 0.2. The host speaks 0.1.
@Test func incompatibleVersionStopsAndNamesTheHostVersion() throws {
    let value = try incompatibility("ERROR.incompatible_version", appVersion: "0.2")
    #expect(value.neededVersion == "0.1")
    #expect(value.appVersion == "0.2")
    #expect(value.direction == .agentTooOld)
    #expect(value.isRetryable == false)
    #expect(value.message == "This agent speaks OIP 0.1. This app speaks OIP 0.2. Ask the agent's owner to update it.")
}

@Test func incompatibleVersionUsesTheAppsOwnVersionByDefault() throws {
    #expect(try incompatibility("ERROR.incompatible_version").appVersion == OIP.version)
}

@Test func incompatibleVersionWithoutADescriptorStillStops() throws {
    let value = try incompatibility("ERROR.incompatible_version.no_descriptor")
    #expect(value.neededVersion == nil)
    #expect(value.direction == .unknown)
    #expect(value.message.contains("does not support"))
}

@Test func incompatibleVersionSaysWhichSideHasToUpdate() {
    let newer = OIPHandshake.Incompatibility(neededVersion: "0.2", appVersion: "0.1")
    #expect(newer.direction == .appTooOld)
    #expect(newer.message == "This agent needs OIP 0.2. This app speaks OIP 0.1. Update the app to connect.")

    let older = OIPHandshake.Incompatibility(neededVersion: "0.1", appVersion: "0.2")
    #expect(older.direction == .agentTooOld)
    #expect(older.message.contains("Ask the agent's owner to update it."))

    #expect(OIPHandshake.Incompatibility(neededVersion: "0.10", appVersion: "0.9").direction == .appTooOld)
}

@Test func nonNumericVersionsDoNotCompare() {
    let value = OIPHandshake.Incompatibility(neededVersion: "next", appVersion: "0.1")
    #expect(value.direction == .unknown)
    #expect(value.neededVersion == "next")
}

@Test func theSharedIncompatibleFixtureIsReadTheSameWay() throws {
    guard case .incompatible(let value) = try OIPHandshake.interpret(
        fixture("ERROR.incompatible_version", folder: "frames"),
        appVersion: "0.2"
    ) else {
        Issue.record("expected .incompatible")
        return
    }
    #expect(value.neededVersion == "0.1")
}

// MARK: Other ERRORs

@Test func hostAuthenticationErrorsAreRejectedWithTheirMessage() throws {
    let cases = [
        ("ERROR.wrong_recipient", "unauthorized: wrong recipient"),
        ("ERROR.replayed", "unauthorized: this CONNECT was already used"),
        ("ERROR.expired", "unauthorized: signature expired")
    ]
    for (name, message) in cases {
        #expect(try step(name) == .rejected(message: message))
    }
}

@Test func errorWithoutAMessageFallsBackToErrorThenReasonThenADefault() throws {
    #expect(try text(#"{"type":"ERROR","error":"Still waiting"}"#) == .rejected(message: "Still waiting"))
    #expect(try text(#"{"type":"ERROR","reason":"closed"}"#) == .rejected(message: "closed"))
    #expect(try text(#"{"type":"ERROR"}"#) == .rejected(message: "Authentication failed"))
}

@Test func aStringCodeIsNeverTreatedAsIncompatible() throws {
    #expect(try text(#"{"type":"ERROR","code":"-32010","message":"odd"}"#) == .rejected(message: "odd"))
}

// MARK: Everything else in the handshake

@Test func pingGetsAPong() throws {
    #expect(try text(#"{"type":"PING"}"#) == .reply(OIPClientFrames.pong()))
}

@Test func onboardingFramesAreReported() throws {
    let required = #"""
    {"type":"ONBOARD_REQUIRED","identity":"0xabc","methods":["invite_code","payment"],\#
    "payment_amount":4.5,"payment_address":"0xpay"}
    """#
    guard case .onboardRequired(let value) = try text(required) else {
        Issue.record("expected .onboardRequired")
        return
    }
    #expect(value.identity == "0xabc")
    #expect(value.methods == ["invite_code", "payment"])
    #expect(value.paymentAmount == 4.5)
    #expect(value.paymentAddress == "0xpay")

    #expect(try text(#"{"type":"ONBOARD_SUCCESS","message":"Welcome"}"#) == .onboardSucceeded(message: "Welcome"))
    #expect(try text(#"{"type":"ONBOARD_SUCCESS"}"#) == .onboardSucceeded(message: nil))
}

@Test func onboardRequiredWithoutMethodsHasNone() throws {
    guard case .onboardRequired(let value) = try text(#"{"type":"ONBOARD_REQUIRED"}"#) else {
        Issue.record("expected .onboardRequired")
        return
    }
    #expect(value.methods.isEmpty)
}

@Test func sharedFramesFixturesAreReadTheSameWay() throws {
    #expect(try OIPHandshake.interpret(fixture("PING", folder: "frames")) == .reply(OIPClientFrames.pong()))
    if case .onboardSucceeded = try OIPHandshake.interpret(fixture("ONBOARD_SUCCESS", folder: "frames")) {
    } else {
        Issue.record("ONBOARD_SUCCESS fixture was not .onboardSucceeded")
    }
}

@Test func otherFramesAndUntypedObjectsAreIgnored() throws {
    #expect(try text(#"{"type":"ignored"}"#) == .ignore)
    #expect(try text(#"{"type":"OUTPUT"}"#) == .ignore)
    #expect(try text(#"{"no":"type"}"#) == .ignore)
}

@Test func aFrameThatIsNotAnObjectThrows() {
    #expect(throws: OIPHandshake.Failure.notAnObject) {
        try OIPHandshake.interpret(Data("[1,2]".utf8))
    }
}
