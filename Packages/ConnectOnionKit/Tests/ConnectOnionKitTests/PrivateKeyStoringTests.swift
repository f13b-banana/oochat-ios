import Foundation
import Testing
@testable import ConnectOnionKit
@Test func generatedKeyIsStableAnd32Bytes()  throws {
    let store = InMemoryPrivateKeyStore()
    let first = try store.loadOrCreatePrivateKey()
    #expect(first.count == 32)
    #expect(try store.loadOrCreatePrivateKey() == first)

}
@Test func suppliedKeyIsReturnedUnchanged() throws {
    let key = Data((0..<32).map { UInt8($0) })
    #expect(try InMemoryPrivateKeyStore(rawKey: key).loadOrCreatePrivateKey() == key)
}
