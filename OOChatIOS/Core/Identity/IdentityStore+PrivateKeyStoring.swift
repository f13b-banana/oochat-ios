import ConnectOnionKit
import Foundation

extension IdentityStore: PrivateKeyStoring {
    func loadOrCreatePrivateKey() throws -> Data {
        try loadOrCreateSigningKey().rawRepresentation
    }
}
