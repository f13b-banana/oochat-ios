import Foundation
import LocalAuthentication
import Observation
import os

/// The link sheet's state, for either role. The app makes one per sheet, calls `start()` when it opens
/// and `cancel()` when it closes; the person's actions call `submit(_:)` and `confirm()`.
/// Nothing touches the network before `start()`, and nothing on a Receiving Device changes until its person
/// accepts the verified Identity.
@MainActor
@Observable
public final class DeviceLinkFlow {
    public enum Step: Equatable, Sendable {
        /// This device displays the offer as a QR with its Link Code under it, until `offer.expiry`.
        case showingCode(DeviceLinkOffer)
        /// This device waits for the other device's QR or Link Code.
        case enteringCode
        case connecting
        /// Receiving Device: the verified Identity has arrived. `confirm()` replaces `current` with `incoming`.
        case confirmingReplace(current: String, incoming: String)
        /// Giving Device: "Send my identity to this device?". `confirm()` runs the owner check, then sends.
        case confirmingSend
        /// The Identity is on its way: the giver waits for the receiver to accept, the receiver saves it and answers.
        case sending
        /// Both devices now speak as `address`.
        case done(address: String)
        case failed(DeviceLinkFailure)
    }

    /// Runs the Receiving Device's side of one link. `accept` asks the person; see `DeviceLinkReceiver.link(accept:)`.
    public typealias Receive = @Sendable (
        DeviceLinkReceiver, _ accept: @escaping @Sendable (DeviceLinkIdentity) async -> Bool
    ) async throws -> DeviceLinkIdentity

    /// Runs the Giving Device's side of one link. `approve` asks the person; see `DeviceLinkGiver.link(approve:)`.
    public typealias Give = @Sendable (DeviceLinkGiver, _ approve: @escaping @Sendable () async -> Bool) async throws -> Void

    public let role: DeviceLinkRole
    /// This device shows its own code for the other device to scan or type, rather than entering the other's.
    /// Either role can do either; `switchCodeMode()` changes it.
    public private(set) var displaysCode: Bool
    /// Before `start()`: `.connecting` if this device displays its code, else `.enteringCode`.
    public private(set) var step: Step
    /// Giving Device: the last owner check was refused, so `confirmingSend` is being asked again.
    public private(set) var ownerCheckFailed = false

    private let keyStore: any DeviceLinkKeyStore
    private let onReplaced: @MainActor (_ previousAddress: String) -> Void
    private let agentNames: @MainActor () -> [DeviceLinkAgentName]
    private let onAgentNames: @MainActor ([DeviceLinkAgentName]) throws -> Void
    private let onLinked: @MainActor () -> Void
    private let ownerCheck: @MainActor () async -> Bool
    private let now: @Sendable () -> Date
    private let random: @Sendable (Int) -> Data
    private let receiveLink: Receive
    private let giveLink: Give
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
    /// Receiving Device: the Address this attempt replaced and the Identity it stored, once the key is replaced.
    @ObservationIgnored private var replaced: (previous: String, identity: DeviceLinkIdentity)?

    /// The replace warning's line about Agent Names.
    public nonisolated static let agentNamesWarning = "Agent names will match the other device."
    private static let log = Logger(subsystem: "ai.openonion.ConnectOnionKit", category: "DeviceLink")

    /// - Parameters:
    ///   - displaysCode: whether the sheet opens on this device's own code. Nil keeps the usual split:
    ///     the Receiving Device displays and the Giving Device enters the code.
    ///   - onReplaced: runs on the Receiving Device right after its key is replaced, with the Address it replaced.
    ///     The app stamps its old chats with that Address and updates its connections.
    ///   - onLinked: runs on the Giving Device right after it marks itself linked, even if the sheet has just closed.
    ///   - agentNames: Giving Device: its Agent Name list, read when the link starts and sealed with the key.
    ///   - onAgentNames: Receiving Device: the giver's Agent Name list, after the key is replaced and before
    ///     `onReplaced`. Best-effort: a throw is logged and the link still succeeds.
    ///   - ownerCheck: Giving Device: Face ID, Touch ID or passcode before anything is sent.
    ///   - receive, give: the link itself; tests pass in-memory ones so no socket opens.
    public init(
        role: DeviceLinkRole,
        keyStore: any DeviceLinkKeyStore,
        displaysCode: Bool? = nil,
        onReplaced: @escaping @MainActor (_ previousAddress: String) -> Void = { _ in },
        onLinked: @escaping @MainActor () -> Void = {},
        agentNames: @escaping @MainActor () -> [DeviceLinkAgentName] = { [] },
        onAgentNames: @escaping @MainActor ([DeviceLinkAgentName]) throws -> Void = { _ in },
        ownerCheck: @escaping @MainActor () async -> Bool = { await DeviceLinkFlow.checkDeviceOwner() },
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable (Int) -> Data = { DeviceLinkOffer.systemRandom($0) },
        receive: @escaping Receive = { receiver, accept in try await receiver.link(accept: accept) },
        give: @escaping Give = { giver, approve in try await giver.link(approve: approve) }
    ) {
        self.role = role
        self.keyStore = keyStore
        self.onReplaced = onReplaced
        self.onLinked = onLinked
        self.agentNames = agentNames
        self.onAgentNames = onAgentNames
        self.ownerCheck = ownerCheck
        self.now = now
        self.random = random
        self.receiveLink = receive
        self.giveLink = give
        let displaysCode = displaysCode ?? (role == .receiving)
        self.displaysCode = displaysCode
        step = displaysCode ? .connecting : .enteringCode
    }

