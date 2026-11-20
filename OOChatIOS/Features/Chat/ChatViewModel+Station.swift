import ConnectOnionKit
import Foundation

extension ChatViewModel {
    /// Title of the conversation that carries a paired Claude Station session. Shown only; never used to find it.
    static let stationSessionTitle = "Claude Code session"
    private static let stationAddressesKey = "ClaudeStationAddresses"
    /// The paired Station session id by agent address, so the row reopens that conversation.
    private static let stationSessionsKey = "ClaudeStationSessions"

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
