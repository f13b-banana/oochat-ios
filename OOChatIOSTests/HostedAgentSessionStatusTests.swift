import ConnectOnionKit
import Foundation
import XCTest
@testable import OOChatIOS

// N1.5: socket size and DASHBOARD_SNAPSHOT.
extension HostedAgentConnectionTests {
    func testDefaultSocketAcceptsTheHostsLargestMessage() async throws {
        let connection = HostedAgentConnection(
            key: HostedAgentConnectionKey(agentAddress: agentAddress, conversationID: "size"),
            identityStore: IdentityStore(),
            session: .shared,
            discovery: HostedAgentDiscovery(session: .shared, relayURL: "ws://unused.test", localEndpoints: []),
            connectionStateObserver: HostedAgentConnectionStateObserver()
        )

        let url = try XCTUnwrap(URL(string: "ws://unit.test/ws"))
        let makeSocket = await connection.socketFactory
        let task = try XCTUnwrap(makeSocket(url) as? URLSessionWebSocketTask)

        defer { task.cancel() }

        XCTAssertEqual(task.maximumMessageSize, OIPDashboard.socketMessageBytes)
    }

    func testDashboardSnapshotReachesTheAppAndAnOversizedOneIsTooLarge() async throws {
        let factory = MockHostedAgentSocketFactory()
        let recorder = SessionUpdateRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer)

        _ = try await establish(connection, conversation: makeConversation(id: "dashboard"), factory: factory)

        let socket = try await factory.socket(at: 0)

        try socket.enqueueFrame(["type": .string("DASHBOARD_SNAPSHOT"), "html": .string("<h1>Hi</h1>")])
        try await recorder.wait { $0.contains(.dashboard(.page(html: "<h1>Hi</h1>"))) }

        let oversized = String(repeating: "a", count: OIPDashboard.clientCapBytes + 1)

        try socket.enqueueFrame(["type": .string("DASHBOARD_SNAPSHOT"), "html": .string(oversized)])

        try await recorder.wait(timeout: 10) { $0.contains(.dashboard(.tooLarge(bytes: OIPDashboard.clientCapBytes + 1))) }

        let isConnected = await connection.state == .connected

        XCTAssertTrue(isConnected, "a big page must not drop the chat")

        await connection.close()
    }

    func testRunningSessionIsPolledUntilTheHostSaysOtherwise() async throws {
        let factory = MockHostedAgentSocketFactory()

        let recorder = SessionUpdateRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer, statusPollInterval: 0.02)

        let connect = Task {
            try await connection.ensureConnected(conversation: makeConversation(id: "poll"))
        }

        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame(["type": .string("CONNECTED"), "status": .string("running"), "session_id": .string("poll")])
        _ = try await connect.value

        let first = try await socket.waitForSentFrame(type: "SESSION_STATUS")

        XCTAssertEqual(first["session"], .object(["session_id": .string("poll")]))
        XCTAssertNil(first["signature"], "SESSION_STATUS on a live socket is unsigned")

        try socket.enqueueFrame(["type": .string("SESSION_STATUS"), "session_id": .string("poll"), "status": .string("running")])
        _ = try await socket.waitForSentFrame(type: "SESSION_STATUS", occurrence: 2)

        try socket.enqueueFrame(["type": .string("SESSION_STATUS"), "session_id": .string("poll"), "status": .string("not_found")])

        try await recorder.wait { $0.last == .hostStatus("not_found") }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(try socket.sentFrames().filter { $0["type"]?.stringValue == "SESSION_STATUS" }.count, 2)

        await connection.close()
    }

    func testOwnPromptShowsRunningWithoutPolling() async throws {
        let factory = MockHostedAgentSocketFactory()

        let recorder = SessionUpdateRecorder()
        let connection = makeConnection(factory: factory, observer: recorder.observer, statusPollInterval: 0.02)
        let conversation = makeConversation(id: "own-run")
        _ = try await establish(connection, conversation: conversation, factory: factory)

        let socket = try await factory.socket(at: 0)

        let prompt = Task {
            try await connection.sendPrompt(conversation: conversation, prompt: "hi", onEvent: nil, onInteraction: nil)
        }
        _ = try await socket.waitForSentFrame(type: "INPUT")

        try await recorder.wait { $0.last == .hostStatus("running") }
        try socket.enqueueFrame(["type": .string("OUTPUT"), "result": .string("done")])
        _ = try await prompt.value
        try await recorder.wait { $0.last == .hostStatus("connected") }

        XCTAssertTrue(try socket.sentFrames().filter { $0["type"]?.stringValue == "SESSION_STATUS" }.isEmpty)

        await connection.close()
    }
}

/// observer session updates
@MainActor
private final class SessionUpdateRecorder {
    let observer = HostedAgentConnectionStateObserver()

    private(set) var updates: [HostedAgentSessionUpdate] = []

    init() {
        observer.updateHandler = { [weak self] _, update in
            self?.updates.append(update)
        }
    }

    func wait(timeout: TimeInterval = 1, until condition: ([HostedAgentSessionUpdate]) -> Bool) async throws {

        let deadline = Date().addingTimeInterval(timeout)

        while !condition(updates) {
            guard Date() < deadline else {
                throw HostedAgentTestError.timedOut
            }

            try await Task.sleep(nanoseconds: 2000000)
        }
    }
}
