import ConnectOnionKit
import SwiftUI
import XCTest
@testable import OOChatIOS

@MainActor
final class AgentPresencePillTests: XCTestCase {
    func testPillSpeaksTheSessionStatus() {
        let runningWindow = ViewHost.host(AgentPresencePill(label: "Running", isLive: true).padding())
        let reconnectingWindow = ViewHost.host(AgentPresencePill(label: "Reconnecting", isLive: false).padding())

        XCTAssertNotNil(ViewHost.element(labelContains: "Session status: Running", in: runningWindow))
        XCTAssertNotNil(ViewHost.element(labelContains: "Session status: Reconnecting", in: reconnectingWindow))
    }
}

@MainActor
final class ChatSidebarHeaderViewTests: XCTestCase {
    // New chat and Search lead the drawer; no brand or online count (spec D8).
    func testHeaderLeadsWithNewChatAndSearch() {
        var newChatCount = 0
        var toggleCount = 0
        let window = ViewHost.host(
            HeaderHarness(
                isSearchVisible: false,
                searchText: "",
                onNewChat: { newChatCount += 1 },
                onToggleSearch: { toggleCount += 1 }
            )
        )

        XCTAssertNil(ViewHost.element(labelContains: "online", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "New chat", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Search", in: window))
        XCTAssertEqual(newChatCount, 1)
        XCTAssertEqual(toggleCount, 1)
    }

    // Folding an agent must not hide a chat that needs you; with one, the line opens it.
    func testAttentionLineOpensTheOneChatThatNeedsYou() {
        let quiet = ViewHost.host(HeaderHarness(isSearchVisible: false, searchText: "", onToggleSearch: {}))
        XCTAssertNil(ViewHost.element(labelContains: "needs approval", in: quiet))

        let agent = ViewFixtures.agent()
        let chat = ViewFixtures.conversation(id: "waiting", agent: agent)
        var opened: [String] = []
        let busy = ViewHost.host(
            HeaderHarness(
                attentionItems: [SidebarAttentionItem(conversation: chat, status: .approval)],
                onOpenChat: { opened.append($0.id) },
                isSearchVisible: false,
                searchText: "",
                onToggleSearch: {}
            )
        )
        XCTAssertTrue(ViewHost.activateButton(labelContains: "1 chat needs approval", in: busy))
        XCTAssertEqual(opened, ["waiting"])
    }

    // Several: the line lists them underneath, and each opens its chat.
    func testAttentionLineListsSeveralChats() {
        let agent = ViewFixtures.agent()
        let waiting = ViewFixtures.conversation(id: "waiting", agent: agent)
        let failed = ViewFixtures.conversation(id: "failed", agent: agent)
        var opened: [String] = []
        let window = ViewHost.host(
            HeaderHarness(
                attentionItems: [
                    SidebarAttentionItem(conversation: waiting, status: .approval),
                    SidebarAttentionItem(conversation: failed, status: .notSent)
                ],
                onOpenChat: { opened.append($0.id) },
                isSearchVisible: false,
                searchText: "",
                onToggleSearch: {}
            )
        )

        XCTAssertNil(ViewHost.element(labelContains: "message not sent", in: window))
        XCTAssertTrue(ViewHost.activateButton(labelContains: "2 chats need attention", in: window))
        ViewHost.pump(0.2)
        XCTAssertTrue(ViewHost.activateButton(labelContains: "message not sent", in: window))
        XCTAssertEqual(opened, ["failed"])
    }

    func testVisibleSearchShowsCloseActionAndCanClearText() {
        var toggleCount = 0
        let window = ViewHost.host(
            HeaderHarness(
                isSearchVisible: true,
                searchText: "deploy",
                onToggleSearch: { toggleCount += 1 }
            )
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Clear search", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Clear search", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Clear search", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Close search", in: window))
        XCTAssertEqual(toggleCount, 1)
    }
}

@MainActor
final class SidebarRowViewTests: XCTestCase {
    func testDisplayNameCompactsTheDefaultAddressName() {
        let agent = SavedAgent(id: "default-agent", address: "0x6e0469abcdef1234567890abcdefcd567a")
        XCTAssertEqual(agent.displayName, "0x6e04...567a")
        XCTAssertEqual(ViewFixtures.agent(name: "Orbit Agent").displayName, "Orbit Agent")
    }

