import ConnectOnionKit
import SwiftUI
import UIKit

struct ChatShellView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isSidebarOpen = false
    @State private var isSidebarSearchFocused = false
    @State private var dragOffset: CGFloat = 0
    @State private var activeContent: SidebarContent = .chat
    @State private var isControlCenterOpen = true
    @State private var agentView: OOAgentView = .chat

    init(
        viewModel: ChatViewModel,
        startsSidebarOpen: Bool = false,
        startsInSettings: Bool = false
    ) {
        self.viewModel = viewModel
        _isSidebarOpen = State(initialValue: startsSidebarOpen)
        _activeContent = State(initialValue: startsInSettings ? .settings : .chat)
    }

    // The outer reader keeps its safe area so it can report the real insets; the inner one
    // ignores it so the shell lays out edge to edge. Reading the insets off a reader that
    // already ignores the safe area only ever yields zero.
    var body: some View {
        GeometryReader { safeAreaProxy in
            let safeAreaInsets = safeAreaProxy.safeAreaInsets

            GeometryReader { proxy in
                if isRegularWidth {
                    sideBySideLayout(proxy: proxy, safeAreaInsets: safeAreaInsets)
                } else {
                    drawerLayout(proxy: proxy, safeAreaInsets: safeAreaInsets)
                }
            }
            .ignoresSafeArea()
        }
    }

    // On a regular-width canvas the sidebar is permanent and sits beside the content
    // instead of sliding over it: at iPad widths the drawer would push the chat off-screen
    // while leaving most of the display unused. Compact widths — every iPhone, and iPad
    // Slide Over — keep the drawer below.
    // with dashboard, tabs in portrait, side by side in landscape
    private func sideBySideLayout(proxy: GeometryProxy, safeAreaInsets: EdgeInsets) -> some View {
        let contentWidth = proxy.size.width - SidebarShellMetrics.permanentSidebarWidth - 1
        let paneWidth = ControlCenterLayout.paneWidth(contentWidth: contentWidth)
        let dashboard = activeContent == .chat ? viewModel.activeDashboard : nil
        return HStack(spacing: 0) {
            sidebar(safeAreaInsets: safeAreaInsets, isOpen: true)
                .frame(width: SidebarShellMetrics.permanentSidebarWidth)

            Divider()

            contentView(for: activeContent, controlCenter: controlCenter(for: dashboard, paneWidth: paneWidth))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(contentKeyboardSafeAreaRegions, edges: .bottom)

            if let dashboard, let paneWidth, isControlCenterOpen {
                Divider()

                OOControlCenterPane(
                    dashboard: dashboard,
                    skills: viewModel.activeAgentSkills,
                    onRunSkill: viewModel.runControlCenterSkill,
                    onCollapse: {
                        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                            isControlCenterOpen = false
                        }
                    }
                )
                .frame(width: paneWidth)
                .transition(.move(edge: .trailing))
            }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .background(OOColor.paper)
    }

    private func drawerLayout(proxy: GeometryProxy, safeAreaInsets: EdgeInsets) -> some View {
        let drawerWidth = min(proxy.size.width * SidebarShellMetrics.drawerWidthRatio, SidebarShellMetrics.maxDrawerWidth)
            let openOffset = min(drawerWidth, proxy.size.width - SidebarShellMetrics.visibleChatWidth)
            let contentOffset = SidebarShellLayout.contentOffset(
                isSidebarOpen: isSidebarOpen,
                dragOffset: dragOffset,
                openOffset: openOffset
            )
            let progress = SidebarShellLayout.sidebarProgress(contentOffset: contentOffset, openOffset: openOffset)
            let cornerRadius = SidebarShellMetrics.cornerRadius * progress

            return ZStack(alignment: .leading) {
                sidebar(safeAreaInsets: safeAreaInsets, isOpen: isSidebarOpen)
                .frame(width: drawerWidth)
                .offset(x: reduceMotion ? 0 : -SidebarShellMetrics.sidebarParallax * (1 - progress))
                .zIndex(0)

                contentView(for: activeContent, controlCenter: controlCenter(for: viewModel.activeDashboard, paneWidth: nil))
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(OOColor.paper)
                .ignoresSafeArea(contentKeyboardSafeAreaRegions, edges: .bottom)
                .allowsHitTesting(progress == 0)
                .clipShape(contentMask(cornerRadius: cornerRadius))
                .compositingGroup()
                .shadow(
                    color: .black.opacity(SidebarShellMetrics.shadowOpacity * progress),
                    radius: SidebarShellMetrics.shadowRadius,
                    x: SidebarShellMetrics.shadowOffset.width,
                    y: SidebarShellMetrics.shadowOffset.height
                )
                .offset(x: contentOffset)
                .zIndex(1)

                if isSidebarOpen {
                    Color.black.opacity(
                        (reduceTransparency ? SidebarShellMetrics.reducedTransparencyScrimOpacity : SidebarShellMetrics.scrimOpacity)
                            * progress
                    )
                        .frame(width: max(0, proxy.size.width - contentOffset), height: proxy.size.height)
                        .clipShape(contentMask(cornerRadius: cornerRadius))
                        .contentShape(Rectangle())
                        .offset(x: contentOffset)
                        .onTapGesture {
                            closeSidebar()
                        }
                        .accessibilityHidden(true)
                        .zIndex(2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .simultaneousGesture(sidebarDrag(openOffset: openOffset))
            .background(OOColor.paper)
            .clipped()
    }

    private func sidebar(safeAreaInsets: EdgeInsets, isOpen: Bool) -> some View {
        ChatSidebarView(
            viewModel: viewModel,
            safeAreaInsets: safeAreaInsets,
            isSidebarOpen: isOpen,
            isSearchFocused: $isSidebarSearchFocused,
            selection: sidebarSelection,
            onSelectConversation: { conversation in
                viewModel.selectConversation(conversation)
                showContentFromSidebar(.chat)
            },
            onAddChat: { agent in
                _ = viewModel.createConversation(for: agent)
                showContentFromSidebar(.chat)
            },
            onConnected: {
                showContentFromSidebar(.chat)
            },
            onSettings: {
                showContentFromSidebar(.settings)
            }
        )
    }

    // Control Center
    private func controlCenter(for dashboard: OIPDashboard?, paneWidth: CGFloat?) -> ChatControlCenter? {
        guard let dashboard else {
            return nil
        }
        guard paneWidth == nil else {
            return .beside(isOpen: isControlCenterOpen) {
                withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                    isControlCenterOpen.toggle()
                }
            }
        }
        return .tabs(
            dashboard: dashboard,
            selection: $agentView,
            attention: viewModel.activeChatAwaitsReader ? .chat : nil
        )
    }

    @ViewBuilder
    private func contentView(for content: SidebarContent, controlCenter: ChatControlCenter? = nil) -> some View {
        switch content {
        case .chat:
            ChatView(
                viewModel: viewModel,
                showsComposer: isRegularWidth || !isSidebarSearchFocused,
                showsSidebarButton: !isRegularWidth,
                controlCenter: controlCenter
            ) {
                openSidebar()
            }
        case .settings:
            SettingsView(viewModel: viewModel) {
                returnToSidebar()
            }
        }
    }

    private func showContent(_ content: SidebarContent) {
        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
            activeContent = content
            isSidebarOpen = false
            isSidebarSearchFocused = false
            dragOffset = 0
        }
    }

    private func returnToSidebar() {
        guard !isRegularWidth else {
            withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                activeContent = .chat
            }
            return
        }

        withAnimation(AppMotion.drawer(reduceMotion: reduceMotion)) {
            isSidebarOpen = true
            dragOffset = 0
        }
    }

    private func showContentFromSidebar(_ content: SidebarContent) {
        guard !isRegularWidth else {
            withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                activeContent = content
            }
            return
        }

        guard isSidebarOpen else {
            showContent(content)
            return
        }

        guard activeContent != content else {
            closeSidebar()
            return
        }

        withTransaction(Transaction(animation: nil)) {
            activeContent = content
            dragOffset = 0
        }

        DispatchQueue.main.async {
            closeSidebar()
        }
    }

    private func openSidebar() {
        guard canOpenSidebar else {
            return
        }

        withAnimation(AppMotion.drawer(reduceMotion: reduceMotion)) {
            isSidebarOpen = true
            dragOffset = 0
        }
    }

    private func closeSidebar() {
        withAnimation(AppMotion.drawer(reduceMotion: reduceMotion)) {
            isSidebarOpen = false
            isSidebarSearchFocused = false
            dragOffset = 0
        }
    }

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    // The drawer only exists in compact widths; when the sidebar is permanent there is
    // nothing to open, so the edge drag and the toolbar button both stand down.
    private var canOpenSidebar: Bool {
        !isRegularWidth
    }

    // Only the drawer hides the content behind a search keyboard; side by side, the chat
    // stays visible and keeps its normal keyboard behavior while the sidebar is searched.
    private var contentKeyboardSafeAreaRegions: SafeAreaRegions {
        !isRegularWidth && isSidebarSearchFocused ? .keyboard : []
    }

    private var sidebarSelection: ChatSidebarSelection? {
        switch activeContent {
        case .chat:
            guard let conversationID = viewModel.activeConversationID else {
                return nil
            }
            return .conversation(conversationID)
        case .settings:
            return nil
        }
    }

    private func sidebarDrag(openOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: SidebarShellMetrics.dragMinimumDistance, coordinateSpace: .global)
            .onChanged { value in
                guard isHorizontalDrag(value) else {
                    return
                }

                if isSidebarOpen {
                    dragOffset = value.translation.width
                } else if canOpenSidebar, value.startLocation.x <= SidebarShellMetrics.openEdgeWidth {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                guard isHorizontalDrag(value) else {
                    return
                }

                let shouldOpen: Bool
                if isSidebarOpen {
                    let projectedOffset = openOffset + value.predictedEndTranslation.width
                    shouldOpen = projectedOffset > openOffset * SidebarShellMetrics.closeThreshold
                } else {
                    shouldOpen = canOpenSidebar
                        && value.startLocation.x <= SidebarShellMetrics.openEdgeWidth
                        && value.predictedEndTranslation.width > openOffset * SidebarShellMetrics.openThreshold
                }

                let animation = drawerGestureAnimation(
                    value: value,
                    openOffset: openOffset,
                    shouldOpen: shouldOpen
                )
                withAnimation(animation) {
                    isSidebarOpen = shouldOpen
                    if !shouldOpen {
                        isSidebarSearchFocused = false
                    }
                    dragOffset = 0
                }
            }
    }

    private func isHorizontalDrag(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) > abs(value.translation.height)
    }

    private func drawerGestureAnimation(
        value: DragGesture.Value,
        openOffset: CGFloat,
        shouldOpen: Bool
    ) -> Animation? {
        let currentOffset = SidebarShellLayout.contentOffset(
            isSidebarOpen: isSidebarOpen,
            dragOffset: dragOffset,
            openOffset: openOffset
        )
        let targetOffset = shouldOpen ? openOffset : 0
        let remainingDistance = targetOffset - currentOffset
        guard abs(remainingDistance) > 1 else {
            return AppMotion.drawerGesture(reduceMotion: reduceMotion, initialVelocity: 0)
        }

        let projectedTravel = value.predictedEndTranslation.width - value.translation.width
        let normalizedVelocity = projectedTravel / remainingDistance
        return AppMotion.drawerGesture(
            reduceMotion: reduceMotion,
            initialVelocity: Double(
                min(
                    SidebarShellMetrics.maximumNormalizedVelocity,
                    max(-SidebarShellMetrics.maximumNormalizedVelocity, normalizedVelocity)
                )
            )
        )
    }

    private func contentMask(cornerRadius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: cornerRadius,
            style: .continuous
        )
    }
}

