import CryptoKit
import Foundation

/// Builds the `x-co-*` headers a ConnectOnion 1.8.10 host expects on a signed
/// HTTP request (same shape as the host's `sign_http_request`).
public enum SignedRequestHeaders {
    /// - Parameters:
    ///   - path: URL path only, e.g. `/sessions`.
    ///   - query: raw query string, canonicalised here; empty for none.
    ///   - body: the exact bytes sent on the wire.
    ///   - to: the agent's address, which the host checks against its own.
    ///   - key: raw 32-byte Ed25519 private key.
    public static func make(
        method: String,
        path: String,
        query: String = "",
        body: Data = Data(),
        to recipient: String,
        key: Data,
        now: Date = Date(),
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> [String: String] {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key)
        let timestamp = Int(now.timeIntervalSince1970.rounded(.down))
        let signature = try signingKey.signature(for: signedBytes(
            method: method, path: path, query: query, body: body,
            timestamp: timestamp, requestID: requestID, to: recipient
        ))
        return [
            "x-co-from": "0x" + Hex.encode(signingKey.publicKey.rawRepresentation),
            "x-co-signature": Hex.encode(signature),
            "x-co-timestamp": String(timestamp),
            "x-co-to": recipient,
            "x-co-request-id": requestID
        ]
    }

    /// The canonical JSON the host verifies the signature over.
    static func signedBytes(
        method: String, path: String, query: String = "", body: Data = Data(),
        timestamp: Int, requestID: String, to recipient: String
    ) -> Data {
        CanonicalJSON.data(from: [
            "method": .string(method.uppercased()),
            "path": .string(path),
            "query": .string(canonicalQuery(query)),
            "body_sha256": .string(Hex.encode(Data(SHA256.hash(data: body)))),
            "timestamp": .number(Double(timestamp)),
            "request_id": .string(requestID),
            "to": .string(recipient)
        ])
    }

    /// Sorted `key=value` pairs, form-encoded like Python's `urlencode`.
    static func canonicalQuery(_ query: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-~")
        func decode(_ text: Substring) -> String {
            let spaced = text.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        func encode(_ text: String) -> String {
            (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)
                .replacingOccurrences(of: "%20", with: "+")
        }
        var pairs: [(String, String)] = []
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            pairs.append((decode(parts[0]), parts.count > 1 ? decode(parts[1]) : ""))
        }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let encoded: [String] = pairs.map { encode($0.0) + "=" + encode($0.1) }
        return encoded.joined(separator: "&")
    }
}
