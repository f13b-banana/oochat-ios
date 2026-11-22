import ConnectOnionKit
import SwiftUI
import UIKit

struct ChatShellView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isSidebarOpen = false
    @State private var isSidebarSearchFocused = false
    @State private var dragOffset: CGFloat = 0
    @State private var isSettingsPresented = false
    /// iPad only: the agent pane beside the rail, shown or hidden as on the Mac (same key, ⌃⌘S).
    @AppStorage(ChatShellView.paneVisibleKey) private var isPaneVisible = true
    /// The Mac's key, so the setting reads the same on both.
    static let paneVisibleKey = "isSidebarVisible"
    @State private var isControlCenterOpen = true
    @State private var agentView: OOAgentView = .chat
    @State private var workRoomPath: [String] = []
    // Bumped by the chat's empty state; the sidebar owns the Add Agent form and opens it.
    @State private var addAgentRequest = 0

    private var isStationShown: Bool {
        viewModel.activeAgent.map(viewModel.isStation) ?? false
    }

    init(
        viewModel: ChatViewModel,
        startsSidebarOpen: Bool = false,
        startsInSettings: Bool = false
    ) {
        self.viewModel = viewModel
        _isSidebarOpen = State(initialValue: startsSidebarOpen)
        _isSettingsPresented = State(initialValue: startsInSettings)
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
        // A Work Room belongs to its chat; another chat starts at its own timeline.
        .onChange(of: viewModel.activeConversationID) {
            workRoomPath = []
        }
        // A sheet, so Done leaves you on the chat or in the drawer, wherever you opened it from.
        .sheet(isPresented: $isSettingsPresented) {
            // On iPad a sheet is already a form sheet.
            SettingsView(viewModel: viewModel) {
                isSettingsPresented = false
            }
        }
    }

    // On a regular-width canvas the sidebar is permanent and sits beside the content
    // instead of sliding over it: at iPad widths the drawer would push the chat off-screen
    // while leaving most of the display unused. Compact widths — every iPhone, and iPad
    // Slide Over — keep the drawer below.
    // with dashboard, tabs in portrait, side by side in landscape
    private func sideBySideLayout(proxy: GeometryProxy, safeAreaInsets: EdgeInsets) -> some View {
        // With the pane hidden only the rail stays, and the chat and Control Center share what it gave up.
        let sidebarWidth = isPaneVisible
            ? SidebarShellMetrics.permanentSidebarWidth
            : AgentRail.width + safeAreaInsets.leading
        let contentWidth = proxy.size.width - sidebarWidth - 1
        let paneWidth = ControlCenterLayout.paneWidth(contentWidth: contentWidth)
        let dashboard = isStationShown ? nil : viewModel.activeDashboard
        return HStack(spacing: 0) {
            sidebar(
                safeAreaInsets: safeAreaInsets,
                isOpen: true,
                controlCenterBeside: paneWidth != nil,
                showsPane: isPaneVisible
            )
            .frame(width: sidebarWidth)

            Divider()

            contentView(controlCenter: controlCenter(for: dashboard, paneWidth: paneWidth))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(contentKeyboardSafeAreaRegions, edges: .bottom)

            // The Control Center is absent inside a Work Room; isControlCenterOpen is left as it was.
            if let dashboard, let paneWidth, isControlCenterOpen, workRoomPath.isEmpty {
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
        .background {
            // ⌃⌘S with a hardware keyboard, wherever focus is; also listed when you hold ⌘.
            Button(isPaneVisible ? "Hide Agent Pane" : "Show Agent Pane", action: togglePane)
                .keyboardShortcut("s", modifiers: [.control, .command])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func togglePane() {
        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
            isPaneVisible.toggle()
        }
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
                sidebar(safeAreaInsets: safeAreaInsets, isOpen: isSidebarOpen, controlCenterBeside: false)
                .frame(width: drawerWidth)
                // While open, VoiceOver stays in the drawer, like a sheet.
                .accessibilityAddTraits(isSidebarOpen ? .isModal : [])
                .offset(x: reduceMotion ? 0 : -SidebarShellMetrics.sidebarParallax * (1 - progress))
                .zIndex(0)

                contentView(controlCenter: controlCenter(for: drawerDashboard, paneWidth: nil))
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(OOColor.paper)
                .ignoresSafeArea(contentKeyboardSafeAreaRegions, edges: .bottom)
                .allowsHitTesting(progress == 0)
                .accessibilityHidden(isSidebarOpen)
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
                    Color.black.opacity(scrimOpacity * progress)
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
            .simultaneousGesture(sidebarDrag(openOffset: openOffset, paneStart: AgentRail.width + safeAreaInsets.leading))
            .background(OOColor.paper)
            .clipped()
    }

    private var scrimOpacity: Double {
        SidebarShellLayout.scrimOpacity(isDark: colorScheme == .dark, reduceTransparency: reduceTransparency)
    }

    private var drawerDashboard: OIPDashboard? {
        isStationShown ? nil : viewModel.activeDashboard
    }

    private func sidebar(
        safeAreaInsets: EdgeInsets,
        isOpen: Bool,
        controlCenterBeside: Bool,
        showsPane: Bool = true
    ) -> some View {
        ChatSidebarView(
            viewModel: viewModel,
            safeAreaInsets: safeAreaInsets,
            isSidebarOpen: isOpen,
            isSearchFocused: $isSidebarSearchFocused,
            selection: sidebarSelection,
            onSelectConversation: { conversation in
                viewModel.selectConversation(conversation)
                showChatFromSidebar()
            },
            onAddChat: { agent in
                _ = viewModel.createConversation(for: agent)
                showChatFromSidebar()
            },
            onConnected: {
                showChatFromSidebar()
            },
            onSettings: presentSettings,
            addAgentRequest: addAgentRequest,
            onSelectStation: { agent in
                viewModel.selectStation(agent)
                showChatFromSidebar()
            },
            opensLatestChatOnPick: isRegularWidth,
            onOpenWorkRoom: openWorkRoom,
            onShowChat: {
                agentView = .chat
                showChatFromSidebar()
            },
            controlCenterTitle: controlCenterTitle(beside: controlCenterBeside),
            onShowControlCenter: { showControlCenter(beside: controlCenterBeside) },
            showsPane: showsPane,
            // A tile tapped while the pane is hidden brings it back, showing that agent.
            onRailPick: {
                if !showsPane {
                    togglePane()
                }
            }
        )
    }

    /// From the agent pane: the Work Room opens over the chat, with Back to return.
    private func openWorkRoom(_ workRoomID: String) {
        agentView = .chat
        workRoomPath = [workRoomID]
        showChatFromSidebar()
    }

    private func controlCenterTitle(beside: Bool) -> String {
        guard beside else {
            return "Open Control Center"
        }
        return isControlCenterOpen ? "Hide Control Center" : "Show Control Center"
    }

    /// Beside the chat it shows or hides its pane; on a phone it opens the Control tab.
    private func showControlCenter(beside: Bool) {
        guard !beside else {
            withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                isControlCenterOpen.toggle()
                workRoomPath = []
            }
            return
        }
        workRoomPath = []
        agentView = .control
        showChatFromSidebar()
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
    private func contentView(controlCenter: ChatControlCenter? = nil) -> some View {
        if viewModel.activeOnboarding != nil {
            OnboardingPaneView(viewModel: viewModel, showsSidebarButton: !isRegularWidth) {
                openSidebar()
            }
        } else if isStationShown {
            // A Station's Work Room is the pane itself, so the Control Center has no place beside it.
            StationPaneView(viewModel: viewModel, showsSidebarButton: !isRegularWidth) {
                openSidebar()
            }
        } else {
            ChatView(
                viewModel: viewModel,
                showsComposer: isRegularWidth || !isSidebarSearchFocused,
                showsSidebarButton: !isRegularWidth,
                controlCenter: controlCenter,
                workRoomPath: $workRoomPath,
                onAddAgent: { addAgentRequest += 1 },
                onOpenSidebar: { openSidebar() },
                isCoveredByDrawer: !isRegularWidth && isSidebarOpen,
                paneToggle: isRegularWidth ? ChatPaneToggle(isVisible: isPaneVisible, toggle: togglePane) : nil
            )
        }
    }

    /// A tap that lands while another sheet is still closing gets dropped with the flag left on,
    /// and the next tap would change nothing. Turning it off first lets that tap present it.
    private func presentSettings() {
        guard isSettingsPresented else {
            isSettingsPresented = true
            return
        }
        isSettingsPresented = false
        DispatchQueue.main.async {
            isSettingsPresented = true
        }
    }

    /// On a phone, picking something in the drawer closes it onto the chat. Side by side, the
    /// chat is already showing.
    private func showChatFromSidebar() {
        guard !isRegularWidth else {
            return
        }
        closeSidebar()
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
    // nothing to open, so the edge drag and the toolbar button both stand down. Inside a Work Room
    // the same edge swipe goes Back, so the drawer stands down there too.
    private var canOpenSidebar: Bool {
        !isRegularWidth && workRoomPath.isEmpty
    }

    // Only the drawer hides the content behind a search keyboard; side by side, the chat
    // stays visible and keeps its normal keyboard behavior while the sidebar is searched.
    private var contentKeyboardSafeAreaRegions: SafeAreaRegions {
        !isRegularWidth && isSidebarSearchFocused ? .keyboard : []
    }

    private var sidebarSelection: ChatSidebarSelection? {
        viewModel.activeConversationID.map { .conversation($0) }
    }

    /// `paneStart`: where the agent pane begins. While the drawer is open, a drag that starts in
    /// the pane belongs to its chat rows (swipe to delete or rename), so only the rail and the strip
    /// of chat beside the drawer drag it closed.
    private func sidebarDrag(openOffset: CGFloat, paneStart: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: SidebarShellMetrics.dragMinimumDistance, coordinateSpace: .global)
            .onChanged { value in
                guard isHorizontalDrag(value),
                      !isSidebarOpen || SidebarShellLayout.dragClosesDrawer(
                          startX: value.startLocation.x, paneStart: paneStart, openOffset: openOffset
                      ) else {
                    return
                }

                if isSidebarOpen {
                    dragOffset = value.translation.width
                } else if canOpenSidebar, value.startLocation.x <= SidebarShellMetrics.openEdgeWidth {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                guard isHorizontalDrag(value),
                      !isSidebarOpen || SidebarShellLayout.dragClosesDrawer(
                          startX: value.startLocation.x, paneStart: paneStart, openOffset: openOffset
                      ) else {
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

    static func dragClosesDrawer(startX: CGFloat, paneStart: CGFloat, openOffset: CGFloat) -> Bool {
        startX < paneStart || startX >= openOffset
    }

    static func sidebarProgress(contentOffset: CGFloat, openOffset: CGFloat) -> CGFloat {
        guard openOffset > 0 else {
            return 0
        }
        return min(1, max(0, contentOffset / openOffset))
    }

    /// Dark enough that the strip of chat beside the open drawer reads as "tap to close".
    /// Dark mode needs more to show on a dark chat; Reduce Transparency never goes lighter.
    static func scrimOpacity(isDark: Bool, reduceTransparency: Bool) -> Double {
        let opacity = isDark ? SidebarShellMetrics.darkScrimOpacity : SidebarShellMetrics.lightScrimOpacity
        return reduceTransparency ? max(opacity, SidebarShellMetrics.reducedTransparencyScrimOpacity) : opacity
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
    /// Wide enough for the rail and a pane whose chat titles still read: 334 pt on a 390 pt phone.
    static let drawerWidthRatio: CGFloat = 0.86
    static let maxDrawerWidth: CGFloat = 360
    static let permanentSidebarWidth: CGFloat = 340
    static let visibleChatWidth: CGFloat = 56
    static let cornerRadius: CGFloat = 34
    static let shadowOpacity: Double = 0.08
    static let shadowRadius: CGFloat = 16
    static let shadowOffset = CGSize(width: -2, height: 0)
    static let sidebarParallax: CGFloat = 18
    static let lightScrimOpacity: Double = 0.35
    static let darkScrimOpacity: Double = 0.5
    static let reducedTransparencyScrimOpacity: Double = 0.45
    static let dragMinimumDistance: CGFloat = 16
    static let openEdgeWidth: CGFloat = 24
    static let closeThreshold: CGFloat = 0.40
    static let openThreshold: CGFloat = 0.33
    static let rubberBandConstant: CGFloat = 0.42
    static let maximumNormalizedVelocity: CGFloat = 5
}
