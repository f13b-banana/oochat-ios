import Combine
import ConnectOnionKit
import Foundation
import XCTest
@testable import OOChatIOS

@MainActor
final class DashboardSnapshotTests: XCTestCase {
    private let agentAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func testTheViewModelHoldsTheSecondOfTwoSnapshots() throws {
        let (viewModel, transport) = try makeViewModel()
        let conversationID = try makeConversation(in: viewModel)

        transport.simulateDashboard("<p>one</p>", conversationID: conversationID)
        XCTAssertEqual(viewModel.activeDashboard, .page(html: "<p>one</p>"))
        transport.simulateDashboard("<p>two</p>", conversationID: conversationID)

        XCTAssertEqual(viewModel.activeDashboard, .page(html: "<p>two</p>"))
    }

    func testAnIdenticalSnapshotCausesNoChange() throws {
        let (viewModel, transport) = try makeViewModel()
        let conversationID = try makeConversation(in: viewModel)
        var changes = 0
        let cancellable = viewModel.$dashboards
            .dropFirst()
            .sink { _ in changes += 1 }

        transport.simulateDashboard("<p>same</p>", conversationID: conversationID)
        transport.simulateDashboard("<p>same</p>", conversationID: conversationID)
        transport.simulateDashboard("<p>same</p>", conversationID: conversationID)

        XCTAssertEqual(changes, 1)
        XCTAssertEqual(viewModel.activeDashboard, .page(html: "<p>same</p>"))
        withExtendedLifetime(cancellable) {}
    }

    func testTheLastPageStaysWhileReconnectingAndASnapshotOnReattachReplacesIt() throws {
        let (viewModel, transport) = try makeViewModel()
        let conversationID = try makeConversation(in: viewModel)
        transport.simulateDashboard("<p>first</p>", conversationID: conversationID)

        transport.simulateConnectionState(.disconnected, conversationID: conversationID)
        transport.simulateConnectionState(.reconnecting, conversationID: conversationID)
        XCTAssertEqual(viewModel.activeDashboard, .page(html: "<p>first</p>"), "kept until the new one arrives")

        transport.simulateConnectionState(.connected, conversationID: conversationID)
        transport.simulateDashboard("<p>after reattach</p>", conversationID: conversationID)

        XCTAssertEqual(viewModel.activeDashboard, .page(html: "<p>after reattach</p>"))
    }

    func testEachConversationKeepsItsOwnPageAndDeletingOneForgetsIt() throws {
        let (viewModel, transport) = try makeViewModel()
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Dashboard Agent", address: agentAddress))
        _ = viewModel.createConversation(for: agent)
        let first = try XCTUnwrap(viewModel.activeConversation)
        _ = viewModel.createConversation(for: agent)
        let second = try XCTUnwrap(viewModel.activeConversation)
        XCTAssertNotEqual(first.id, second.id)

        transport.simulateDashboard("<p>for first</p>", conversationID: first.id)
        transport.simulateDashboard("<p>for second</p>", conversationID: second.id)
        XCTAssertEqual(viewModel.activeDashboard, .page(html: "<p>for second</p>"))

        viewModel.deleteConversation(second)

        XCTAssertNil(viewModel.dashboards[second.id])
        XCTAssertEqual(viewModel.dashboards[first.id], .page(html: "<p>for first</p>"))
    }

    func testAPageOverTheCapIsHeldAsTooLarge() throws {
        let (viewModel, transport) = try makeViewModel()
        let conversationID = try makeConversation(in: viewModel)
        let huge = String(repeating: "a", count: OIPDashboard.clientCapBytes + 1)

        transport.simulateDashboard(huge, conversationID: conversationID)
        XCTAssertEqual(viewModel.activeDashboard, .tooLarge(bytes: OIPDashboard.clientCapBytes + 1))

        transport.simulateDashboard("<p>small</p>", conversationID: conversationID)
        XCTAssertEqual(viewModel.activeDashboard, .page(html: "<p>small</p>"))
    }

    // MARK: observer and connection

