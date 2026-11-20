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

    // `sharedBackgroundVisibility` is an iOS 26 API. The `#available` check keeps it
    // safe at run time, but availability does not help at COMPILE time: the symbol
    // has to exist in the SDK being built against, and an older SDK fails outright.
    // The compiler check compiles the whole branch out on toolchains that predate
    // the API, so this file builds on Xcode 15 as well as Xcode 26 — where the
    // iOS 26 polish (suppressing the empty glass capsule behind a hidden toolbar
    // item) is still applied. Swift 6.2 is the version that ships with Xcode 26,
    // and is used here as a proxy for "the iOS 26 SDK is present".
    @ToolbarContentBuilder
    var trailingBalanceItem: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                hiddenSidebarButtonMirror
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                hiddenSidebarButtonMirror
            }
        }
        #else
        ToolbarItem(placement: .topBarTrailing) {
            hiddenSidebarButtonMirror
        }
        #endif
    }

    private var hiddenSidebarButtonMirror: some View {
        Button {
        } label: {
            Image(systemName: "sidebar.left")
        }
        .hidden()
        .accessibilityHidden(true)
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

    func shouldShowMessage(_ message: ChatMessage, in conversationID: String) -> Bool {
        !viewModel.isToolCallCoveredByPendingApproval(message, in: conversationID)
    }

    func timelineEntries(for conversation: Conversation) -> [ChatTimelineEntry] {
        ChatTimelineBuilder.entries(
            from: conversation.messages.filter {
                shouldShowMessage($0, in: conversation.id)
            },
            workRooms: viewModel.conversationState.workRoomStore(for: conversation.id)
        )
    }

    @ViewBuilder
    func timelineView(for entry: ChatTimelineEntry) -> some View {
        switch entry {
        case .message(let message):
            MessageBubble(message: message) {
                viewModel.retryMessage(message)
            }
        case .toolCallGroup(let messages):
            ToolCallGroupView(messages: messages)
        case .workRoom(let workRoom):
            // No-op until the Work Room screen exists; it will push onto this chat's NavigationStack.
            OOWorkRoomCard(workRoom: workRoom) {}
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
