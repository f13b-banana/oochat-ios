import ConnectOnionKit
import SwiftUI

/// The sidebar, as on the Mac: the agent rail, then the pane for the agent picked on it. On a
/// phone, picking an agent only turns the pane to it; the chat changes when you pick one of its
/// chats, so the drawer never swaps what's behind it unseen. Beside the chat (iPad), picking an
/// agent opens its latest chat, as the Mac does.
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
    /// Beside the chat, picking an agent on the rail opens its latest chat.
    var opensLatestChatOnPick = false
    var onOpenWorkRoom: (String) -> Void = { _ in }
    /// Back to the chat, after a skill is put in its message box.
    var onShowChat: () -> Void = {}
    var controlCenterTitle: String?
    var onShowControlCenter: () -> Void = {}

    /// The agent picked on the rail, kept only while the open chat's agent stays the same, so a
    /// new open chat brings the pane with it in the same update.
    @State private var railPick: RailPick?
    @AppStorage("agentRailOrder") private var railOrder = ""
    @State private var isChatsExpanded = true
    @State private var isRoomsExpanded = true
    /// Folded at first: skills are occasional, chats are the point.
    @State private var isSkillsExpanded = false
    @State private var showsAllSkills = false
    @State private var showsAllChats = false
    @State private var deleteTarget: Conversation?
    @State private var conversationRenameTarget: Conversation?
    @State private var conversationRenameText = ""
    @State private var agentRenameTarget: SavedAgent?
    @State private var agentRenameText = ""
    @State private var agentDeleteTarget: SavedAgent?
    @State private var agentFormDraft: AgentFormDraft?
    @State private var qrCodeShareURL: URL?
    @State private var isSearchVisible = false
    @State private var sidebarSearchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        sheets(alerts(baseContent))
    }

    private var baseContent: some View {
        HStack(spacing: 0) {
            AgentRail(
                viewModel: viewModel,
                agents: railAgents,
                selectedID: paneAgent?.id,
                safeAreaInsets: safeAreaInsets,
                actions: railActions
            )
            VStack(spacing: 0) {
                paneContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(OOColor.surface)
        }
        // A different agent starts with its search closed and its chats folded back to five.
        .onChange(of: paneAgent?.id) {
            resetSidebarSearch()
            showsAllChats = false
        }
        // A removed agent leaves the saved order; a new one joins it at the end.
        .onChange(of: viewModel.agents.map(\.id)) {
            if !railOrder.isEmpty {
                railOrder = AgentRailOrder.encode(railAgents.map(\.id))
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

    /// Every agent, in the order you've put them on the rail.
    private var railAgents: [SavedAgent] {
        AgentRailOrder.ordered(viewModel.agents, by: AgentRailOrder.decode(railOrder))
    }

    /// The one picked on the rail, else the open chat's, else the first.
    private var paneAgent: SavedAgent? {
        let agents = viewModel.agents
        if let railPick, railPick.activeAgentID == viewModel.activeAgentID,
           let picked = agents.first(where: { $0.id == railPick.agentID }) {
            return picked
        }
        return agents.first { $0.id == viewModel.activeAgentID } ?? railAgents.first
    }

    private var railActions: AgentRailActions {
        AgentRailActions(
            pick: pick,
            newChat: { agent in
                railPick = nil
                if viewModel.isStation(agent) {
                    onSelectStation(agent)
                } else {
                    onAddChat(agent)
                }
            },
            move: { id, targetID in
                railOrder = AgentRailOrder.encode(AgentRailOrder.moving(id, to: targetID, in: railAgents.map(\.id)))
            },
            step: { id, step in
                railOrder = AgentRailOrder.encode(AgentRailOrder.moving(id, by: step, in: railAgents.map(\.id)))
            },
            addAgent: beginAddingAgent,
            settings: onSettings
        )
    }

    /// A Station opens at once: it has no chats to pick from.
    private func pick(_ agent: SavedAgent) {
        railPick = RailPick(agentID: agent.id, activeAgentID: viewModel.activeAgentID)
        if viewModel.isStation(agent) {
            onSelectStation(agent)
            return
        }
        guard opensLatestChatOnPick, viewModel.activeAgentID != agent.id else {
            return
        }
        if let latest = listedConversations(for: agent).first {
            onSelectConversation(latest)
        } else {
            onAddChat(agent)
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
                Text("Deleting \"\(conversation.title)\" also deletes its messages and keeps its server record hidden on this device.")
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

    @ViewBuilder
    private var paneContent: some View {
        if let agent = paneAgent {
            AgentPaneHeader(
                agent: agent,
                isOnline: viewModel.isAgentOnline(agent),
                isStation: viewModel.isStation(agent),
                actions: AgentPaneHeaderActions(
                    rename: beginRenaming,
                    edit: beginEditing,
                    showQRCode: { qrCodeShareURL = $0 },
                    delete: { agentDeleteTarget = $0 }
                ),
                topInset: safeAreaInsets.top
            )
            OOColor.hairline
                .frame(height: 1)
                .accessibilityHidden(true)
            paneList(agent)
        } else {
            emptyPane
        }
    }

    /// No agents yet: the pane says what to do, and its button is the rail's ＋ spelled out.
    private var emptyPane: some View {
        VStack(alignment: .leading, spacing: OOSpace.medium) {
            Text("Add an agent by its address to start chatting.")
                .font(.subheadline)
                .foregroundStyle(OOColor.inkSecondary)
            Button(action: beginAddingAgent) {
                Label("Add agent", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OOColor.onPrimary)
                    .padding(.horizontal, OOSpace.medium)
                    .frame(height: 34)
                    .background(
                        OOColor.primary,
                        in: RoundedRectangle(cornerRadius: OOSidebarMetrics.rowCornerRadius, style: .continuous)
                    )
                    .frame(minHeight: ooMinimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarFooterButtonStyle())
        }
        .padding(.horizontal, OOSpace.medium)
        .padding(.top, safeAreaInsets.top + AgentRail.headerHeight + OOSpace.medium)
    }

    private func paneList(_ agent: SavedAgent) -> some View {
        List {
            if viewModel.isStation(agent) {
                stationRows(agent)
            } else {
                header(for: agent)
                    .paneRow(top: OOSpace.small)
                if let state = viewModel.restoreStates[agent.id] {
                    Text(Self.restoreCaption(state))
                        .font(.caption)
                        .foregroundStyle(OOColor.inkSecondary)
                        .padding(.horizontal, OOSidebarMetrics.horizontalPadding)
                        .paneRow(top: OOSpace.tiny)
                }
                chatsSection(agent)
            }
            if agent.id == viewModel.activeAgentID, !viewModel.isStation(agent),
               let conversationID = viewModel.activeConversationID {
                agentSections(conversationID: conversationID)
            }
        }
        .refreshable { await viewModel.refreshHistory() }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, safeAreaInsets.bottom + OOSpace.medium, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, SidebarMetrics.minimumRowHeight)
    }

    @ViewBuilder
    private func stationRows(_ agent: SavedAgent) -> some View {
        AgentPaneSectionHeader(title: "Station")
            .paneRow(top: OOSpace.small)
        AgentPaneActionRow(title: "Open Station", systemImage: "terminal", isProminent: true) {
            onSelectStation(agent)
        }
        .paneRow()
    }

    /// What the open chat offers, under its agent's chats: its Work Rooms, its skills (tap one to put
    /// it in the composer) and the agent's Control Center. Only for the open chat's agent, because
    /// these belong to a live connection. Rows of this list, not a view of their own, so the list
    /// diffs them like the chats when the open chat changes.
    @ViewBuilder
    private func agentSections(conversationID: String) -> some View {
        let rooms = viewModel.conversationState.existingWorkRoomStore(for: conversationID)?.workRooms ?? []
        if !rooms.isEmpty {
            foldingHeader("Work Rooms", isExpanded: $isRoomsExpanded)
            if isRoomsExpanded {
                ForEach(rooms) { room in
                    AgentPaneActionRow(title: room.displayTitle, systemImage: "terminal") {
                        onOpenWorkRoom(room.id)
                    }
                    .paneRow()
                }
            }
        }
        if let skills = viewModel.activeAgentSkills, !skills.isEmpty {
            foldingHeader("Skills", isExpanded: $isSkillsExpanded)
            if isSkillsExpanded {
                skillRows(skills)
            }
        }
        AgentPaneSectionHeader(title: "Agent")
            .paneRow(top: OOSpace.small)
        if viewModel.activeDashboard != nil, let controlCenterTitle {
            AgentPaneActionRow(title: controlCenterTitle, systemImage: "square.grid.2x2", action: onShowControlCenter)
                .paneRow()
        }
        AgentPaneActionRow(title: "Refresh dashboard", systemImage: "arrow.clockwise", action: refreshDashboard)
            .accessibilityHint("Reconnects to the agent, which sends its dashboard again")
            .paneRow()
    }

    @ViewBuilder
    private func skillRows(_ skills: [OIPAgentSkill]) -> some View {
        let shown = showsAllSkills ? skills : Array(skills.prefix(Self.skillsBeforeShowAll))
        ForEach(shown, id: \.name) { skill in
            AgentPaneActionRow(title: "/\(skill.name)", systemImage: "sparkle") {
                viewModel.prompt = "/\(skill.name) "
                onShowChat()
            }
            .accessibilityHint(skill.description ?? "Puts the skill in the message box")
            .paneRow()
        }
        // The first four, then "Show all (n)" / "Show less", as the chats do.
        if skills.count > Self.skillsBeforeShowAll {
            AgentPaneShowAllRow(isShowingAll: showsAllSkills, total: skills.count, indent: 0) {
                withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                    showsAllSkills.toggle()
                }
            }
            .paneRow()
        }
    }

    private func foldingHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        AgentPaneSectionHeader(title: title, isExpanded: isExpanded.wrappedValue) {
            withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                isExpanded.wrappedValue.toggle()
            }
        }
        .paneRow(top: OOSpace.small)
    }

    private func refreshDashboard() {
        Task {
            await viewModel.reconnect()
        }
    }

    static let skillsBeforeShowAll = 4

    @ViewBuilder
    private func chatsSection(_ agent: SavedAgent) -> some View {
        let listed = listedConversations(for: agent)
        let conversations = visibleConversations(for: agent)
        let isExpanded = isSearching || isChatsExpanded
        // No chats yet: no section, as New chat sits right above (no filler under an empty agent).
        if !listed.isEmpty || isSearching {
            chatsList(listed: listed, conversations: conversations, isExpanded: isExpanded)
        }
    }

    @ViewBuilder
    private func chatsList(listed: [Conversation], conversations: [Conversation], isExpanded: Bool) -> some View {
        // Searching opens the section and lists every match, so the header doesn't fold it then.
        AgentPaneSectionHeader(
            title: listed.isEmpty ? "Chats" : "Chats · \(listed.count)",
            isExpanded: isExpanded,
            toggle: isSearching ? nil : toggleChats
        )
        .paneRow(top: OOSpace.small)
        if isExpanded {
            if conversations.isEmpty {
                Text("No matches")
                    .font(.subheadline)
                    .foregroundStyle(OOColor.inkTertiary)
                    .padding(.leading, OOSidebarMetrics.horizontalPadding)
                    .frame(maxWidth: .infinity, minHeight: OOSidebarMetrics.rowHeight, alignment: .leading)
                    .paneRow()
            }
            let shown = isSearching || showsAllChats ? conversations : firstChats(of: conversations)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, conversation in
                conversationButton(conversation, showsSeparator: index < shown.count - 1)
                    .transition(AppMotion.disclosure(reduceMotion: reduceMotion))
            }
            if !isSearching && conversations.count > SidebarMetrics.chatsBeforeShowAll {
                AgentPaneShowAllRow(
                    isShowingAll: showsAllChats,
                    total: conversations.count,
                    indent: OOSidebarMetrics.horizontalPadding
                ) {
                    withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
                        showsAllChats.toggle()
                    }
                }
                .paneRow()
            }
        }
    }

    private func toggleChats() {
        withAnimation(AppMotion.stateChange(reduceMotion: reduceMotion)) {
            isChatsExpanded.toggle()
        }
    }

    private var searchQuery: String {
        ChatSidebarSearch.query(from: sidebarSearchText)
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    private func header(for agent: SavedAgent) -> some View {
        ChatSidebarHeaderView(
            isSearchVisible: isSearchVisible,
            searchText: $sidebarSearchText,
            searchFieldFocus: $isSearchFieldFocused,
            attentionItems: attentionItems(for: agent),
            onOpenChat: onSelectConversation,
            onNewChat: { onAddChat(agent) },
            onToggleSearch: toggleSidebarSearch,
            agentID: agent.id
        )
    }

    /// Only this agent's chats: the ✋ on another agent's tile says where else you're needed.
    private func attentionItems(for agent: SavedAgent) -> [SidebarAttentionItem] {
        viewModel.conversations(for: agent).compactMap { conversation -> SidebarAttentionItem? in
            guard let status = viewModel.sidebarStatus(forConversationID: conversation.id),
                  status.needsYou else {
                return nil
            }
            return SidebarAttentionItem(conversation: conversation, status: status)
        }
    }

    static func restoreCaption(_ state: RestoreState) -> String {
        switch state {
        case .restored: return "History restored"
        case .pending: return "History pending: agent unreachable"
        case .failed: return "Couldn't restore history"
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

    private func conversationButton(_ conversation: Conversation, showsSeparator: Bool) -> some View {
        SidebarConversationRow(
            conversation: conversation,
            isSelected: selection == .conversation(conversation.id),
            activityState: viewModel.activityState(forConversationID: conversation.id),
            isFromPreviousIdentity: viewModel.isFromPreviousIdentity(conversation),
            status: viewModel.sidebarStatus(forConversationID: conversation.id),
            showsSeparator: showsSeparator,
            indent: OOSidebarMetrics.horizontalPadding,
            onSelect: {
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

    private func beginRenaming(_ agent: SavedAgent) {
        agentRenameText = agent.name
        agentRenameTarget = agent
    }

    private func beginAddingAgent() {
        agentFormDraft = AgentFormDraft()
    }

    private func beginEditing(_ agent: SavedAgent) {
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

        railPick = nil
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
        railPick = nil
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

/// An agent picked on the rail, and the open chat's agent when it was picked.
private struct RailPick: Equatable {
    let agentID: String
    let activeAgentID: String?
}
