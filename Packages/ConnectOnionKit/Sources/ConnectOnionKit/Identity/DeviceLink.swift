import CommonCrypto
import CryptoKit
import Foundation

/// The two sides of a Device Link. Either side may display the offer; the other scans or types it.
public enum DeviceLinkRole: String, Codable, Sendable {
    case giving
    case receiving

    /// The other device's role in the same link.
    var counterpart: DeviceLinkRole { self == .giving ? .receiving : .giving }
}

public enum DeviceLinkError: Error, Equatable, Sendable {
    case malformed
    case expired
    case reused
    case wrongCode
    case addressMismatch
    case tampered
    case cancelled
    /// The Giving Device has no saved key to send.
    case noIdentity
}

/// What the QR and the Link Code carry. Never any Identity material: the receiver's key
/// here is a one-time X25519 key, thrown away after the link.
public struct DeviceLinkOffer: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 120
    /// 2 added the Agent Name list to the sealed payload. Older offers are refused.
    static let currentVersion = 2

    public let version: Int
    public let displayer: DeviceLinkRole
    /// 10 Crockford base32 characters: the first 2 name the Bonjour service, the last 8 are the one-time secret.
    public let linkCode: String
    /// The Receiving Device's one-time public key, present only in a QR the receiver displays.
    public let receiverKey: Data?
    public let expiry: Date

    /// The Bonjour service instance the displaying device advertises.
    public var serviceName: String { "oochat-link-" + linkCode.prefix(2) }

    public var qrPayload: String {
        get throws {
            guard let text = String(data: try Self.encoder.encode(self), encoding: .utf8) else { throw DeviceLinkError.malformed }
            return text
        }
    }

    /// The default randomness for offers and one-time keys.
    public static func systemRandom(_ count: Int) -> Data {
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    public init(qrPayload: String) throws {
        guard let offer = try? JSONDecoder.deviceLink.decode(Self.self, from: Data(qrPayload.utf8)),
              offer.version == Self.currentVersion,
              offer.linkCode == (try? Self.normalize(offer.linkCode)),
              offer.receiverKey == nil || offer.displayer == .receiving
        else { throw DeviceLinkError.malformed }
        self = offer
    }

    /// A typed Link Code. It carries no expiry, so the typing side gives itself the full lifetime from now;
    /// the displaying side still enforces its own.
    public init(linkCode: String, displayer: DeviceLinkRole, now: Date) throws {
        self.init(displayer: displayer, linkCode: try Self.normalize(linkCode), receiverKey: nil, now: now)
    }

    /// What the person entered: a scanned QR payload, or a typed Link Code. A scanned QR's expiry is the
    /// other device's clock, so like a typed code it gets the full lifetime from this device's now; the
    /// displaying side still enforces its own.
    public init(entered: String, displayer: DeviceLinkRole, now: Date) throws {
        let entered = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entered.hasPrefix("{") else {
            self = try DeviceLinkOffer(linkCode: entered, displayer: displayer, now: now)
            return
        }
        let scanned = try DeviceLinkOffer(qrPayload: entered)
        self.init(displayer: scanned.displayer, linkCode: scanned.linkCode, receiverKey: scanned.receiverKey, now: now)
    }

    init(displayer: DeviceLinkRole, linkCode: String, receiverKey: Data?, now: Date) {
        version = Self.currentVersion
        self.displayer = displayer
        self.linkCode = linkCode
        self.receiverKey = receiverKey
        expiry = now.addingTimeInterval(Self.lifetime)
    }

    static func generateCode(random: (Int) -> Data) -> String {
        // 256 is a multiple of 32, so `% 32` draws every character equally often.
        String(random(10).map { alphabet[Int($0) % 32] })
    }

    /// Crockford base32: no I, L, O or U, and the lookalikes a person might type map back.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static func normalize(_ typed: String) throws -> String {
        let code = String(typed.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", " ": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return character
            }
        })
        guard code.count == 10, code.allSatisfy(alphabet.contains) else { throw DeviceLinkError.malformed }
        return code
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    fileprivate static let deviceLink: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// The Identity a link delivered, already checked. The app replaces its key with `privateKey`, then applies
/// the Giving Device's `agentNames`.
public struct DeviceLinkIdentity: Equatable, Sendable {
    public let privateKey: Data
    public let address: String
    public let agentNames: [DeviceLinkAgentName]
}

/// The exchange runs on one connection, whoever displayed: receiver → giver `KeyMessage`, then
/// giver → receiver `SealedMessage` (or a wrong-code notice), then the receiver's `accepted`.
private struct KeyMessage: Codable {
    let key: Data
    /// HMAC of the binding and `key` under the Link Code secret, so a typed code authenticates the key.
    let tag: Data
}

