import Combine
import Foundation
import ConnectOnionKit

// SkillLoadingCoordinator now uses the kit decoded profile skills instead of /info
@MainActor
final class SkillLoadingCoordinator: ObservableObject {
    @Published private var skillsByAgentAddress: [String: [AgentSkill]] = [:]

    func updateProfile(_ profile: OIPAgentProfile, for agentAddress: String) {
        let skills = profile.skills.map { skill in
            AgentSkill(
                name: skill.name,
                description: skill.description ?? "",
                location: skill.location
            )
        }

        skillsByAgentAddress[agentAddress.lowercased()] = skills
    }

    func suggestions(prompt: String, agentAddress: String?) -> [AgentSkill] {
        guard let query = slashQuery(in: prompt),
              let agentAddress else {
            return []
        }

        let skills = skillsByAgentAddress[agentAddress.lowercased()] ?? []

        guard !query.isEmpty else {
            return skills
        }

        let rankedNames = SkillSearch.rank(
            skills.map(\.name),
            query: query
        )

        return rankedNames.compactMap { name in
            skills.first { $0.name == name }
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
