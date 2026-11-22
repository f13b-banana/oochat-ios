import SwiftUI
import XCTest
@testable import OOChatIOS

@MainActor
final class ChatSidebarViewTests: XCTestCase {
    func testSidebarRendersEmptyStateAndFooterActions() {
        let viewModel = makeViewModel(agents: [], conversations: [])
        var settingsCount = 0
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: nil,
                onSelectConversation: { _ in XCTFail("unexpected conversation selection") },
                onAddChat: { _ in XCTFail("unexpected add chat") },
                onConnected: { XCTFail("unexpected connection") },
                onSettings: { settingsCount += 1 }
            )
        )

        XCTAssertNil(ViewHost.element(labelContains: "No agents connected", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Add agent", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Settings", in: window))
        XCTAssertEqual(settingsCount, 1)

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Add agent", in: window))
        ViewHost.pump(0.3)
        XCTAssertNotNil(ViewHost.element(labelContains: "Agent address", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Cancel", in: window))
    }

    func testSidebarLabelsAChatFromAPreviousIdentity() {
        let fixture = SidebarFixture()
        var old = fixture.alphaConversation
        old.identityAddress = "0x" + String(repeating: "0", count: 64)
        let viewModel = makeViewModel(
            agents: [fixture.alphaAgent],
            conversations: [old],
            activeAgentID: fixture.alphaAgent.id,
            activeConversationID: old.id
        )
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: .conversation(old.id),
                onSelectConversation: { _ in },
                onAddChat: { _ in },
                onConnected: {},
                onSettings: {}
            )
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "From a previous identity", in: window))
    }

    func testSidebarShowsActiveAgentConversationAndSelectsIt() {
        let fixture = SidebarFixture()
        let viewModel = makeViewModel(
            agents: [fixture.alphaAgent, fixture.betaAgent],
            conversations: [fixture.alphaConversation, fixture.betaConversation],
            activeAgentID: fixture.alphaAgent.id,
            activeConversationID: fixture.alphaConversation.id
        )
        var selectedConversationID: String?
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: .conversation(fixture.alphaConversation.id),
                onSelectConversation: { selectedConversationID = $0.id },
                onAddChat: { _ in XCTFail("unexpected add chat") },
                onConnected: { XCTFail("unexpected connection") },
                onSettings: {}
            )
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Alpha Agent", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Alpha Planning", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Beta Agent", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Beta Backlog", in: window))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Alpha Planning", in: window))
        XCTAssertEqual(selectedConversationID, fixture.alphaConversation.id)
    }

    func testPickingAnAgentOnTheRailShowsItsChats() {
        let fixture = SidebarFixture()
        let viewModel = makeViewModel(
            agents: [fixture.alphaAgent, fixture.betaAgent],
            conversations: [fixture.alphaConversation, fixture.betaConversation],
            activeAgentID: fixture.alphaAgent.id,
            activeConversationID: fixture.alphaConversation.id
        )
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: .conversation(fixture.alphaConversation.id),
                onSelectConversation: { _ in },
                onAddChat: { _ in XCTFail("unexpected add chat") },
                onConnected: { XCTFail("unexpected connection") },
                onSettings: {}
            )
        )

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Beta Agent", in: window))
        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Beta Backlog", in: window, timeout: 2))
    }

    func testPaneFollowsTheActiveAgent() {
        let fixture = SidebarFixture()
        let viewModel = makeViewModel(
            agents: [fixture.alphaAgent, fixture.betaAgent],
            conversations: [fixture.alphaConversation, fixture.betaConversation],
            activeAgentID: fixture.alphaAgent.id,
            activeConversationID: fixture.alphaConversation.id
        )
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: .conversation(fixture.alphaConversation.id),
                onSelectConversation: { _ in },
                onAddChat: { _ in XCTFail("unexpected add chat") },
                onConnected: { XCTFail("unexpected connection") },
                onSettings: {}
            )
        )

        XCTAssertNil(ViewHost.element(labelContains: "Beta Backlog", in: window))
        viewModel.selectAgent(fixture.betaAgent)
        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Beta Backlog", in: window, timeout: 2))
    }

    func testPaneShowsTheActiveAgentsChats() {
        let fixture = SidebarFixture()
        let viewModel = makeViewModel(
            agents: [fixture.alphaAgent, fixture.betaAgent],
            conversations: [fixture.alphaConversation, fixture.betaConversation],
            activeAgentID: fixture.betaAgent.id,
            activeConversationID: fixture.betaConversation.id
        )
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: .conversation(fixture.betaConversation.id),
                onSelectConversation: { _ in },
                onAddChat: { _ in XCTFail("unexpected add chat") },
                onConnected: { XCTFail("unexpected connection") },
                onSettings: {}
            )
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Beta Backlog", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Refresh dashboard", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Alpha Planning", in: window))
    }

    func testSidebarShowsNoChatSessionsForExpandedAgent() {
        let fixture = SidebarFixture()
        let viewModel = makeViewModel(
            agents: [fixture.alphaAgent],
            conversations: [],
            activeAgentID: fixture.alphaAgent.id
        )
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: nil,
                onSelectConversation: { _ in XCTFail("unexpected conversation selection") },
                onAddChat: { _ in XCTFail("unexpected add chat") },
                onConnected: { XCTFail("unexpected connection") },
                onSettings: {}
            )
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Alpha Agent", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "No chats yet", in: window), "no filler under an empty agent")
    }

    func testSidebarDefaultsToFirstAgentWhenNoAgentIsActive() {
        let fixture = SidebarFixture()
        let viewModel = makeViewModel(
            agents: [fixture.alphaAgent, fixture.betaAgent],
            conversations: [fixture.alphaConversation, fixture.betaConversation]
        )
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: nil,
                onSelectConversation: { _ in },
                onAddChat: { _ in XCTFail("unexpected add chat") },
                onConnected: { XCTFail("unexpected connection") },
                onSettings: {}
            )
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Alpha Planning", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Beta Backlog", in: window))
    }

    func testRailOrderKeepsNewAgentsLastAndMovesTiles() {
        let start = Date(timeIntervalSince1970: 0)
        let first = SavedAgent(id: "a", address: sidebarHostedAddress, name: "A", createdAt: start)
        let second = SavedAgent(id: "b", address: sidebarHostedAddress, name: "B", createdAt: start.addingTimeInterval(1))
        let third = SavedAgent(id: "c", address: sidebarHostedAddress, name: "C", createdAt: start.addingTimeInterval(2))

        // The saved list is newest first; with no order yet the rail is oldest first.
        XCTAssertEqual(AgentRailOrder.ordered([third, second, first], by: []).map(\.id), ["a", "b", "c"])
        // A known order wins, and an agent it doesn't know yet goes under the last one.
        XCTAssertEqual(AgentRailOrder.ordered([third, second, first], by: ["b", "a"]).map(\.id), ["b", "a", "c"])

        XCTAssertEqual(AgentRailOrder.moving("a", to: "c", in: ["a", "b", "c"]), ["b", "c", "a"])
        XCTAssertEqual(AgentRailOrder.moving("c", to: "a", in: ["a", "b", "c"]), ["c", "a", "b"])
        XCTAssertEqual(AgentRailOrder.moving("b", by: -1, in: ["a", "b", "c"]), ["b", "a", "c"])
        XCTAssertEqual(AgentRailOrder.moving("c", by: 1, in: ["a", "b", "c"]), ["a", "b", "c"])
        XCTAssertEqual(AgentRailOrder.decode(AgentRailOrder.encode(["a", "b"])), ["a", "b"])
    }

    func testRailDropFindsTheTileUnderThePointer() {
        // 8 pt top padding, then 48 pt slots 4 pt apart.
        XCTAssertEqual(AgentRailDropDelegate.index(atY: 0, count: 3), 0)
        XCTAssertEqual(AgentRailDropDelegate.index(atY: 30, count: 3), 0)
        XCTAssertEqual(AgentRailDropDelegate.index(atY: 70, count: 3), 1)
        XCTAssertEqual(AgentRailDropDelegate.index(atY: 500, count: 3), 2, "below the last tile is the last tile")
        XCTAssertNil(AgentRailDropDelegate.index(atY: 30, count: 0))
    }

    func testSidebarAddAgentSheetSavesAgent() {
        let viewModel = makeViewModel(agents: [], conversations: [])
        var connectedCount = 0
        let window = ViewHost.host(
            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: true,
                isSearchFocused: .constant(false),
                selection: nil,
                onSelectConversation: { _ in XCTFail("unexpected conversation selection") },
                onAddChat: { _ in XCTFail("unexpected add chat") },
                onConnected: { connectedCount += 1 },
                onSettings: {}
            )
        )

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Add agent", in: window))
        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Agent address", in: window))

        XCTAssertTrue(ViewHost.enterText("Saved Agent", intoTextInput: "Name", in: window))
        XCTAssertTrue(ViewHost.enterText(sidebarHostedAddress, intoTextInput: "Agent address", in: window))
        XCTAssertTrue(ViewHost.activate(identifier: "agentForm.confirm", in: window))
        ViewHost.pump(0.4)

        XCTAssertEqual(viewModel.agents.first?.name, "Saved Agent")
        XCTAssertEqual(viewModel.agents.first?.address, sidebarHostedAddress)
        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertEqual(viewModel.activeAgentID, viewModel.agents.first?.id)
        XCTAssertEqual(viewModel.activeConversationID, viewModel.conversations.first?.id)
        XCTAssertEqual(connectedCount, 1)
        XCTAssertNotNil(ViewHost.waitForElement(labelContains: "Saved Agent", in: window))
    }

    func testSidebarSearchToggleFocusAndCloseReset() {
        let fixture = SidebarFixture()
        let viewModel = makeViewModel(
            agents: [fixture.alphaAgent],
            conversations: [fixture.alphaConversation],
            activeAgentID: fixture.alphaAgent.id,
            activeConversationID: fixture.alphaConversation.id
        )
        let window = ViewHost.host(
            SidebarOpenHarness(viewModel: viewModel),
            size: CGSize(width: 390, height: 920)
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Sidebar search unfocused", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Search", in: window))
        ViewHost.pump(0.2)
        XCTAssertNotNil(ViewHost.element(labelContains: "Close search", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Sidebar search focused", in: window))

        XCTAssertTrue(ViewHost.activateButton(labelContains: "Close Drawer", in: window))
        ViewHost.pump(0.2)
        XCTAssertNotNil(ViewHost.element(labelContains: "Search", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Close search", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Sidebar search unfocused", in: window))
    }
}

