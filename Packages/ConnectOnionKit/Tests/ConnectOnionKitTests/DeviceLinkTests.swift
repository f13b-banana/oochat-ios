import CryptoKit
import Foundation
import Testing
@testable import ConnectOnionKit

private let start = Date(timeIntervalSince1970: 1_700_000_000)
private let identityKey = Data((0..<32).map { UInt8($0) })
private let identityAddress = "0x03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
private let bothModes: [DeviceLinkRole] = [.giving, .receiving]
private let agentNames = [("0x" + String(repeating: "AB", count: 32), "Scriptbot"), ("0x" + String(repeating: "cd", count: 32), "Helper")]
    .compactMap { DeviceLinkAgentName(address: $0, name: $1) }

/// Counts up from `seed`, so every run draws the same bytes.
private final class FixedRandom: @unchecked Sendable {
    private var next: UInt8
    init(seed: UInt8) { next = seed }
    func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in defer { next &+= 1 }; return next })
    }
}

/// A clock the test moves by hand.
private final class TestClock: @unchecked Sendable {
    var now = start
}

private func giver(offer: DeviceLinkOffer? = nil, clock: TestClock = TestClock()) throws -> DeviceLinkGiver {
    let store = InMemoryPrivateKeyStore(rawKey: identityKey)
    let random = FixedRandom(seed: 100)
    if let offer {
        return try DeviceLinkGiver(scanning: offer, keyStore: store, agentNames: agentNames, now: { clock.now })
    }
    return DeviceLinkGiver(displayingWith: store, agentNames: agentNames, now: { clock.now }, random: { random.bytes($0) })
}

private func receiver(offer: DeviceLinkOffer? = nil, clock: TestClock = TestClock()) throws -> DeviceLinkReceiver {
    let random = FixedRandom(seed: 0)
    if let offer {
        return try DeviceLinkReceiver(scanning: offer, now: { clock.now }, random: { random.bytes($0) })
    }
    return try DeviceLinkReceiver(now: { clock.now }, random: { random.bytes($0) })
}

/// A giver and a receiver for one display mode. The other side scans the QR, or, given `typing`,
/// types what that function makes of the displayed Link Code.
private func pair(
    displayedBy displayer: DeviceLinkRole,
    typing: ((String) -> String)? = nil,
    clock: TestClock = TestClock()
) throws -> (giving: DeviceLinkGiver, receiving: DeviceLinkReceiver) {
    func scan(_ offer: DeviceLinkOffer) throws -> DeviceLinkOffer {
        guard let typing else { return try DeviceLinkOffer(qrPayload: offer.qrPayload) }
        return try DeviceLinkOffer(linkCode: typing(offer.linkCode), displayer: displayer, now: clock.now)
    }
    if displayer == .giving {
        let giving = try giver(clock: clock)
        return (giving, try receiver(offer: try scan(giving.offer), clock: clock))
    }
    let receiving = try receiver(clock: clock)
    return (try giver(offer: try scan(receiving.offer), clock: clock), receiving)
}

/// The giver's reply to the receiver's opening message, with the owner approving.
private func reply(_ giving: DeviceLinkGiver, _ receiving: DeviceLinkReceiver) throws -> Data {
    try giving.seal(for: try giving.verify(try receiving.start()))
}

/// Same service, different secret.
private func wrongSecret(_ code: String) -> String {
    String(code.prefix(2)) + (code.hasSuffix("ZZZZZZZZ") ? "YYYYYYYY" : "ZZZZZZZZ")
}

/// Rewrites one field of a JSON wire message, as a peer or the network could.
private func rewrite(_ message: Data, _ field: String, _ change: (Any) throws -> Any) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: message) as? [String: Any])
    object[field] = try change(try #require(object[field]))
    return try JSONSerialization.data(withJSONObject: object)
}

// MARK: - Offer

@Test func giverOfferRoundTripsAndCarriesNoIdentityMaterial() throws {
    let offer = try giver().offer

    #expect(offer.displayer == .giving)
    #expect(offer.linkCode.count == 10)
    #expect(offer.expiry == start.addingTimeInterval(120))
    #expect(try DeviceLinkOffer(qrPayload: offer.qrPayload) == offer)
    #expect(try offer.qrPayload.contains(Hex.encode(identityKey)) == false)
    #expect(try offer.qrPayload.contains(String(identityAddress.dropFirst(2))) == false)
}

