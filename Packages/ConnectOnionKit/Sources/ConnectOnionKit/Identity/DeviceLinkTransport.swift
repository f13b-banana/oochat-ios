import Foundation
import Network
import os

extension DeviceLinkReceiver {
    /// Runs the whole link on the Receiving Device: listens if it displayed the offer, else connects.
    /// `accept` is the person's answer to replacing this device's Identity: it runs only once the delivered
    /// Identity has passed every check, while the connection is still open, so the Giving Device learns the answer.
    /// The Identity is returned only if it returns true; replacing the stored key is then up to the caller.
    /// Cancelling the calling task closes the sheet: the listener and connection go, and no Identity is returned.
    public func link(accept personAccepts: (DeviceLinkIdentity) async -> Bool) async throws -> DeviceLinkIdentity {
        let keyMessage = try start() // consumes the offer before anything is advertised
        let connection = try await DeviceLinkConnection.open(offer, as: .receiving, now: now)
        defer { connection.cancel() }
        return try await connection.run {
            try await connection.send(keyMessage)
            let reply = try await connection.receive()
            guard reply != DeviceLinkConnection.wrongCode else { throw DeviceLinkError.wrongCode }
            let identity = try accept(reply)
            guard await personAccepts(identity) else {
                cancel()
                throw DeviceLinkError.cancelled
            }
            try await connection.send(DeviceLinkConnection.accepted)
            return identity
        }
    }
}

extension DeviceLinkGiver {
    /// Runs the whole link on the Giving Device. `approve` is the confirmation and owner check: it runs
    /// only once the connected receiver's key has been verified, and nothing is sent unless it returns true.
    /// Returns once the Receiving Device's person has accepted the Identity; throws `.cancelled` if they declined.
    public func link(approve: () async -> Bool) async throws {
        try claim()
        let connection = try await DeviceLinkConnection.open(offer, as: .giving, now: now)
        defer { connection.cancel() }
        try await connection.run {
            let receiver: VerifiedReceiver
            do {
                receiver = try verify(try await connection.receive())
            } catch DeviceLinkError.wrongCode {
                // Only the giver can check the code, so it tells the receiver, who may be the one who typed it.
                try? await connection.send(DeviceLinkConnection.wrongCode)
                throw DeviceLinkError.wrongCode
            }
            guard await approve() else {
                cancel()
                throw DeviceLinkError.cancelled
            }
            try await connection.send(try seal(for: receiver))
            // The receiver's `accepted`; it hangs up instead if it declined.
            guard try await connection.receive() == DeviceLinkConnection.accepted else { throw DeviceLinkError.malformed }
        }
    }
}

