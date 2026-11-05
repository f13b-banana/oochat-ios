import CryptoKit
import Foundation

/// Where the app stores its Ed25519 private key.
/// Pkg nevber touches keychain/disk, each app conforms its own store to this
public protocol PrivateKeyStoring: Sendable {
    // RaW 32B Ed25519 private key. Creates and Persists one on first use
    func loadOrCreatePrivateKey() throws -> Data
}

/// for tests:
public struct InMemoryPrivateKeyStore: PrivateKeyStoring {
    private let key: Data

    public init(rawKey: Data) { key = rawKey }
    public init() {key = Curve25519.Signing.PrivateKey().rawRepresentation }
    public func loadOrCreatePrivateKey() throws -> Data {key}

}
