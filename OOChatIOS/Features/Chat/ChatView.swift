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
    /// The open drawer covers the chat. A hidden modifier outside the NavigationStack doesn't
    /// reach VoiceOver in here, so the shell passes it in.
    var isCoveredByDrawer = false

    init(
        viewModel: ChatViewModel,
        showsComposer: Bool = true,
        showsSidebarButton: Bool = true,
        controlCenter: ChatControlCenter? = nil,
        workRoomPath: Binding<[String]> = .constant([]),
        onAddAgent: @escaping () -> Void = {},
        onOpenSidebar: @escaping () -> Void = {},
        isCoveredByDrawer: Bool = false
    ) {
        self.viewModel = viewModel
        self.showsComposer = showsComposer
        self.showsSidebarButton = showsSidebarButton
        self.controlCenter = controlCenter
        _workRoomPath = workRoomPath
        self.onAddAgent = onAddAgent
        self.onOpenSidebar = onOpenSidebar
        self.isCoveredByDrawer = isCoveredByDrawer
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
            .accessibilityHidden(isControlTabShowing || isCoveredByDrawer)
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
    // Something new arrived while you were scrolled up; shown as a dot on Jump to latest.
    @State var hasUnseenLatest = false
    @State var promptFocusRequest = 0
    @State var isPromptFocused = false
    /// When the open chat started connecting; the header turns "Connecting…" into "Can't connect" after 10 s.
    @State var connectingSince: Date?
    let bottomAnchorID = "chat.bottomAnchor"
    let scrollCoordinateSpace = "chat.scroll"

    var body: some View {
        VStack(spacing: 0) {
            // The solid bar draws no line of its own, so this marks where the header ends.
            OOColor.hairline
                .frame(height: 1)
                .accessibilityHidden(true)

            if showsComposer {
                AgentBalanceNotice(
                    balanceUSD: viewModel.activeAgentProfile?.balanceUSD,
                    agentAddress: viewModel.activeAgent?.address
                )
            }

            if let conversation = viewModel.activeConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                if shouldShowEmptyState(for: conversation) {
                                    EmptyChatState(
                                        agentName: viewModel.activeAgent?.name ?? "Your agent",
                                        skills: StarterSkills.ordered(
                                            viewModel.activeAgentSkills ?? [],
                                            dashboard: viewModel.activeDashboard
                                        ),
                                        showsSkills: showsComposer && !viewModel.isFromPreviousIdentity(conversation)
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

                                // A chat from a previous identity never sends again, so it offers no Retry.
                                let offersRetry = !viewModel.isFromPreviousIdentity(conversation)
                                ForEach(timelineEntries(for: conversation)) { entry in
                                    timelineView(for: entry, offersRetry: offersRetry)
                                        .id(entry.id)
                                        .transition(AppMotion.materialize(reduceMotion: reduceMotion))
                                }
                                .environment(
                                    \.toolAwaitingApprovalID,
                                    viewModel.toolAwaitingApprovalID(in: conversation.id)
                                )

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
                                    } onSwitchToAuto: {
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
                                    } onDiscard: {
                                        viewModel.discardPendingPlan(id: review.id)
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
                            // Outside the lazy stack so it is always laid out: inside, it is dropped when you scroll
                            // far up, its position reads 0, and the chat wrongly thinks you are at the bottom.
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .onGeometryChange(for: CGFloat.self) { geometry in
                                    geometry.frame(in: .named(scrollCoordinateSpace)).maxY
                                } action: { maxY in
                                    bottomAnchorY = maxY
                                    updateFollowLatest()
                                }
                        }
                    }
                    .coordinateSpace(name: scrollCoordinateSpace)
                    // Read directly: the old preference-key version never arrived, so the height
                    // stayed 0 and the chat always thought you were at the bottom.
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        let wasFollowingLatest = shouldFollowLatest
                        scrollViewportHeight = height
                        updateFollowLatest()
                        if isPromptFocused && wasFollowingLatest {
                            scrollToBottom(proxy)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        scrollToBottom(proxy, animated: false)
                    }
                    .onChange(of: scrollUpdate(for: conversation)) { previous, current in
                        let isNewMessage = current.isNewMessage(comparedTo: previous)
                        guard shouldFollowLatest else {
                            // Only the agent's reply lights the dot, not your message, "Thinking…"
                            // or tool steps.
                            let latestRole = viewModel.activeConversation?.messages.last?.role
                            if isNewMessage && latestRole == .agent {
                                hasUnseenLatest = true
                            }
                            return
                        }
                        scrollToBottom(proxy, animated: isNewMessage)
                    }
                    .onChange(of: viewModel.pendingInteractionID) {
                        if let interactionID = viewModel.pendingInteractionID {
                            withAnimation(AppMotion.contentArrival(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(scrollTarget(for: interactionID), anchor: .bottom)
                            }
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if showsComposer, viewModel.isFromPreviousIdentity(conversation) {
                            PreviousIdentityBar {
                                viewModel.startNewChat(withAgentOf: conversation)
                            }
                            .background {
                                ChatSurfacePalette.backgroundBase
                                    .ignoresSafeArea(edges: .bottom)
                            }
                        } else if showsComposer {
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
                                // Above the composer's top edge, drawn over the messages. An overlay on the
                                // scroll view sits behind the composer, since the scroll view runs under it.
                                .overlay(alignment: .top) {
                                    // The ZStack stays put, so the button's own transition can animate.
                                    ZStack {
                                        jumpToLatestButton(proxy)
                                    }
                                        .alignmentGuide(.top) { $0[.bottom] }
                                        .animation(
                                            AppMotion.stateChange(reduceMotion: reduceMotion),
                                            value: isFarFromLatest
                                        )
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
        // Solid, so messages scrolling underneath never sit behind the title and status.
        .toolbarBackground(OOColor.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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

                // Also balances the leading button. With a leading item only, UIKit centres a
                // long title in the space left over, which pushes it right of centre.
                newChatItem
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
        // Ticks once a second only while connecting, to turn into "Can't connect" at 10 s.
        TimelineView(.periodic(from: .now, by: connectingSince == nil ? 3_600 : 1)) { context in
            statusLabel(
                viewModel.activeConnectionStatus(
                    connectingFor: connectingSince.map { context.date.timeIntervalSince($0) } ?? 0
                )
            )
        }
        .onChange(of: viewModel.isActiveChatConnecting, initial: true) { _, isConnecting in
            connectingSince = isConnecting ? (connectingSince ?? .now) : nil
        }
        .onChange(of: viewModel.activeConversationID) {
            connectingSince = viewModel.isActiveChatConnecting ? .now : nil
        }
    }

    /// Green when live, red when it failed, grey while waiting. When a retry can help,
    /// the whole status is the Retry button.
    @ViewBuilder
    private func statusLabel(_ status: ChatConnectionStatus) -> some View {
        let detail = status.detail(agentName: viewModel.activeAgent?.name ?? "the agent")
        let mark = HStack(spacing: 4) {
            OOStatusDot(label: status.label, tone: status.tone)
            if status.canRetry {
                Text("· Retry")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OOColor.primary)
            }
        }
        .animation(AppMotion.stateChange(reduceMotion: reduceMotion), value: status)

        if status.canRetry {
            Button {
                // Same as Settings → Reconnect.
                Task { await viewModel.reconnect() }
            } label: {
                // A taller tap area that takes no layout space, so the title above doesn't move.
                mark
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .padding(.vertical, -12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(detail)
            .accessibilityHint("Tries to connect again")
        } else {
            mark
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(detail)
        }
    }
}

/// Sits where the composer would in a chat from a previous identity: the chat stays readable, and the
/// only way on is a new chat with the same agent as the current Address.
struct PreviousIdentityBar: View {
    let onNewChat: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Label(PreviousIdentity.label, systemImage: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(PreviousIdentity.startNewChat, action: onNewChat)
                .buttonStyle(.ooPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}

/// Looks the Work Room up by id on every render, so the pushed screen follows live frames.
private struct WorkRoomScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let workRoomID: String
    @StateObject private var dictation: WorkRoomDictation

    init(viewModel: ChatViewModel, workRoomID: String) {
        self.viewModel = viewModel
        self.workRoomID = workRoomID
        _dictation = StateObject(wrappedValue: WorkRoomDictation(controller: viewModel.voiceInputController))
    }

    var body: some View {
        Group {
            if let conversationID = viewModel.activeConversationID,
               case let store = viewModel.conversationState.workRoomStore(for: conversationID),
               let workRoom = store.workRoom(id: workRoomID) {
                OOWorkRoomView(
                    workRoom: workRoom,
                    onDecide: { store.decide($0, in: workRoomID) },
                    onStop: { store.stop(in: workRoomID) },
                    onDraftChange: { store.setDraft($0, in: workRoomID) },
                    onSend: { store.send(in: workRoomID) },
                    onChangePermission: { store.changePermission(to: $0, confirmRisk: $1, in: workRoomID) },
                    mic: OOWorkRoomMic(state: dictation.micState, guidance: dictation.guidance) {
                        dictation.toggle(in: workRoomID) { _ = store.appendDictation($0, in: workRoomID) }
                    }
                )
                .onChange(of: workRoom.composer.canDictate) { _, canDictate in
                    if !canDictate { dictation.cancel() }
                }
            }
        }
        .onDisappear { dictation.cancel() }
        // The heading is inside the Work Room, so the bar title stays short.
        .navigationTitle("Work Room")
        .navigationBarTitleDisplayMode(.inline)
    }
}
