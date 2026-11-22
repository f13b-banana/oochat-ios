import ConnectOnionKit
import CryptoKit
import Security
import XCTest
@testable import OOChatIOS

/// Runs against the real Keychain, under a service of its own so the app's identity is never touched.
final class IdentityStoreTests: XCTestCase {
    private var service = ""
    private var store: IdentityStore!

    override func setUp() {
        service = "identity-store-tests.\(UUID().uuidString)"
        store = IdentityStore(service: service)
    }

    override func tearDown() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    func testReplaceChangesTheAddressAndSignaturesVerifyUnderTheNewKey() throws {
        let before = try OIPSigner(keyStore: store).address()
        let incoming = Curve25519.Signing.PrivateKey()

        try store.replacePrivateKey(with: incoming.rawRepresentation)

        let signer = OIPSigner(keyStore: store)
        XCTAssertNotEqual(try signer.address(), before)
        XCTAssertEqual(try signer.address(), "0x" + Hex.encode(incoming.publicKey.rawRepresentation))
        let payload: [String: JSONValue] = ["type": .string("INPUT"), "prompt": .string("hi")]
        let signature = try XCTUnwrap(Hex.decode(try signer.signature(for: payload)))
        XCTAssertTrue(incoming.publicKey.isValidSignature(signature, for: CanonicalJSON.data(from: payload)))
        XCTAssertEqual(try store.loadOrCreateIdentity().address, try signer.address())
    }

    func testReplaceRefusesSomethingThatIsNotAnEd25519Key() throws {
        let before = try store.loadOrCreatePrivateKey()

        XCTAssertThrowsError(try store.replacePrivateKey(with: Data([1, 2, 3])))

        XCTAssertEqual(try store.loadOrCreatePrivateKey(), before)
        XCTAssertFalse(store.isLinked)
    }

    func testLinkedFlagIsFalseOnAFreshStore() throws {
        _ = try store.loadOrCreatePrivateKey()

        XCTAssertFalse(store.isLinked)
    }

    func testLinkedFlagIsSetByReplace() throws {
        try store.replacePrivateKey(with: Curve25519.Signing.PrivateKey().rawRepresentation)

        XCTAssertTrue(store.isLinked)
        XCTAssertTrue(IdentityStore(service: service).isLinked, "the flag is stored, not held in memory")
    }

    func testLinkedFlagIsSetAfterASuccessfulSend() throws {
        let key = try store.loadOrCreatePrivateKey()

        try store.markLinked()

        XCTAssertTrue(store.isLinked)
        XCTAssertEqual(try store.loadOrCreatePrivateKey(), key)
    }

    func testReplaceRestartsTheIdentityDate() throws {
        let key = IdentityStore.createdAtKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let old = Date(timeIntervalSince1970: 1_000)
        UserDefaults.standard.set(old, forKey: key)

        try store.replacePrivateKey(with: Curve25519.Signing.PrivateKey().rawRepresentation)

        XCTAssertGreaterThan(try store.loadOrCreateIdentity().createdAt, old)
    }

    /// A Giving Device with no key must not make one up to send or to mark linked.
    func testAStoreWithNoKeyGivesNothingAndCreatesNothing() throws {
        XCTAssertNil(try store.loadPrivateKey())
        XCTAssertThrowsError(try store.markLinked())
        XCTAssertNil(try store.loadPrivateKey(), "nothing was created")
    }

    /// The giver shows its code and a receiver types it; the link runs in memory, so no socket opens.
    @MainActor
    func testAGiverThatShowsItsCodeIsLinkedAfterItSends() async throws {
        let address = try store.loadOrCreateIdentity().address
        let flow = DeviceLinkFlow(role: .giving, keyStore: store, displaysCode: true, ownerCheck: { true }, give: { giver, approve in
            let typed = try DeviceLinkOffer(linkCode: giver.offer.linkCode, displayer: .giving, now: Date())
            let receiver = try DeviceLinkReceiver(scanning: typed)
            let verified = try giver.verify(try receiver.start())
            guard await approve() else { throw DeviceLinkError.cancelled }
            _ = try receiver.accept(try giver.seal(for: verified))
        })

        flow.start()
        try await waitFor { flow.step == .confirmingSend }
        XCTAssertFalse(store.isLinked)
        flow.confirm()
        try await waitFor { flow.step == .done(address: address) }

        XCTAssertTrue(IdentityStore(service: service).isLinked)
        XCTAssertEqual(try store.loadOrCreateIdentity().address, address, "the giver keeps its key")
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition())
    }

    func testLinkedFlagGoesWithTheKey() throws {
        _ = try store.loadOrCreatePrivateKey()
        try store.markLinked()

        // The key is lost (for example a restore without this device's Keychain) and a fresh one is made.
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default"
        ] as CFDictionary)
        _ = try store.loadOrCreatePrivateKey()

        XCTAssertFalse(store.isLinked)
    }
}
