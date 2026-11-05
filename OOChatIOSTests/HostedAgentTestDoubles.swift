import ConnectOnionKit
import Foundation
import XCTest
@testable import OOChatIOS

actor PromptGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class MockNetworkMonitor: NetworkPathMonitoring {
    var onUpdate: (@MainActor (Bool) -> Void)?
    private(set) var started = false
    private(set) var cancelled = false

    func start() {
        started = true
    }

    func cancel() {
        cancelled = true
    }

    @MainActor
    func simulate(online: Bool) {
        onUpdate?(online)
    }
}

final class MockAgentTransport: HostedAgentTransport {
    enum Behavior {
        case succeed(output: String)
        case fail(Error)
        case wait(gate: PromptGate, output: String)
        case waitThenFail(gate: PromptGate, error: Error)
        case waitUntilCancelled
    }

    var connectBehavior: Behavior = .succeed(output: "")
    var sendBehavior: Behavior = .succeed(output: "mock reply")
    var onConnectionStateChange: (@MainActor (String, ConversationConnectionState) -> Void)?
    var sendBehaviorsByPrompt: [String: Behavior] = [:]
    var streamedEvents: [HostedAgentEvent] = []
    var approvalRequests: [ToolApprovalRequest] = []
    var ulwCheckpoints: [UlwCheckpointRequest] = []
    var planReviews: [PlanReviewRequest] = []
    var askUserRequests: [AskUserRequest] = []
    var availableSkills: [AgentSkill] = []
    var skillsByAddress: [String: [AgentSkill]] = [:]
    var agentNamesByAddress: [String: String] = [:]
    var agentAvailabilityByAddress: [String: AgentAvailability] = [:]
    var defaultAgentAvailability: AgentAvailability = .unknown
    var skillFetchError: Error?
    var onSend: (@MainActor () -> Void)?
    var waitAfterInteractionsUntilCancelled = false
    // What the host says about a prompt sent before a relaunch. Fails by default, so a test
    // that never expects a resume notices one.
    var resumeBehavior: Behavior = .fail(HostedAgentClientError.outcomeUnknown)

    private(set) var networkLossNotices = 0
    private(set) var connectedAddresses: [String] = []
    private(set) var sentPrompts: [String] = []
    private(set) var resumedPrompts: [String] = []
    private(set) var sentImages: [[String]] = []
    private(set) var sentFiles: [[HostedAgentFilePayload]] = []
    private(set) var approvalDecisions: [ApprovalDecision] = []
    private(set) var ulwDecisions: [UlwCheckpointDecision] = []
    private(set) var planReviewDecisions: [PlanReviewDecision] = []
    private(set) var askUserDecisions: [AskUserDecision] = []
    private(set) var fetchedSkillAddresses: [String] = []
    private(set) var fetchedNameAddresses: [String] = []
    private(set) var checkedAvailabilityAddresses: [String] = []
    private(set) var interactionResponseWaits: [(agentAddress: String, conversationID: String)] = []