    /// Starts the link from its first step, or starts it over ("New code", "Try again"),
    /// cancelling any attempt still running.
    public func start() {
        cancel()
        replaced = nil
        ownerCheckFailed = false
        guard displaysCode else {
            step = .enteringCode
            return
        }
        switch role {
        case .giving:
            let giver = DeviceLinkGiver(displayingWith: keyStore, agentNames: agentNames(), now: now, random: random)
            step = .showingCode(giver.offer)
            run { try await self.give(giver) }
        case .receiving:
            do {
                let receiver = try DeviceLinkReceiver(now: now, random: random)
                step = .showingCode(receiver.offer)
                run { try await self.receive(receiver) }
            } catch {
                step = .failed(DeviceLinkFailure(error))
            }
        }
    }

    /// "Show my code instead", or back to entering the other device's code. Starts over either way.
    public func switchCodeMode() {
        displaysCode.toggle()
        start()
    }

    /// The other device's QR payload, as scanned, or its Link Code, as typed.
    public func submit(_ code: String) {
        guard step == .enteringCode else { return }
        step = .connecting
        run {
            // Only a code refused here, before connecting, leaves the other device's code usable.
            func parsed<T>(_ make: () throws -> T) throws -> T {
                do { return try make() } catch DeviceLinkError.malformed { throw DeviceLinkFailure.mistypedCode }
            }
            let offer = try parsed { try DeviceLinkOffer(entered: code, displayer: self.role.counterpart, now: self.now()) }
            switch self.role {
            case .giving:
                let names = self.agentNames()
                try await self.give(parsed {
                    try DeviceLinkGiver(scanning: offer, keyStore: self.keyStore, agentNames: names, now: self.now)
                })
            case .receiving: try await self.receive(parsed { try DeviceLinkReceiver(scanning: offer, now: self.now, random: self.random) })
            }
        }
    }

    /// The person's yes to the confirmation on screen.
    public func confirm() {
        answer?.resume(returning: true)
        answer = nil
    }

    /// The sheet closed or the person said no: the running link stops and nothing more changes.
    public func cancel() {
        task?.cancel()
        task = nil
        answer?.resume(returning: false)
        answer = nil
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        task = Task {
            do {
                try await work()
            } catch {
                // The first failure named wins, such as a key that could not be saved.
                if case .failed = step { return }
                if !Task.isCancelled { step = .failed(DeviceLinkFailure(error)) }
            }
        }
    }

    private func receive(_ receiver: DeviceLinkReceiver) async throws {
        do {
            _ = try await receiveLink(receiver) { identity in
                await self.askToReplace(with: identity, before: receiver.offer.expiry)
            }
        } catch {
            // Once the key is replaced this device has the Identity, whatever happens to the connection.
            guard replaced != nil else { throw error }
        }
        guard let replaced else { return }
        do {
            try onAgentNames(replaced.identity.agentNames)
        } catch {
            // The Identity is the part that must not fail; agents can still be added by hand.
            Self.log.error("Couldn't save the linked agent names: \(error.localizedDescription, privacy: .public)")
        }
        onReplaced(replaced.previous)
        step = .done(address: replaced.identity.address)
    }

    private func give(_ giver: DeviceLinkGiver) async throws {
        try await giveLink(giver) { await self.approveSend() }
        // The Identity has been sent and accepted; a flag that can't be written only keeps the Mac's viewer off.
        try? keyStore.markLinked()
        onLinked()
        step = .done(address: try OIPSigner(keyStore: keyStore).address())
    }

    /// Asks until the owner check passes, or the sheet closes. A cancelled attempt touches nothing,
    /// so it can't overwrite a restarted one.
    private func approveSend() async -> Bool {
        while !Task.isCancelled {
            step = .confirmingSend
            guard await nextAnswer() else { return false }
            if await ownerCheck() {
                guard !Task.isCancelled else { return false }
                ownerCheckFailed = false
                step = .sending
                return true
            }
            ownerCheckFailed = true
        }
        return false
    }

    /// The person's answer, or no if this attempt is cancelled.
    private func nextAnswer() async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { answer = $0 }
    }

    /// Replaces the key before the receiver tells the giver it accepted, so the giver only reports a link
    /// this device kept. A key that can't be saved is declined, and the giver hears cancelled.
    /// A yes that comes after `expiry` is too late: the giver has already given up, so the key stays.
    private func askToReplace(with identity: DeviceLinkIdentity, before expiry: Date) async -> Bool {
        guard !Task.isCancelled, let current = try? OIPSigner(keyStore: keyStore).address() else { return false }
        step = .confirmingReplace(current: current, incoming: identity.address)
        guard await nextAnswer(), !Task.isCancelled else { return false }
        guard now() < expiry else {
            step = .failed(.expired)
            return false
        }
        step = .sending // the choice is made; "accepted" goes out next
        do {
            try keyStore.replacePrivateKey(with: identity.privateKey)
        } catch {
            step = .failed(.couldNotSave)
            return false
        }
        replaced = (current, identity)
        return true
    }

    /// Device-owner authentication: Face ID, Touch ID, or the device passcode or login password.
    /// False if the person cancels, fails, or the device has no passcode.
    public nonisolated static func checkDeviceOwner() async -> Bool {
        let context = LAContext()
        // macOS shows it after "OO Chat is trying to"; iOS shows it on its own.
        #if os(macOS)
        let reason = "send your identity to your other device"
        #else
        let reason = "Send your identity to your other device"
        #endif
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
