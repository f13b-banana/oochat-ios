import SwiftUI
import XCTest
@testable import OOChatIOS

@MainActor
final class ChatViewTests: XCTestCase {
    func testNoConversationShowsEmptyStateAndOpenSidebarAction() {
        let viewModel = makeContainerViewModel(agents: [], conversations: [])
        var openSidebarCount = 0
        let window = ViewHost.host(
            ChatView(viewModel: viewModel) {
                openSidebarCount += 1
            }
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "No Conversation", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Open sidebar", in: window))
        XCTAssertEqual(openSidebarCount, 1)
    }

    func testTimelineRendersMessagesAndToolGroupsWithoutComposer() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation(
            messages: [
                ChatMessage(id: "user1", role: .user, content: "Need a project summary"),
                ChatMessage(
                    id: "tool1",
                    role: .tool,
                    content: "",
                    toolName: "read_file",
                    toolArguments: ["path": .string("/tmp/notes.md")],
                    toolState: .completed
                ),
                ChatMessage(
                    id: "tool2",
                    role: .tool,
                    content: "",
                    toolName: "bash",
                    toolArguments: ["cmd": .string("swift test")],
                    toolState: .completed
                ),
                ChatMessage(id: "agent1", role: .agent, content: "Here is the summary.")
            ]
        )
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatView(viewModel: viewModel, showsComposer: false))

        XCTAssertNotNil(ViewHost.element(labelContains: "Container Chat", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Need a project summary", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Read a file and ran a command", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Here is the summary.", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Send message", in: window))
    }

    func testComposerRendersWhenEnabled() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatView(viewModel: viewModel))

        XCTAssertNotNil(ViewHost.element(labelContains: "Send message", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Chat mode: Auto", in: window))
    }

    /// toolbar reports Conversation's session, not agent
    func testToolbarShowsSessionStatusRatherThanAgentPresence() async {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let transport = MockAgentTransport()
        let monitor = MockNetworkMonitor()
        transport.agentAvailabilityByAddress[fixture.agent.address] = .online
        // The chat's own socket fails to open, so only presence says the agent is online.
        transport.connectBehavior = .fail(HostedAgentClientError.closed)
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id,
            client: transport,
            networkMonitor: monitor
        )
        let window = ViewHost.host(
            NavigationStack {
                ChatView(viewModel: viewModel)
            }
        )

        monitor.simulate(online: true)
        let deadline = Date().addingTimeInterval(1)
        while !viewModel.isActiveAgentOnline, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        ViewHost.pump()

        XCTAssertTrue(viewModel.isActiveAgentOnline)
        XCTAssertEqual(viewModel.connectionState, .disconnected)
        XCTAssertNotNil(
            ViewHost.element(labelContains: "Session status: Not Connected", in: window)
        )
    }

    // open chat opens socket for dashboard_snapshot
    func testShowingAChatConnectsItSoTheControlCenterCanArrive() async {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let transport = MockAgentTransport()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id,
            client: transport,
            networkMonitor: MockNetworkMonitor()
        )
        XCTAssertTrue(transport.connectedAddresses.isEmpty)

        _ = ViewHost.host(NavigationStack { ChatView(viewModel: viewModel) })
        let deadline = Date().addingTimeInterval(1)
        while viewModel.connectionState != .connected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(transport.connectedAddresses, [fixture.agent.address])
        XCTAssertEqual(viewModel.connectionState, .connected)
    }

    func testEmptyConversationShowsStartersAndPopulatesComposer() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatView(viewModel: viewModel))

        XCTAssertNotNil(ViewHost.element(labelContains: "Start with \(fixture.agent.name)", in: window))
        XCTAssertEqual(
            ChatStarterSuggestion.defaults.map(\.title),
            ["Plan a feature", "Review code", "Debug issue", "Explain project"]
        )

        for suggestion in ChatStarterSuggestion.defaults {
            viewModel.prompt = ""
            XCTAssertTrue(
                ViewHost.activateButton(labelContains: suggestion.title, in: window),
                "Expected starter button for \(suggestion.title)"
            )
            XCTAssertEqual(viewModel.prompt, suggestion.prompt)
        }
    }

    func testConversationWithMessagesDoesNotShowStarters() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation(
            messages: [
                ChatMessage(id: "user1", role: .user, content: "Review this change")
            ]
        )
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatView(viewModel: viewModel))

        XCTAssertNil(ViewHost.element(labelContains: "Start with \(fixture.agent.name)", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Plan a feature", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Review this change", in: window))
    }
}

@MainActor
final class ChatShellViewTests: XCTestCase {
    func testShellOpensSidebar() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatShellView(viewModel: viewModel))

        XCTAssertNotNil(ViewHost.element(labelContains: "Container Chat", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Open sidebar", in: window))
        ViewHost.pump(0.4)
        XCTAssertNotNil(ViewHost.element(labelContains: "Container Agent", in: window))
    }

    func testShellSettingsCanReturnToSidebar() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatShellView(viewModel: viewModel, startsInSettings: true))

        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Settings", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Reconnect", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: conversation.id, in: window))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Close", in: window))
        ViewHost.pump(0.4)
        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Container Agent", in: window))
    }

    func testShellSelectingActiveConversationFromOpenSidebarReturnsToChat() {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        let window = ViewHost.host(ChatShellView(viewModel: viewModel, startsSidebarOpen: true))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Container Chat", in: window))
        ViewHost.pump(0.4)

        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Send message", in: window))
    }
}

/// iPhone sized tests
@MainActor
final class ControlCenterTabsTests: XCTestCase {
    private func makeViewModel() -> (ChatViewModel, Conversation) {
        let fixture = ChatContainerFixture()
        let conversation = fixture.conversation()
        let viewModel = makeContainerViewModel(
            agents: [fixture.agent],
            conversations: [conversation],
            activeAgentID: fixture.agent.id,
            activeConversationID: conversation.id
        )
        return (viewModel, conversation)
    }

