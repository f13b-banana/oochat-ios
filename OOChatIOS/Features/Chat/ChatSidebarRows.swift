import ConnectOnionKit
import SwiftUI

/// One chat, drawn by the shared kit row: title, then its time or what's happening instead.
struct SidebarConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let activityState: ConversationActivityState?
    var isFromPreviousIdentity = false
    /// What the row says in place of its time (Approve, Reply, Not sent, Working). Without it,
    /// the activity state's own mapping, which can't tell a question from an approval.
    var status: SidebarChatStatus?
    /// The last message under the title, when "Show message previews" is on in Settings.
    var preview: String?
    /// A soft line under the row, between it and the next chat of the same agent.
    var showsSeparator = false
    /// Where the title starts: the agent pane lists chats flush with its other rows.
    var indent: CGFloat = OOSidebarMetrics.chatIndent
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            OOSidebarChatRow(
                title: conversation.isUntitled ? Conversation.defaultTitle : conversation.title,
                lastActivity: conversation.updatedAt,
                status: status ?? activityState?.sidebarStatus,
                preview: isFromPreviousIdentity ? PreviousIdentity.label : preview,
                isSelected: isSelected,
                isUnread: activityState == .completedUnread,
                indent: indent
            )
            .frame(minHeight: ooMinimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                OOColor.hairline
                    .frame(height: 1)
                    .padding(.leading, indent)
                    .padding(.trailing, OOSidebarMetrics.horizontalPadding)
                    .accessibilityHidden(true)
            }
        }
        .listRowInsets(SidebarMetrics.conversationRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text("Delete"), onDelete)
        .accessibilityAction(named: Text("Rename"), onRename)
    }
}

extension ConversationActivityState {
    /// The row shows waiting, failed and working in place of its time; a finished reply you
    /// haven't opened shows as a semibold title instead.
    var sidebarStatus: SidebarChatStatus? {
        switch self {
        case .actionRequired:
            return .approval
        case .failedDelivery:
            return .notSent
        case .working:
            return .working
        case .completedUnread:
            return nil
        }
    }
}

struct ConversationStatusDot: View {
    let state: ConversationActivityState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: SidebarMetrics.statusDotSize, height: SidebarMetrics.statusDotSize)
            .overlay {
                Circle()
                    .stroke(
                        Color(.systemBackground),
                        lineWidth: SidebarMetrics.activityIndicatorStrokeWidth
                    )
            }
            .accessibilityLabel(accessibilityLabel)
    }

    private var color: Color {
        switch state {
        case .actionRequired:
            return Color(.systemYellow)
        case .completedUnread:
            return Color(.systemBlue)
        case .failedDelivery:
            return Color(.systemRed)
        case .working:
            return AppTheme.primary
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .actionRequired:
            return "Action required"
        case .working:
            return "Agent working"
        case .completedUnread:
            return "Background task completed"
        case .failedDelivery:
            return "Message failed to send"
        }
    }
}