private let sidebarHostedAddress = "0x" + String(repeating: "dd", count: 32)

private struct SidebarOpenHarness: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var isSidebarOpen = true
    @State private var isSearchFocused = false

    var body: some View {
        VStack(spacing: 0) {
            Button("Close Drawer") {
                isSidebarOpen = false
            }
            .padding(.vertical, 8)

            Text(isSearchFocused ? "Sidebar search focused" : "Sidebar search unfocused")
                .font(.caption)

            ChatSidebarView(
                viewModel: viewModel,
                safeAreaInsets: .init(),
                isSidebarOpen: isSidebarOpen,
                isSearchFocused: $isSearchFocused,
                selection: viewModel.activeConversationID.map(ChatSidebarSelection.conversation),
                onSelectConversation: { _ in },
                onAddChat: { _ in },
                onConnected: {},
                onSettings: {}
            )
        }
    }
}

private struct SidebarFixture {
    let alphaAgent = SavedAgent(
        id: "agent-alpha",
        address: "0x" + String(repeating: "aa", count: 32),
        name: "Alpha Agent"
    )
    let betaAgent = SavedAgent(
        id: "agent-beta",
        address: "0x" + String(repeating: "bb", count: 32),
        name: "Beta Agent"
    )

    var alphaConversation: Conversation {
        conversation(
            id: "conversation-alpha",
            title: "Alpha Planning",
            agent: alphaAgent,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    var betaConversation: Conversation {
        conversation(
            id: "conversation-beta",
            title: "Beta Backlog",
            agent: betaAgent,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func conversation(
        id: String,
        title: String,
        agent: SavedAgent,
        updatedAt: Date
    ) -> Conversation {
        Conversation(
            id: id,
            title: title,
            agentID: agent.id,
            agentAddress: agent.address,
            mode: .safe,
            createdAt: Date(timeIntervalSince1970: 500),
            updatedAt: updatedAt,
            // A chat is only listed once it has a message (story 182).
            messages: [ChatMessage(role: .user, content: title)],
            serverSession: nil
        )
    }
}

@MainActor
private func makeViewModel(
    agents: [SavedAgent],
    conversations: [Conversation],
    activeAgentID: String? = nil,
    activeConversationID: String? = nil
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
        client: MockAgentTransport(),
        networkMonitor: MockNetworkMonitor()
    )
}
