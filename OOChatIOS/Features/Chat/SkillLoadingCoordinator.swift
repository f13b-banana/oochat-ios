import Combine
import Foundation

@MainActor
final class SkillLoadingCoordinator: ObservableObject {
    @Published private var skillsByAgentAddress: [String: [AgentSkill]] = [:]

    private var fetchTasksByAgentAddress: [String: Task<Void, Never>] = [:]
    private let transport: AgentMetadataProviding

    init(transport: AgentMetadataProviding) {
        self.transport = transport
    }

    deinit {
        fetchTasksByAgentAddress.values.forEach { $0.cancel() }
    }

    func suggestions(prompt: String, agentAddress: String?) -> [AgentSkill] {
        guard let query = slashQuery(in: prompt),
              let agentAddress else {
            return []
        }
        let skills = skillsByAgentAddress[agentAddress] ?? []
        guard !query.isEmpty else {
            return skills
        }
        return skills.filter {
            $0.name.range(
                of: query,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    func shouldShowSuggestions(prompt: String, agentAddress: String?) -> Bool {
        slashQuery(in: prompt) != nil && !suggestions(
            prompt: prompt,
            agentAddress: agentAddress
        ).isEmpty
    }

    func isSlashQuery(_ prompt: String) -> Bool {
        slashQuery(in: prompt) != nil
    }

    func loadSkillsIfNeeded(
        for agent: SavedAgent,
        isOffline: Bool,
        allowWhileOffline: Bool = false
    ) {
        let address = agent.address
        guard allowWhileOffline || !isOffline,
              HostedAgentClient.isHostedAgentAddress(address),
              skillsByAgentAddress[address] == nil,
              fetchTasksByAgentAddress[address] == nil else {
            return
        }

        let transport = transport
        fetchTasksByAgentAddress[address] = Task { [weak self, transport] in
            defer {
                self?.fetchTasksByAgentAddress[address] = nil
            }
            do {
                let skills = try await transport.fetchSkills(agentAddress: address)
                guard !Task.isCancelled else {
                    return
                }
                self?.skillsByAgentAddress[address] = skills.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            } catch {
                // Slash discovery is optional. Leave the command editable and retry
                // the next time the user invokes the picker.
            }
        }
    }

    func refreshSkills(for agent: SavedAgent) {
        skillsByAgentAddress[agent.address] = nil
        loadSkillsIfNeeded(for: agent, isOffline: false, allowWhileOffline: true)
    }

    private func slashQuery(in prompt: String) -> String? {
        guard prompt.hasPrefix("/") else {
            return nil
        }
        let query = String(prompt.dropFirst())
        guard !query.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        return query
    }
}
