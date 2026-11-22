import CryptoKit
import Foundation
import Testing
@testable import ConnectOnionKit

private let key = Data((0..<32).map { UInt8($0) })
private let agent = "0x" + String(repeating: "ab", count: 32)
private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// Vectors produced by ConnectOnion 1.8.9 `sign_http_request` with the same key, clock and request id.
/// CryptoKit Ed25519 signatures are randomised, so instead of comparing signature bytes we check that
/// ConnectOnion's signature verifies over our signed bytes, and that ours verifies too.
@Suite struct SignedRequestHeadersTests {
    private func check(path: String, vector: String) throws {
        let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: key).publicKey
        let headers = try SignedRequestHeaders.make(
            method: "get", path: path, to: agent, key: key, now: fixedNow, requestID: "req-fixed-1"
        )
        let bytes = SignedRequestHeaders.signedBytes(
            method: "GET", path: path, timestamp: 1_700_000_000, requestID: "req-fixed-1", to: agent
        )
        #expect(headers["x-co-from"] == "0x03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8")
        #expect(headers["x-co-timestamp"] == "1700000000")
        #expect(headers["x-co-to"] == agent)
        #expect(headers["x-co-request-id"] == "req-fixed-1")
        let vectorSignature = try #require(Hex.decode(vector))
        let ourSignature = try #require(headers["x-co-signature"].flatMap(Hex.decode))
        #expect(pub.isValidSignature(vectorSignature, for: bytes))
        #expect(pub.isValidSignature(ourSignature, for: bytes))
    }

    @Test func listMatchesConnectOnionSigner() throws {
        try check(
            path: "/sessions",
            vector: "386914f900d032f81e6b44682ef8e54284ba076eac2b4a0b5cc78e36ba78c8c5"
                + "59d748a61112ef86ae6d21b9b6359324d60a999457b34390e24c9f421c8f6c0b"
        )
    }

    @Test func singleSessionMatchesConnectOnionSigner() throws {
        try check(
            path: "/sessions/abc-123",
            vector: "f08036994a7fad05703f1085c1eed22addbcbd408c12d62a680ee0b230f6d834"
                + "f7bcc066674d2d9a0afffffe87125b69c40b6c72ea8e48c283d4e236d24e1f0d"
        )
    }

    @Test func queryIsCanonicalised() {
        #expect(SignedRequestHeaders.canonicalQuery("b=2&a=1&a=0&c=x y") == "a=0&a=1&b=2&c=x+y")
        #expect(SignedRequestHeaders.canonicalQuery("").isEmpty)
    }
}