    func testObserverKeepsOnlyTheNewestPageOfABurst() async {
        let observer = HostedAgentConnectionStateObserver()
        let delivered = expectation(description: "newest page delivered")
        var pages: [OIPDashboard] = []
        observer.updateHandler = { _, update in
            if case .dashboard(let page) = update {
                pages.append(page)
            }
            delivered.fulfill()
        }

        observer.notify(conversationID: "conversation", update: .dashboard(OIPDashboard(html: "<p>old</p>")))
        observer.notify(conversationID: "conversation", update: .dashboard(OIPDashboard(html: "<p>new</p>")))
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(pages, [.page(html: "<p>new</p>")])
    }

    func testSnapshotFramesReachTheCallbackAndAnotherSessionsAreDropped() async throws {
        let factory = MockHostedAgentSocketFactory()
        let observer = HostedAgentConnectionStateObserver()
        let delivered = expectation(description: "page delivered")
        var received: [(conversationID: String, page: OIPDashboard)] = []
        observer.updateHandler = { conversationID, update in
            if case .dashboard(let page) = update {
                received.append((conversationID, page))
                delivered.fulfill()
            }
        }
        let connection = try makeConnection(factory: factory, observer: observer)
        let conversation = makeConversationValue(id: "test-conversation")

        let connectTask = Task {
            try await connection.ensureConnected(conversation: conversation)
        }
        let socket = try await factory.socket(at: 0)
        _ = try await socket.waitForSentFrame(type: "CONNECT")
        try socket.enqueueFrame([
            "type": .string("CONNECTED"),
            "status": .string("new"),
            "session_id": .string("session-1")
        ])
        _ = try await connectTask.value

        try socket.enqueueFrame([
            "type": .string("DASHBOARD_SNAPSHOT"),
            "html": .string("<p>theirs</p>"),
            "session_id": .string("someone-else")
        ])
        try socket.enqueueFrame([
            "type": .string("DASHBOARD_SNAPSHOT"),
            "html": .string("<p>mine</p>"),
            "session_id": .string("session-1")
        ])
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(received.map(\.page), [.page(html: "<p>mine</p>")])
        XCTAssertEqual(received.first?.conversationID, "test-conversation")
        await connection.close()
    }

    // MARK: helpers

    private func makeViewModel() throws -> (ChatViewModel, MockAgentTransport) {
        let suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        let transport = MockAgentTransport()
        let viewModel = ChatViewModel(store: store, client: transport, networkMonitor: MockNetworkMonitor())
        return (viewModel, transport)
    }

    private func makeConversation(in viewModel: ChatViewModel) throws -> String {
        let agent = try XCTUnwrap(viewModel.saveAgent(name: "Dashboard Agent", address: agentAddress))
        _ = viewModel.createConversation(for: agent)
        return try XCTUnwrap(viewModel.activeConversation).id
    }

    private func makeConversationValue(id: String) -> Conversation {
        Conversation(
            id: id,
            title: "Test",
            agentID: "agent-id",
            agentAddress: agentAddress,
            mode: .safe,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            messages: [],
            serverSession: nil
        )
    }

    private func makeConnection(
        factory: MockHostedAgentSocketFactory,
        observer: HostedAgentConnectionStateObserver
    ) throws -> HostedAgentConnection {
        let endpoint = ResolvedEndpoint(
            wsURL: try XCTUnwrap(URL(string: "ws://unit.test/ws")),
            kind: .direct,
            label: "Unit Test Agent"
        )
        return HostedAgentConnection(
            key: HostedAgentConnectionKey(agentAddress: agentAddress, conversationID: "test-conversation"),
            identityStore: IdentityStore(),
            session: .shared,
            discovery: HostedAgentDiscovery(session: .shared, relayURL: "ws://unused.test", localEndpoints: []),
            connectionStateObserver: observer,
            socketFactory: factory.factory,
            endpointResolver: { _ in endpoint },
            connectTimeout: 1,
            livenessTimeout: 5,
            livenessCheckInterval: 0.1,
            resumeAttemptLimit: 0,
            resumeRetryDelay: 0,
            bookmarkStore: HostedAgentBookmarkStore(suiteName: "test.bookmarks.\(UUID().uuidString)")
        )
    }
}
