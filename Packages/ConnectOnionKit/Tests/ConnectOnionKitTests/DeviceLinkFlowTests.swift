import dnssd
import Foundation
import Network
import Testing
import ConnectOnionKit

// Drives DeviceLinkFlow through its public API. The link operations are played in memory with the real
// Device Link crypto, so no socket is opened.

private let identityKey = Data((0..<32).map { UInt8($0) })
private let identityAddress = "0x03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
private let giversAgents = [DeviceLinkAgentName(address: "0x" + String(repeating: "ab", count: 32), name: "Scriptbot")].compactMap { $0 }

private func address(of store: some PrivateKeyStoring) throws -> String {
    try OIPSigner(keyStore: store).address()
}

/// Waits for the flow's background work to reach `condition`.
@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

/// The Giving Device, in memory: it scans the receiver's offer and sends `giverStore`'s Identity.
private func givingDevice(
    _ giverStore: InMemoryPrivateKeyStore = InMemoryPrivateKeyStore(rawKey: identityKey),
    agentNames: [DeviceLinkAgentName] = []
) -> DeviceLinkFlow.Receive {
    { receiver, accept in
        let giver = try DeviceLinkGiver(scanning: receiver.offer, keyStore: giverStore, agentNames: agentNames)
        let identity = try receiver.accept(try giver.seal(for: try giver.verify(try receiver.start())))
        guard await accept(identity) else { throw DeviceLinkError.cancelled }
        return identity
    }
}

/// The Receiving Device, in memory: it displayed `receiver`'s offer and reports the Identity it got.
private func receivingDevice(_ receiver: DeviceLinkReceiver, delivered: Delivered) -> DeviceLinkFlow.Give {
    { giver, approve in
        let verified = try giver.verify(try receiver.start())
        guard await approve() else {
            await delivered.giveUp()
            giver.cancel()
            throw DeviceLinkError.cancelled
        }
        await delivered.set(try receiver.accept(try giver.seal(for: verified)))
    }
}

/// The Receiving Device, in memory: it types the Link Code the giver displays and reports the Identity it got.
private func typingReceiver(delivered: Delivered) -> DeviceLinkFlow.Give {
    { giver, approve in
        let typed = try DeviceLinkOffer(linkCode: giver.offer.linkCode, displayer: .giving, now: Date())
        let receiver = try DeviceLinkReceiver(scanning: typed)
        let verified = try giver.verify(try receiver.start())
        guard await approve() else { throw DeviceLinkError.cancelled }
        await delivered.set(try receiver.accept(try giver.seal(for: verified)))
    }
}

/// The Giving Device, in memory, displaying `giver`'s offer for the receiver to type.
private func displayingGiver(_ giver: DeviceLinkGiver) -> DeviceLinkFlow.Receive {
    { receiver, accept in
        let identity = try receiver.accept(try giver.seal(for: try giver.verify(try receiver.start())))
        guard await accept(identity) else { throw DeviceLinkError.cancelled }
        return identity
    }
}

/// A clock the test moves by hand.
private final class FlowClock: @unchecked Sendable {
    var now = Date()
}

@MainActor
private final class Delivered {
    var identity: DeviceLinkIdentity?
    /// The giver said no to sending, so the link stopped here.
    var gaveUp = false
    func set(_ identity: DeviceLinkIdentity) { self.identity = identity }
    func giveUp() { gaveUp = true }
}

@MainActor
@Suite struct DeviceLinkFlowTests {
    @Test func receiverShowsACodeThenReplacesItsKeyOnceThePersonAccepts() async throws {
        let store = InMemoryPrivateKeyStore()
        let before = try address(of: store)
        var replaced: String?
        let flow = DeviceLinkFlow(role: .receiving, keyStore: store, onReplaced: { replaced = $0 }, receive: givingDevice())

        flow.start()
        guard case .showingCode(let offer) = flow.step else { Issue.record("no code shown"); return }
        #expect(offer.linkCode.count == 10)

        try await eventually { flow.step == .confirmingReplace(current: before, incoming: identityAddress) }
        #expect(try address(of: store) == before)
        #expect(!store.isLinked)

        flow.confirm()
        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(try address(of: store) == identityAddress)
        #expect(store.isLinked)
        // The app stamps its old chats with the Address that was replaced.
        #expect(replaced == before)
    }

