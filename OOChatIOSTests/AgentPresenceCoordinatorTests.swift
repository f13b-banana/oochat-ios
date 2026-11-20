import XCTest
@testable import OOChatIOS

@MainActor
final class AgentPresenceCoordinatorTests: XCTestCase {
    private struct TestEnvironment {
        let viewModel: ChatViewModel
        let transport: MockAgentTransport
        let monitor: MockNetworkMonitor
    }

    private let address = "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    func testOnlineCountTracksBackgroundConnectionLiveness() throws {
        let environment = try makeEnvironment()
        let viewModel = environment.viewModel
        let transport = environment.transport
        let firstAgent = setUpAgentAndConversation(viewModel)
        let firstConversation = viewModel.activeConversation!
        let secondAddress = "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        let secondAgent = viewModel.saveAgent(name: "Second", address: secondAddress)!
        _ = viewModel.createConversation(for: secondAgent)

        transport.simulateConnectionState(.connected, conversationID: firstConversation.id)

        XCTAssertEqual(viewModel.activeAgentID, secondAgent.id)
        XCTAssertTrue(viewModel.isAgentOnline(firstAgent))
        XCTAssertFalse(viewModel.isAgentOnline(secondAgent))
        XCTAssertEqual(viewModel.onlineAgentCount, 1)

        transport.simulateConnectionState(.disconnected, conversationID: firstConversation.id)