@Test func receiverOfferCarriesItsOneTimeKeyThroughTheQR() throws {
    let offer = try receiver().offer

    #expect(offer.displayer == .receiving)
    #expect(offer.receiverKey?.count == 32)
    #expect(try DeviceLinkOffer(qrPayload: offer.qrPayload) == offer)
}

@Test func aScannedQRUsesTheScanningDevicesClock() throws {
    let offer = try receiver().offer
    // The scanner's clock runs 3 minutes ahead: the displayer's expiry is already past by it.
    let later = start.addingTimeInterval(180)
    let scanned = try DeviceLinkOffer(entered: offer.qrPayload, displayer: .receiving, now: later)

    #expect(scanned.expiry == later.addingTimeInterval(120))
    #expect(scanned.linkCode == offer.linkCode)
    #expect(scanned.receiverKey == offer.receiverKey)
}

@Test func anOfferFromTheVersionBeforeAgentNamesIsRejected() throws {
    let payload = try giver().offer.qrPayload.replacingOccurrences(of: "\"version\":2", with: "\"version\":1")

    #expect(throws: DeviceLinkError.malformed) { try DeviceLinkOffer(qrPayload: payload) }
}

@Test func typedLinkCodeIsForgivingAboutCaseDashesAndLookalikes() throws {
    let offer = try receiver().offer
    let code = offer.linkCode
    #expect(code == "0123456789")
    let typed = (code.prefix(5) + "-" + code.dropFirst(5)).lowercased()
        .replacingOccurrences(of: "0", with: "o")
        .replacingOccurrences(of: "1", with: "l")

    let parsed = try DeviceLinkOffer(linkCode: typed, displayer: .receiving, now: start)
    #expect(parsed.linkCode == code)
    #expect(parsed.serviceName == offer.serviceName)
    #expect(throws: DeviceLinkError.malformed) {
        try DeviceLinkOffer(linkCode: "TOO-SHORT", displayer: .giving, now: start)
    }
}

@Test func linkCodeTagUsesAStretchedSecret() throws {
    // Produced by Python: key = hashlib.pbkdf2_hmac("sha256", b"23456789",
    //   b"oochat-device-link/v2/receiving/oochat-link-01", 100_000, 32), then
    // hmac.new(key, b"oochat-device-link/v2/receiving/0123456789" + bytes([0xAA]) * 32, "sha256").
    // The stretch makes guessing the 8-character secret offline too slow to finish within an offer's life.
    let offer = try receiver().offer
    #expect(offer.linkCode == "0123456789")

    let tag = try offer.tag(for: Data(repeating: 0xAA, count: 32))

    #expect(Hex.encode(tag) == "73b78525f43b6d45060bd30a3876b7f4ce94294aef5a0fcc74d13da1ae820543")
}

// MARK: - Exchange, in both display modes

@Test(arguments: bothModes, [false, true])
func linkEndsWithTheGiversIdentity(displayedBy displayer: DeviceLinkRole, typed: Bool) throws {
    let (giving, receiving) = try pair(displayedBy: displayer, typing: typed ? { $0 } : nil)

    let identity = try receiving.accept(try reply(giving, receiving))

    #expect(identity.address == identityAddress)
    #expect(identity.privateKey == identityKey)
    #expect(identity.agentNames == agentNames)
}

@Test(arguments: bothModes)
func giverRejectsAnExpiredOffer(displayedBy displayer: DeviceLinkRole) throws {
    let clock = TestClock()
    let (giving, receiving) = try pair(displayedBy: displayer, clock: clock)

    clock.now = start.addingTimeInterval(120)
    #expect(throws: DeviceLinkError.expired) { try reply(giving, receiving) }
}

@Test(arguments: bothModes)
func receiverRejectsAnIdentityArrivingAfterItsOfferExpired(displayedBy displayer: DeviceLinkRole) throws {
    let clock = TestClock()
    let (giving, receiving) = try pair(displayedBy: displayer, clock: clock)
    let sealed = try reply(giving, receiving)

    clock.now = start.addingTimeInterval(121)
    #expect(throws: DeviceLinkError.expired) { try receiving.accept(sealed) }
}

@Test(arguments: bothModes)
func wrongLinkCodeSecretIsRejected(displayedBy displayer: DeviceLinkRole) throws {
    let (giving, receiving) = try pair(displayedBy: displayer, typing: wrongSecret)

    #expect(throws: DeviceLinkError.wrongCode) { try reply(giving, receiving) }
}

