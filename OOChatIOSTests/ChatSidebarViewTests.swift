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

    func testSidebarExpandsAnotherAgent() {
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
        ViewHost.pump(0.2)
        XCTAssertNotNil(ViewHost.element(labelContains: "Beta Backlog", in: window))
    }

    func testSidebarExpandsAgentWhenActiveAgentChanges() {
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
        ViewHost.pump(0.2)
        XCTAssertNotNil(ViewHost.element(labelContains: "Beta Backlog", in: window))
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

    func testSidebarSearchShowsMatchingConversations() {
        let fixture = SidebarFixture()
        let conversations = [fixture.alphaConversation, fixture.betaConversation]
        let query = ChatSidebarSearch.query(from: "  Beta  ")
        let visibleAgents = ChatSidebarSearch.visibleAgents(
            agents: [fixture.alphaAgent, fixture.betaAgent],
            query: query
        ) { agent in
            conversations.matching(query, for: agent)
        }

        XCTAssertEqual(visibleAgents.map(\.id), [fixture.betaAgent.id])
        XCTAssertEqual(
            ChatSidebarSearch.resultCount(visibleAgents: visibleAgents, query: query) { agent in
                conversations.matching(query, for: agent)
            },
            2
        )
    }

    func testSidebarSearchCanMatchAgentAddress() {
        let fixture = SidebarFixture()
        let visibleAgents = ChatSidebarSearch.visibleAgents(
            agents: [fixture.alphaAgent, fixture.betaAgent],
            query: "bbbb"
        ) { _ in
            []
        }

        XCTAssertEqual(visibleAgents.map(\.id), [fixture.betaAgent.id])
        XCTAssertEqual(
            ChatSidebarSearch.resultCount(visibleAgents: visibleAgents, query: "bbbb") { _ in [] },
            1
        )
    }

    func testSidebarSearchShowsNoMatches() {
        let fixture = SidebarFixture()
        let visibleAgents = ChatSidebarSearch.visibleAgents(
            agents: [fixture.alphaAgent, fixture.betaAgent],
            query: "Gamma"
        ) { _ in
            []
        }

        XCTAssertTrue(visibleAgents.isEmpty)
        XCTAssertEqual(
            ChatSidebarSearch.resultCount(visibleAgents: visibleAgents, query: "Gamma") { _ in [] },
            0
        )
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
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Save", in: window))
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

private extension Array where Element == Conversation {
    func matching(_ query: String, for agent: SavedAgent) -> [Conversation] {
        filter { conversation in
            conversation.agentID == agent.id
                && conversation.title.localizedStandardContains(query)
        }
    }
}

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
