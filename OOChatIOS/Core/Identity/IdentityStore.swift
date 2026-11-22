import CryptoKit
import Foundation
import Security
import ConnectOnionKit

enum IdentityStoreError: LocalizedError {
    case invalidStoredKey
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredKey:
            return "This device's saved identity key is unreadable, so the app can't sign messages."
        case .keychain(let status):
            // refine error message
            return "Couldn't load this device's identity from the Keychain (\(Self.keychainDetail(status))). "
                + "If you're running in the Simulator without code signing, this is expected."
        }
    }

    private static func keychainDetail(_ status: OSStatus) -> String {
        let code = "OSStatus \(status)"
        guard let message = SecCopyErrorMessageString(status, nil) as String?,
              !message.hasPrefix("OSStatus") else {
            return code
        }
        return "\(code): \(message)"
    }
}

final class IdentityStore: Sendable {
    private let service: String
    private let account = "default"
    /// The linked flag, a Keychain item beside the key. It holds the public key it was set for, so it
    /// goes with that key: a lost key's replacement reads as unlinked.
    private let linkedAccount = "linked"

    /// `service` is the Keychain service both items live under; tests pass one of their own.
    init(service: String = "connectonion.native-ios.identity.ed25519") {
        self.service = service
    }

    /// When this device first held its current key. Shared by every store, as the key's Keychain item is.
    static let createdAtKey = "connectonion.native-ios.identity.createdAt"

    func loadOrCreateIdentity() throws -> StoredIdentity {
        let key: Curve25519.Signing.PrivateKey = try loadOrCreateSigningKey()
        let publicKeyHex = Hex.encode(key.publicKey.rawRepresentation)
        let createdAt: Date
        if let stored = UserDefaults.standard.object(forKey: Self.createdAtKey) as? Date {
            createdAt = stored
        } else {
            createdAt = Date()
            UserDefaults.standard.set(createdAt, forKey: Self.createdAtKey)
        }
        return StoredIdentity(address: "0x\(publicKeyHex)", publicKeyHex: publicKeyHex, createdAt: createdAt)
    }

    func loadOrCreateSigningKey() throws -> Curve25519.Signing.PrivateKey {
        if let data = try readPrivateKeyData() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        switch try writePrivateKeyData(key.rawRepresentation) {
        case .stored:
            return key
        case .adoptedExisting(let data):
            // Another caller won the race and already stored a key. Adopt theirs rather than
            // overwriting it — the device address is derived from this key, and changing it
            // invalidates every peer's trust entry for this device.
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
    }

    /// Receiving Device: swaps the key in one Keychain update, so a reader sees the old key or the new
    /// one, never neither. Nothing caches the key, so the next signature uses it. Then restarts
    /// `createdAt`, which described the old key, and sets the flag.
    func replacePrivateKey(with rawKey: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        try upsert(key.rawRepresentation, account: account)
        UserDefaults.standard.set(Date(), forKey: Self.createdAtKey)
        // The key change is what matters; a flag that can't be written only reads as unlinked.
        try? upsert(key.publicKey.rawRepresentation, account: linkedAccount)
    }

    var isLinked: Bool {
        guard let keyData = try? readItem(account: account),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData),
              let flag = try? readItem(account: linkedAccount) else {
            return false
        }
        return flag == key.publicKey.rawRepresentation
    }

    /// Giving Device: after a successful send.
    func markLinked() throws {
        guard let data = try readPrivateKeyData() else { throw IdentityStoreError.invalidStoredKey }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        try upsert(key.publicKey.rawRepresentation, account: linkedAccount)
    }

    /// The saved key, or nil if there is none yet. Never creates one.
    func storedPrivateKey() throws -> Data? {
        try readPrivateKeyData()
    }

    private enum KeyWriteResult {
        case stored
        case adoptedExisting(Data)
    }

    private func readPrivateKeyData() throws -> Data? {
        try readItem(account: account)
    }

    private func readItem(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw IdentityStoreError.invalidStoredKey
        }
        return data
    }

    /// Adds `data` without clobbering an existing entry, reporting whether this caller's key
    /// won the race or an existing one has to be adopted.
    private func writePrivateKeyData(_ data: Data) throws -> KeyWriteResult {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try readPrivateKeyData() else {
                throw IdentityStoreError.keychain(status)
            }
            return .adoptedExisting(existing)
        }
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status)
        }
        return .stored
    }

    /// Overwrites the item in place, or adds it, keeping the after-first-unlock, this-device-only class.
    private func upsert(_ data: Data, account: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw IdentityStoreError.keychain(status)
        }
    }
}
