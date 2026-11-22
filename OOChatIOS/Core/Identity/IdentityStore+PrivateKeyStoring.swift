import ConnectOnionKit
import Foundation

extension IdentityStore: DeviceLinkKeyStore {
    func loadOrCreatePrivateKey() throws -> Data {
        try loadOrCreateSigningKey().rawRepresentation
    }

    func loadPrivateKey() throws -> Data? {
        try storedPrivateKey()
    }
}
