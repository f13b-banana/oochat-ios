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
    func testHeaderShowsBrandConnectionSummaryAndSearchAction() {
        var toggleCount = 0
        let window = ViewHost.host(
            HeaderHarness(
                onlineAgentCount: 2,
                isSearchVisible: false,
                searchText: "",
                onToggleSearch: { toggleCount += 1 }
            )
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "oo-chat", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "2 agents online", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Search", in: window))
        XCTAssertEqual(toggleCount, 1)
    }

    func testVisibleSearchShowsCloseActionAndCanClearText() {
        var toggleCount = 0
        let window = ViewHost.host(
            HeaderHarness(
                onlineAgentCount: 1,
                isSearchVisible: true,
                searchText: "deploy",
                onToggleSearch: { toggleCount += 1 }
            )
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "1 agent online", in: window))
        XCTAssertNotNil(ViewHost.element(labelContains: "Clear search", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Clear search", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Clear search", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Close search", in: window))
        XCTAssertEqual(toggleCount, 1)
    }
}

@MainActor
final class SidebarRowViewTests: XCTestCase {
    func testAgentRowRendersAgentNameAndInvokesToggle() {
        let agent = ViewFixtures.agent(name: "Orbit Agent")
        var toggled = false
        var addChatCount = 0
        let window = ViewHost.host(
            SidebarAgentRow(
                agent: agent,
                isExpanded: true,
                isOnline: true,
                onToggle: { toggled = true },
                onRename: {},
                onEdit: {},
                onAddChat: { addChatCount += 1 },
                onShowQRCode: { _ in },
                onDelete: {}
            )
            .padding()
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "Orbit Agent", in: window))
        XCTAssertTrue(ViewHost.activate(labelContains: "Orbit Agent", in: window))
        XCTAssertTrue(toggled)
        XCTAssertTrue(ViewHost.activateButton(labelContains: "Add Chat", in: window))
        XCTAssertEqual(addChatCount, 1)
    }

    func testAgentRowCompactsDefaultAddressNameForDisplay() {
        let agent = SavedAgent(
            id: "default-agent",
            address: "0x6e0469abcdef1234567890abcdefcd567a"
        )
        let window = ViewHost.host(
            SidebarAgentRow(
                agent: agent,
                isExpanded: false,
                isOnline: false,
                onToggle: {},
                onRename: {},
                onEdit: {},
                onAddChat: {},
                onShowQRCode: { _ in },
                onDelete: {}
            )
            .padding()
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "0x6e04...567a", in: window))
        XCTAssertNil(ViewHost.element(labelContains: "Agent 0x6e04...567a", in: window))
    }

    func testAgentRowFallsBackToDefaultInitialForBlankName() {
        let agent = ViewFixtures.agent(name: "   ")
        let window = ViewHost.host(
            SidebarAgentRow(
                agent: agent,
                isExpanded: false,
                isOnline: false,
                onToggle: {},
                onRename: {},
                onEdit: {},
                onAddChat: {},
                onShowQRCode: { _ in },
                onDelete: {}
            )
            .padding()
        )

        XCTAssertNotNil(ViewHost.element(labelContains: "A", in: window))
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
        let agent = ViewFixtures.agent()
        let conversation = ViewFixtures.conversation(title: "Status Chat", agent: agent)

        let pendingWindow = ViewHost.host(
            SidebarConversationRow(
                conversation: conversation,
                isSelected: false,
                activityState: .actionRequired,
                onSelect: {},
                onRename: {},
                onDelete: {}
            )
            .padding()
        )
        XCTAssertNotNil(ViewHost.element(labelContains: "Action required", in: pendingWindow))

        let processingWindow = ViewHost.host(
            SidebarConversationRow(
                conversation: conversation,
                isSelected: false,
                activityState: .working,
                onSelect: {},
                onRename: {},
                onDelete: {}
            )
            .padding()
        )
        XCTAssertNotNil(ViewHost.element(labelContains: "Agent working", in: processingWindow))

        let failedWindow = ViewHost.host(
            SidebarConversationRow(
                conversation: conversation,
                isSelected: false,
                activityState: .failedDelivery,
                onSelect: {},
                onRename: {},
                onDelete: {}
            )
            .padding()
        )
        XCTAssertNotNil(ViewHost.element(labelContains: "Message failed to send", in: failedWindow))

        let completedWindow = ViewHost.host(
            SidebarConversationRow(
                conversation: conversation,
                isSelected: false,
                activityState: .completedUnread,
                onSelect: {},
                onRename: {},
                onDelete: {}
            )
            .padding()
        )
        XCTAssertNotNil(ViewHost.element(labelContains: "Background task completed", in: completedWindow))
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
    let onlineAgentCount: Int
    let isSearchVisible: Bool
    let onToggleSearch: () -> Void
    @State private var searchText: String
    @FocusState private var isSearchFocused: Bool

    init(
        onlineAgentCount: Int,
        isSearchVisible: Bool,
        searchText: String,
        onToggleSearch: @escaping () -> Void
    ) {
        self.onlineAgentCount = onlineAgentCount
        self.isSearchVisible = isSearchVisible
        self.onToggleSearch = onToggleSearch
        _searchText = State(initialValue: searchText)
    }

    var body: some View {
        ChatSidebarHeaderView(
            onlineAgentCount: onlineAgentCount,
            isSearchVisible: isSearchVisible,
            searchText: $searchText,
            searchFieldFocus: $isSearchFocused,
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
