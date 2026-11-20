import ConnectOnionKit
import SwiftUI
import UIKit

/// tabs or beside control center viewing
enum ChatControlCenter {

    // next to chat, hidden or showing via toolbar
    case beside(isOpen: Bool, toggle: () -> Void)

    case tabs(dashboard: OIPDashboard, selection: Binding<OOAgentView>, attention: OOAgentView?)
}

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    let showsSidebarButton: Bool
    let controlCenter: ChatControlCenter?
    /// Ids of the Work Rooms pushed onto this chat; the shell reads it to hide the Control Center.
    @Binding var workRoomPath: [String]
    let onAddAgent: () -> Void
    let onOpenSidebar: () -> Void

    init(
        viewModel: ChatViewModel,
        showsComposer: Bool = true,
        showsSidebarButton: Bool = true,
        controlCenter: ChatControlCenter? = nil,
        workRoomPath: Binding<[String]> = .constant([]),
        onAddAgent: @escaping () -> Void = {},
        onOpenSidebar: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.showsComposer = showsComposer
        self.showsSidebarButton = showsSidebarButton
        self.controlCenter = controlCenter
        _workRoomPath = workRoomPath
        self.onAddAgent = onAddAgent
        self.onOpenSidebar = onOpenSidebar
    }

    /// The chat stays mounted under the Control tab, so VoiceOver must not read it there.
    private var isControlTabShowing: Bool {
        if case .tabs(_, let selection, _) = controlCenter {
            return selection.wrappedValue == .control
        }
        return false
    }

    var body: some View {
        NavigationStack(path: $workRoomPath) {
            ChatScreen(
                viewModel: viewModel,
                showsComposer: showsComposer,
                showsSidebarButton: showsSidebarButton,
                onAddAgent: onAddAgent,
                onOpenSidebar: onOpenSidebar,
                onOpenWorkRoom: { workRoomPath.append($0) }
            )
            // The Control tab and its switch below hang off this root screen, so a pushed Work Room has neither.
            .navigationDestination(for: String.self) { workRoomID in
                WorkRoomScreen(viewModel: viewModel, workRoomID: workRoomID)
            }
            .accessibilityHidden(isControlTabShowing)
            .overlay {
                if case .tabs(let dashboard, let selection, _) = controlCenter {
                    // Mounted once and only shown or hidden, so the page keeps its state across tab switches.
                    // After a skill button, back to Chat where its turn runs
                    OOControlCenterPane(dashboard: dashboard, skills: viewModel.activeAgentSkills) { message in
                        viewModel.runControlCenterSkill(message)
                        selection.wrappedValue = .chat
                    }
                    .opacity(selection.wrappedValue == .control ? 1 : 0)
                    .allowsHitTesting(selection.wrappedValue == .control)
                    .accessibilityHidden(selection.wrappedValue != .control)
                }
            }
            .onChange(of: isControlTabShowing) { _, isShowing in
                if isShowing {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                    )
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if case .tabs(_, let selection, let attention) = controlCenter {
                    OOViewSwitch(selection: selection, attention: attention)
                        .frame(maxWidth: .infinity)
                        .background(OOColor.paper)
                }
            }
            .toolbar {
                if case .beside(let isOpen, let toggle) = controlCenter {
                    ToolbarItem(placement: .topBarTrailing) {
                        OOControlCenterButton(isOpen: isOpen, action: toggle)
                    }
                }
            }
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    var showsSidebarButton: Bool = true
    var onAddAgent: () -> Void = {}
    let onOpenSidebar: () -> Void
    let onOpenWorkRoom: (String) -> Void
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var bottomAnchorY: CGFloat = 0
    @State var scrollViewportHeight: CGFloat = 0
    @State var shouldFollowLatest = true
    @State var promptFocusRequest = 0
    @State var isPromptFocused = false
    let bottomAnchorID = "chat.bottomAnchor"
    let scrollCoordinateSpace = "chat.scroll"

    var body: some View {
        VStack(spacing: 0) {
            if showsComposer {
                    balanceNotice
                }

            if let conversation = viewModel.activeConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if shouldShowEmptyState(for: conversation) {
                                EmptyChatState(
                                    agentName: viewModel.activeAgent?.name ?? "Your agent",
                                    skills: StarterSkills.ordered(
                                        viewModel.activeAgentSkills ?? [],
                                        dashboard: viewModel.activeDashboard
                                    ),
                                    showsSkills: showsComposer
                                ) { skill in
                                    viewModel.prompt = "/\(skill.name) "
                                    promptFocusRequest += 1
                                } onShowAllSkills: {
                                    // A lone "/" opens the composer's skill picker.
                                    viewModel.prompt = "/"
                                    promptFocusRequest += 1
                                }
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: max(0, scrollViewportHeight - 32),
                                    alignment: .bottom
                                )
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            ForEach(timelineEntries(for: conversation)) { entry in
                                timelineView(for: entry)
                                    .id(entry.id)
                                    .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let approval = viewModel.activePendingApproval {
                                ApprovalCard(approval: approval) {
                                    viewModel.allowPendingApprovalOnce(id: approval.id)
                                } onTrustSession: {
                                    viewModel.trustPendingApprovalForSession(id: approval.id)
                                } onSkip: {
                                    viewModel.skipPendingApproval(id: approval.id)
                                } onStop: {
                                    viewModel.stopPendingApproval(id: approval.id)
                                } onExplain: {
                                    viewModel.explainPendingApproval(id: approval.id)
                                }
                                .id("pendingApproval")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let checkpoint = viewModel.activePendingUlwCheckpoint {
                                UlwCheckpointCard(checkpoint: checkpoint) {
                                    viewModel.continueUlw(id: checkpoint.id)
                                } onAcceptEdits: {
                                    viewModel.switchModeFromUlwCheckpoint(id: checkpoint.id, to: .accept)
                                } onSafeMode: {
                                    viewModel.switchModeFromUlwCheckpoint(id: checkpoint.id, to: .safe)
                                }
                                .id("pendingUlwCheckpoint")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let review = viewModel.activePendingPlanReview {
                                PlanReviewCard(review: review) {
                                    viewModel.approvePendingPlan(id: review.id)
                                } onRequestChanges: { feedback in
                                    viewModel.requestPlanChanges(id: review.id, feedback: feedback)
                                }
                                .id("pendingPlanReview")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }

                            if let pending = viewModel.activePendingAskUser {
                                AskUserCard(pending: pending) { answer in
                                    viewModel.answerPendingAskUser(id: pending.id, answer: answer)
                                }
                                .id("pendingAskUser")
                                .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: ChatBottomAnchorPreferenceKey.self,
                                            value: geometry.frame(
                                                in: .named(scrollCoordinateSpace)
                                            ).maxY
                                        )
                                    }
                                }
                        }
                        .id(conversation.id)
                        .transition(conversationTransition)
                        .padding(.horizontal)
                        .padding(.vertical, 16)
                        .frame(maxWidth: ChatReadableWidth.maximum)
                        .frame(maxWidth: .infinity)
                        .animation(
                            AppMotion.contentArrival(reduceMotion: reduceMotion),
                            value: conversation.messages.map(\.id)
                        )
                        .animation(
                            AppMotion.contentArrival(reduceMotion: reduceMotion),
                            value: viewModel.pendingInteractionID
                        )
                    }
                    .coordinateSpace(name: scrollCoordinateSpace)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ChatViewportHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: scrollUpdate(for: conversation)) { previous, current in
                        guard shouldFollowLatest else {
                            return
                        }
                        scrollToBottom(
                            proxy,
                            animated: current.isNewMessage(comparedTo: previous)
                        )
                    }
                    .onChange(of: viewModel.pendingInteractionID) {
                        if let interactionID = viewModel.pendingInteractionID {
                            withAnimation(AppMotion.contentArrival(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(scrollTarget(for: interactionID), anchor: .bottom)
                            }
                        }
                    }
                    .onPreferenceChange(ChatBottomAnchorPreferenceKey.self) { value in
                        bottomAnchorY = value
                        updateFollowLatest()
                    }
                    .onPreferenceChange(ChatViewportHeightPreferenceKey.self) { value in
                        let wasFollowingLatest = shouldFollowLatest
                        scrollViewportHeight = value
                        updateFollowLatest()
                        if isPromptFocused && wasFollowingLatest {
                            scrollToBottom(proxy)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if showsComposer {
                            Composer(
                                viewModel: viewModel,
                                focusRequest: promptFocusRequest
                            ) { isFocused in
                                isPromptFocused = isFocused
                                guard isFocused, shouldFollowLatest else {
                                    return
                                }
                                scrollToBottomAfterKeyboardLayout(proxy)
                            }
                                .padding(.top, 8)
                                .background {
                                    ChatSurfacePalette.backgroundBase
                                        .ignoresSafeArea(edges: .bottom)
                                }
                        }
                    }
                }
            } else {
                noChatState
            }
        }
        .background {
            ChatScreenBackdrop()
                .ignoresSafeArea()
        }
        // connect as soon as the chat is on screen for control center
        .task(id: viewModel.activeConversationID) {
            viewModel.connectActiveConversationOnOpen()
        }
        .navigationTitle(viewModel.activeConversation?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(viewModel.activeConversation?.title ?? "Chat")
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)

                    // No chat, nothing to connect: a status here would only read as a fault.
                    if viewModel.activeConversation != nil {
                        sessionStatus
                            .contentTransition(.opacity)
                    }
                }
                .animation(
                    AppMotion.stateChange(reduceMotion: reduceMotion),
                    value: viewModel.activeConversationID
                )
            }

            if showsSidebarButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onOpenSidebar()
                    } label: {
                        Image(systemName: "sidebar.left")
                            .overlay(alignment: .topTrailing) {
                                if let state = viewModel.backgroundActivityState {
                                    ConversationStatusDot(state: state)
                                        .offset(x: 4, y: -3)
                                        .transition(AppMotion.statusTransition(reduceMotion: reduceMotion))
                                }
                            }
                            .animation(AppMotion.statusChange, value: viewModel.backgroundActivityState)
                    }
                    .accessibilityLabel(backgroundAttentionLabel)
                }

                // Invisible mirror of the leading button: with a leading item only, UIKit
                // centers an overflowing principal title in the leftover asymmetric space,
                // pushing the title and status pill right of screen center.
                trailingBalanceItem
            }
        }
    }

    /// No chat open. With an agent, the next step is a chat with it; with none, adding one.
    @ViewBuilder
    private var noChatState: some View {
        if let agent = viewModel.activeAgent ?? viewModel.agents.first {
            ContentUnavailableView {
                Label("No chat open", systemImage: "bubble.left")
            } description: {
                Text("Start a chat with \(agent.name), or pick one from the sidebar.")
            } actions: {
                Button {
                    _ = viewModel.createConversation(for: agent)
                } label: {
                    Text("New chat with \(agent.name)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.ooPrimary)

                Button("Add agent", action: onAddAgent)
                    .buttonStyle(.ooSecondary)
            }
        } else {
            ContentUnavailableView {
                Label("Add your first agent", systemImage: "person.badge.plus")
            } description: {
                Text("An agent's address starts with 0x. Find it where the agent runs, or scan its QR code.")
            } actions: {
                Button("Add agent", action: onAddAgent)
                    .buttonStyle(.ooPrimary)
            }
        }
    }

    private var sessionStatus: some View {
        let text = viewModel.activeSessionStatusText
        return ZStack {
            // The longest label reserves the width, so the header doesn't resize when the status changes.
            OOStatusDot(label: "Not Connected", isLive: false)
                .hidden()

            OOStatusDot(label: text, isLive: viewModel.isActiveSessionLive)
                .id(text)
                .transition(AppMotion.statusTransition(reduceMotion: reduceMotion))
        }
        .animation(AppMotion.stateChange(reduceMotion: reduceMotion), value: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session status: \(text)")
    }

    @ViewBuilder
    private var balanceNotice: some View {
        if let profile = viewModel.activeAgentProfile,
           let notice = AgentBalance.notice(for: profile.balanceUSD) {

            let message = AgentBalance.message(for: notice)

            let background = Color(
                red: 42.0 / 255.0,
                green: 32.0 / 255.0,
                blue: 25.0 / 255.0
            )

            let border = Color(
                red: 58.0 / 255.0,
                green: 37.0 / 255.0,
                blue: 29.0 / 255.0
            )

            let textColor = Color(
                red: 253.0 / 255.0,
                green: 142.0 / 255.0,
                blue: 134.0 / 255.0
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(message)
                        .multilineTextAlignment(.center)

                    addCreditsLink(color: textColor)
                }

                VStack(spacing: 4) {
                    Text(message)
                        .multilineTextAlignment(.center)

                    addCreditsLink(color: textColor)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(background)
            .overlay(alignment: .top) {
                border.frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private func addCreditsLink(color: Color) -> some View {
        if let address = viewModel.activeAgent?.address,
           let url = AgentBalance.topUpURL(agentAddress: address) {
            Link(destination: url) {
                Text("Add credits")
                    .fontWeight(.semibold)
                    .underline()
                    .foregroundStyle(color)
            }
            .frame(minHeight: 24)
        }
    }
}

/// Looks the Work Room up by id on every render, so the pushed screen follows live frames.
private struct WorkRoomScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let workRoomID: String

    var body: some View {
        Group {
            if let conversationID = viewModel.activeConversationID,
               let workRoom = viewModel.conversationState.workRoomStore(for: conversationID).workRoom(id: workRoomID) {
                OOWorkRoomView(workRoom: workRoom)
            }
        }
        // The heading is inside the Work Room, so the bar title stays short.
        .navigationTitle("Work Room")
        .navigationBarTitleDisplayMode(.inline)
    }
}