extension DeviceLinkFlow {
    /// Browses for the link service until the calling task is cancelled. The first browse shows the
    /// system's local-network prompt, so running this while the link sheet is open gets the prompt
    /// answered before the scan. If it first appeared mid-connection, that scan was lost and had to be redone.
    public nonisolated static func askForLocalNetwork() async {
        let browser = NWBrowser(for: .bonjour(type: DeviceLinkConnection.serviceType, domain: nil), using: .tcp)
        browser.start(queue: .global())
        defer { browser.cancel() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

/// One TCP connection between the two devices, found by Bonjour, carrying length-prefixed messages.
/// It closes itself when the offer expires.
final class DeviceLinkConnection: Sendable {
    /// Declared as `NSBonjourServices` in each app's Info.plist.
    static let serviceType = "_oochat-link._tcp"
    /// The Receiving Device's last message: its person accepted the Identity.
    static let accepted = Data([1])
    /// The Giving Device's reply to a key that failed the Link Code or QR check.
    static let wrongCode = Data([2])
    /// How long the scanning side looks for the displaying device before it reports it can't be found.
    /// Bonjour on one network answers in about a second; this leaves room for the local-network prompt.
    static let findTimeout: TimeInterval = 30
    private static let queue = DispatchQueue(label: "ConnectOnionKit.DeviceLink")
    private static let maximumMessageLength = 64 * 1024
    private static let log = Logger(subsystem: "ai.openonion.ConnectOnionKit", category: "DeviceLink")

    private let connection: NWConnection
    private let deadline: ContinuousClock.Instant

    private init(_ connection: NWConnection, deadline: ContinuousClock.Instant) {
        self.connection = connection
        self.deadline = deadline
    }

    /// The displaying side advertises `offer.serviceName` until the first connection, expiry or cancel,
    /// and never takes a second connection. The scanning side resolves that name and connects.
    static func open(_ offer: DeviceLinkOffer, as role: DeviceLinkRole, now: () -> Date) async throws -> DeviceLinkConnection {
        let seconds = offer.expiry.timeIntervalSince(now())
        guard seconds > 0 else { throw DeviceLinkError.expired }
        let deadline = ContinuousClock.now + .seconds(seconds)
        let displaying = offer.displayer == role
        let connection = displaying
            ? try await firstConnection(advertising: offer.serviceName, for: seconds)
            : NWConnection(to: .service(name: offer.serviceName, type: serviceType, domain: "local.", interface: nil), using: .tcp)
        let remaining = { (deadline - ContinuousClock.now) / .seconds(1) }
        // A scanning side that can't find the displaying device within `findTimeout` reports a timeout,
        // which the person sees as "not on the same network", rather than waiting out the whole offer.
        let timeout: (any Error) = displaying ? DeviceLinkError.expired : NWError.posix(.ETIMEDOUT)
        try await once(within: displaying ? remaining() : min(remaining(), findTimeout), timeout: timeout,
                       onFailure: { connection.cancel() }, start: { gate in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case .failed(let error): gate.finish(.failure(error))
                case .waiting(let error):
                    // A waiting connection only retries on a path change. On Wi-Fi that drops or delays
                    // multicast, the first Bonjour lookup misses, so look again each second until the timeout.
                    log.info("Device link waiting: \(error.debugDescription, privacy: .public)")
                    gate.wait(error)
                    queue.asyncAfter(deadline: .now() + 1) {
                        if case .waiting = connection.state { connection.restart() }
                    }
                default: break
                }
            }
            connection.start(queue: queue)
        })
        queue.asyncAfter(deadline: .now() + remaining()) { connection.cancel() }
        return DeviceLinkConnection(connection, deadline: deadline)
    }

    private static func firstConnection(advertising name: String, for seconds: TimeInterval) async throws -> NWConnection {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: name, type: serviceType)
        defer { listener.cancel() }
        return try await once(within: seconds, timeout: DeviceLinkError.expired, onFailure: { listener.cancel() }, start: { gate in
            listener.newConnectionHandler = { connection in
                if !gate.finish(.success(connection)) { connection.cancel() }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.wait(nil)
                case .failed(let error): gate.finish(.failure(error))
                case .waiting(let error): gate.wait(error)
                default: break
                }
            }
            listener.start(queue: queue)
        })
    }

    /// Runs the exchange, turning a cancelled task into `.cancelled` and a cut at the deadline into `.expired`.
    func run<T>(_ exchange: () async throws -> T) async throws -> T {
        do {
            return try await withTaskCancellationHandler(operation: exchange, onCancel: { self.cancel() })
        } catch let error as DeviceLinkError {
            throw error
        } catch {
            if Task.isCancelled { throw DeviceLinkError.cancelled }
            if ContinuousClock.now >= deadline { throw DeviceLinkError.expired }
            throw error
        }
    }

    func send(_ message: Data) async throws {
        let length = UInt32(message.count)
        let frame = Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) }) + message
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        let length = try await read(4).reduce(0) { $0 << 8 | Int($1) }
        guard (1...Self.maximumMessageLength).contains(length) else { throw DeviceLinkError.malformed }
        return try await read(length)
    }

    func cancel() {
        connection.cancel()
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    // The other device hung up: its person closed the sheet or declined.
                    continuation.resume(throwing: DeviceLinkError.cancelled)
                }
            }
        }
    }

    /// Waits for the first of: `start`'s gate reporting a result, the timeout, or the task being cancelled.
    /// Anything after the first is ignored. At the timeout, the last error Network.framework reported while
    /// waiting wins over `timeout`: that is how a refused local-network permission shows up.
    private static func once<T: Sendable>(
        within seconds: TimeInterval,
        timeout: any Error,
        onFailure: @escaping @Sendable () -> Void,
        start: (OnceGate<T>) -> Void
    ) async throws -> T {
        let gate = OnceGate<T>(onFailure: onFailure)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(continuation)
                start(gate)
                queue.asyncAfter(deadline: .now() + seconds) { gate.finish(.failure(gate.waitingError ?? timeout)) }
            }
        } onCancel: {
            gate.finish(.failure(DeviceLinkError.cancelled))
        }
    }
}

/// Resumes a continuation exactly once, even if the result arrives before the continuation does.
final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let onFailure: @Sendable () -> Void
    private var continuation: CheckedContinuation<T, any Error>?
    private var result: Result<T, any Error>?
    private var lastWaitingError: (any Error)?

    init(onFailure: @escaping @Sendable () -> Void) {
        self.onFailure = onFailure
    }

    func attach(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let result { continuation.resume(with: result) } else { self.continuation = continuation }
    }

    /// Network.framework is waiting rather than failing: it may still recover (for example once the person
    /// answers the local-network prompt), so this is only remembered for the timeout. Nil once it is ready again,
    /// so a code that later simply expires is reported as expired.
    func wait(_ error: (any Error)?) {
        lock.withLock { lastWaitingError = error }
    }

    var waitingError: (any Error)? {
        lock.withLock { lastWaitingError }
    }

    @discardableResult
    func finish(_ result: Result<T, any Error>) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        if case .failure = result { onFailure() }
        continuation?.resume(with: result)
        return true
    }
}