@Test(arguments: bothModes)
func receiverRejectsAnAddressThatIsNotTheSealedKeys(displayedBy displayer: DeviceLinkRole) throws {
    let (giving, receiving) = try pair(displayedBy: displayer)
    let lying = try rewrite(try reply(giving, receiving), "address") { _ in "0x" + String(repeating: "ab", count: 32) }

    #expect(throws: DeviceLinkError.addressMismatch) { try receiving.accept(lying) }
}

@Test(arguments: bothModes)
func receiverRejectsATamperedCiphertext(displayedBy displayer: DeviceLinkRole) throws {
    let (giving, receiving) = try pair(displayedBy: displayer)
    let tampered = try rewrite(try reply(giving, receiving), "ciphertext") { value in
        let text = try #require(value as? String)
        var bytes = try #require(Data(base64Encoded: text))
        bytes[bytes.startIndex] ^= 0x01
        return bytes.base64EncodedString()
    }

    #expect(throws: DeviceLinkError.tampered) { try receiving.accept(tampered) }
}

@Test(arguments: bothModes)
func cancellingMidExchangeDeliversNoIdentity(displayedBy displayer: DeviceLinkRole) throws {
    let (giving, receiving) = try pair(displayedBy: displayer)
    let sealed = try reply(giving, receiving)

    receiving.cancel()
    #expect(throws: DeviceLinkError.cancelled) { try receiving.accept(sealed) }
}

@Test(arguments: bothModes)
func cancelledGiverSendsNothing(displayedBy displayer: DeviceLinkRole) throws {
    let (giving, receiving) = try pair(displayedBy: displayer)
    let verified = try giving.verify(try receiving.start())

    giving.cancel()
    #expect(throws: DeviceLinkError.cancelled) { try giving.seal(for: verified) }
}

// MARK: - Single use

@Test func giversOfferIsConsumedByTheFirstAttemptEvenAFailedOne() throws {
    let giving = try giver()
    let code = giving.offer.linkCode
    let guesser = try receiver(offer: try DeviceLinkOffer(linkCode: wrongSecret(code), displayer: .giving, now: start))
    let owner = try receiver(offer: try DeviceLinkOffer(linkCode: code, displayer: .giving, now: start))

    #expect(throws: DeviceLinkError.wrongCode) { try giving.verify(try guesser.start()) }
    #expect(throws: DeviceLinkError.reused) { try giving.verify(try owner.start()) }
}

@Test func receiversOfferAndReplyAreSingleUse() throws {
    let (giving, receiving) = try pair(displayedBy: .receiving)
    let sealed = try reply(giving, receiving)

    #expect(throws: DeviceLinkError.reused) { try receiving.start() }
    _ = try receiving.accept(sealed)
    #expect(throws: DeviceLinkError.reused) { try receiving.accept(sealed) }
}

/// A Device Link store that has no key yet, and fails the test if anything asks it to make one.
private final class EmptyKeyStore: DeviceLinkKeyStore, @unchecked Sendable {
    func loadOrCreatePrivateKey() throws -> Data {
        Issue.record("a giver must not create a key to send")
        return Data(repeating: 1, count: 32)
    }
    func loadPrivateKey() throws -> Data? { nil }
    func replacePrivateKey(with rawKey: Data) throws {}
    var isLinked: Bool { false }
    func markLinked() throws {}
}

@Test func aGiverWithNoKeySendsNothing() throws {
    let receiving = try receiver()
    let giving = try DeviceLinkGiver(scanning: receiving.offer, keyStore: EmptyKeyStore(), now: { start })
    let verified = try giving.verify(try receiving.start())
    #expect(throws: DeviceLinkError.noIdentity) { try giving.seal(for: verified) }
    #expect(DeviceLinkFailure(DeviceLinkError.noIdentity) == .other)
}

@Test func giverScanningAQRRejectsAKeyOtherThanTheOneInTheQR() throws {
    let displayed = try receiver()
    let giving = try giver(offer: displayed.offer)
    // Knows the Link Code, so its HMAC is valid, but its one-time key is not the QR's.
    var draws = 0
    let impostor = try DeviceLinkReceiver(now: { start }, random: { count in
        draws += 1
        return draws == 1 ? Data((0..<count).map { UInt8($0) }) : Data(repeating: 0xEE, count: count)
    })
    #expect(impostor.offer.linkCode == displayed.offer.linkCode)

    #expect(throws: DeviceLinkError.wrongCode) { try giving.verify(try impostor.start()) }
}