private struct SealedMessage: Codable {
    let encapsulatedKey: Data
    let ciphertext: Data
    let address: String
}

/// What `SealedMessage.ciphertext` opens to.
private struct SealedPayload: Codable {
    let privateKey: Data
    let agentNames: [DeviceLinkAgentName]
}

private let hpkeSuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
private let hpkeInfo = Data("oochat device link".utf8)

extension DeviceLinkOffer {
    /// Ties the exchange to this offer: HPKE associated data and the HMAC's prefix.
    fileprivate var binding: Data {
        Data("oochat-device-link/v\(version)/\(displayer.rawValue)/\(linkCode)".utf8)
    }

    /// HMAC of the binding and `key`, under the Link Code secret stretched with PBKDF2. The secret is only
    /// about 40 bits, so the stretch is what keeps an offline guess from finishing inside an offer's life.
    func tag(for key: Data) throws -> Data {
        let secret = SymmetricKey(data: try stretchedSecret())
        return Data(HMAC<SHA256>.authenticationCode(for: binding + key, using: secret))
    }

    /// Checks a tag from `tag(for:)` in constant time.
    func isValidTag(_ tag: Data, for key: Data) throws -> Bool {
        let secret = SymmetricKey(data: try stretchedSecret())
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: binding + key, using: secret)
    }

    private static let stretchRounds: UInt32 = 100_000

    private func stretchedSecret() throws -> Data {
        let password = Array(linkCode.suffix(8).utf8)
        let salt = Array("oochat-device-link/v\(version)/\(displayer.rawValue)/\(serviceName)".utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { password in
            password.withMemoryRebound(to: CChar.self) { password in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress, password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), Self.stretchRounds,
                    &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw DeviceLinkError.malformed }
        return Data(derived)
    }
}

/// Where one endpoint is in its single use. A reference type, so every copy of an endpoint shares it.
/// Every step moves it forward, success or not.
private final class Stage: @unchecked Sendable {
    enum Step { case open, claimed, started, finished, cancelled }

    private let lock = NSLock()
    private var step = Step.open

    /// Moves from one of `expected` to `next`, or says why this step can't happen.
    func advance(from expected: Set<Step>, to next: Step) throws {
        try lock.withLock {
            guard expected.contains(step) else {
                throw step == .cancelled ? DeviceLinkError.cancelled : DeviceLinkError.reused
            }
            step = next
        }
    }

    func cancel() {
        lock.withLock { step = .cancelled }
    }
}

private func decode<Message: Decodable>(_ type: Message.Type, from data: Data) throws -> Message {
    guard let message = try? JSONDecoder().decode(type, from: data) else { throw DeviceLinkError.malformed }
    return message
}

/// The Giving Device's side of one link. Single use: `verify`, then the owner check, then `seal`.
public final class DeviceLinkGiver: Sendable {
    /// A receiver whose one-time key passed the Link Code and QR checks. Only `seal` can use it.
    public struct VerifiedReceiver: Sendable {
        fileprivate let key: Curve25519.KeyAgreement.PublicKey
    }

    public let offer: DeviceLinkOffer
    private let keyStore: any DeviceLinkKeyStore
    /// Sealed with the key, for the Receiving Device to apply.
    private let agentNames: [DeviceLinkAgentName]
    let now: @Sendable () -> Date
    private let stage = Stage()

    /// The giver displays: it makes the offer.
    public init(
        displayingWith keyStore: any DeviceLinkKeyStore,
        agentNames: [DeviceLinkAgentName] = [],
        now: @escaping @Sendable () -> Date = { Date() },
        random: (Int) -> Data = DeviceLinkOffer.systemRandom
    ) {
        offer = DeviceLinkOffer(displayer: .giving, linkCode: DeviceLinkOffer.generateCode(random: random), receiverKey: nil, now: now())
        self.keyStore = keyStore
        self.agentNames = agentNames
        self.now = now
    }

    /// The giver scans or types the receiver's offer.
    public init(
        scanning offer: DeviceLinkOffer,
        keyStore: any DeviceLinkKeyStore,
        agentNames: [DeviceLinkAgentName] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard offer.displayer == .receiving else { throw DeviceLinkError.malformed }
        self.offer = offer
        self.keyStore = keyStore
        self.agentNames = agentNames
        self.now = now
    }