        XCTAssertFalse(viewModel.isAgentOnline(firstAgent))
        XCTAssertEqual(viewModel.onlineAgentCount, 0)
    }

    func testPresencePollingMarksAgentOnlineWithoutOpeningConversationSocket() async throws {
        let environment = try makeEnvironment()
        let viewModel = environment.viewModel
        let transport = environment.transport
        let monitor = environment.monitor
        viewModel.presenceInterval = 0.01
        let agent = setUpAgentAndConversation(viewModel)
        let checksBeforeRefresh = transport.checkedAvailabilityAddresses.count
        transport.agentAvailabilityByAddress[agent.address] = .online

        monitor.simulate(online: true)
        await waitForAvailabilityCheck(
            on: transport,
            address: agent.address,
            minimumCount: checksBeforeRefresh + 1
        )

        XCTAssertTrue(viewModel.isAgentOnline(agent))
        XCTAssertTrue(viewModel.isActiveAgentOnline)
        XCTAssertEqual(viewModel.onlineAgentCount, 1)
        XCTAssertTrue(transport.connectedAddresses.isEmpty)
        XCTAssertEqual(viewModel.connectionState, .disconnected)
    }

    func testUnknownPresenceKeepsLastKnownAvailabilityAndOfflineClearsIt() async throws {
        let environment = try makeEnvironment()
        let viewModel = environment.viewModel
        let transport = environment.transport
        let monitor = environment.monitor
        viewModel.presenceInterval = 0.01
        let agent = setUpAgentAndConversation(viewModel)
        let checksBeforeRefresh = transport.checkedAvailabilityAddresses.count
        transport.agentAvailabilityByAddress[agent.address] = .online

        monitor.simulate(online: true)
        await waitForAvailabilityCheck(
            on: transport,
            address: agent.address,
            minimumCount: checksBeforeRefresh + 1
        )
        XCTAssertTrue(viewModel.isAgentOnline(agent))

        transport.agentAvailabilityByAddress[agent.address] = .unknown
        let checksBeforeUnknown = transport.checkedAvailabilityAddresses.count
        await waitForAvailabilityCheck(
            on: transport,
            address: agent.address,
            minimumCount: checksBeforeUnknown + 1
        )
        XCTAssertTrue(viewModel.isAgentOnline(agent))

        monitor.simulate(online: false)
        XCTAssertFalse(viewModel.isAgentOnline(agent))
        XCTAssertEqual(viewModel.onlineAgentCount, 0)
    }

    func testPresencePollingStopsInBackgroundAndResumesOnForeground() async throws {
        let environment = try makeEnvironment()
        let viewModel = environment.viewModel
        let transport = environment.transport
        let monitor = environment.monitor
        viewModel.presenceInterval = 0.01
        let agent = setUpAgentAndConversation(viewModel)
        transport.agentAvailabilityByAddress[agent.address] = .online

        monitor.simulate(online: true)
        await waitForAvailabilityCheck(on: transport, address: agent.address)
        let checksBeforeBackground = transport.checkedAvailabilityAddresses.count

        viewModel.handleScenePhaseChange(.background)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            transport.checkedAvailabilityAddresses.count,
            checksBeforeBackground,
            "backgrounded scenes must not keep polling"
        )

        viewModel.handleScenePhaseChange(.active)
        await waitForAvailabilityCheck(
            on: transport,
            address: agent.address,
            minimumCount: checksBeforeBackground + 1
        )
    }

    func testDeletingAgentPrunesItsPresenceAndAddingAgentRefreshesIt() async throws {
        let environment = try makeEnvironment()
        let viewModel = environment.viewModel
        let transport = environment.transport
        let monitor = environment.monitor
        viewModel.presenceInterval = 0.01
        let firstAgent = setUpAgentAndConversation(viewModel)
        let firstChecksBeforeRefresh = transport.checkedAvailabilityAddresses.count
        transport.agentAvailabilityByAddress[firstAgent.address] = .online
        monitor.simulate(online: true)
        await waitForAvailabilityCheck(
            on: transport,
            address: firstAgent.address,
            minimumCount: firstChecksBeforeRefresh + 1
        )
        XCTAssertEqual(viewModel.onlineAgentCount, 1)

        let secondAddress = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        transport.agentAvailabilityByAddress[secondAddress] = .online
        let secondChecksBeforeRefresh = transport.checkedAvailabilityAddresses.filter {
            $0 == secondAddress
        }.count
        let secondAgent = viewModel.saveAgent(name: "Second", address: secondAddress)!
        _ = viewModel.createConversation(for: secondAgent)
        await waitForAvailabilityCheck(
            on: transport,
            address: secondAddress,
            minimumCount: secondChecksBeforeRefresh + 1
        )
        XCTAssertTrue(viewModel.isAgentOnline(secondAgent))

        viewModel.deleteAgent(firstAgent)
        XCTAssertFalse(viewModel.isAgentOnline(firstAgent))
        XCTAssertEqual(viewModel.onlineAgentCount, 1)
    }

    func testEditingAgentAddressDropsOldSocketStateAndRefreshesNewAddress() async throws {
        let environment = try makeEnvironment()
        let viewModel = environment.viewModel
        let transport = environment.transport
        let monitor = environment.monitor
        viewModel.presenceInterval = 0.01
        let agent = setUpAgentAndConversation(viewModel)
        let conversationID = viewModel.activeConversation!.id
        let firstChecksBeforeRefresh = transport.checkedAvailabilityAddresses.count
        transport.agentAvailabilityByAddress[agent.address] = .online
        monitor.simulate(online: true)
        await waitForAvailabilityCheck(
            on: transport,
            address: agent.address,
            minimumCount: firstChecksBeforeRefresh + 1
        )
        transport.simulateConnectionState(.connected, conversationID: conversationID)
        XCTAssertTrue(viewModel.isAgentOnline(agent))

        let replacementAddress = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        transport.agentAvailabilityByAddress[replacementAddress] = .online
        let replacementChecksBeforeRefresh = transport.checkedAvailabilityAddresses.filter {
            $0 == replacementAddress
        }.count
        let editedAgent = viewModel.saveAgent(
            id: agent.id,
            name: agent.name,
            address: replacementAddress
        )!

        XCTAssertEqual(viewModel.connectionState, .disconnected)
        await waitForAvailabilityCheck(
            on: transport,
            address: replacementAddress,
            minimumCount: replacementChecksBeforeRefresh + 1
        )
        XCTAssertTrue(viewModel.isAgentOnline(editedAgent))
        XCTAssertFalse(viewModel.isAgentOnline(agent))
    }

    /// header gets label from socket state and last status
    func testHeaderStatusFollowsTheSocketAndTheHost() throws {
        let environment = try makeEnvironment()
        let viewModel = environment.viewModel
        let transport = environment.transport
        setUpAgentAndConversation(viewModel)
        let conversationID = try XCTUnwrap(viewModel.activeConversationID)

        XCTAssertEqual(viewModel.activeSessionStatusText, "Not Connected")

        transport.simulateConnectionState(.reconnecting, conversationID: conversationID)

        XCTAssertEqual(viewModel.activeSessionStatusText, "Connecting")

        transport.simulateConnectionState(.connected, conversationID: conversationID)
        viewModel.apply(.hostStatus("running"), forConversationID: conversationID)

        XCTAssertEqual(viewModel.activeSessionStatusText, "Running")
        XCTAssertTrue(viewModel.isActiveSessionLive)

        transport.simulateConnectionState(.reconnecting, conversationID: conversationID)

        XCTAssertEqual(viewModel.activeSessionStatusText, "Reconnecting")

        transport.simulateConnectionState(.connected, conversationID: conversationID)
        viewModel.apply(.hostStatus("not_found"), forConversationID: conversationID)

        XCTAssertEqual(viewModel.activeSessionStatusText, "Ended")
        XCTAssertFalse(viewModel.isActiveSessionLive)
    }

    func testDashboardIsKeptPerConversation() throws {
        let environment = try makeEnvironment()
        let viewModel = environment.viewModel
        setUpAgentAndConversation(viewModel)
        let conversationID = try XCTUnwrap(viewModel.activeConversationID)

        XCTAssertNil(viewModel.activeDashboard)

        viewModel.apply(.dashboard(.page(html: "<p>hi</p>")), forConversationID: "another-conversation")

        XCTAssertNil(viewModel.activeDashboard)

        viewModel.apply(.dashboard(.tooLarge(bytes: 20)), forConversationID: conversationID)

        XCTAssertEqual(viewModel.activeDashboard, .tooLarge(bytes: 20))
    }

    private func makeEnvironment() throws -> TestEnvironment {
        let suiteName = "OOChatIOSTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = try SwiftDataConversationRepository(inMemory: true, defaults: defaults)
        let transport = MockAgentTransport()
        let monitor = MockNetworkMonitor()
        let viewModel = ChatViewModel(store: store, client: transport, networkMonitor: monitor)
        return TestEnvironment(viewModel: viewModel, transport: transport, monitor: monitor)
    }

    private func waitForAvailabilityCheck(
        on transport: MockAgentTransport,
        address: String,
        minimumCount: Int = 1
    ) async {
        for _ in 0..<200 {
            if transport.checkedAvailabilityAddresses.filter({ $0 == address }).count >= minimumCount {
                await Task.yield()
                await Task.yield()
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for an availability check for \(address)")
    }

    @discardableResult
    private func setUpAgentAndConversation(_ viewModel: ChatViewModel) -> SavedAgent {
        let agent = viewModel.saveAgent(name: "Presence Agent", address: address)!
        _ = viewModel.createConversation(for: agent)
        return agent
    }
}