    func testNoSnapshotMeansNoSwitch() {
        let (viewModel, _) = makeViewModel()
        let window = ViewHost.host(ChatShellView(viewModel: viewModel))

        XCTAssertNotNil(ViewHost.element(labelContains: "Container Chat", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Control Center", in: window))
    }

    func testSwitchingTabsKeepsThePaneMountedAndTheDraft() {
        let (viewModel, conversation) = makeViewModel()
        viewModel.apply(.dashboard(.page(html: "<h1>Hi</h1>")), forConversationID: conversation.id)
        viewModel.prompt = "half-written thought"
        let window = ViewHost.host(ChatShellView(viewModel: viewModel))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Control Center", in: window))
        ViewHost.pump(0.2)
        // The kit's web view speaks as "Agent Control Center"; the buttons say "Open/Collapse Control Center".
        let webView = ViewHost.waitForElement(labelContains: "Agent Control Center", in: window)
        XCTAssertNotNil(webView)

        // "Chat" alone: other buttons, such as Add Chat, contain the word too.
        XCTAssertTrue(activateTab(named: "Chat", in: window))
        ViewHost.pump(0.2)
        window.layoutIfNeeded()
        XCTAssertEqual(viewModel.activeConversationID, conversation.id)
        XCTAssertTrue(
            ViewHost.element(labelContains: "Agent Control Center", in: window) === webView,
            "the pane is shown or hidden, never rebuilt"
        )
        XCTAssertEqual(viewModel.prompt, "half-written thought")

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Control Center", in: window))
        ViewHost.pump(0.2)
        XCTAssertTrue(ViewHost.element(labelContains: "Agent Control Center", in: window) === webView)
    }

    private func activateTab(named name: String, in window: UIWindow) -> Bool {
        guard let tab = ViewHost.accessibilityElements(in: window).first(where: { $0.accessibilityLabel == name }) else {
            return false
        }
        let activated = tab.accessibilityActivate()
        ViewHost.pump()
        return activated
    }
}

final class ControlCenterLayoutTests: XCTestCase {
    // contentWidth is the window less the 320-point sidebar and its divider.
    func testPaneFitsBesideTheChatOrFallsBackToTabs() {
        XCTAssertNil(ControlCenterLayout.paneWidth(contentWidth: 513), "11-inch iPad in portrait uses tabs")
        XCTAssertNil(ControlCenterLayout.paneWidth(contentWidth: 679))
        XCTAssertEqual(ControlCenterLayout.paneWidth(contentWidth: 680), 320)
        XCTAssertEqual(ControlCenterLayout.paneWidth(contentWidth: 700), 340)
        XCTAssertEqual(ControlCenterLayout.paneWidth(contentWidth: 873), 500, "11-inch iPad in landscape")
    }
}

final class SidebarShellLayoutTests: XCTestCase {
    func testContentOffsetCoversClosedOpenAndRubberBandStates() {
        XCTAssertEqual(
            SidebarShellLayout.contentOffset(isSidebarOpen: false, dragOffset: 0, openOffset: 100),
            0
        )
        XCTAssertEqual(
            SidebarShellLayout.contentOffset(isSidebarOpen: true, dragOffset: 0, openOffset: 100),
            100
        )
        XCTAssertLessThan(
            SidebarShellLayout.contentOffset(isSidebarOpen: false, dragOffset: -40, openOffset: 100),
            0
        )
        XCTAssertGreaterThan(
            SidebarShellLayout.contentOffset(isSidebarOpen: true, dragOffset: 40, openOffset: 100),
            100
        )
    }

    func testSidebarProgressClampsToOpenRange() {
        XCTAssertEqual(SidebarShellLayout.sidebarProgress(contentOffset: 40, openOffset: 0), 0)
        XCTAssertEqual(SidebarShellLayout.sidebarProgress(contentOffset: -10, openOffset: 100), 0)
        XCTAssertEqual(SidebarShellLayout.sidebarProgress(contentOffset: 50, openOffset: 100), 0.5)
        XCTAssertEqual(SidebarShellLayout.sidebarProgress(contentOffset: 140, openOffset: 100), 1)
    }

    func testRubberBandHandlesZeroDimension() {
        XCTAssertEqual(SidebarShellLayout.rubberBand(40, dimension: 0), 0)
        XCTAssertGreaterThan(SidebarShellLayout.rubberBand(40, dimension: 100), 0)
    }
}

private struct ChatContainerFixture {
    let agent = SavedAgent(
        id: "agent-container",
        address: "0x" + String(repeating: "cc", count: 32),
        name: "Container Agent"
    )

    func conversation(messages: [ChatMessage] = []) -> Conversation {
        Conversation(
            id: "conversation-container",
            title: "Container Chat",
            agentID: agent.id,
            agentAddress: agent.address,
            mode: .safe,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: messages,
            serverSession: nil
        )
    }
}

@MainActor
private func makeContainerViewModel(
    agents: [SavedAgent],
    conversations: [Conversation],
    activeAgentID: String? = nil,
    activeConversationID: String? = nil,
    client: MockAgentTransport = MockAgentTransport(),
    networkMonitor: MockNetworkMonitor = MockNetworkMonitor()
) -> ChatViewModel {
    let repository = InMemoryConversationRepository(
        snapshot: ChatSnapshot(
            agents: agents,
            conversations: conversations,
            activeAgentID: activeAgentID,
            activeConversationID: activeConversationID
        )
    )
    return ChatViewModel(
        store: repository,
        client: client,
        networkMonitor: networkMonitor
    )
}