    func testDisplayNameSaysAgentForABlankName() {
        XCTAssertEqual(ViewFixtures.agent(name: "   ").displayName, "Agent")
    }

    func testConversationRowRendersTitleAndInvokesSelection() {
        let agent = ViewFixtures.agent()
        let conversation = ViewFixtures.conversation(title: "Planning Notes", agent: agent)
        var selected = false
        let window = ViewHost.host(
            SidebarConversationRow(
                conversation: conversation,
                isSelected: true,
                activityState: nil,
                onSelect: { selected = true },
                onRename: {},
                onDelete: {}
            )
            .padding()
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Planning Notes", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Planning Notes", in: window))
        XCTAssertTrue(selected)
    }

    func testConversationRowStatusIndicatorsUseDistinctAccessibilityLabels() {
        let cases = [
            StatusCase(state: .actionRequired, label: "Status Chat, needs your approval"),
            // A question waits on you too, but there's nothing to approve.
            StatusCase(state: .actionRequired, status: .reply, label: "Status Chat, waiting for your reply"),
            StatusCase(state: .working, label: "Status Chat, agent working"),
            StatusCase(state: .failedDelivery, label: "Status Chat, message not sent"),
            StatusCase(state: .completedUnread, label: "Status Chat, new reply")
        ]
        for item in cases {
            let window = hostStatusRow(state: item.state, status: item.status)
            XCTAssertNotNil(ViewHost.element(labelContains: item.label, in: window), item.label)
        }
    }

    private struct StatusCase {
        let state: ConversationActivityState
        var status: SidebarChatStatus?
        let label: String
    }

    private func hostStatusRow(state: ConversationActivityState, status: SidebarChatStatus?) -> UIWindow {
        let conversation = ViewFixtures.conversation(title: "Status Chat", agent: ViewFixtures.agent())
        return ViewHost.host(
            SidebarConversationRow(
                conversation: conversation,
                isSelected: false,
                activityState: state,
                status: status,
                onSelect: {},
                onRename: {},
                onDelete: {}
            )
            .padding()
        )
    }
}

@MainActor
final class SidebarBannerViewTests: XCTestCase {
    func testOfflineBannerRendersAndInvokesActions() {
        var retryCount = 0
        var dismissCount = 0
        let window = ViewHost.host(
            OfflineBanner(
                onRetry: { retryCount += 1 },
                onDismiss: { dismissCount += 1 }
            )
            .padding()
        )

        XCTAssertNotNil(ViewHost.element(identifier: "offlineBanner", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "You're offline", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Retry connection", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Dismiss offline banner", in: window))
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(dismissCount, 1)
    }

    func testOfflineBannerShowsAnInFlightRetryOnTheButton() {
        let window = ViewHost.host(
            OfflineBanner(isRetrying: true, onRetry: {}, onDismiss: {})
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Retrying", in: window))
    }

    func testErrorBannerRendersMessageAndInvokesDismiss() {
        var dismissed = false
        let window = ViewHost.host(
            ErrorBanner(message: "Connection failed") {
                dismissed = true
            }
            .padding()
        )

        XCTAssertNotNil(ViewHost.element(identifier: "errorBanner", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Connection failed", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Close error", in: window))
        XCTAssertTrue(dismissed)
    }

    func testErrorBannerOffersRetryOnlyWhenGivenOne() {
        var retried = false
        let withRetry = ViewHost.host(
            ErrorBanner(message: "Couldn't reconnect", onRetry: { retried = true }, onDismiss: {})
        )
        XCTAssertTrue(ViewHost.activate(labelContains: "Retry connection", in: withRetry))
        XCTAssertTrue(retried)

        let withoutRetry = ViewHost.host(ErrorBanner(message: "That photo could not be loaded.", onDismiss: {}))
        XCTAssertNil(ViewHost.element(labelContains: "Retry connection", in: withoutRetry))
    }

    func testOnlyAFailedReconnectMakesTheErrorRetryable() {
        let viewModel = ViewFixtures.chatViewModel()
        viewModel.errorMessage = "That photo could not be loaded."
        XCTAssertFalse(viewModel.canRetryError)

        viewModel.presentConnectionError(HostedAgentClientError.busy, forConversationID: viewModel.activeConversationID ?? "")
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.canRetryError)

        viewModel.errorMessage = "That photo could not be loaded."
        XCTAssertFalse(viewModel.canRetryError, "a later, different error has nothing to retry")

        viewModel.dismissError()
        XCTAssertFalse(viewModel.canRetryError)
    }

