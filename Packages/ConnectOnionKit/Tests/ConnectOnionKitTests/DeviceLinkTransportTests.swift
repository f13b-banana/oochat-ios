import dnssd
import Foundation
import Network
import Testing
@testable import ConnectOnionKit

// Real Bonjour over this machine's loopback: the displaying side advertises, the other side resolves it.
// Serialized so two tests never advertise at once.

private let identityKey = Data((0..<32).map { UInt8($0) })
private let identityAddress = "0x03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
private let store = InMemoryPrivateKeyStore(rawKey: identityKey)

private func run(_ receiver: DeviceLinkReceiver, accept: Bool = true) -> Task<DeviceLinkIdentity, any Error> {
    Task { try await receiver.link(accept: { _ in accept }) }
}

private func run(_ giver: DeviceLinkGiver, approve: Bool = true) -> Task<Void, any Error> {
    Task { try await giver.link(approve: { approve }) }
}

private final class TestClock: @unchecked Sendable {
    var now = Date()
}

@Test func aWaitingErrorThatClearedDoesNotOutliveTheWait() {
    let gate = OnceGate<Void>(onFailure: {})

    gate.wait(NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
    gate.wait(nil) // the person allowed local network access and the listener became ready

    #expect(gate.waitingError == nil)
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct DeviceLinkTransportTests {
    @Test func receiverDisplaysAndTheGiverLinksOverBonjour() async throws {
        let receiving = try DeviceLinkReceiver()
        let giving = try DeviceLinkGiver(scanning: try DeviceLinkOffer(qrPayload: receiving.offer.qrPayload), keyStore: store)

        let identity = run(receiving)
        try await run(giving).value

        #expect(try await identity.value.address == identityAddress)
    }

    @Test func giverDisplaysAndAReceiverTypingTheCodeLinksOverBonjour() async throws {
        let giving = DeviceLinkGiver(displayingWith: store)
        let typed = try DeviceLinkOffer(linkCode: giving.offer.linkCode, displayer: .giving, now: Date())

        let gave = run(giving)
        let identity = try await run(try DeviceLinkReceiver(scanning: typed)).value
        try await gave.value

        #expect(identity.address == identityAddress)
    }

    @Test func aReceiverTypingAWrongSecretIsToldTheCodeWasWrong() async throws {
        let giving = DeviceLinkGiver(displayingWith: store)
        let code = giving.offer.linkCode
        let wrongSecret = code.prefix(2) + (code.hasSuffix("00000000") ? "11111111" : "00000000")
        let typed = try DeviceLinkOffer(linkCode: String(wrongSecret), displayer: .giving, now: Date())

        let gave = run(giving)
        let identity = run(try DeviceLinkReceiver(scanning: typed))

        await #expect(throws: DeviceLinkError.wrongCode) { try await identity.value }
        await #expect(throws: DeviceLinkError.wrongCode) { try await gave.value }
    }

    @Test func declinedApprovalSendsNothing() async throws {
        let giving = DeviceLinkGiver(displayingWith: store)
        let typed = try DeviceLinkOffer(linkCode: giving.offer.linkCode, displayer: .giving, now: Date())

        let gave = run(giving, approve: false)
        let identity = run(try DeviceLinkReceiver(scanning: typed))

        await #expect(throws: DeviceLinkError.cancelled) { try await gave.value }
        // The receiver hears it as "cancelled on the other device".
        await #expect(throws: DeviceLinkError.cancelled) { try await identity.value }
    }

    @Test func theGiverHearsWhenTheReceiversPersonDeclinesTheIdentity() async throws {
        let receiving = try DeviceLinkReceiver()
        let giving = try DeviceLinkGiver(scanning: try DeviceLinkOffer(qrPayload: receiving.offer.qrPayload), keyStore: store)

        let identity = run(receiving, accept: false)
        let gave = run(giving)

        await #expect(throws: DeviceLinkError.cancelled) { try await identity.value }
        await #expect(throws: DeviceLinkError.cancelled) { try await gave.value }
    }

    @Test func cancellingTheDisplayingSideTearsDownItsListener() async throws {
        let waiting = run(try DeviceLinkReceiver())
        try await Task.sleep(for: .milliseconds(200))

        waiting.cancel()
        await #expect(throws: DeviceLinkError.cancelled) { try await waiting.value }
    }

    @Test func anOfferIsNeverAdvertisedTwiceEvenAfterAFailedAttempt() async throws {
        let giving = DeviceLinkGiver(displayingWith: store)
        let receiving = try DeviceLinkReceiver()
        let firstGive = run(giving)
        let firstReceive = run(receiving)
        try await Task.sleep(for: .milliseconds(200))
        firstGive.cancel()
        firstReceive.cancel()
        _ = await (firstGive.result, firstReceive.result)

        await #expect(throws: DeviceLinkError.reused) { try await run(giving).value }
        await #expect(throws: DeviceLinkError.reused) { try await run(receiving).value }
    }

    @Test func cancellingTheReceiverMidExchangeReturnsNoIdentity() async throws {
        let giving = DeviceLinkGiver(displayingWith: store)
        let typed = try DeviceLinkOffer(linkCode: giving.offer.linkCode, displayer: .giving, now: Date())
        let asked = AsyncStream<Void>.makeStream()

        // The giver has verified the receiver and is waiting on the owner when the receiver backs out.
        let gave = Task {
            try await giving.link(approve: { asked.continuation.yield(); try? await Task.sleep(for: .seconds(30)); return false })
        }
        let receiving = run(try DeviceLinkReceiver(scanning: typed))
        for await _ in asked.stream { break }
        receiving.cancel()

        // The Kit never writes a key: the receiving app saves only what link() returns, and nothing came back.
        await #expect(throws: DeviceLinkError.cancelled) { try await receiving.value }
        gave.cancel()
        _ = await gave.result
    }

    @Test func anExpiredOfferStopsListening() async throws {
        let clock = TestClock()
        let receiving = try DeviceLinkReceiver(now: { clock.now })
        clock.now = clock.now.addingTimeInterval(DeviceLinkOffer.lifetime - 0.3)

        await #expect(throws: DeviceLinkError.expired) { try await run(receiving).value }
    }
}