    @Test func receiverThatDeclinesKeepsItsKeyAndTellsTheGiver() async throws {
        let store = InMemoryPrivateKeyStore()
        let before = try store.loadOrCreatePrivateKey()
        var replaced = false
        var gotAgentNames = false
        let giverHeard = Answer()
        let flow = DeviceLinkFlow(role: .receiving, keyStore: store, onReplaced: { _ in replaced = true },
                                  onAgentNames: { _ in gotAgentNames = true }, receive: { receiver, accept in
            do {
                return try await givingDevice(agentNames: giversAgents)(receiver, accept)
            } catch {
                await giverHeard.set(error as? DeviceLinkError)
                throw error
            }
        })

        flow.start()
        try await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        flow.cancel()

        try await eventually { giverHeard.value == .cancelled }
        #expect(try store.loadOrCreatePrivateKey() == before)
        #expect(!store.isLinked)
        #expect(!replaced)
        #expect(!gotAgentNames)
    }

    @Test func giverSendsItsIdentityOnlyAfterTheOwnerCheckAndMarksItselfLinked() async throws {
        let store = InMemoryPrivateKeyStore(rawKey: identityKey)
        let receiver = try DeviceLinkReceiver()
        let delivered = Delivered()
        var asked = 0
        let flow = DeviceLinkFlow(role: .giving, keyStore: store, ownerCheck: { asked += 1; return true },
                                  give: receivingDevice(receiver, delivered: delivered))
        #expect(flow.step == .enteringCode)

        flow.submit(try receiver.offer.qrPayload)
        try await eventually { flow.step == .confirmingSend }
        #expect(asked == 0)
        #expect(delivered.identity == nil)

        flow.confirm()
        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(asked == 1)
        #expect(delivered.identity?.address == identityAddress)
        #expect(store.isLinked)
    }

    @Test func giverShowsACodeThenSendsAfterTheOwnerCheckAndMarksItselfLinked() async throws {
        let store = InMemoryPrivateKeyStore(rawKey: identityKey)
        let delivered = Delivered()
        var linkedWhenCalled: Bool?
        let flow = DeviceLinkFlow(role: .giving, keyStore: store, displaysCode: true, onLinked: { linkedWhenCalled = store.isLinked },
                                  ownerCheck: { true }, give: typingReceiver(delivered: delivered))

        flow.start()
        guard case .showingCode(let offer) = flow.step else { Issue.record("no code shown"); return }
        #expect(offer.displayer == .giving)
        #expect(offer.receiverKey == nil)
        try await eventually { flow.step == .confirmingSend }
        #expect(delivered.identity == nil)

        flow.confirm()
        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(delivered.identity?.address == identityAddress)
        #expect(store.isLinked)
        #expect(linkedWhenCalled == true)
    }

    @Test func receiverTypesTheGiversCodeThenReplacesItsKeyOnceThePersonAccepts() async throws {
        let store = InMemoryPrivateKeyStore()
        let before = try address(of: store)
        let giver = DeviceLinkGiver(displayingWith: InMemoryPrivateKeyStore(rawKey: identityKey))
        var replaced: String?
        let flow = DeviceLinkFlow(role: .receiving, keyStore: store, displaysCode: false, onReplaced: { replaced = $0 },
                                  receive: displayingGiver(giver))
        flow.start()
        #expect(flow.step == .enteringCode)

        flow.submit(giver.offer.linkCode)
        try await eventually { flow.step == .confirmingReplace(current: before, incoming: identityAddress) }
        #expect(try address(of: store) == before)

        flow.confirm()
        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(try address(of: store) == identityAddress)
        #expect(store.isLinked)
        #expect(replaced == before)
    }

    @Test func aReceiverGivenAnotherReceiversCodeIsCaughtBeforeConnecting() async throws {
        let flow = DeviceLinkFlow(role: .receiving, keyStore: InMemoryPrivateKeyStore(), displaysCode: false, receive: { _, _ in
            Issue.record("no link without a giver's code")
            throw DeviceLinkError.cancelled
        })
        flow.start()

        flow.submit(try DeviceLinkReceiver().offer.qrPayload)

        try await eventually { flow.step == .failed(.mistypedCode) }
    }

    @Test func switchingModeShowsAFreshCodeOrAsksForOneAndStopsTheListener() async throws {
        let stopped = Answer()
        let flow = DeviceLinkFlow(role: .giving, keyStore: InMemoryPrivateKeyStore(), displaysCode: false, give: { _, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await stopped.set(.cancelled)
            }
            throw DeviceLinkError.cancelled
        })
        flow.start()
        #expect(!flow.displaysCode)

        flow.switchCodeMode()
        #expect(flow.displaysCode)
        guard case .showingCode(let offer) = flow.step else { Issue.record("no code shown"); return }
        #expect(offer.displayer == .giving)