    func testBalanceNoticeShowsLowAndEmptyWithAddCredits() {
        let address = "0x" + String(repeating: "a", count: 64)
        let low = ViewHost.host(AgentBalanceNotice(balanceUSD: 0.42, agentAddress: address))
        XCTAssertNotNil(ViewHost.element(labelContains: "Running low", in: low))
        XCTAssertNotNil(ViewHost.element(labelContains: "Add credits", in: low))

        let empty = ViewHost.host(AgentBalanceNotice(balanceUSD: 0, agentAddress: address))
        XCTAssertNotNil(ViewHost.element(labelContains: "out of credits", in: empty))

        let healthy = ViewHost.host(AgentBalanceNotice(balanceUSD: 5, agentAddress: address))
        XCTAssertNil(ViewHost.element(identifier: "agentBalanceNotice", in: healthy))
    }

    func testErrorBannerWithNilMessageRendersNothing() {
        let window = ViewHost.host(
            ErrorBanner(message: nil, onDismiss: {})
                .padding()
        )

        XCTAssertNil(ViewHost.element(identifier: "errorBanner", in: window))
    }
}

@MainActor
final class SidebarButtonStyleRenderTests: XCTestCase {
    func testSidebarButtonStylesRenderEnabledDisabledSelectedAndHighlightedStates() {
        let window = ViewHost.host(SidebarButtonStyleHarness())

        XCTAssertNotNil(ViewHost.element(labelContains: "Highlighted row", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Footer enabled", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Footer disabled", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Selected conversation", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Unselected conversation", in: window))
    }
}

private extension ViewFixtures {
    static func agent(name: String) -> SavedAgent {
        var agent = agent()
        agent.name = name
        return agent
    }

    static func conversation(title: String, agent: SavedAgent) -> Conversation {
        var conversation = conversation(agent: agent)
        conversation.title = title
        return conversation
    }
}

private struct HeaderHarness: View {
    var attentionItems: [SidebarAttentionItem] = []
    var onOpenChat: (Conversation) -> Void = { _ in }
    let isSearchVisible: Bool
    var onNewChat: () -> Void = {}
    let onToggleSearch: () -> Void
    @State private var searchText: String
    @FocusState private var isSearchFocused: Bool

    init(
        attentionItems: [SidebarAttentionItem] = [],
        onOpenChat: @escaping (Conversation) -> Void = { _ in },
        isSearchVisible: Bool,
        searchText: String,
        onNewChat: @escaping () -> Void = {},
        onToggleSearch: @escaping () -> Void
    ) {
        self.attentionItems = attentionItems
        self.onOpenChat = onOpenChat
        self.isSearchVisible = isSearchVisible
        self.onNewChat = onNewChat
        self.onToggleSearch = onToggleSearch
        _searchText = State(initialValue: searchText)
    }

    var body: some View {
        ChatSidebarHeaderView(
            isSearchVisible: isSearchVisible,
            searchText: $searchText,
            searchFieldFocus: $isSearchFocused,
            attentionItems: attentionItems,
            onOpenChat: onOpenChat,
            onNewChat: onNewChat,
            onToggleSearch: onToggleSearch
        )
        .padding()
    }
}

private struct SidebarButtonStyleHarness: View {
    var body: some View {
        VStack(spacing: 12) {
            Button("Highlighted row") {}
                .buttonStyle(SidebarPressedRowButtonStyle(isHighlighted: true))

            Button("Footer enabled") {}
                .buttonStyle(SidebarFooterButtonStyle())

            Button("Footer disabled") {}
                .buttonStyle(SidebarFooterButtonStyle())
                .disabled(true)

            Button("Selected conversation") {}
                .buttonStyle(SidebarConversationButtonStyle(isSelected: true))

            Button("Unselected conversation") {}
                .buttonStyle(SidebarConversationButtonStyle(isSelected: false))
        }
        .padding()
    }
}
