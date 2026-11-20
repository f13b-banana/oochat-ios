import ConnectOnionKit
import SwiftUI

/// A chat that needs you, for the list under the attention line.
struct SidebarAttentionItem: Identifiable, Equatable {
    let conversation: Conversation
    let agentName: String
    let status: SidebarChatStatus

    var id: String { conversation.id }
}

/// The top of the drawer: New chat and Search as plain rows, the search field when open, and
/// one amber line whenever a chat needs you. No brand, no online count (spec D8).
struct ChatSidebarHeaderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isSearchVisible: Bool
    @Binding var searchText: String
    let searchFieldFocus: FocusState<Bool>.Binding
    /// Chats waiting on approval or with a message that didn't send, across every agent.
    var attentionItems: [SidebarAttentionItem] = []
    var onOpenChat: (Conversation) -> Void = { _ in }
    /// The agent a new chat goes to, shown on the row so the target is never a guess.
    var newChatAgentName: String?
    let onNewChat: () -> Void
    let onToggleSearch: () -> Void
    @State private var isAttentionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            newChatRow
            actionRow(
                isSearchVisible ? "Close search" : "Search",
                systemImage: isSearchVisible ? "xmark" : "magnifyingglass",
                action: onToggleSearch
            )

            if isSearchVisible {
                SidebarSearchField(text: $searchText, focus: searchFieldFocus)
                    .padding(.vertical, OOSpace.tiny)
                    .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
            }

            attention
        }
        .onChange(of: attentionItems.count) { _, count in
            if count < 2 {
                isAttentionExpanded = false
            }
        }
    }

    // One chat: the line opens it. Several: the amber panel opens to list them, so the chats
    // plainly belong to the line (impeccable: contain it, rather than an accent stripe).
    @ViewBuilder
    private var attention: some View {
        if let summary = SidebarAttention.summary(attentionItems.map(\.status)) {
            let listsChats = attentionItems.count > 1
            VStack(spacing: 0) {
                Button {
                    if listsChats {
                        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                            isAttentionExpanded.toggle()
                        }
                    } else if let item = attentionItems.first {
                        onOpenChat(item.conversation)
                    }
                } label: {
                    OOSidebarAttentionLine(
                        summary,
                        isExpanded: listsChats ? isAttentionExpanded : nil,
                        drawsBackground: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(listsChats ? "Lists the chats" : "Opens the chat")

                // Always present and clipped: on close the chats slide up into the line and are
                // cut off under it, rather than fading where they stand.
                VStack(spacing: 0) {
                    if listsChats && isAttentionExpanded {
                        OOColor.decisionLine
                            .frame(height: 1)
                            .accessibilityHidden(true)
                        VStack(spacing: 0) {
                            ForEach(Array(attentionItems.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    onOpenChat(item.conversation)
                                } label: {
                                    OOSidebarChatRow(
                                        title: item.conversation.isUntitled ? Conversation.defaultTitle : item.conversation.title,
                                        lastActivity: nil,
                                        status: item.status,
                                        preview: item.agentName,
                                        indent: OOSidebarMetrics.horizontalPadding + 24
                                    )
                                }
                                .buttonStyle(.plain)
                                if index < attentionItems.count - 1 {
                                    OOColor.decisionLine
                                        .opacity(0.6)
                                        .frame(height: 1)
                                        .padding(.leading, OOSidebarMetrics.horizontalPadding + 24)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .padding(.vertical, OOSpace.tiny)
                        .transition(reduceMotion ? .opacity : .move(edge: .top))
                    }
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .background(
                OOColor.decisionFill,
                in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
            )
            .padding(.top, OOSpace.small)
            .transition(AppMotion.materialize(reduceMotion: reduceMotion, edge: .top))
        }
    }

    // The one action the drawer exists for: a green symbol and a heavier label make it the
    // first thing found, without the weight of a filled button.
    private var newChatRow: some View {
        Button(action: onNewChat) {
            HStack(spacing: OOSpace.medium) {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(OOColor.primary)
                    .frame(width: 22)
                // "New chat (PCAgent)": the agent the same size, only grey and regular weight.
                HStack(alignment: .firstTextBaseline, spacing: OOSpace.tiny + 2) {
                    Text("New chat")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(OOColor.ink)
                        .layoutPriority(1)
                    if let newChatAgentName {
                        Text("(\(newChatAgentName))")
                            .font(.body)
                            .foregroundStyle(OOColor.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterButtonStyle())
        .accessibilityLabel(newChatAgentName.map { "New chat with \($0)" } ?? "New chat")
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: OOSpace.medium) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(OOColor.inkSecondary)
                    .frame(width: 22)
                Text(title)
                    .font(.body)
                    .foregroundStyle(OOColor.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
            .frame(minHeight: OOSidebarMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarFooterButtonStyle())
    }
}

struct SidebarSearchField: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: SidebarMetrics.searchFieldSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.secondaryLabel))

            TextField("Search", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(focus)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: SidebarMetrics.searchClearButtonSize, height: SidebarMetrics.searchClearButtonSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, SidebarMetrics.searchFieldHorizontalPadding)
        .frame(height: SidebarMetrics.searchFieldHeight)
        .background(Color(.secondarySystemFill), in: Capsule())
        .accessibilityElement(children: .contain)
    }
}

struct SidebarIconButtonLabel: View {
    let systemName: String
    let foregroundColor: Color
    let size: CGFloat
    let font: Font

    var body: some View {
        Image(systemName: systemName)
            .font(font)
            .foregroundStyle(foregroundColor)
            .frame(width: size, height: size)
            .glassBackground(
                in: Circle(),
                interactive: true,
                tint: Color(.systemBackground),
                fallback: Color(.tertiarySystemFill)
            )
            .overlay {
                Circle()
                    .stroke(Color(.separator).opacity(SidebarMetrics.settingsButtonStrokeOpacity), lineWidth: 0.5)
            }
    }
}