        flow.switchCodeMode()
        #expect(flow.step == .enteringCode)
        try await eventually { stopped.value == .cancelled }
        try await Task.sleep(for: .milliseconds(20))
        #expect(flow.step == .enteringCode)
    }

    @Test func eachRoleKeepsItsUsualModeUnlessTheAppPicksOne() {
        #expect(DeviceLinkFlow(role: .receiving, keyStore: InMemoryPrivateKeyStore()).displaysCode)
        #expect(!DeviceLinkFlow(role: .giving, keyStore: InMemoryPrivateKeyStore()).displaysCode)
    }

    @Test func refusedOwnerCheckSendsNothingAndAsksAgain() async throws {
        let store = InMemoryPrivateKeyStore(rawKey: identityKey)
        let receiver = try DeviceLinkReceiver()
        let delivered = Delivered()
        let flow = DeviceLinkFlow(role: .giving, keyStore: store, ownerCheck: { false },
                                  give: receivingDevice(receiver, delivered: delivered))

        flow.submit(try DeviceLinkOffer(qrPayload: receiver.offer.qrPayload).linkCode)
        try await eventually { flow.step == .confirmingSend }
        #expect(!flow.ownerCheckFailed)
        flow.confirm()
        try await eventually { flow.ownerCheckFailed }

        #expect(flow.step == .confirmingSend)
        #expect(delivered.identity == nil)
        #expect(!store.isLinked)
    }

    @Test(arguments: [
        (DeviceLinkError.expired as any Error & Sendable, DeviceLinkFailure.expired),
        (DeviceLinkError.cancelled, .cancelledOnOtherDevice),
        (DeviceLinkError.tampered, .other),
        (NWError.posix(.ETIMEDOUT), .notOnSameNetwork),
        (NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)), .localNetworkDenied)
    ])
    func aFailedLinkShowsItsNamedFailure(error: any Error & Sendable, failure: DeviceLinkFailure) async throws {
        let receiving = DeviceLinkFlow(role: .receiving, keyStore: InMemoryPrivateKeyStore(), receive: { _, _ in throw error })
        let giving = DeviceLinkFlow(role: .giving, keyStore: InMemoryPrivateKeyStore(), give: { _, _ in throw error })

        receiving.start()
        giving.submit("0123456789")

        try await eventually { receiving.step == .failed(failure) && giving.step == .failed(failure) }
    }

    @Test func aMistypedCodeIsCaughtBeforeConnecting() async throws {
        let flow = DeviceLinkFlow(role: .giving, keyStore: InMemoryPrivateKeyStore(), give: { _, _ in })

        flow.submit("TOO-SHORT")

        try await eventually { flow.step == .failed(.mistypedCode) }
    }

    @Test func newCodeReplacesTheOfferAndTryAgainReturnsToCodeEntry() async throws {
        let receiving = DeviceLinkFlow(role: .receiving, keyStore: InMemoryPrivateKeyStore(),
                                       receive: { _, _ in throw DeviceLinkError.expired })
        receiving.start()
        guard case .showingCode(let first) = receiving.step else { Issue.record("no code shown"); return }
        try await eventually { receiving.step == .failed(.expired) }

        receiving.start()
        guard case .showingCode(let second) = receiving.step else { Issue.record("no new code"); return }
        #expect(second.linkCode != first.linkCode)

        let giving = DeviceLinkFlow(role: .giving, keyStore: InMemoryPrivateKeyStore(), give: { _, _ in throw DeviceLinkError.wrongCode })
        giving.submit("0123456789")
        try await eventually { giving.step == .failed(.wrongCode) }
        giving.start()
        #expect(giving.step == .enteringCode)
    }

    @Test func closingTheSheetStopsTheRunningLinkWithoutAFailure() async throws {
        let stopped = Answer()
        let flow = DeviceLinkFlow(role: .receiving, keyStore: InMemoryPrivateKeyStore(), receive: { _, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await stopped.set(.cancelled)
            }
            throw DeviceLinkError.cancelled
        })
        flow.start()
        let shown = flow.step

        flow.cancel()

        try await eventually { stopped.value == .cancelled }
        try await Task.sleep(for: .milliseconds(20))
        #expect(flow.step == shown)
    }

    @Test func theGiversAgentNamesGoIntoWhatItSends() async throws {
        let receiver = try DeviceLinkReceiver()
        let delivered = Delivered()
        let flow = DeviceLinkFlow(role: .giving, keyStore: InMemoryPrivateKeyStore(rawKey: identityKey),
                                  agentNames: { giversAgents }, ownerCheck: { true },
                                  give: receivingDevice(receiver, delivered: delivered))

        flow.submit(try receiver.offer.qrPayload)
        try await eventually { flow.step == .confirmingSend }
        flow.confirm()

        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(delivered.identity?.agentNames == giversAgents)
    }

    @Test func theReceiverGetsTheGiversAgentNamesOnceItsKeyIsReplacedAndBeforeOnReplaced() async throws {
        let store = InMemoryPrivateKeyStore()
        var events: [String] = []
        let flow = DeviceLinkFlow(
            role: .receiving, keyStore: store,
            onReplaced: { _ in events.append("replaced") },
            onAgentNames: { names in
                events.append(try address(of: store) == identityAddress ? "names after key" : "names before key")
                #expect(names == giversAgents)
            },
            receive: givingDevice(agentNames: giversAgents)
        )

        flow.start()
        try await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        #expect(events.isEmpty)
        flow.confirm()

        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(events == ["names after key", "replaced"])
    }

    @Test func agentNamesThatCannotBeSavedStillLeaveTheLinkDone() async throws {
        let store = InMemoryPrivateKeyStore()
        var replaced = false
        let flow = DeviceLinkFlow(
            role: .receiving, keyStore: store,
            onReplaced: { _ in replaced = true },
            onAgentNames: { _ in throw CocoaError(.fileWriteUnknown) },
            receive: givingDevice(agentNames: giversAgents)
        )

        flow.start()
        try await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        flow.confirm()

        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(try address(of: store) == identityAddress)
        #expect(replaced)
    }

    @Test func theReceiverSavesTheKeyBeforeTellingTheGiverItAccepted() async throws {
        let store = InMemoryPrivateKeyStore()
        let keyWhenAccepted = KeyRecord()
        let flow = DeviceLinkFlow(role: .receiving, keyStore: store, receive: { receiver, accept in
            let identity = try await givingDevice()(receiver) { identity in
                let accepted = await accept(identity)
                await keyWhenAccepted.set(try? store.loadOrCreatePrivateKey())
                return accepted
            }
            return identity
        })

        flow.start()
        try await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        flow.confirm()

        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(keyWhenAccepted.key == identityKey)
    }

    @Test func aKeyThatCannotBeSavedIsDeclinedAndNamedAsThisDevicesFailure() async throws {
        let giverHeard = Answer()
        var replaced = false
        let store = FailingStore()
        let flow = DeviceLinkFlow(role: .receiving, keyStore: store, onReplaced: { _ in replaced = true }, receive: { receiver, accept in
            do {
                return try await givingDevice()(receiver, accept)
            } catch {
                await giverHeard.set(error as? DeviceLinkError)
                throw error
            }
        })

        flow.start()
        try await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        flow.confirm()

        try await eventually { flow.step == .failed(.couldNotSave) }
        #expect(giverHeard.value == .cancelled)
        #expect(!replaced)
    }

    @Test func aYesAfterTheCodeExpiresLeavesTheKeyAlone() async throws {
        let store = InMemoryPrivateKeyStore()
        let before = try store.loadOrCreatePrivateKey()
        let clock = FlowClock()
        var replaced = false
        let flow = DeviceLinkFlow(role: .receiving, keyStore: store, onReplaced: { _ in replaced = true },
                                  now: { clock.now }, receive: givingDevice())

        flow.start()
        try await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        clock.now += DeviceLinkOffer.lifetime
        flow.confirm()

        try await eventually { flow.step == .failed(.expired) }
        #expect(try store.loadOrCreatePrivateKey() == before)
        #expect(!store.isLinked)
        #expect(!replaced)
    }

    @Test func aReplacedKeyIsKeptAndReportedEvenIfTheGiverHangsUpAfterward() async throws {
        let store = InMemoryPrivateKeyStore()
        var replaced = false
        let flow = DeviceLinkFlow(role: .receiving, keyStore: store, onReplaced: { _ in replaced = true }, receive: { receiver, accept in
            _ = try await givingDevice()(receiver, accept)
            throw DeviceLinkError.cancelled // the "accepted" message could not be sent
        })

        flow.start()
        try await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        flow.confirm()

        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(try address(of: store) == identityAddress)
        #expect(replaced)
    }

    @Test func closingTheSheetDuringTheOwnerCheckSendsNothingAndLeavesARestartAlone() async throws {
        let store = InMemoryPrivateKeyStore(rawKey: identityKey)
        let receiver = try DeviceLinkReceiver()
        let delivered = Delivered()
        let ownerCheck = OwnerCheckGate()
        let flow = DeviceLinkFlow(role: .giving, keyStore: store, ownerCheck: { await ownerCheck.wait() },
                                  give: receivingDevice(receiver, delivered: delivered))
        flow.submit(try receiver.offer.qrPayload)
        try await eventually { flow.step == .confirmingSend }
        flow.confirm()
        try await eventually { ownerCheck.isWaiting }

        flow.cancel()
        flow.start()
        ownerCheck.answer(true)
        try await eventually { delivered.gaveUp }

        #expect(flow.step == .enteringCode)
        #expect(delivered.identity == nil)
        #expect(!store.isLinked)
    }

    @Test func aGiverThatCannotSetItsFlagStillShowsTheLinkItMade() async throws {
        let receiver = try DeviceLinkReceiver()
        let delivered = Delivered()
        let flow = DeviceLinkFlow(role: .giving, keyStore: FailingStore(rawKey: identityKey), ownerCheck: { true },
                                  give: receivingDevice(receiver, delivered: delivered))

        flow.submit(try receiver.offer.qrPayload)
        try await eventually { flow.step == .confirmingSend }
        flow.confirm()

        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(delivered.identity?.address == identityAddress)
    }

    @Test func theGiverRunsOnLinkedAfterMarkingItselfLinkedEvenIfTheSheetJustClosed() async throws {
        let store = InMemoryPrivateKeyStore(rawKey: identityKey)
        let receiver = try DeviceLinkReceiver()
        let delivered = Delivered()
        let flowBox = FlowBox()
        var linkedWhenCalled: Bool?
        let flow = DeviceLinkFlow(role: .giving, keyStore: store, onLinked: { linkedWhenCalled = store.isLinked }, ownerCheck: { true },
                                  give: { giver, approve in
            try await receivingDevice(receiver, delivered: delivered)(giver, approve)
            await flowBox.flow?.cancel() // the person closes the sheet as the link completes
        })
        flowBox.flow = flow

        flow.submit(try receiver.offer.qrPayload)
        try await eventually { flow.step == .confirmingSend }
        flow.confirm()

        try await eventually { linkedWhenCalled != nil }
        #expect(linkedWhenCalled == true)
    }

    @Test func afterAcceptingTheReceiverShowsProgressInsteadOfTheChoice() async throws {
        let flowBox = FlowBox()
        let stepWhileAccepting = StepRecord()
        let flow = DeviceLinkFlow(role: .receiving, keyStore: InMemoryPrivateKeyStore(), receive: { receiver, accept in
            try await givingDevice()(receiver) { identity in
                let accepted = await accept(identity)
                await stepWhileAccepting.set(await flowBox.flow?.step)
                return accepted
            }
        })
        flowBox.flow = flow

        flow.start()
        try await eventually { if case .confirmingReplace = flow.step { true } else { false } }
        flow.confirm()

        try await eventually { flow.step == .done(address: identityAddress) }
        #expect(stepWhileAccepting.step == .sending)
    }
}