private enum SidebarContent {
    case chat
    case settings
}

enum SidebarShellLayout {
    static func contentOffset(isSidebarOpen: Bool, dragOffset: CGFloat, openOffset: CGFloat) -> CGFloat {
        let baseOffset = isSidebarOpen ? openOffset : CGFloat.zero
        let rawOffset = baseOffset + dragOffset

        if rawOffset < 0 {
            return -rubberBand(-rawOffset, dimension: openOffset)
        }
        if rawOffset > openOffset {
            return openOffset + rubberBand(rawOffset - openOffset, dimension: openOffset)
        }
        return rawOffset
    }

    static func sidebarProgress(contentOffset: CGFloat, openOffset: CGFloat) -> CGFloat {
        guard openOffset > 0 else {
            return 0
        }
        return min(1, max(0, contentOffset / openOffset))
    }

    static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat) -> CGFloat {
        guard dimension > 0 else {
            return 0
        }
        let constant = SidebarShellMetrics.rubberBandConstant
        return (overshoot * dimension * constant) / (dimension + (constant * overshoot))
    }
}

/// The Control Center pane
enum ControlCenterLayout {
    static let chatFloor: CGFloat = 360
    static let minimumPane: CGFloat = 320
    static let defaultPane: CGFloat = 500

    /// nil when both do not fit, and the tabs are used instead.
    static func paneWidth(contentWidth: CGFloat) -> CGFloat? {
        let room = contentWidth - chatFloor
        guard room >= minimumPane else {
            return nil
        }
        return min(defaultPane, room)
    }
}

// Sidebar metrics and constants.
private enum SidebarShellMetrics {
    static let drawerWidthRatio: CGFloat = 0.80
    static let maxDrawerWidth: CGFloat = 332
    static let permanentSidebarWidth: CGFloat = 320
    static let visibleChatWidth: CGFloat = 78
    static let cornerRadius: CGFloat = 34
    static let shadowOpacity: Double = 0.08
    static let shadowRadius: CGFloat = 16
    static let shadowOffset = CGSize(width: -2, height: 0)
    static let sidebarParallax: CGFloat = 18
    static let scrimOpacity: Double = 0.025
    static let reducedTransparencyScrimOpacity: Double = 0.05
    static let dragMinimumDistance: CGFloat = 16
    static let openEdgeWidth: CGFloat = 24
    static let closeThreshold: CGFloat = 0.40
    static let openThreshold: CGFloat = 0.33
    static let rubberBandConstant: CGFloat = 0.42
    static let maximumNormalizedVelocity: CGFloat = 5
}
