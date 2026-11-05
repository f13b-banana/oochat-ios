//
//  OIPSignertests.swift
//  ConnectOnionKit
//
//
import CryptoKit
import Foundation
import Testing
@testable import ConnectOnionKit

// Key bytes 0...31, the same key the macOS suite uses and the host fixture was made with.
private let fixtureKey = Data((0..<32).map { UInt8($0) })
private let fixtureAddress = "0x03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
private let host = "0x" + String(repeating: "ab", count: 32)
// Produced by Python (PyNaCl) over the canonical bytes of `connectPayload`, then accepted by
// the host's verify_signature in connectonion 1.8.10.
private let pythonSignature =
    "8a85a528ab2a04c440c763cdcb5c85c762d74dc9eb7e10ce63a8b52193cd8861"
    + "4eea210b35b03caff13a433e9fbcea8a4c54a52bcbd96f3e6ef8aa2d24afb00e"
private let connectPayload: [String: JSONValue] = [
    "to": .string(host),
    "timestamp": .number(1_700_000_000),
    "nonce": .string("nonce-1"),
    "signed_commands": .number(1)
]

private func signer(
    now: Date = Date(timeIntervalSince1970: 1_700_000_000.9),
    nonce: String = "nonce-1"
) -> OIPSigner {
    OIPSigner(keyStore: InMemoryPrivateKeyStore(rawKey: fixtureKey), now: { now }, nonce: { nonce })
}

private func verifies(_ hexSignature: String, over payload: [String: JSONValue]) throws -> Bool {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: fixtureKey).publicKey
    return key.isValidSignature(try #require(Hex.decode(hexSignature)), for: CanonicalJSON.data(from: payload))
}

@Test func addressMatchesTheHostFixture() throws {
    #expect(try signer().address() == fixtureAddress)
}

@Test func cryptoKitAcceptsThePythonSignature() throws {
    #expect(try verifies(pythonSignature, over: connectPayload))
}

@Test func ourSignatureVerifiesButIsNeverComparedByBytes() throws {
    let ours = try signer().signature(for: connectPayload)
    #expect(try verifies(ours, over: connectPayload))
}

@Test func envelopeCarriesTypePayloadFromSignatureAndTimestamp() throws {
    let frame = try signer().envelope(type: "CONNECT", payload: connectPayload)
    #expect(frame["type"] == .string("CONNECT"))
    #expect(frame["payload"] == .object(connectPayload))
    #expect(frame["from"] == .string(fixtureAddress))
    #expect(frame["timestamp"] == .number(1_700_000_000))
    #expect(try verifies(try #require(frame["signature"]?.stringValue), over: connectPayload))
}

@Test func commandSignsFieldsPlusTypeToTimestampAndNonce() throws {
    let frame = try signer().command(type: "INPUT", fields: ["prompt": .string("hi")], to: host)
    guard case .object(let payload) = frame["payload"] else { Issue.record("no payload"); return }
    #expect(payload["type"] == .string("INPUT"))
    #expect(payload["to"] == .string(host))
    #expect(payload["timestamp"] == .number(1_700_000_000))   // whole seconds, rounded down
    #expect(payload["nonce"] == .string("nonce-1"))
    #expect(payload["prompt"] == .string("hi"))
    #expect(frame["prompt"] == .string("hi"))                  // duplicated at the top level
    #expect(frame["nonce"] == .string("nonce-1"))
    #expect(try verifies(try #require(frame["signature"]?.stringValue), over: payload))
}

@Test func commandRefusesToLetFieldsOverrideSignerOwnedKeys() {
    for key in ["type", "to", "timestamp", "nonce"] {
        #expect(throws: OIPSignerError.reservedField(key)) {
            try signer().command(type: "INPUT", fields: [key: .string("x")], to: host)
        }
    }
}

@Test func fractionalAndOversizedNumbersAreRefused() {
    #expect(throws: OIPSignerError.unsignableNumber("a.b[0]")) {
        try OIPSigner.requireSignable(["a": .object(["b": .array([.number(1.5)])])])
    }
    #expect(throws: OIPSignerError.unsignableNumber("n")) {
        try OIPSigner.requireSignable(["n": .number(9_007_199_254_740_994)])
    }
}

@Test func connectPayloadMatchesTheHostFixture() throws {
    #expect(try signer().connectPayload(to: host) == connectPayload)
}
