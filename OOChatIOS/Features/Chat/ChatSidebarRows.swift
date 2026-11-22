import ConnectOnionKit
import SwiftUI

/// An agent's folding header, drawn by the shared kit header: status dot, name, then ✋ and
/// the chat count while folded. Tapping folds it; ＋ starts a chat with this agent.
struct SidebarAgentRow: View {
    let agent: SavedAgent
    /// The name the sidebar shows; the same helper names it in New chat and the attention panel.
    /// A blank name says "Agent"; the default name (the address) is shortened to 0x1234...abcd.
    static func displayName(for agent: SavedAgent) -> String {
        let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "Agent"
        }
        guard name == SavedAgent.defaultName(for: agent.address), agent.address.count > 12 else {
            return name
        }
        return "\(agent.address.prefix(6))...\(agent.address.suffix(4))"
    }

    let isExpanded: Bool
    let isOnline: Bool
    var chatCount = 0
    var needsYou = false
    /// New chat goes here; its name reads in the selection green.
    var isCurrent = false
    let onToggle: () -> Void
    let onRename: () -> Void
    let onEdit: () -> Void
    let onAddChat: () -> Void
    let onShowQRCode: (URL) -> Void
    let onDelete: () -> Void
    var isStation = false

    var body: some View {
        OOSidebarAgentHeader(
            name: Self.displayName(for: agent),
            isOnline: isOnline,
            isExpanded: isExpanded,
            chatCount: chatCount,
            needsYou: needsYou,
            isCurrent: isCurrent,
            onToggle: onToggle,
            // A Claude Station opens rather than folds: no chevron, and its row is the way in.
            disclosure: isStation ? .hidden : .trailing,
            isStation: isStation
        ) {
            // Every agent: start a chat with it without opening one of its chats first. A
            // Station has no chats of its own, so its ＋ keeps its place but isn't shown.
            addChatButton
                .opacity(isStation ? 0 : 1)
                .allowsHitTesting(!isStation)
                .accessibilityHidden(isStation)
        }
        .contextMenu {
            if isStation {
                Button(action: onToggle) {
                    Label("Open Station", systemImage: "terminal")
                }
            } else {
                Button(action: onAddChat) {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            Button(action: onEdit) {
                Label("Edit Agent", systemImage: "slider.horizontal.3")
            }
            if let shareURL = AgentShareURL.url(for: agent.address) {
                ShareLink(item: shareURL) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                Button {
                    onShowQRCode(shareURL)
                } label: {
                    Label("Show QR Code", systemImage: "qrcode")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var addChatButton: some View {
        Button(action: onAddChat) {
            Image(systemName: "plus")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(OOColor.inkSecondary)
                // 44 pt to hit, glyph unchanged (story 162).
                .frame(width: ooMinimumTarget, height: ooMinimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New chat with \(Self.displayName(for: agent))")
    }
}

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
                isUnread: activityState == .completedUnread
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                OOColor.hairline
                    .frame(height: 1)
                    .padding(.leading, OOSidebarMetrics.chatIndent)
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
