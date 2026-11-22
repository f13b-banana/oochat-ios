import ConnectOnionKit
import SwiftUI

extension ChatScreen {
    func shouldShowEmptyState(for conversation: Conversation) -> Bool {
        conversation.messages.isEmpty && viewModel.pendingInteractionID == nil
    }

    var backgroundAttentionLabel: String {
        switch viewModel.backgroundActivityState {
        case .actionRequired:
            return "Open sidebar, action required"
        case .failedDelivery:
            return "Open sidebar, a message failed to send"
        case .completedUnread:
            return "Open sidebar, background task completed"
        case .working, nil:
            return "Open sidebar"
        }
    }

    /// New chat sits opposite the sidebar button, so the title stays centred. Tap starts a chat
    /// with the current agent, the same as the drawer's New chat; hold to pick another agent.
    var newChatItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(viewModel.chattableAgents) { agent in
                    Button(agent.displayName) {
                        _ = viewModel.createConversation(for: agent)
                    }
                }
            } label: {
                // No frame of our own: the bar already makes it a 44 pt circle. A bigger frame
                // makes it wider than the sidebar button and pushes the title off centre.
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(OOColor.primary)
            } primaryAction: {
                startNewChat()
            }
            .tint(OOColor.primary)
            .accessibilityLabel(viewModel.newChatAgent.map { "New chat with \($0.displayName)" } ?? "New chat")
            .accessibilityHint("Hold to choose an agent")
            .accessibilityIdentifier("chat.newChat")
        }
    }

    /// With no agent to chat with, New chat adds one instead, as in the drawer.
    func startNewChat() {
        guard let agent = viewModel.newChatAgent else {
            onAddAgent()
            return
        }
        _ = viewModel.createConversation(for: agent)
    }

    func scrollTarget(for interactionID: String) -> String {
        if interactionID == viewModel.activePendingApproval?.id {
            return "pendingApproval"
        }
        if interactionID == viewModel.activePendingUlwCheckpoint?.id {
            return "pendingUlwCheckpoint"
        }
        if interactionID == viewModel.activePendingPlanReview?.id {
            return "pendingPlanReview"
        }
        return "pendingAskUser"
    }

    // The tool the approval card asks about stays in the timeline, marked Awaiting approval:
    // the card is where you decide, the row is the record of what's happening.
    func timelineEntries(for conversation: Conversation) -> [ChatTimelineEntry] {
        ChatTimelineBuilder.entries(
            from: conversation.messages,
            workRooms: viewModel.conversationState.workRoomStore(for: conversation.id)
        )
    }

    func messageMenu(for message: ChatMessage) -> MessageMenu {
        MessageMenu(
            canEdit: viewModel.canEdit(message),
            canRetry: viewModel.canRetry(message),
            onEdit: { viewModel.editLatestMessage(to: $0) },
            onRetry: { viewModel.retryLatestReply() }
        )
    }

    @ViewBuilder
    func timelineView(for entry: ChatTimelineEntry, offersRetry: Bool) -> some View {
        switch entry {
        case .message(let message):
            let failure = message.deliveryState == .failed ? viewModel.failure(forMessageID: message.id) : nil
            MessageBubble(
                message: message,
                menu: messageMenu(for: message),
                failureReason: failure?.reason,
                failureDetails: failure?.details,
                agentName: viewModel.activeAgent?.displayName ?? "Agent",
                onStop: viewModel.isProcessing ? { viewModel.stopActiveResponse() } : nil,
                onRetry: offersRetry ? { viewModel.retryMessage(message) } : nil
            )
        case .toolCallGroup(let messages):
            ToolCallGroupView(messages: messages)
        case .workRoom(let workRoom):
            let store = viewModel.activeConversationID.map { viewModel.conversationState.workRoomStore(for: $0) }
            OOWorkRoomCard(workRoom: workRoom, onOpen: {
                onOpenWorkRoom(workRoom.id)
            }, onDecide: { store?.decide($0, in: workRoom.id) })
        }
    }

    func scrollUpdate(for conversation: Conversation) -> ChatScrollUpdate {
        let message = conversation.messages.last
        return ChatScrollUpdate(
            conversationID: conversation.id,
            messageCount: conversation.messages.count,
            messageID: message?.id,
            contentLength: message?.content.count ?? 0,
            deliveryState: message?.deliveryState.rawValue ?? "",
            toolState: message?.toolState?.rawValue ?? ""
        )
    }

    func updateFollowLatest() {
        guard scrollViewportHeight > 0 else {
            return
        }
        shouldFollowLatest = bottomAnchorY - scrollViewportHeight
            <= ChatScrollMetrics.followThreshold
        if shouldFollowLatest {
            hasUnseenLatest = false
        }
    }

    /// About 1.5 screens above the newest message, measured in the chat's own height.
    var isFarFromLatest: Bool {
        scrollViewportHeight > 0
            && bottomAnchorY - scrollViewportHeight
                > scrollViewportHeight * ChatScrollMetrics.jumpToLatestScreens
    }

    /// Shown while you're scrolled up; brings you back to the newest message.
    @ViewBuilder
    func jumpToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        if isFarFromLatest {
            Button {
                scrollToBottom(proxy)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OOColor.ink)
                    .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                    .background(OOColor.paper, in: Circle())
                    .overlay(Circle().stroke(OOColor.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .overlay(alignment: .topTrailing) {
                        if hasUnseenLatest {
                            Circle()
                                .fill(OOColor.primary)
                                .frame(width: 10, height: 10)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasUnseenLatest ? "Jump to latest, new messages" : "Jump to latest")
            .padding(.bottom, 24)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
        }
    }

    func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    func scrollToBottomAfterKeyboardLayout(_ proxy: ScrollViewProxy) {
        scrollToBottom(proxy)
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatScrollMetrics.keyboardFollowUpDelay) {
            guard isPromptFocused else {
                return
            }
            scrollToBottom(proxy)
        }
    }

    var conversationTransition: AnyTransition {
        guard !reduceMotion else {
            return .opacity
        }

        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 10, y: 0)),
            removal: .opacity
        )
    }
}
