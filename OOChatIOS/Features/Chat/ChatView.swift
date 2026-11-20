import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void

    init(
        viewModel: ChatViewModel,
        showsComposer: Bool = true,
        showsSidebarButton: Bool = true,
        onOpenSidebar: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.showsComposer = showsComposer
        self.showsSidebarButton = showsSidebarButton
        self.onOpenSidebar = onOpenSidebar
    }

    var body: some View {
        NavigationStack {
            ChatScreen(
                viewModel: viewModel,
                showsComposer: showsComposer,
                showsSidebarButton: showsSidebarButton,
                onOpenSidebar: onOpenSidebar
            )
        }
    }
}

struct ChatScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    let showsComposer: Bool
    var showsSidebarButton: Bool = true
    let onOpenSidebar: () -> Void
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
            if let conversation = viewModel.activeConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if shouldShowEmptyState(for: conversation) {
                                EmptyChatState(
                                    agentName: viewModel.activeAgent?.name ?? "Your agent",
                                    showsSuggestions: showsComposer
                                ) { suggestion in
                                    viewModel.prompt = suggestion.prompt
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
                ContentUnavailableView("No Conversation", systemImage: "bubble.left")
            }
        }
        .background {
            ChatScreenBackdrop()
                .ignoresSafeArea()
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

                    HStack {
                        AgentPresencePill(
                            label: viewModel.activeSessionStatusText,
                            isLive: viewModel.isActiveSessionLive
                        )
                    }
                    .contentTransition(.opacity)
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
}