    /// Checks the receiver's key message. This consumes the offer, whether or not the check passes.
    /// Ask the owner only after this succeeds.
    public func verify(_ keyMessage: Data) throws -> VerifiedReceiver {
        try stage.advance(from: [.open, .claimed], to: .started)
        guard now() < offer.expiry else { throw DeviceLinkError.expired }
        let message = try decode(KeyMessage.self, from: keyMessage)
        // A QR the receiver displayed already carries its key; a typed code only authenticates it by HMAC.
        guard try offer.isValidTag(message.tag, for: message.key),
              offer.receiverKey == nil || offer.receiverKey == message.key
        else { throw DeviceLinkError.wrongCode }
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.key) else {
            throw DeviceLinkError.malformed
        }
        return VerifiedReceiver(key: key)
    }

    /// Seals the Identity to the verified receiver. This is the moment the Identity leaves the device,
    /// so the owner check goes before it.
    public func seal(for receiver: VerifiedReceiver) throws -> Data {
        try stage.advance(from: [.started], to: .finished)
        guard now() < offer.expiry else { throw DeviceLinkError.expired }
        // A device with no Identity yet has nothing to give, so it must not make one up and send it.
        guard let privateKey = try keyStore.loadPrivateKey() else { throw DeviceLinkError.noIdentity }
        var sender = try HPKE.Sender(recipientKey: receiver.key, ciphersuite: hpkeSuite, info: hpkeInfo)
        let payload = try JSONEncoder().encode(SealedPayload(privateKey: privateKey, agentNames: agentNames))
        let ciphertext = try sender.seal(payload, authenticating: offer.binding)
        return try JSONEncoder().encode(SealedMessage(
            encapsulatedKey: sender.encapsulatedKey,
            ciphertext: ciphertext,
            address: try OIPSigner(keyStore: keyStore).address()
        ))
    }

    /// Closing the sheet. Nothing is sent after this.
    public func cancel() {
        stage.cancel()
    }

    /// Taken by `link()` before it listens or connects, so one offer is never advertised twice.
    func claim() throws {
        try stage.advance(from: [.open], to: .claimed)
    }
}

/// The Receiving Device's side of one link. Single use: `start`, then `accept`. It never writes a key store:
/// it hands back a checked Identity and the app replaces its key.
public final class DeviceLinkReceiver: Sendable {
    public let offer: DeviceLinkOffer
    private let oneTimeKey: Curve25519.KeyAgreement.PrivateKey
    let now: @Sendable () -> Date
    private let stage = Stage()

    /// The receiver displays: it makes the offer, carrying its one-time key.
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        random: (Int) -> Data = DeviceLinkOffer.systemRandom
    ) throws {
        let code = DeviceLinkOffer.generateCode(random: random)
        oneTimeKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: random(32))
        offer = DeviceLinkOffer(displayer: .receiving, linkCode: code, receiverKey: oneTimeKey.publicKey.rawRepresentation, now: now())
        self.now = now
    }

    /// The receiver scans or types the giver's offer.
    public init(
        scanning offer: DeviceLinkOffer,
        now: @escaping @Sendable () -> Date = { Date() },
        random: (Int) -> Data = DeviceLinkOffer.systemRandom
    ) throws {
        guard offer.displayer == .giving else { throw DeviceLinkError.malformed }
        self.offer = offer
        oneTimeKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: random(32))
        self.now = now
    }

    /// The first message on the connection, whoever opened it: this device's one-time key.
    /// This consumes the offer.
    public func start() throws -> Data {
        try stage.advance(from: [.open], to: .started)
        let key = oneTimeKey.publicKey.rawRepresentation
        return try JSONEncoder().encode(KeyMessage(key: key, tag: try offer.tag(for: key)))
    }

    /// Opens the giver's reply. Returns the Identity only once every check has passed.
    public func accept(_ sealedMessage: Data) throws -> DeviceLinkIdentity {
        try stage.advance(from: [.started], to: .finished)
        guard now() < offer.expiry else { throw DeviceLinkError.expired }
        let message = try decode(SealedMessage.self, from: sealedMessage)
        let opened: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: oneTimeKey, ciphersuite: hpkeSuite, info: hpkeInfo, encapsulatedKey: message.encapsulatedKey
            )
            opened = try recipient.open(message.ciphertext, authenticating: offer.binding)
        } catch {
            throw DeviceLinkError.tampered
        }
        let payload = try decode(SealedPayload.self, from: opened)
        guard let address = try? OIPSigner(keyStore: InMemoryPrivateKeyStore(rawKey: payload.privateKey)).address(),
              address == message.address
        else { throw DeviceLinkError.addressMismatch }
        // Decoding skips `init?`, so each entry is checked and lower-cased again here.
        let agentNames = payload.agentNames.compactMap { DeviceLinkAgentName(address: $0.address, name: $0.name) }
        return DeviceLinkIdentity(privateKey: payload.privateKey, address: address, agentNames: agentNames)
    }

    /// Closing the sheet. No Identity is delivered after this.
    public func cancel() {
        stage.cancel()
    }
}
