//
//  OIPSigner.swift
//  ConnectOnionKit
//
//

import CryptoKit
import Foundation

public enum OIPSignerError: Error, Equatable {
    /// Signer owns type/to/timestamp/nonce, not the command
    case reservedField(String)
    case unsignableNumber(String)
}

/// Builds and signs OIP Frames. It holds no key, app supplies one
/// PrivateKeyStoring, and clock and nonce are injected

public struct OIPSigner: Sendable {
    private let keyStore: any PrivateKeyStoring
    private let now: @Sendable() -> Date
    private let nonce: @Sendable() -> String

    /// Sets up signer with app's key store + clock and nonce generator
    public init(
        keyStore: any PrivateKeyStoring,
        now: @escaping @Sendable () -> Date = { Date() },
        nonce: @escaping @Sendable () -> String = { UUID().uuidString.lowercased()}
    ) {
        self.keyStore = keyStore
        self.now = now
        self.nonce = nonce
    }

    /// Returns this devices identity: "0x" followed by the 64 hex characters of the public key
    public func address() throws -> String {
        "0x" + Hex.encode(try privateKey().publicKey.rawRepresentation)
    }

    /// Signs a payload by turning it into canonical JSON and returns Ed25519 signature as hex
    public func signature(for payload: [String: JSONValue]) throws -> String {
        try Self.requireSignable(payload)
        let bytes = try privateKey().signature(for: CanonicalJSON.data(from: payload))
        return Hex.encode(bytes)
    }

    /// builds part of CONNECT that gets signed
    /// Signed part for CONNECT: recipient, whole-second timestamp, a fresh nonce, and
    /// 'signed_commands: 1'  which switches the host's per-command signature check on.
    public func connectPayload(to recipient: String) -> [String: JSONValue] {
        [
            "to": .string(recipient),
            "timestamp": .number(now().timeIntervalSince1970.rounded(.down)),
            "nonce": .string(nonce()),
            "signed_commands": .number(1)
        ]
    }

    /// Wraps payload into complete signed frame.
    /// v1 signs 'payload' exactly as given. Used by Connect and ONBOARD_SUBMIT.
    public func envelope(type: String, payload: [String: JSONValue]) throws -> [String: JSONValue] {
        var frame: [String: JSONValue] = [
            "type": .string(type),
            "payload": .object(payload),
            "from": .string(try address()),
            "signature": .string(try signature(for: payload))
        ]
        if let timestamp = payload["timestamp"] {
            frame["timestamp"] = timestamp
        }

        return frame
    }

    /// Builds a complete signed frame for any non-CONNECT msg.
    /// v2: the signed payload is 'fields', type, to, timestamp (whole seconds) and nonce.
    /// Every Field is also copied to top level for pre-v2 hosts, which is what reference client does
    /// A v2 host discards those copies and runs the signed payload
    public func command(
        type: String,
        fields: [String: JSONValue],
        to recipient: String
    ) throws -> [String: JSONValue] {
        for key in ["type", "to", "timestamp", "nonce"] where fields[key] != nil {
            throw OIPSignerError.reservedField(key)
        }
        var payload = fields
        payload["type"] = .string(type)
        payload["to"] = .string(recipient)
        payload["timestamp"] = .number(now().timeIntervalSince1970.rounded(.down))
        payload["nonce"] = .string(nonce())

        var frame = payload
        frame["payload"] = .object(payload)
        frame["from"] = .string(try address())
        frame["signature"] = .string(try signature(for: payload))
        return frame
    }

    /// Rejects nums that are fractional or larger than 2^53 anywhere in the payload
    public static func requireSignable(_ payload: [String: JSONValue]) throws {
        for (key, value) in payload {
            try check(value, at: key)
        }
    }

    private static func check(_ value: JSONValue, at path: String) throws {
        switch value {
        case .number(let number):
            guard number.isFinite, number == number.rounded(.towardZero), abs(number) <= 9_007_199_254_740_992 else {
                throw OIPSignerError.unsignableNumber(path)
            }
        case .object(let object):
            for (key, inner) in object { try check(inner, at: "\(path).\(key)")}
        case .array(let array):
            for (index, inner) in array.enumerated() { try check(inner, at: "\(path)[\(index)]") }
        case .string, .bool, .null:
            break
        }
    }

    /// Loads raw 32-byte key from keystore and turns it into a CryptoKit signing key.
    private func privateKey() throws -> Curve25519.Signing.PrivateKey {
    try Curve25519.Signing.PrivateKey(rawRepresentation: keyStore.loadOrCreatePrivateKey())
    }
}
