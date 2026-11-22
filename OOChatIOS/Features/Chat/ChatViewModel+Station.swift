import ConnectOnionKit
import Foundation

extension ChatViewModel {
    /// Title of the conversation that carries a paired Claude Station session. Shown only; never used to find it.
    static let stationSessionTitle = "Claude Code session"
    private static let stationAddressesKey = "ClaudeStationAddresses"
    /// The paired Station session id by agent address, so the row reopens that conversation.
    private static let stationSessionsKey = "ClaudeStationSessions"

    /// Every agent a new chat can go to. A Claude Station is left out: a new chat there would
    /// be an ordinary chat, not the Station.
    var chattableAgents: [SavedAgent] {
        agents.filter { !isStation($0) }
    }

    /// Where the rail keeps your order of agents.
    static let railOrderKey = "agentRailOrder"

    /// The order you've dragged the rail into; empty until you first move a tile.
    var savedRailOrder: [String] {
        AgentRailOrder.decode(UserDefaults.standard.string(forKey: Self.railOrderKey) ?? "")
    }

    func saveRailOrder(_ ids: [String]) {
        objectWillChange.send()
        UserDefaults.standard.set(AgentRailOrder.encode(ids), forKey: Self.railOrderKey)
    }

    /// Every agent, in the order you've put them on the rail.
    var railAgents: [SavedAgent] {
        AgentRailOrder.ordered(agents, by: savedRailOrder)
    }

    /// The agent the pane shows.
    var paneAgent: SavedAgent? {
        currentAgentCandidates.first
    }

    /// Where New chat goes, from the pane or the nav bar: the pane's agent, unless that's a Station.
    var newChatAgent: SavedAgent? {
        currentAgentCandidates.first { !isStation($0) }
    }

    func pickOnRail(_ agent: SavedAgent) {
        railPick = RailPick(agentID: agent.id, activeAgentID: activeAgentID)
    }

    /// After New chat or a saved agent, the open chat's agent leads the pane again.
    func clearRailPick() {
        railPick = nil
    }

    /// The one picked on the rail, then the open chat's agent, then the rail from the top. A rail pick
    /// lasts while the open chat's agent stays the same, so opening another chat brings the pane with it.
    private var currentAgentCandidates: [SavedAgent] {
        var candidates: [SavedAgent] = []
        if let railPick, railPick.activeAgentID == activeAgentID,
           let picked = agents.first(where: { $0.id == railPick.agentID }) {
            candidates.append(picked)
        }
        if let activeAgent {
            candidates.append(activeAgent)
        }
        return candidates + railAgents
    }

    /// The profile arrives after CONNECTED, so the address is remembered to draw the row before the next connect.
    func isStation(_ agent: SavedAgent) -> Bool {
        let address = agent.address.lowercased()
        if agentProfilesByAddress[address]?.isClaudeStation == true {
            return true
        }
        return Self.rememberedStationAddresses().contains(address)
    }

    /// A `provider_station_only` refusal marks the agent a Station even when its profile does not.
    func noteStationHost(conversationID: String) {
        guard conversationState.workRoomStore(for: conversationID).isStationHost,
              let address = conversationState.conversation(withID: conversationID)?.agentAddress,
              !Self.rememberedStationAddresses().contains(address.lowercased()) else {
            return
        }
        Self.rememberStationAddress(address)
        objectWillChange.send()
    }

    static func rememberStation(_ profile: OIPAgentProfile, address: String) {
        if profile.isClaudeStation {
            rememberStationAddress(address)
        }
    }

    static func rememberStationAddress(_ address: String) {
        var addresses = rememberedStationAddresses()
        addresses.insert(address.lowercased())
        UserDefaults.standard.set(Array(addresses), forKey: stationAddressesKey)
    }

    static func rememberedStationAddresses() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: stationAddressesKey) ?? [])
    }

    static func rememberedStationSession(address: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: stationSessionsKey) as? [String: String])?[address.lowercased()]
    }

    static func rememberStationSession(_ sessionID: String, address: String) {
        var sessions = UserDefaults.standard.dictionary(forKey: stationSessionsKey) as? [String: String] ?? [:]
        sessions[address.lowercased()] = sessionID
        UserDefaults.standard.set(sessions, forKey: stationSessionsKey)
    }

    /// Selecting the row shows the paired session if there is one, else the agent's latest chat carries the pairing.
    func selectStation(_ agent: SavedAgent) {
        let own = conversations(for: agent)
        let paired = Self.rememberedStationSession(address: agent.address)
        if let conversation = own.first(where: { $0.id == paired }) ?? own.first {
            selectConversation(conversation)
        } else {
            _ = createConversation(for: agent)
        }
    }

    /// Reconnects under the paired session id. The store that holds the pairing moves with it.
    func openStationSession(_ sessionID: String, for agent: SavedAgent) {
        guard let current = activeConversationID, current != sessionID else {
            return
        }
        let session = conversation(withID: sessionID) ?? Conversation(
            id: sessionID,
            title: Self.stationSessionTitle,
            agentID: agent.id,
            agentAddress: agent.address,
            mode: .safe,
            createdAt: Date(),
            updatedAt: Date(),
            messages: [],
            serverSession: nil
        )
        Self.rememberStationSession(sessionID, address: agent.address)
        conversationState.upsert(session)
        conversationState.moveWorkRoomStore(from: current, to: sessionID)
        selectConversation(session)
        connectActiveConversationOnOpen()
    }
}

/// An agent picked on the rail, and the open chat's agent when it was picked.
struct RailPick: Equatable {
    let agentID: String
    let activeAgentID: String?
}
