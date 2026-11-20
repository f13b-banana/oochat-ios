import ConnectOnionKit
import SwiftUI

struct ChatSidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let safeAreaInsets: EdgeInsets
    let isSidebarOpen: Bool
    @Binding var isSearchFocused: Bool
    let selection: ChatSidebarSelection?
    let onSelectConversation: (Conversation) -> Void
    let onAddChat: (SavedAgent) -> Void
    let onConnected: () -> Void
    let onSettings: () -> Void
    /// Each change opens the Add Agent form (sent from the chat's empty state).
    var addAgentRequest = 0
    var onSelectStation: (SavedAgent) -> Void = { _ in }

    @State private var expandedAgentIDs = Set<String>()
    /// Agents whose whole chat list is showing, past the first few.
    @State private var showAllAgentIDs = Set<String>()
    @State private var deleteTarget: Conversation?
    @State private var conversationRenameTarget: Conversation?
    @State private var conversationRenameText = ""
    @State private var agentRenameTarget: SavedAgent?
    @State private var agentRenameText = ""
    @State private var agentDeleteTarget: SavedAgent?
    @State private var agentFormDraft: AgentFormDraft?
    @State private var qrCodeShareURL: URL?
    @State private var focusedAgentID: String?
    @State private var isSearchVisible = false
    @State private var sidebarSearchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        sheets(alerts(baseContent))
    }

    private var baseContent: some View {
        ZStack(alignment: .bottom) {
            sidebarList
                .contentMargins(
                    .bottom,
                    SidebarMetrics.footerOverlayHeight + safeAreaInsets.bottom,
                    for: .scrollContent
                )

            footer
        }
        .background {
            OOColor.surface
                .ignoresSafeArea()
        }
        .onAppear {
            if expandedAgentIDs.isEmpty {
                expandedAgentIDs = Set(viewModel.agents.prefix(1).map(\.id))
            }
            if let activeAgentID = viewModel.activeAgentID {
                expandedAgentIDs.insert(activeAgentID)
                focusedAgentID = activeAgentID
            } else {
                focusedAgentID = viewModel.agents.first?.id
            }
        }
        .onChange(of: viewModel.activeAgentID) {
            if let activeAgentID = viewModel.activeAgentID {
                expandedAgentIDs.insert(activeAgentID)
                focusedAgentID = activeAgentID
            }
        }
        .onChange(of: addAgentRequest) {
            beginAddingAgent()
        }
        .onChange(of: isSidebarOpen) {
            if !isSidebarOpen {
                resetSidebarSearch()
            }
        }
        .onChange(of: isSearchFieldFocused) {
            isSearchFocused = isSearchFieldFocused
        }
        .onChange(of: isSearchFocused) {
            if !isSearchFocused {
                isSearchFieldFocused = false
            }
        }
    }

    private func alerts(_ view: some View) -> some View {
        view
            .alert("Delete Chat", isPresented: isDeleting, presenting: deleteTarget) { conversation in
                Button("Delete", role: .destructive) {
                    viewModel.deleteConversation(conversation)
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteTarget = nil
                }
            } message: { conversation in
                Text("\"\(conversation.title)\" will be permanently deleted.")
            }
            .alert("Rename Chat", isPresented: isRenamingConversation, presenting: conversationRenameTarget) { conversation in
                TextField("Title", text: $conversationRenameText)
                Button("Cancel", role: .cancel) {
                    conversationRenameTarget = nil
                    conversationRenameText = ""
                }
                Button("Save") {
                    renameConversation(conversation)
                }
                .disabled(conversationRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { conversation in
                Text("Enter a new name for \(conversation.title).")
            }
            .alert("Rename Agent", isPresented: isRenamingAgent, presenting: agentRenameTarget) { agent in
                TextField("Name", text: $agentRenameText)
                Button("Cancel", role: .cancel) {
                    agentRenameTarget = nil
                    agentRenameText = ""
                }
                Button("Save") {
                    renameAgent(agent)
                }
                .disabled(agentRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { agent in
                Text("Enter a new name for \(agent.name).")
            }
            .alert("Delete Agent?", isPresented: isDeletingAgent, presenting: agentDeleteTarget) { agent in
                Button("Delete", role: .destructive) {
                    viewModel.deleteAgent(agent)
                    agentDeleteTarget = nil
                }
                Button("Cancel", role: .cancel) {
                    agentDeleteTarget = nil
                }
            } message: { agent in
                Text("This removes \(agent.name) and its chat sessions.")
            }
    }

    private func sheets(_ view: some View) -> some View {
        view
            .sheet(isPresented: isPresentingQRCodeShare) {
                if let qrCodeShareURL {
                    AgentQRCodeShareView(url: qrCodeShareURL)
                }
            }
            .sheet(item: $agentFormDraft) { draft in
                AgentFormView(draft: draft) { savedDraft in
                    saveAgentDraft(savedDraft)
                } onCancel: {
                    agentFormDraft = nil
                } fetchAgentName: { address in
                    await viewModel.fetchAgentName(for: address)
                }
            }
    }

    private var sidebarList: some View {
        List {
            header
                .listRowInsets(
                    EdgeInsets(
                        top: safeAreaInsets.top + SidebarMetrics.headerTopPadding,
                        leading: SidebarMetrics.compactRowLeading,
                        bottom: SidebarMetrics.headerTopPadding,
                        trailing: SidebarMetrics.compactRowTrailing
                    )
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            // A firmer line than between chats: actions above, agents and their chats below.
            OOColor.inkTertiary
                .opacity(0.5)
                .frame(height: 1)
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: SidebarMetrics.compactRowLeading,
                    bottom: 4,
                    trailing: SidebarMetrics.compactRowTrailing
                ))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityHidden(true)

            if viewModel.agents.isEmpty {
                Button(action: beginAddingAgent) {
                    Label("Add agent", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                        .frame(maxWidth: .infinity, minHeight: ooMinimumTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(SidebarMetrics.emptyRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if visibleAgents.isEmpty {
                Text("No matches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(SidebarMetrics.emptyRowInsets)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(visibleAgents) { agent in
                    agentRows(for: agent)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, SidebarMetrics.minimumRowHeight)
        .animation(
            AppMotion.stateChange(reduceMotion: reduceMotion),
            value: expandedAgentIDs
        )
    }

    private var searchQuery: String {
        ChatSidebarSearch.query(from: sidebarSearchText)
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    private var visibleAgents: [SavedAgent] {
        ChatSidebarSearch.visibleAgents(agents: viewModel.agents, query: searchQuery) { agent in
            matchingConversations(for: agent, query: searchQuery)
        }
    }

    private var header: some View {
        ChatSidebarHeaderView(
            isSearchVisible: isSearchVisible,
            searchText: $sidebarSearchText,
            searchFieldFocus: $isSearchFieldFocused,
            attentionItems: attentionItems,
            onOpenChat: { conversation in
                focusedAgentID = conversation.agentID
                onSelectConversation(conversation)
            },
            newChatAgentName: newChatAgent.map(displayName),
            onNewChat: startNewChat,
            onToggleSearch: toggleSidebarSearch
        )
    }

    /// Counted across every agent, so folding one never hides a chat that needs you.
    private var attentionItems: [SidebarAttentionItem] {
        viewModel.agents.flatMap { agent in
            viewModel.conversations(for: agent).compactMap { conversation -> SidebarAttentionItem? in
                guard let status = viewModel.sidebarStatus(forConversationID: conversation.id),
                      status.needsYou else {
                    return nil
                }
                return SidebarAttentionItem(conversation: conversation, agentName: displayName(agent), status: status)
            }
        }
    }

    private func needsYou(_ agent: SavedAgent) -> Bool {
        viewModel.conversations(for: agent).contains {
            viewModel.sidebarStatus(forConversationID: $0.id)?.needsYou == true
        }
    }

    /// The current agent; with none chosen yet, the first one. Never a Claude Station: a new
    /// chat there would be an ordinary chat, not the Station.
    private var newChatAgent: SavedAgent? {
        let chattable = viewModel.agents.filter { !viewModel.isStation($0) }
        return chattable.first { $0.id == viewModel.activeAgentID } ?? chattable.first
    }

    private func displayName(_ agent: SavedAgent) -> String {
        SidebarAgentRow.displayName(for: agent)
    }

    /// With no agents, New chat adds one instead.
    private func startNewChat() {
        guard let agent = newChatAgent else {
            beginAddingAgent()
            return
        }
        expandedAgentIDs.insert(agent.id)
        onAddChat(agent)
    }

    private var footer: some View {
        ChatSidebarFooterView(
            safeAreaInsets: safeAreaInsets,
            onAddAgent: beginAddingAgent,
            onSettings: onSettings
        )
    }

    @ViewBuilder
    private func agentRows(for agent: SavedAgent) -> some View {
        agentRow(for: agent)
            .listRowInsets(SidebarMetrics.agentRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

        if expandedAgentIDs.contains(agent.id) || isSearching {
            let conversations = visibleConversations(for: agent)
            let isShowingAll = isSearching || showAllAgentIDs.contains(agent.id)
            let shown = isShowingAll ? conversations : firstChats(of: conversations)
            if !conversations.isEmpty {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, conversation in
                    conversationButton(conversation, showsSeparator: index < shown.count - 1)
                        .transition(AppMotion.disclosure(reduceMotion: reduceMotion))
                }
                if !isSearching && conversations.count > SidebarMetrics.chatsBeforeShowAll {
                    showAllButton(for: agent, total: conversations.count)
                }
            }
        }
    }

    /// The first few chats, plus the open one when it's further down: opening an older chat
    /// from the attention panel must not highlight a row you can't see.
    private func firstChats(of conversations: [Conversation]) -> [Conversation] {
        var shown = Array(conversations.prefix(SidebarMetrics.chatsBeforeShowAll))
        if case .conversation(let selectedID)? = selection,
           !shown.contains(where: { $0.id == selectedID }),
           let selected = conversations.first(where: { $0.id == selectedID }) {
            shown.append(selected)
        }
        return shown
    }

    /// "Show all (n)" opens the rest; "Show less" folds back to the first five, as on the Mac.
    private func showAllButton(for agent: SavedAgent, total: Int) -> some View {
        let isShowingAll = showAllAgentIDs.contains(agent.id)
        return Button {
            withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                if isShowingAll {
                    showAllAgentIDs.remove(agent.id)
                } else {
                    showAllAgentIDs.insert(agent.id)
                }
            }
        } label: {
            Text(isShowingAll ? "Show less" : "Show all (\(total))")
                .font(.subheadline)
                .foregroundStyle(OOColor.inkSecondary)
                .padding(.leading, OOSidebarMetrics.chatIndent)
                .frame(maxWidth: .infinity, minHeight: OOSidebarMetrics.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(SidebarMetrics.conversationRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// A chat is listed once it has a message; an empty one only while it's the open chat.
    private func listedConversations(for agent: SavedAgent) -> [Conversation] {
        viewModel.conversations(for: agent).filter {
            !$0.messages.isEmpty || selection == .conversation($0.id)
        }
    }

    private func visibleConversations(for agent: SavedAgent) -> [Conversation] {
        let conversations = listedConversations(for: agent)
        guard isSearching else {
            return conversations
        }

        return matchingConversations(for: agent, query: searchQuery)
    }

    private func matchingConversations(for agent: SavedAgent, query: String) -> [Conversation] {
        viewModel.searchConversations(query, for: agent)
    }

    private func toggleSidebarSearch() {
        let shouldShowSearch = !isSearchVisible
        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
            isSearchVisible = shouldShowSearch
            if !shouldShowSearch {
                sidebarSearchText = ""
            }
        }

        if shouldShowSearch {
            DispatchQueue.main.async {
                isSearchFieldFocused = true
                isSearchFocused = true
            }
        } else {
            resetSidebarSearch()
        }
    }

    private func resetSidebarSearch() {
        isSearchVisible = false
        sidebarSearchText = ""
        isSearchFieldFocused = false
        isSearchFocused = false
    }

    private func agentRow(for agent: SavedAgent) -> some View {
        SidebarAgentRow(
            agent: agent,
            isExpanded: expandedAgentIDs.contains(agent.id),
            isOnline: viewModel.isAgentOnline(agent),
            chatCount: listedConversations(for: agent).count,
            needsYou: needsYou(agent),
            isCurrent: agent.id == newChatAgent?.id,
            onToggle: {
                if viewModel.isStation(agent) {
                    focusedAgentID = agent.id
                    onSelectStation(agent)
                } else {
                    toggleAgent(agent)
                }
            },
            onRename: {
                beginRenaming(agent)
            },
            onEdit: {
                beginEditing(agent)
            },
            onAddChat: {
                focusedAgentID = agent.id
                expandedAgentIDs.insert(agent.id)
                onAddChat(agent)
            },
            onShowQRCode: { shareURL in
                qrCodeShareURL = shareURL
            },
            onDelete: {
                agentDeleteTarget = agent
            },
            isStation: viewModel.isStation(agent)
        )
    }

    private func conversationButton(_ conversation: Conversation, showsSeparator: Bool) -> some View {
        SidebarConversationRow(
            conversation: conversation,
            isSelected: selection == .conversation(conversation.id),
            activityState: viewModel.activityState(forConversationID: conversation.id),
            status: viewModel.sidebarStatus(forConversationID: conversation.id),
            showsSeparator: showsSeparator,
            onSelect: {
                focusedAgentID = conversation.agentID
                onSelectConversation(conversation)
            },
            onRename: {
                beginRenaming(conversation)
            },
            onDelete: {
                deleteTarget = conversation
            }
        )
    }

    private func toggleAgent(_ agent: SavedAgent) {
        focusedAgentID = agent.id
        // Nothing to unfold: tapping an agent with no chats starts one (audit UI-015).
        if listedConversations(for: agent).isEmpty {
            expandedAgentIDs.insert(agent.id)
            onAddChat(agent)
            return
        }
        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
            if expandedAgentIDs.contains(agent.id) {
                expandedAgentIDs.remove(agent.id)
            } else {
                expandedAgentIDs.insert(agent.id)
            }
        }
    }

    private func beginRenaming(_ agent: SavedAgent) {
        focusedAgentID = agent.id
        agentRenameText = agent.name
        agentRenameTarget = agent
    }

    private func beginAddingAgent() {
        agentFormDraft = AgentFormDraft()
    }

    private func beginEditing(_ agent: SavedAgent) {
        focusedAgentID = agent.id
        agentFormDraft = AgentFormDraft(agent: agent)
    }

    private func saveAgentDraft(_ savedDraft: AgentFormDraft) -> Bool {
        let isNewAgent = savedDraft.agentID == nil
        guard let agent = viewModel.saveAgent(
            id: savedDraft.agentID,
            name: savedDraft.name,
            address: savedDraft.address
        ) else {
            return false
        }

        focusedAgentID = agent.id
        expandedAgentIDs.insert(agent.id)
        agentFormDraft = nil

        if savedDraft.shouldConnectAfterSave {
            connect(agent)
        } else if isNewAgent {
            viewModel.switchToAgentForChat(agent)
            onConnected()
        }

        return true
    }

    private func connect(_ agent: SavedAgent) {
        focusedAgentID = agent.id
        expandedAgentIDs.insert(agent.id)
        viewModel.selectAgent(agent)

        Task { @MainActor in
            if await viewModel.connectToAgent() != nil {
                onConnected()
            }
        }
    }

    private func renameAgent(_ agent: SavedAgent) {
        let trimmedName = agentRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            agentRenameTarget = nil
            agentRenameText = ""
        }

        guard !trimmedName.isEmpty else {
            return
        }

        _ = viewModel.saveAgent(
            id: agent.id,
            name: trimmedName,
            address: agent.address
        )
    }

    private func beginRenaming(_ conversation: Conversation) {
        focusedAgentID = conversation.agentID
        conversationRenameText = conversation.title
        conversationRenameTarget = conversation
    }

    private func renameConversation(_ conversation: Conversation) {
        let trimmedTitle = conversationRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            conversationRenameTarget = nil
            conversationRenameText = ""
        }

        guard !trimmedTitle.isEmpty else {
            return
        }

        viewModel.renameConversation(conversation, to: trimmedTitle)
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var isRenamingConversation: Binding<Bool> {
        Binding(
            get: { conversationRenameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    conversationRenameTarget = nil
                    conversationRenameText = ""
                }
            }
        )
    }

    private var isRenamingAgent: Binding<Bool> {
        Binding(
            get: { agentRenameTarget != nil },
            set: { isPresented in
                if !isPresented {
                    agentRenameTarget = nil
                    agentRenameText = ""
                }
            }
        )
    }

    private var isDeletingAgent: Binding<Bool> {
        Binding(get: { agentDeleteTarget != nil }, set: { if !$0 { agentDeleteTarget = nil } })
    }

    private var isPresentingQRCodeShare: Binding<Bool> {
        Binding(
            get: { qrCodeShareURL != nil },
            set: { isPresented in
                if !isPresented {
                    qrCodeShareURL = nil
                }
            }
        )
    }
}
