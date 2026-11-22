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

@Test func inMemoryStoreStartsUnlinked() {
    #expect(InMemoryPrivateKeyStore().isLinked == false)
}

@Test func replacingTheKeySignsWithTheNewKeyAndMarksTheStoreLinked() throws {
    let store = InMemoryPrivateKeyStore()
    let newKey = Data((0..<32).map { UInt8($0) })

    try store.replacePrivateKey(with: newKey)

    #expect(try OIPSigner(keyStore: store).address() == "0x03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8")
    #expect(store.isLinked)
}

@Test func markingLinkedKeepsTheKey() throws {
    let store = InMemoryPrivateKeyStore()
    let key = try store.loadOrCreatePrivateKey()

    try store.markLinked()

    #expect(store.isLinked)
    #expect(try store.loadOrCreatePrivateKey() == key)
}
