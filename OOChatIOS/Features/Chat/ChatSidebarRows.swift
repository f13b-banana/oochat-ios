import ConnectOnionKit
import SwiftUI

struct SidebarAgentRow: View {
    let agent: SavedAgent
    let isExpanded: Bool
    let isOnline: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onEdit: () -> Void
    let onAddChat: () -> Void
    let onShowQRCode: (URL) -> Void
    let onDelete: () -> Void
    var isStation = false

    var body: some View {
        HStack(spacing: SidebarMetrics.agentRowSpacing) {
            toggleButton

            addChatButton
        }
        .contextMenu {
            Button {
                onRename()
            } label: {
                sidebarContextMenuLabel("Rename", systemImage: "pencil", color: Color(.label))
            }
            .tint(Color(.label))

            Button {
                onEdit()
            } label: {
                sidebarContextMenuLabel("Edit Agent", systemImage: "slider.horizontal.3", color: Color(.label))
            }
            .tint(Color(.label))

            if let shareURL = AgentShareURL.url(for: agent.address) {
                ShareLink(item: shareURL) {
                    sidebarContextMenuLabel("Share Link", systemImage: "square.and.arrow.up", color: Color(.label))
                }
                .tint(Color(.label))

                Button {
                    onShowQRCode(shareURL)
                } label: {
                    sidebarContextMenuLabel("Show QR Code", systemImage: "qrcode", color: Color(.label))
                }
                .tint(Color(.label))
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                sidebarContextMenuLabel("Delete", systemImage: "trash", color: AppTheme.destructive)
            }
            .tint(AppTheme.destructive)
        }
    }

    private var toggleButton: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: SidebarMetrics.agentRowSpacing) {
                Image(systemName: "chevron.forward")
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarMetrics.chevronWidth, height: SidebarMetrics.agentRowHeight)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                HStack(spacing: SidebarMetrics.agentAvatarSpacing) {
                    // The tile carries the live dot on its corner, as in O Chat's sidebar.
                    OOAvatarTile(name: avatarName, address: agent.address, isOnline: isOnline, isStation: isStation)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(sidebarAgentName(for: agent))
                            .font(.body)
                            .foregroundStyle(OOColor.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isStation {
                            OOStationCaption()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(isOnline ? "Online" : "")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AppPressButtonStyle(pressedScale: 0.985, pressedOpacity: 0.90))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addChatButton: some View {
        Button(action: onAddChat) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: SidebarMetrics.agentActionIconSize, weight: .regular))
                .foregroundStyle(Color(.label))
                .frame(
                    width: SidebarMetrics.agentActionButtonSize,
                    height: SidebarMetrics.agentActionButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterButtonStyle())
        .accessibilityLabel("Add Chat")
    }

    private var avatarName: String {
        let trimmedName = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName == SavedAgent.defaultName(for: agent.address) ? "" : trimmedName
    }

    private func sidebarAgentName(for agent: SavedAgent) -> String {
        let trimmedName = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName == SavedAgent.defaultName(for: agent.address) else {
            return agent.name
        }

        guard agent.address.count > 12 else {
            return trimmedName
        }

        return "\(agent.address.prefix(6))...\(agent.address.suffix(4))"
    }
}

struct SidebarConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let activityState: ConversationActivityState?
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: SidebarMetrics.sessionContentSpacing) {
                    Image(systemName: "message")
                        .imageScale(.medium)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: SidebarMetrics.sessionIconWidth)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(conversation.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        // Says what the red mark means.
                        if activityState == .failedDelivery {
                            Text("Message not sent")
                                .font(.caption2)
                                .foregroundStyle(OOColor.inkSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    ConversationActivityIndicator(state: activityState)
                }
                .padding(.leading, SidebarMetrics.sessionIndent)
            }
        }
        .buttonStyle(SidebarConversationButtonStyle(isSelected: isSelected))
        .listRowInsets(SidebarMetrics.conversationRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                onRename()
            } label: {
                sidebarContextMenuLabel("Rename", systemImage: "pencil", color: Color(.label))
            }
            .tint(Color(.label))

            Button(role: .destructive) {
                onDelete()
            } label: {
                sidebarContextMenuLabel("Delete", systemImage: "trash", color: AppTheme.destructive)
            }
            .tint(AppTheme.destructive)
        }
        .accessibilityAction(named: Text("Delete")) {
            onDelete()
        }
        .accessibilityAction(named: Text("Rename")) {
            onRename()
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

private struct ConversationActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: ConversationActivityState?

    var body: some View {
        ZStack {
            if let state {
                indicator(for: state)
                    .id(state)
                    .transition(AppMotion.statusTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(
            width: SidebarMetrics.activityIndicatorSlotSize,
            height: SidebarMetrics.activityIndicatorSlotSize
        )
        .animation(AppMotion.statusChange, value: state)
    }

    @ViewBuilder
    private func indicator(for state: ConversationActivityState) -> some View {
        switch state {
        case .actionRequired, .completedUnread:
            ConversationStatusDot(state: state)
        case .working:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Agent working")
        case .failedDelivery:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(.systemRed))
                .accessibilityLabel("Message failed to send")
        }
    }
}

private func sidebarContextMenuLabel(_ title: String, systemImage: String, color: Color) -> some View {
    Label {
        Text(title)
            .foregroundStyle(color)
    } icon: {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
    }
    .tint(color)
}