/// What the other device heard, set from the link operation.
@MainActor
private final class Answer {
    var value: DeviceLinkError?
    func set(_ error: DeviceLinkError?) { value = error }
}

@MainActor
private final class KeyRecord {
    var key: Data?
    func set(_ key: Data?) { self.key = key }
}

/// An owner check the test answers by hand.
@MainActor
private final class OwnerCheckGate {
    private var pending: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool { pending != nil }
    func wait() async -> Bool { await withCheckedContinuation { pending = $0 } }
    func answer(_ yes: Bool) {
        pending?.resume(returning: yes)
        pending = nil
    }
}

/// A key store whose writes fail, as a full or locked Keychain would.
private final class FailingStore: DeviceLinkKeyStore, @unchecked Sendable {
    private let key: Data
    init(rawKey: Data = Data((100..<132).map { UInt8($0) })) { key = rawKey }
    func loadOrCreatePrivateKey() throws -> Data { key }
    func loadPrivateKey() throws -> Data? { key }
    func replacePrivateKey(with rawKey: Data) throws { throw CocoaError(.fileWriteUnknown) }
    var isLinked: Bool { false }
    func markLinked() throws { throw CocoaError(.fileWriteUnknown) }
}

@MainActor
private final class FlowBox {
    var flow: DeviceLinkFlow?
}

@MainActor
private final class StepRecord {
    var step: DeviceLinkFlow.Step?
    func set(_ step: DeviceLinkFlow.Step?) { self.step = step }
}
