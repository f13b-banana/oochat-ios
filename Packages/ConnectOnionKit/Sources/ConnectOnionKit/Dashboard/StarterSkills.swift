import Foundation

/// The skills a new chat offers as starters.
///
/// Skills the agent's Control Center buttons use come first, in the order the page names them,
/// then the rest in the profile's order. Only the agent's own skills are returned, so the page
/// (agent-authored, untrusted) can reorder skills but never add a name the agent doesn't have.
public enum StarterSkills {
    public static func ordered(_ skills: [OIPAgentSkill], dashboard: OIPDashboard?) -> [OIPAgentSkill] {
        let used = dashboardSkillNames(dashboard)
        guard !used.isEmpty else {
            return skills
        }

        let byName = Dictionary(skills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let first = used.compactMap { byName[$0] }
        let firstNames = Set(first.map(\.name))
        return first + skills.filter { !firstNames.contains($0.name) }
    }

    /// The `data-ochat-skill` names on the page, each once, in the order they first appear.
    static func dashboardSkillNames(_ dashboard: OIPDashboard?) -> [String] {
        guard case .page(let html)? = dashboard, let pattern = skillAttribute else {
            return []
        }

        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var names: [String] = []
        for match in pattern.matches(in: html, range: range) {
            let quoted = [1, 2].lazy
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
            guard let quoted, let swiftRange = Range(quoted, in: html) else {
                continue
            }
            let name = String(html[swiftRange])
            if !name.isEmpty, seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    // data-ochat-skill="name" or data-ochat-skill='name', the attribute the bridge script reads.
    private static let skillAttribute = try? NSRegularExpression(
        pattern: #"data-ochat-skill\s*=\s*(?:"([^"]*)"|'([^']*)')"#
    )
}