    func connect(agentAddress: String, conversation: Conversation) async throws -> HostedAgentResult {
        connectedAddresses.append(agentAddress)
        switch connectBehavior {
        case .succeed:
            return HostedAgentResult(
                output: nil,
                endpointLabel: "mock",
                serverSession: ["session_id": .string(conversation.id)]
            )
        case .fail(let error):
            throw error
        case .wait(let gate, _):
            await gate.wait()
            return HostedAgentResult(
                output: nil,
                endpointLabel: "mock",
                serverSession: ["session_id": .string(conversation.id)]
            )
        case .waitThenFail(let gate, let error):
            await gate.wait()
            throw error
        case .waitUntilCancelled:
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    func fetchSkills(agentAddress: String) async throws -> [AgentSkill] {
        fetchedSkillAddresses.append(agentAddress)
        if let skillFetchError {
            throw skillFetchError
        }
        return skillsByAddress[agentAddress] ?? availableSkills
    }

    func fetchAgentName(agentAddress: String) async throws -> String? {
        fetchedNameAddresses.append(agentAddress)
        return agentNamesByAddress[agentAddress]
    }

    func checkAgentAvailability(agentAddress: String) async -> AgentAvailability {
        checkedAvailabilityAddresses.append(agentAddress)
        return agentAvailabilityByAddress[agentAddress] ?? defaultAgentAvailability
    }

    func sendPrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: HostedAgentPrompt,
        handlers: HostedAgentPromptHandlers
    ) async throws -> HostedAgentResult {
        sentPrompts.append(prompt.text)
        sentImages.append(prompt.images)
        sentFiles.append(prompt.files)
        // The real connection reports the dispatch before the INPUT leaves.
        if let onInputDispatched = handlers.onInputDispatched {
            await onInputDispatched()
        }
        let output = try await output(for: sendBehaviorsByPrompt[prompt.text] ?? sendBehavior)
        try await replayInteractions(onInteraction: handlers.onInteraction)
        if waitAfterInteractionsUntilCancelled {
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        for event in streamedEvents {
            await handlers.onEvent?(event)
        }
        if let onSend {
            await MainActor.run { onSend() }
        }
        return HostedAgentResult(output: output, endpointLabel: "mock", serverSession: nil)
    }

    func resumePrompt(
        agentAddress: String,
        conversation: Conversation,
        prompt: HostedAgentPrompt,
        handlers: HostedAgentPromptHandlers
    ) async throws -> HostedAgentResult {
        resumedPrompts.append(prompt.text)
        let output = try await output(for: resumeBehavior)
        for event in streamedEvents {
            await handlers.onEvent?(event)
        }
        return HostedAgentResult(output: output, endpointLabel: "mock", serverSession: nil)
    }

    private func output(for behavior: Behavior) async throws -> String {
        switch behavior {
        case .succeed(let value):
            return value
        case .fail(let error):
            throw error
        case .wait(let gate, let value):
            await gate.wait()
            try Task.checkCancellation()
            return value
        case .waitThenFail(let gate, let error):
            await gate.wait()
            throw error
        case .waitUntilCancelled:
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    private func replayInteractions(
        onInteraction: (@MainActor (HostedAgentInteraction) async -> HostedAgentInteractionDecision)?
    ) async throws {
        for request in approvalRequests {
            guard let onInteraction,
                  case .approval(let decision) = await onInteraction(.approval(request)) else {
                throw HostedAgentClientError.badFrame
            }
            approvalDecisions.append(decision)
        }
        for checkpoint in ulwCheckpoints {
            guard let onInteraction,
                  case .ulwCheckpoint(let decision) = await onInteraction(.ulwCheckpoint(checkpoint)) else {
                throw HostedAgentClientError.badFrame
            }
            ulwDecisions.append(decision)
        }
        for review in planReviews {
            guard let onInteraction,
                  case .planReview(let decision) = await onInteraction(.planReview(review)) else {
                throw HostedAgentClientError.badFrame
            }
            planReviewDecisions.append(decision)
        }
        for request in askUserRequests {
            guard let onInteraction,
                  case .askUser(let decision) = await onInteraction(.askUser(request)) else {
                throw HostedAgentClientError.badFrame
            }
            askUserDecisions.append(decision)
        }
    }

    func noteNetworkLost() async {
        networkLossNotices += 1
    }

    func waitForPendingInteractionResponses(agentAddress: String, conversationID: String) async {
        interactionResponseWaits.append((agentAddress, conversationID))
        for _ in 0..<100 where approvalDecisions.isEmpty
            && ulwDecisions.isEmpty
            && planReviewDecisions.isEmpty
            && askUserDecisions.isEmpty {
            await Task.yield()
        }
    }

    var askUserAnswers: [String] {
        askUserDecisions.compactMap { decision in
            guard case .answer(let answer) = decision else {
                return nil
            }
            return answer
        }
    }

    @MainActor
    func simulateConnectionState(_ state: ConversationConnectionState, conversationID: String) {
        onConnectionStateChange?(conversationID, state)
    }
}

// Socket-level test doubles for HostedAgentConnection and HostedAgentConnectionPool tests.
// Moved out of HostedAgentConnectionTests.swift to keep that file under the file_length limit.

enum HostedAgentTestError: Error {
    case failed
    case cancelled
    case timedOut
}

final class MockHostedAgentWebSocket: HostedAgentWebSocketTask, @unchecked Sendable {
    typealias Message = URLSessionWebSocketTask.Message

    private let lock = NSLock()
    private var queuedReceives: [Result<Message, Error>] = []
    private var receiveContinuation: CheckedContinuation<Message, Error>?
    private var storedSentMessages: [Message] = []
    private var storedNextSendError: Error?
    private var storedRecordsFailedSend = false
    private var storedIsResumed = false
    private var storedCloseCode: URLSessionWebSocketTask.CloseCode?

    var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsResumed
    }

    var closeCode: URLSessionWebSocketTask.CloseCode? {
        lock.lock()
        defer { lock.unlock() }
        return storedCloseCode
    }

    func resume() {
        lock.lock()
        storedIsResumed = true
        lock.unlock()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let continuation: CheckedContinuation<Message, Error>?
        lock.lock()
        storedCloseCode = closeCode
        continuation = receiveContinuation
        receiveContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: HostedAgentTestError.cancelled)
    }

    func send(_ message: Message) async throws {
        if let error = recordSend(message) {
            throw error
        }
    }

    private func recordSend(_ message: Message) -> Error? {
        lock.lock()
        if let error = storedNextSendError {
            storedNextSendError = nil
            if storedRecordsFailedSend {
                storedRecordsFailedSend = false
                storedSentMessages.append(message)
            }
            lock.unlock()
            return error
        }
        storedSentMessages.append(message)
        lock.unlock()
        return nil
    }

    func receive() async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result = queuedReceives.first {
                queuedReceives.removeFirst()
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            if storedCloseCode != nil {
                lock.unlock()
                continuation.resume(throwing: HostedAgentTestError.cancelled)
                return
            }
            receiveContinuation = continuation
            lock.unlock()
        }
    }

    func failNextSend(with error: Error = HostedAgentTestError.failed, afterRecording: Bool = false) {
        lock.lock()
        storedNextSendError = error
        storedRecordsFailedSend = afterRecording
        lock.unlock()
    }

    func enqueueFrame(_ frame: [String: JSONValue], asData: Bool = false) throws {
        let data = try JSONEncoder().encode(frame)
        let message: Message
        if asData {
            message = .data(data)
        } else {
            message = .string(try XCTUnwrap(String(data: data, encoding: .utf8)))
        }
        enqueue(.success(message))
    }

    func enqueueText(_ text: String) {
        enqueue(.success(.string(text)))
    }

    func enqueueError(_ error: Error = HostedAgentTestError.failed) {
        enqueue(.failure(error))
    }

    func sentFrames() throws -> [[String: JSONValue]] {
        let messages: [Message]
        lock.lock()
        messages = storedSentMessages
        lock.unlock()

        return try messages.map { message in
            let data: Data
            switch message {
            case .string(let text):
                data = try XCTUnwrap(text.data(using: .utf8))
            case .data(let value):
                data = value
            @unknown default:
                throw HostedAgentTestError.failed
            }
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        }
    }

    func waitForSentFrame(
        type: String,
        occurrence: Int = 1,
        timeout: TimeInterval = 1
    ) async throws -> [String: JSONValue] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matching = try sentFrames().filter { $0["type"]?.stringValue == type }
            if matching.count >= occurrence {
                return matching[occurrence - 1]
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw HostedAgentTestError.timedOut
    }

    private func enqueue(_ result: Result<Message, Error>) {
        let continuation: CheckedContinuation<Message, Error>?
        lock.lock()
        continuation = receiveContinuation
        receiveContinuation = nil
        if continuation == nil {
            queuedReceives.append(result)
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

final class MockHostedAgentSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let configureSocket: @Sendable (MockHostedAgentWebSocket) -> Void
    private var storedSockets: [MockHostedAgentWebSocket] = []
    private var storedURLs: [URL] = []

    init(configureSocket: @escaping @Sendable (MockHostedAgentWebSocket) -> Void = { _ in }) {
        self.configureSocket = configureSocket
    }

    var factory: HostedAgentWebSocketFactory {
        { [weak self] url in
            guard let self else {
                return MockHostedAgentWebSocket()
            }
            let socket = MockHostedAgentWebSocket()
            self.configureSocket(socket)
            self.lock.lock()
            self.storedURLs.append(url)
            self.storedSockets.append(socket)
            self.lock.unlock()
            return socket
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSockets.count
    }

    func url(at index: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedURLs.indices.contains(index) ? storedURLs[index] : nil
    }

    func socket(at index: Int, timeout: TimeInterval = 1) async throws -> MockHostedAgentWebSocket {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let socket = storedSocket(at: index)
            if let socket {
                return socket
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw HostedAgentTestError.timedOut
    }

    private func storedSocket(at index: Int) -> MockHostedAgentWebSocket? {
        lock.lock()
        defer { lock.unlock() }
        return storedSockets.indices.contains(index) ? storedSockets[index] : nil
    }
}

final class MutableHostedAgentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date = Date(timeIntervalSince1970: 1_000)) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}

actor EndpointSequence {
    private var queue: [ResolvedEndpoint]

    init(_ endpoints: [ResolvedEndpoint]) {
        queue = endpoints
    }

    func next() -> ResolvedEndpoint {
        queue.count > 1 ? queue.removeFirst() : queue[0]
    }
}
