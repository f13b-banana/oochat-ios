import CryptoKit
import Foundation

/// Where the app stores its Ed25519 private key.
/// Pkg nevber touches keychain/disk, each app conforms its own store to this
public protocol PrivateKeyStoring: Sendable {
    // RaW 32B Ed25519 private key. Creates and Persists one on first use
    func loadOrCreatePrivateKey() throws -> Data
}

/// A key store a Device Link can write to. Each app's store keeps its storage class
/// (iOS Keychain item, macOS 0600 file) and keeps the linked flag beside the key.
public protocol DeviceLinkKeyStore: PrivateKeyStoring {
    /// The saved key, or nil if this device has none yet. Never creates one.
    func loadPrivateKey() throws -> Data?

    /// Receiving Device: atomically writes `rawKey` and clears any cached key so the next
    /// signature uses it. Then sets the linked flag if it can: the key change is what matters,
    /// and a flag that fails to write only reads as unlinked.
    func replacePrivateKey(with rawKey: Data) throws

    /// The per-device linked flag. False by default, and true only while the key it was set
    /// beside exists: a freshly created key starts unlinked.
    var isLinked: Bool { get }

    /// Giving Device: sets the linked flag after a successful send.
    func markLinked() throws
}

/// for tests:
public final class InMemoryPrivateKeyStore: DeviceLinkKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data
    private var linked = false

    public init(rawKey: Data) { key = rawKey }
    public init() { key = Curve25519.Signing.PrivateKey().rawRepresentation }

    public func loadOrCreatePrivateKey() throws -> Data { lock.withLock { key } }

    public func loadPrivateKey() throws -> Data? { lock.withLock { key } }

    public func replacePrivateKey(with rawKey: Data) throws {
        lock.withLock {
            key = rawKey
            linked = true
        }
    }

    public var isLinked: Bool { lock.withLock { linked } }

    public func markLinked() throws {
        lock.withLock { linked = true }
    }
}
